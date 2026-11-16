pragma solidity ^0.8.30;
import {AggregateRangeAccounting as R} from "aggregate/AggregateRangeAccounting.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LimitAccounting as L} from "contracts/libraries/LimitAccounting.sol";
import {ReferencePriceMath as P} from "contracts/libraries/ReferencePriceMath.sol";
import {PinnedMarketPricing} from "contracts/reference/PinnedMarketPricing.sol";
import {IUserVaultExecution as E} from "contracts/interfaces/IUserVaultExecution.sol";
import {IInternalPolicyVault, InternalSettlementPolicy} from "contracts/mainnet-candidate/InternalSettlementPolicy.sol";

import {MainnetMarketLiquiditySnapshot as S} from "contracts/mainnet-candidate/MainnetMarketLiquiditySnapshot.sol";
import {CreateGroupMath as G} from "contracts/mainnet-candidate/CreateGroupMath.sol";

import {PassiveCrossMath} from "contracts/mainnet-candidate/PassiveCrossMath.sol";
import {V2NativeQuoteAdapter} from "contracts/adapters/V2NativeQuoteAdapter.sol";

interface ILimitTokenAdmission {function prepareLimitToken(address payer,address base,bytes calldata permission) external;}

import {AggregateManagerCore} from "aggregate/AggregateManagerCore.sol";
interface IRangeInternalModule {
    function host() external view returns(address);
    function configuredChainId() external view returns(uint256);
    function pricing() external view returns(address);
    function vault() external view returns(address);
    function run(uint256,uint16,uint256,uint256,uint256) external returns(E.Result memory);
}
contract MainnetMarketLimitOrderManager is AggregateManagerCore {
using L for L.Order;using SafeERC20 for IERC20;

    address public immutable internalExecutionModule;
    bytes32 private immutable internalExecutionHash;
    constructor(uint256 chain,PinnedMarketPricing p,E v,address module_) AggregateManagerCore(chain,p,v){
        if(module_.code.length==0||IRangeInternalModule(module_).configuredChainId()!=chain
            ||IRangeInternalModule(module_).pricing()!=address(p)||IRangeInternalModule(module_).vault()!=address(v))revert InvalidRequest();
        internalExecutionModule=module_;internalExecutionHash=module_.codehash;
    }
    function _checkExecutionModule() private view {
        if(internalExecutionModule.codehash!=internalExecutionHash||IRangeInternalModule(internalExecutionModule).host()!=address(this))revert InvalidRequest();
    }
    function _executeInternal(uint256 id,uint16 index,uint256 budget,uint256 minOutput,uint256 deadline) private returns(E.Result memory){
        _checkExecutionModule();
        (bool ok,bytes memory data)=internalExecutionModule.delegatecall(abi.encodeCall(IRangeInternalModule.run,(id,index,budget,minOutput,deadline)));
        if(!ok){assembly("memory-safe"){revert(add(data,32),mload(data))}}
        return abi.decode(data,(E.Result));
    }
function activeOrderCount(address base,address quote,bool sell) external view returns(uint256){
        uint256 count;
        uint256[] storage ids=activeOrders[_marketKey(base,quote,sell)];
        for(uint256 i;i<ids.length;i++){
            if(_ledgerOrder(ids[i])){(uint256 remaining,,,,,)=R.status(_aggregate().ledger,ids[i]);if(remaining!=0)++count;}
            else if(orders[ids[i]].remaining!=0)++count;
        }return count;
    }
function setPaused(bool value) external onlyOwner nonReentrant {paused=value;emit TradingPauseChanged(value);}
function createWithRegistration(address base,address quote,bool sell,uint256 amount,uint256 lower,uint256 upper,uint16 steps,bytes calldata permission) external payable nonReentrant returns(uint256 id){
        _identity();

        if(quote!=address(0)&&quote!=pricing.usdg())revert InvalidRequest();
        ILimitTokenAdmission(address(vault)).prepareLimitToken(msg.sender,base,permission);

        id=++nextOrder;if(_isAggregate(id))revert InvalidRequest();L.Order storage o=orders[id];
        o.open(msg.sender,base,quote,sell,IERC20Metadata(base).decimals(),amount,lower,upper,steps);
        _activate(id,o);ownerOrders[msg.sender].push(id);_registerAggregate(base,quote,sell);
        address input=sell?base:quote;_collect(input,msg.sender,amount);liabilities[input]+=amount;_solvent(input);
        emit Opened(id,msg.sender,base,quote,sell,amount,lower,upper,steps);
        (,P.Ratio memory usd)=pricing.read(base,quote);
        S snapshot=S(settlementPolicy.settlementSnapshot());
        E.Side side=sell?E.Side.Sell:E.Side.Buy;
        for(uint16 bucketIndex;bucketIndex<steps;++bucketIndex){
            if(!snapshot.hasCounterparty(base,quote,side))break;
            if(_eligible(id,bucketIndex,usd)){
                this.executeInternal(id,bucketIndex,_bucketAvailable(id,bucketIndex),0,block.timestamp);
            }
        }
    uint256[] memory remaining=new uint256[](steps);
        for(uint16 i;i<steps;i++)remaining[i]=o.available(i);
        R.openAfterMatch(_aggregate().ledger,id,msg.sender,base,quote,sell,o.decimals,amount,lower,upper,steps,remaining,o.claimable);
    }
function status(uint256 id) external view returns(address owner,uint256 remaining,uint256 executed,uint256 withdrawn,uint256 claimable,uint256 claimed,uint256 revision){
        L.Order storage o=orders[id];owner=o.owner;
        if(_ledgerOrder(id)){(remaining,executed,withdrawn,claimable,claimed,revision)=R.status(_aggregate().ledger,id);}
        else{return(o.owner,o.remaining,o.executed,o.withdrawn,o.claimable,o.claimed,o.revision);}
    }
function orderMarket(uint256 id) external view returns(address base,address quote,bool sell,uint16 steps,uint256 remaining){
        if(_isAggregate(id)){AggregateGroup storage g=_aggregate().groups[id];if(!g.exists)revert InvalidRequest();
            R.Market storage m=_aggregate().ledger.markets[R.marketKey(g.base,g.quote,g.sell)];return(g.base,g.quote,g.sell,1,m.tree.nodes[m.tree.root].inventory/1e27);}
        L.Order storage o=orders[id];remaining=o.remaining;
        if(_ledgerOrder(id))(remaining,,,,,)=R.status(_aggregate().ledger,id);
        return(o.base,o.quote,o.sell,o.steps,remaining);
    }
function orderDetails(uint256 id) external view returns(uint256 lower,uint256 upper,uint256 total,uint8 decimals,uint256 prepaidClaimable){
        L.Order storage o=orders[id];if(o.owner==address(0))revert InvalidRequest();
        return(o.lower,o.upper,o.total,o.decimals,o.prepaidClaimable);
    }
function bucketBalance(uint256 id,uint16 index) external view returns(uint256 level,uint256 amount){
        if(_ledgerOrder(id))return R.bucketBalance(_aggregate().ledger,id,index);
        L.Order storage o=orders[id];if(o.owner==address(0))revert InvalidRequest();return(o.level(index),o.available(index));
    }
function ownerOrderPage(address owner,uint256 cursor,uint16 size) external view returns(uint256[] memory ids,uint256 next,bool done){
        uint256[] storage all=ownerOrders[owner];if(size==0||size>64||cursor>all.length)revert InvalidRequest();
        next=cursor+Math.min(size,all.length-cursor);ids=new uint256[](next-cursor);
        for(uint256 i=cursor;i<next;i++)ids[i-cursor]=all[i];done=next==all.length;
    }
function eligibleLiquidity(uint256 id) external view returns(uint256[] memory amounts){
        L.Order storage o=orders[id];_identity();if(o.owner==address(0))revert InvalidRequest();
        (,P.Ratio memory usd)=pricing.read(o.base,o.quote);amounts=new uint256[](o.steps);
        for(uint16 i;i<o.steps;i++)if(_eligible(id,i,usd))amounts[i]=_bucketAvailable(id,i);
    }
function eligibleGroupPage(address base,address quote,E.Side activeSide,
        uint256 orderCursor,uint16 bucketCursor,uint16 maxVisits) external view returns(EligiblePage memory p){
        _identity();if(maxVisits==0||maxVisits>64)revert InvalidRequest();
        uint256[] storage ids=activeOrders[_marketKey(base,quote,activeSide==E.Side.Buy)];
        p.activeCount=ids.length;
        if(orderCursor>ids.length||(orderCursor==ids.length&&bucketCursor!=0))revert InvalidRequest();
        (p.rate,p.usd)=pricing.read(base,quote);
        p.nextOrder=orderCursor;p.nextBucket=bucketCursor;
        _scan(ids,p,maxVisits);
    }
function eligibleGroup(address base,address quote,E.Side activeSide) public view returns(P.Ratio memory rate,P.Ratio memory usd,EligibleSource[] memory sources){
        _identity();(rate,usd)=pricing.read(base,quote);bool sell=activeSide==E.Side.Buy;
        uint256 amount=R.available(_aggregate().ledger,base,quote,sell,IERC20Metadata(base).decimals(),usd);
        sources=new EligibleSource[](amount==0?0:1);
        if(amount!=0)sources[0]=EligibleSource(_aggregateId(base,quote,sell),0,2,amount);
    }
function bucket(uint256 id,uint16 index) external view returns(uint256 level,uint256 amount,bool eligible){
        _identity();L.Order storage o=orders[id];level=o.level(index);amount=_bucketAvailable(id,index);
        (,P.Ratio memory usd)=pricing.read(o.base,o.quote);eligible=_eligible(id,index,usd);
    }
function executeDirect(uint256 id,uint16 index,uint256 budget,uint256 minOutput,uint256 deadline,address recipient) external payable nonReentrant returns(E.Result memory r){
        if(budget==0||block.timestamp>deadline||recipient==address(0)||recipient==address(this))revert InvalidRequest();
        (address base,address quote,bool sell)=_market(id);address input=sell?quote:base;address output=sell?base:quote;uint256 net;
        {P.Ratio memory rate=_price(id,index);(r,net)=_plan(id,index,budget,rate);
            if(net==0||r.netOutput==0||r.netOutput<minOutput)revert InvalidRequest();_collect(input,msg.sender,budget);
            P.Ratio memory afterRate=_price(id,index);if(afterRate.n!=rate.n||afterRate.d!=rate.d)revert PriceChanged();}
        (,P.Ratio memory usd)=pricing.read(base,quote);
        if(_isAggregate(id))_fillAggregate(id,r.netOutput,net,usd);
        else R.fillOrder(_aggregate().ledger,id,index,usd,r.netOutput,net);
        liabilities[output]-=r.netOutput;liabilities[input]+=net;_recordLimitFee(input,r.grossInputUsed-net,_limitFeePayer(msg.sender));
        _send(output,recipient,r.netOutput);_send(input,msg.sender,r.inputRefund);_solvent(input);
        emit Filled(id,index,msg.sender,false,r.netOutput,net);
    }
function executeVault(uint256 id,uint16 index,uint256 budget,uint256 minOutput,uint256 deadline)
        external returns(E.Result memory){return _lockedInternal(id,index,budget,minOutput,deadline);}
function executeInternal(uint256 id,uint16 index,uint256 budget,uint256 minOutput,uint256 deadline)
        external returns(E.Result memory){
        if(msg.sender==address(this))return _executeInternal(id,index,budget,minOutput,deadline);
        return _lockedInternal(id,index,budget,minOutput,deadline);
    }
function _lockedInternal(uint256 id,uint16 index,uint256 budget,uint256 minOutput,uint256 deadline)
        private nonReentrant returns(E.Result memory){
        if(minOutput==0)revert InvalidRequest();
        return _executeInternal(id,index,budget,minOutput,deadline);
    }
function claim(uint256 id,uint256 amount) external nonReentrant {
        if(!_ledgerOrder(id)){
        L.Order storage o=orders[id];if(o.owner!=msg.sender)revert Unauthorized();
        uint256 fee=o.claim(amount,FEE_BPS);address asset=o.sell?o.quote:o.base;
        liabilities[asset]-=amount;_recordLimitFee(asset,fee,msg.sender);_send(asset,msg.sender,amount-fee);emit Claimed(id,amount,fee);
    return;}
        L.Order storage o=orders[id];if(o.owner!=msg.sender)revert Unauthorized();R.claim(_aggregate().ledger,id,amount);
        uint256 fee=Math.mulDiv(amount,FEE_BPS,10000);address asset=o.sell?o.quote:o.base;
        liabilities[asset]-=amount;_recordLimitFee(asset,fee,msg.sender);_send(asset,msg.sender,amount-fee);emit Claimed(id,amount,fee);
    }
function withdraw(uint256 id,uint16 index,uint256 amount) external nonReentrant {
        if(!_ledgerOrder(id)){
        L.Order storage o=orders[id];if(o.owner!=msg.sender)revert Unauthorized();o.withdraw(index,amount);_deactivateIfEmpty(id,o);
        address asset=o.sell?o.base:o.quote;liabilities[asset]-=amount;_send(asset,msg.sender,amount);emit Withdrawn(id,index,amount);
    return;}
        L.Order storage o=orders[id];if(o.owner!=msg.sender)revert Unauthorized();
        uint256 paid=R.withdraw(_aggregate().ledger,id,index,amount);address asset=o.sell?o.base:o.quote;
        liabilities[asset]-=paid;_send(asset,msg.sender,paid);emit Withdrawn(id,index,paid);
    }
function withdrawRemaining(uint256 id) external nonReentrant {
        if(!_ledgerOrder(id)){
        L.Order storage o=orders[id];if(o.owner!=msg.sender)revert Unauthorized();
        uint256 amount=o.remaining;if(amount==0)revert InvalidRequest();
        for(uint16 i=0;i<o.steps;i++){uint256 part=o.available(i);if(part==0)continue;o.withdraw(i,part);emit Withdrawn(id,i,part);}
        _deactivateIfEmpty(id,o);address asset=o.sell?o.base:o.quote;
        liabilities[asset]-=amount;_send(asset,msg.sender,amount);
    return;}
        L.Order storage o=orders[id];if(o.owner!=msg.sender)revert Unauthorized();
        uint256 paid=R.withdrawRemaining(_aggregate().ledger,id);o.remaining=0;if(activeIndex[id]!=0)_deactivateIfEmpty(id,o);
        address asset=o.sell?o.base:o.quote;liabilities[asset]-=paid;_send(asset,msg.sender,paid);emit RangePrincipalWithdrawn(id,msg.sender,paid);
    }
function activateAggregation(uint16 maximum) external onlyOwner nonReentrant {
        if(maximum==0||maximum>64)revert InvalidRequest();_checkExecutionModule();AggregateStorage storage a=_aggregate();
        if(a.ready)return;
        if(!a.begun){a.begun=true;a.legacyEnd=nextOrder;}
        uint256 end=Math.min(a.legacyEnd,a.legacyCursor+maximum);
        for(uint256 id=a.legacyCursor+1;id<=end;id++)if(orders[id].remaining!=0||orders[id].claimable!=0)revert LegacyOutstanding();
        a.legacyCursor=end;if(end==a.legacyEnd)a.ready=true;
    }
function aggregationState() external view returns(bool,uint256,uint256){AggregateStorage storage a=_aggregate();return(a.ready,a.legacyCursor,a.legacyEnd);}
function principalInterest(uint256 id) external view returns(bool){
        if(!_ledgerOrder(id))return orders[id].remaining!=0;
        return R.principalInterest(_aggregate().ledger,id);
    }
function withdrawalAmount(uint256 id) external view returns(uint256){
        if(!_ledgerOrder(id))return orders[id].remaining;
        return R.withdrawalAmount(_aggregate().ledger,id);
    }
function aggregateGroupPage(address base,address quote,E.Side activeSide,uint256 orderCursor,uint16 bucketCursor,uint16 maxVisits) external view returns(EligiblePage memory p){
        if(maxVisits==0||maxVisits>64||bucketCursor!=0)revert InvalidRequest();
        (p.rate,p.usd,p.sources)=eligibleGroup(base,quote,activeSide);p.activeCount=p.sources.length;
        if(orderCursor>p.activeCount)revert InvalidRequest();
        p.nextOrder=p.activeCount;p.done=true;
        if(orderCursor==p.activeCount)p.sources=new EligibleSource[](0);else p.visited=p.sources.length;
    }
receive() external payable {if(msg.sender!=address(vault)&&!(internalPositionExecution&&msg.sender==address(internalQuoteAdapter)))revert Unauthorized();}
}
