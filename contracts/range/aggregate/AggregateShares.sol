pragma solidity ^0.8.30;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregateIndexMath as I} from "./AggregateIndexMath.sol";
library AggregateShares {
    uint256 internal constant INDEX=1e54;
    struct Epoch {
        uint256 inventory;
        uint256 shares;
        uint256 index;
        uint256 received;
        uint256 paid;
        uint256 reserved;
        uint256 indexHigh;
    }
    struct Account {
        uint256 shares;
        uint256 checkpoint;
        uint256 accrued;
        uint256 fraction;
        uint256 checkpointHigh;
    }
    error InvalidAccounting();
    function sync(Epoch storage e,uint256 inventory,uint256 proceeds) internal {
        if(inventory>e.inventory)revert InvalidAccounting();
        syncFromTree(e,inventory,proceeds);
    }
    function syncFromTree(Epoch storage e,uint256 inventory,uint256 proceeds) internal {
        if(proceeds!=0){
            if(e.shares==0)revert InvalidAccounting();
            (e.index,e.indexHigh)=indexAfter(e,proceeds);e.received+=proceeds;
        }
        e.inventory=inventory;
    }
    function join(Epoch storage e,Account storage a,uint256 amount) internal {
        joinFromTree(e,a,amount);e.inventory+=amount;
    }
    function joinFromTree(Epoch storage e,Account storage a,uint256 amount) internal {
        if(amount==0||a.shares!=0||a.accrued!=0||a.fraction!=0)revert InvalidAccounting();
        uint256 minted=e.shares==0?amount:Math.mulDiv(amount,e.shares,e.inventory);
        if(minted==0)revert InvalidAccounting();
        a.shares=minted;a.checkpoint=e.index;a.checkpointHigh=e.indexHigh;e.shares+=minted;
    }
    function indexAfter(Epoch storage e,uint256 proceeds) internal view returns(uint256 low,uint256 high){
        low=e.index;high=e.indexHigh;
        if(proceeds!=0){
            (uint256 extraLow,uint256 extraHigh)=I.ratio(proceeds,INDEX,e.shares);
            (low,high)=I.add(low,high,extraLow,extraHigh);
        }
    }
    function earned(Account storage a,uint256 index,uint256 indexHigh) internal view returns(uint256 whole,uint256 fraction){
        (uint256 low,uint256 high)=I.subtract(index,indexHigh,a.checkpoint,a.checkpointHigh);
        (whole,fraction)=I.weighted(a.shares,low,high,INDEX);
        whole+=a.accrued;fraction+=a.fraction;
        whole+=fraction/INDEX;fraction%=INDEX;
    }
    function settle(Epoch storage e,Account storage a) internal {
        (uint256 whole,uint256 fraction)=earned(a,e.index,e.indexHigh);
        e.reserved+=whole-a.accrued;a.accrued=whole;a.fraction=fraction;a.checkpoint=e.index;a.checkpointHigh=e.indexHigh;
        if(e.reserved>e.received-e.paid)revert InvalidAccounting();
    }
    function remaining(Epoch storage e,Account storage a) internal view returns(uint256){
        return e.shares==0?0:Math.mulDiv(a.shares,e.inventory,e.shares);
    }
    function exit(Epoch storage e,Account storage a) internal returns(uint256 amount){
        if(a.shares==0)revert InvalidAccounting();
        settle(e,a);amount=remaining(e,a);e.inventory-=amount;e.shares-=a.shares;a.shares=0;
        if(e.shares==0){
            uint256 dust=e.received-e.paid-e.reserved;
            e.reserved+=dust;a.accrued+=dust;
            if(e.inventory!=0)revert InvalidAccounting();
        }
    }
    function withdraw(Epoch storage e,Account storage a,uint256 amount) internal returns(uint256 debit){
        uint256 available=remaining(e,a);
        if(amount==0||amount>available)revert InvalidAccounting();
        if(amount==available)return exit(e,a);
        settle(e,a);
        uint256 burned=Math.mulDiv(amount,e.shares,e.inventory,Math.Rounding.Ceil);
        debit=Math.mulDiv(burned,e.inventory,e.shares);
        if(debit<amount||burned>=a.shares)revert InvalidAccounting();
        e.shares-=burned;e.inventory-=debit;a.shares-=burned;
    }
    function credit(Epoch storage e,Account storage a,uint256 amount) internal {
        settle(e,a);e.received+=amount;e.reserved+=amount;a.accrued+=amount;
    }
    function claim(Epoch storage e,Account storage a,uint256 amount) internal {
        settle(e,a);if(amount==0||amount>a.accrued)revert InvalidAccounting();
        a.accrued-=amount;e.reserved-=amount;e.paid+=amount;
    }
}
