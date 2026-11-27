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
interface IInternalQuoteHost {function quoteAdapter() external view returns(V2NativeQuoteAdapter);}

abstract contract AggregateManagerCore is ReentrancyGuard,Ownable2Step {
using L for L.Order;
using SafeERC20 for IERC20;
PinnedMarketPricing public immutable pricing;
E public immutable vault;
bytes32 internal immutable pricingHash;
bytes32 internal immutable vaultHash;
InternalSettlementPolicy internal immutable settlementPolicy;
bytes32 internal immutable settlementPolicyHash;
PassiveCrossMath internal immutable passiveCrossMath;
V2NativeQuoteAdapter internal immutable internalQuoteAdapter;
bytes32 internal immutable internalQuoteAdapterHash;
uint256 public immutable configuredChainId;
uint16 public constant FEE_BPS=30;
bool public paused;
uint256 public nextOrder;
bool public internalPositionExecution;
mapping(uint256=>L.Order) internal orders;
mapping(address=>uint256[]) internal ownerOrders;
mapping(bytes32=>uint256[]) internal activeOrders;
mapping(uint256=>uint256) internal activeIndex;
function _marketKey(address base,address quote,bool sell) internal pure returns(bytes32){return keccak256(abi.encode(base,quote,sell));}
function _activate(uint256 id,L.Order storage o) internal {
        uint256[] storage ids=activeOrders[_marketKey(o.base,o.quote,o.sell)];
        ids.push(id);activeIndex[id]=ids.length;
    }
function _deactivateIfEmpty(uint256 id,L.Order storage o) internal {
        if(o.remaining!=0)return;
        uint256 position=activeIndex[id];if(position==0)revert InvalidRequest();
        uint256[] storage ids=activeOrders[_marketKey(o.base,o.quote,o.sell)];
        uint256 last=ids[ids.length-1];
        if(position!=ids.length){ids[position-1]=last;activeIndex[last]=position;}
        ids.pop();delete activeIndex[id];
    }
mapping(address=>uint256) public liabilities;
mapping(address=>uint256) public fees;
error InvalidRequest();
error Unauthorized();
error AssetTransfer();
error PriceChanged();
error TradingPaused();
event TradingPauseChanged(bool paused);
event Opened(uint256 indexed id,address indexed owner,address indexed base,address quote,bool sell,uint256 amount,uint256 lower,uint256 upper,uint16 steps);
event Filled(uint256 indexed id,uint16 indexed bucket,address indexed caller,bool viaVault,uint256 principal,uint256 proceeds);
event Claimed(uint256 indexed id,uint256 gross,uint256 fee);
event Withdrawn(uint256 indexed id,uint16 indexed bucket,uint256 amount);
constructor(uint256 chain,PinnedMarketPricing p,E v) Ownable(msg.sender){
        if(chain!=block.chainid||address(p).code.length==0||address(v).code.length==0)revert InvalidRequest();
        configuredChainId=chain;pricing=p;vault=v;pricingHash=address(p).codehash;vaultHash=address(v).codehash;
        settlementPolicy=IInternalPolicyVault(address(v)).internalSettlementPolicy();
        if(address(settlementPolicy).code.length==0)revert InvalidRequest();
        settlementPolicyHash=address(settlementPolicy).codehash;
        passiveCrossMath=settlementPolicy.crossMath();
        internalQuoteAdapter=IInternalQuoteHost(address(v)).quoteAdapter();
        if(address(internalQuoteAdapter).code.length==0)revert InvalidRequest();
        internalQuoteAdapterHash=address(internalQuoteAdapter).codehash;
        V2NativeQuoteAdapter.Config memory c=internalQuoteAdapter.configuration();
        if(c.chainId!=chain||c.usdg!=p.usdg()||c.wrappedNative!=p.wrappedNative())revert InvalidRequest();
    }
function _identity() internal view {
        if(paused)revert TradingPaused();if(!_aggregate().ready)revert AggregationNotReady();
        if(block.chainid!=configuredChainId||address(pricing).codehash!=pricingHash||address(vault).codehash!=vaultHash||address(settlementPolicy).codehash!=settlementPolicyHash)revert InvalidRequest();
    }
struct EligibleSource {uint256 id;uint16 bucket;uint8 kind;uint256 amount;}
struct EligiblePage {
        P.Ratio rate;P.Ratio usd;EligibleSource[] sources;
        uint256 nextOrder;uint16 nextBucket;uint256 activeCount;uint256 visited;bool done;
    }
function _scan(uint256[] storage ids,EligiblePage memory p,uint256 maxVisits) internal view {
        EligibleSource[] memory rows=new EligibleSource[](maxVisits);
        uint256 count;
        while(p.nextOrder<ids.length&&p.visited<maxVisits){
            uint256 id=ids[p.nextOrder];L.Order storage o=orders[id];
            if(p.nextBucket>=o.steps)revert InvalidRequest();
            uint16 i=p.nextBucket;
            uint256 amount=_bucketAvailable(id,i);uint256 boundary=o.level(i);if(amount!=0&&(o.sell?P.atLeast(10**o.decimals,p.usd,boundary):P.atMost(10**o.decimals,p.usd,boundary)))rows[count++]=EligibleSource(id,i,o.steps==1?1:2,amount);
            ++p.visited;++p.nextBucket;
            if(p.nextBucket==o.steps){++p.nextOrder;p.nextBucket=0;}
        }
        assembly ("memory-safe") { mstore(rows,count) }
        p.sources=rows;p.done=p.nextOrder==ids.length;
    }
function _price(uint256 id,uint16 index) internal view returns(P.Ratio memory rate){
        _identity();(address base,address quote,)=_market(id);P.Ratio memory usd;(rate,usd)=pricing.read(base,quote);
        if(_isAggregate(id)){if(index!=0||_groupAvailable(_aggregate().groups[id],usd)==0)revert L.Ineligible();}
        else if(!_eligible(id,index,usd))revert L.Ineligible();
    }
function _limitFeePayer(address caller) internal view virtual returns(address){return caller;}
function _recordLimitFee(address asset,uint256 amount,address) internal virtual {fees[asset]+=amount;}
function _beginVaultFeeExecution(address) internal virtual {}
function _endVaultFeeExecution() internal virtual {}
function _plan(uint256 id,uint16 index,uint256 budget,P.Ratio memory rate) internal view returns(E.Result memory r,uint256 net){
        (address base,address quote,bool sell)=_market(id);uint256 amount;
        if(_isAggregate(id)){(,P.Ratio memory usd)=pricing.read(base,quote);amount=_groupAvailable(_aggregate().groups[id],usd);}
        else amount=_bucketAvailable(id,index);
        return passiveCrossMath.planLimit(sell,amount,budget,rate,msg.sender==address(vault)?0:FEE_BPS);
    }
event InternalGroupFilled(uint256 indexed id,uint16 indexed bucket,uint256 sourceCount,uint256 principal,uint256 proceeds);
event InternalQuoteConverted(address indexed input,address indexed output,uint256 inputUsed,uint256 outputReceived);
struct CrossResult {uint256 input;uint256 output;uint256 sources;bool viaVault;}
function _balance(address asset) internal view returns(uint256){return asset==address(0)?address(this).balance:IERC20(asset).balanceOf(address(this));}
function _collect(address asset,address from,uint256 amount) internal {
        if(asset==address(0)){if(msg.value!=amount)revert AssetTransfer();}
        else{if(msg.value!=0)revert AssetTransfer();uint256 b=_balance(asset);IERC20(asset).safeTransferFrom(from,address(this),amount);if(_balance(asset)-b!=amount)revert AssetTransfer();}
    }
function _send(address asset,address to,uint256 amount) internal {
        if(amount!=0){if(asset==address(0)){(bool ok,)=payable(to).call{value:amount}("");if(!ok)revert AssetTransfer();}
        else{uint256 b=_balance(asset);uint256 r=IERC20(asset).balanceOf(to);IERC20(asset).safeTransfer(to,amount);if(b-_balance(asset)!=amount||IERC20(asset).balanceOf(to)-r!=amount)revert AssetTransfer();}}
        _solvent(asset);
    }
function _solvent(address asset) internal view {if(_balance(asset)<liabilities[asset]+fees[asset])revert AssetTransfer();}
struct AggregateGroup {address base;address quote;bool sell;bool exists;}
struct AggregateStorage {
        R.State ledger;
        mapping(uint256=>AggregateGroup) groups;
        uint256 legacyCursor;
        uint256 legacyEnd;
        bool begun;
        bool ready;
    }
bytes32 internal constant AGGREGATE_SLOT=keccak256("UserVault.AggregateRange.Accounting.v1");
error AggregationNotReady();
error LegacyOutstanding();
event AggregateRangeFilled(address indexed base,address indexed quote,bool sell,uint256 principal,uint256 proceeds);
event RangePrincipalWithdrawn(uint256 indexed id,address indexed owner,uint256 amount);
function _aggregate() internal pure returns(AggregateStorage storage a){bytes32 slot=AGGREGATE_SLOT;assembly("memory-safe"){a.slot:=slot}}
function _isAggregate(uint256 id) internal pure returns(bool){return id&(uint256(1)<<255)!=0;}
function _aggregateId(address base,address quote,bool sell) internal pure returns(uint256){return uint256(keccak256(abi.encode("UserVault.AggregateRange.Group.v1",base,quote,sell)))|(uint256(1)<<255);}
function _registerAggregate(address base,address quote,bool sell) internal {
        uint256 id=_aggregateId(base,quote,sell);AggregateGroup storage g=_aggregate().groups[id];
        if(g.exists&&(g.base!=base||g.quote!=quote||g.sell!=sell))revert InvalidRequest();
        if(!g.exists){g.base=base;g.quote=quote;g.sell=sell;g.exists=true;}
    }
function aggregateInventory(address base,address quote,bool sell) external view returns(uint256){
        R.Market storage m=_aggregate().ledger.markets[R.marketKey(base,quote,sell)];return m.tree.nodes[m.tree.root].inventory/1e27;
    }
function _ledgerOrder(uint256 id) internal view returns(bool){return _aggregate().ledger.orders[id].owner!=address(0);}
function _bucketAvailable(uint256 id,uint16 index) internal view returns(uint256 amount){
        if(!_ledgerOrder(id))return orders[id].available(index);
        (,amount)=R.bucketBalance(_aggregate().ledger,id,index);
    }
function _eligible(uint256 id,uint16 index,P.Ratio memory usd) internal view returns(bool){
        L.Order storage o=orders[id];uint256 boundary=o.level(index);
        return _bucketAvailable(id,index)!=0&&(o.sell?P.atLeast(10**o.decimals,usd,boundary):P.atMost(10**o.decimals,usd,boundary));
    }
function _groupAvailable(AggregateGroup storage g,P.Ratio memory usd) internal view returns(uint256){
        if(!g.exists)revert InvalidRequest();return R.available(_aggregate().ledger,g.base,g.quote,g.sell,IERC20Metadata(g.base).decimals(),usd);
    }
function _market(uint256 id) internal view returns(address base,address quote,bool sell){
        if(_isAggregate(id)){AggregateGroup storage g=_aggregate().groups[id];if(!g.exists)revert InvalidRequest();return(g.base,g.quote,g.sell);}
        L.Order storage o=orders[id];if(o.owner==address(0))revert InvalidRequest();return(o.base,o.quote,o.sell);
    }
function _fillAggregate(uint256 id,uint256 principal,uint256 proceeds,P.Ratio memory usd) internal {
        AggregateGroup storage g=_aggregate().groups[id];if(!g.exists)revert InvalidRequest();
        R.fillGroup(_aggregate().ledger,g.base,g.quote,g.sell,IERC20Metadata(g.base).decimals(),usd,principal,proceeds);
        emit AggregateRangeFilled(g.base,g.quote,g.sell,principal,proceeds);
    }
}
