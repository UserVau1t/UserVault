pragma solidity ^0.8.30;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregateRangeTree as T} from "./AggregateRangeTree.sol";
import {AggregateShares as A} from "./AggregateShares.sol";
import {ReferencePriceMath as P} from "contracts/libraries/ReferencePriceMath.sol";
library AggregateRangeAccounting {
    using T for T.Book;using A for A.Epoch;
    uint256 internal constant SCALE=1e27;
    struct Level {uint256 current;mapping(uint256=>A.Epoch) epochs;}
    struct Market {T.Book tree;mapping(uint256=>Level) levels;uint256 revision;}
    struct Slot {uint256 epoch;A.Account account;}
    struct Order {
        address owner;address base;address quote;bool sell;uint8 decimals;uint16 steps;
        uint256 lower;uint256 upper;uint256 total;uint256 withdrawn;uint256 claimed;uint256 revision;uint256 directAccrued;
        mapping(uint16=>Slot) slots;
    }
    struct State {
        mapping(bytes32=>Market) markets;
        mapping(uint256=>Order) orders;
        mapping(address=>mapping(address=>uint256)) credit;
    }
    error InvalidOrder();error InvalidBucket();error InvalidAmount();error Ineligible();
    function marketKey(address base,address quote,bool sell) internal pure returns(bytes32){return keccak256(abi.encode(base,quote,sell));}
    function priceKey(bool sell,uint256 price) private pure returns(uint256){return sell?price:~price;}
    function level(Order storage o,uint16 index) internal view returns(uint256){
        if(o.owner==address(0)||index>=o.steps)revert InvalidBucket();
        return o.steps==1?o.lower:o.lower+Math.mulDiv(o.upper-o.lower,index,o.steps-1);
    }
    function _sync(Market storage m,uint256 key) private {
        (,uint256 inventory,uint256 proceeds)=m.tree.takeProceeds(key);Level storage l=m.levels[key];
        l.epochs[l.current].syncFromTree(inventory,proceeds);
    }
    function _threshold(bool sell,uint8 decimals,P.Ratio memory usd) private pure returns(uint256 threshold,bool empty){
        uint256 unit=10**decimals;
        if(P.atLeast(unit,usd,type(uint256).max)){
            if(sell)return(type(uint256).max,false);
            if(!P.atMost(unit,usd,type(uint256).max))return(0,true);
            return(0,false);
        }
        uint256 boundary=Math.mulDiv(unit,usd.n,usd.d,sell?Math.Rounding.Floor:Math.Rounding.Ceil);
        return(priceKey(sell,boundary),false);
    }
    function open(State storage s,uint256 id,address owner,address base,address quote,bool sell,uint8 decimals,
        uint256 amount,uint256 lower,uint256 upper,uint16 steps) internal {
        if(steps==0||steps>128)revert InvalidOrder();
        uint256[] memory amounts=new uint256[](steps);
        for(uint16 i;i<steps;i++)amounts[i]=amount/steps+(i==steps-1?amount%steps:0);
        openAfterMatch(s,id,owner,base,quote,sell,decimals,amount,lower,upper,steps,amounts,0);
    }
    function openAfterMatch(State storage s,uint256 id,address owner,address base,address quote,bool sell,uint8 decimals,
        uint256 amount,uint256 lower,uint256 upper,uint16 steps,uint256[] memory amounts,uint256 proceeds) public {
        Order storage o=s.orders[id];
        if(o.owner!=address(0)||id==0||owner==address(0)||amount==0||amount<steps||lower==0||upper<lower||steps==0||steps>128
            ||decimals>36||amounts.length!=steps||(steps==1?lower!=upper:lower==upper))revert InvalidOrder();
        o.owner=owner;o.base=base;o.quote=quote;o.sell=sell;o.decimals=decimals;o.steps=steps;o.lower=lower;o.upper=upper;o.total=amount;o.revision=1;
        o.directAccrued=proceeds*SCALE;uint256 remaining;
        Market storage m=s.markets[marketKey(base,quote,sell)];
        uint256[] memory keys=new uint256[](steps);uint256[] memory scaled=new uint256[](steps);
        for(uint16 j;j<steps;j++){
            uint16 i=sell?j:steps-1-j;uint256 initial=amount/steps+(i==steps-1?amount%steps:0);
            if(amounts[i]>initial)revert InvalidAmount();remaining+=amounts[i];
            keys[j]=priceKey(sell,level(o,i));scaled[j]=amounts[i]*SCALE;
        }
        (uint256[] memory prior,uint256[] memory gains)=m.tree.addBatch(keys,scaled);
        for(uint16 j;j<steps;j++){
            uint16 i=sell?j:steps-1-j;uint256 allocated=scaled[j];if(allocated==0)continue;
            Level storage l=m.levels[keys[j]];uint256 previousInventory=prior[j];uint256 gain=gains[j];
            l.epochs[l.current].syncFromTree(previousInventory,gain);
            if(l.epochs[l.current].inventory==0&&l.epochs[l.current].shares!=0)++l.current;
            Slot storage p=o.slots[i];p.epoch=l.current;
            l.epochs[p.epoch].joinFromTree(p.account,allocated);
        }
        if((remaining==amount)!=(proceeds==0))revert InvalidAmount();++m.revision;
    }
    function _preview(Market storage m,Order storage o,uint16 index) private view returns(uint256 inventory,uint256 proceeds){
        uint256 key=priceKey(o.sell,level(o,index));Slot storage p=o.slots[index];Level storage l=m.levels[key];A.Epoch storage e=l.epochs[p.epoch];
        if(p.account.shares==0&&p.account.accrued==0&&p.account.fraction==0)return(0,0);
        uint256 poolInventory=e.inventory;uint256 gain;
        if(p.epoch==l.current)(poolInventory,gain)=m.tree.level(key);
        (uint256 earningsIndex,uint256 earningsHigh)=A.indexAfter(e,gain);
        inventory=e.shares==0?0:Math.mulDiv(p.account.shares,poolInventory,e.shares);
        (proceeds,)=A.earned(p.account,earningsIndex,earningsHigh);
    }
    function bucketBalance(State storage s,uint256 id,uint16 index) public view returns(uint256 price,uint256 amount){
        Order storage o=s.orders[id];price=level(o,index);
        (uint256 scaled,)=_preview(s.markets[marketKey(o.base,o.quote,o.sell)],o,index);amount=scaled/SCALE;
    }
    function principalInterest(State storage s,uint256 id) public view returns(bool){
        Order storage o=s.orders[id];if(o.owner==address(0))revert InvalidOrder();Market storage m=s.markets[marketKey(o.base,o.quote,o.sell)];
        for(uint16 i;i<o.steps;i++){(uint256 principal,)=_preview(m,o,i);if(principal!=0)return true;}
        return false;
    }
    function withdrawalAmount(State storage s,uint256 id) public view returns(uint256){
        Order storage o=s.orders[id];if(o.owner==address(0))revert InvalidOrder();Market storage m=s.markets[marketKey(o.base,o.quote,o.sell)];
        uint256 principal=s.credit[o.owner][o.sell?o.base:o.quote];
        for(uint16 i;i<o.steps;i++){(uint256 amount,)=_preview(m,o,i);principal+=amount;}
        return principal/SCALE;
    }
    function status(State storage s,uint256 id) public view returns(uint256 remaining,uint256 executed,uint256 withdrawn,uint256 claimable,uint256 claimed,uint256 revision){
        Order storage o=s.orders[id];if(o.owner==address(0))revert InvalidOrder();Market storage m=s.markets[marketKey(o.base,o.quote,o.sell)];
        uint256 principal;uint256 gains=o.directAccrued;
        for(uint16 i;i<o.steps;i++){(uint256 a,uint256 b)=_preview(m,o,i);principal+=a;gains+=b;}
        remaining=principal/SCALE;withdrawn=o.withdrawn/SCALE;claimable=gains/SCALE;claimed=o.claimed;revision=o.revision+m.revision;
        executed=o.total-remaining-withdrawn;
    }
    function available(State storage s,address base,address quote,bool sell,uint8 decimals,P.Ratio memory usd) public view returns(uint256){
        (uint256 threshold,bool empty)=_threshold(sell,decimals,usd);if(empty)return 0;
        return s.markets[marketKey(base,quote,sell)].tree.available(threshold)/SCALE;
    }
    function fillGroup(State storage s,address base,address quote,bool sell,uint8 decimals,P.Ratio memory usd,uint256 consumed,uint256 proceeds) public {
        (uint256 threshold,bool empty)=_threshold(sell,decimals,usd);if(empty||consumed==0||proceeds==0)revert InvalidAmount();
        Market storage m=s.markets[marketKey(base,quote,sell)];m.tree.fill(threshold,consumed*SCALE,proceeds*SCALE);++m.revision;
    }
    function _settleSlot(Market storage m,Order storage o,uint16 index) private returns(uint256 key){
        key=priceKey(o.sell,level(o,index));Slot storage p=o.slots[index];Level storage l=m.levels[key];
        if(p.account.shares==0&&p.account.accrued==0&&p.account.fraction==0)return key;
        if(p.epoch==l.current)_sync(m,key);
        l.epochs[p.epoch].settle(p.account);
    }
    function _debit(Market storage m,Order storage o,uint16 index,uint256 amount,bool all) private returns(uint256 debit){
        uint256 key=_settleSlot(m,o,index);Slot storage p=o.slots[index];Level storage l=m.levels[key];A.Epoch storage e=l.epochs[p.epoch];
        if(p.account.shares==0){if(!all)revert InvalidAmount();return 0;}
        debit=all?e.exit(p.account):e.withdraw(p.account,amount);
        if(p.epoch==l.current)m.tree.change(key,debit,false);
        else if(debit!=0)revert InvalidAmount();
    }
    function fillOrder(State storage s,uint256 id,uint16 index,P.Ratio memory usd,uint256 consumed,uint256 proceeds) public {
        Order storage o=s.orders[id];uint256 boundary=level(o,index);
        if(!(o.sell?P.atLeast(10**o.decimals,usd,boundary):P.atMost(10**o.decimals,usd,boundary)))revert Ineligible();
        if(consumed==0||proceeds==0)revert InvalidAmount();Market storage m=s.markets[marketKey(o.base,o.quote,o.sell)];
        uint256 requested=consumed*SCALE;uint256 debit=_debit(m,o,index,requested,false);
        uint256 dust=debit-requested;o.withdrawn+=dust;s.credit[o.owner][o.sell?o.base:o.quote]+=dust;
        Slot storage p=o.slots[index];uint256 key=priceKey(o.sell,boundary);
        m.levels[key].epochs[p.epoch].credit(p.account,proceeds*SCALE);++o.revision;++m.revision;
    }
    function claim(State storage s,uint256 id,uint256 amount) public {
        Order storage o=s.orders[id];if(o.owner==address(0)||amount==0)revert InvalidAmount();Market storage m=s.markets[marketKey(o.base,o.quote,o.sell)];
        uint256 left=amount*SCALE;
        uint256 direct=Math.min(left,o.directAccrued);o.directAccrued-=direct;left-=direct;
        for(uint16 i;i<o.steps&&left!=0;i++){
            uint256 key=_settleSlot(m,o,i);Slot storage p=o.slots[i];uint256 part=Math.min(left,p.account.accrued);
            if(part!=0){m.levels[key].epochs[p.epoch].claim(p.account,part);left-=part;}
        }
        if(left!=0)revert InvalidAmount();o.claimed+=amount;++o.revision;
    }
    function _payout(State storage s,Order storage o,uint256 scaled) private returns(uint256 amount){
        address asset=o.sell?o.base:o.quote;scaled+=s.credit[o.owner][asset];amount=scaled/SCALE;s.credit[o.owner][asset]=scaled%SCALE;
    }
    function withdraw(State storage s,uint256 id,uint16 index,uint256 amount) public returns(uint256 paid){
        Order storage o=s.orders[id];Market storage m=s.markets[marketKey(o.base,o.quote,o.sell)];
        uint256 debit=_debit(m,o,index,amount*SCALE,false);o.withdrawn+=debit;paid=_payout(s,o,debit);++o.revision;++m.revision;
    }
    function withdrawRemaining(State storage s,uint256 id) public returns(uint256 paid){
        Order storage o=s.orders[id];if(o.owner==address(0))revert InvalidOrder();Market storage m=s.markets[marketKey(o.base,o.quote,o.sell)];
        uint256 debit;for(uint16 i;i<o.steps;i++)debit+=_debit(m,o,i,0,true);
        o.withdrawn+=debit;paid=_payout(s,o,debit);++o.revision;++m.revision;
    }
}
