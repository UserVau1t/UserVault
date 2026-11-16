pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LimitAccounting as L} from "../libraries/LimitAccounting.sol";
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";
import {PinnedMarketPricing} from "../reference/PinnedMarketPricing.sol";
import {IUserVaultExecution as E} from "../interfaces/IUserVaultExecution.sol";
import {IInternalPolicyVault, InternalSettlementPolicy} from "./InternalSettlementPolicy.sol";

import {MainnetMarketLiquiditySnapshot as S} from "./MainnetMarketLiquiditySnapshot.sol";
import {CreateGroupMath as G} from "./CreateGroupMath.sol";

import {PassiveCrossMath} from "./PassiveCrossMath.sol";
import {V2NativeQuoteAdapter} from "../adapters/V2NativeQuoteAdapter.sol";
interface IInternalQuoteHost {function quoteAdapter() external view returns(V2NativeQuoteAdapter);}
interface ILimitTokenAdmission {function prepareLimitToken(address payer,address base,bytes calldata permission) external;}

contract MainnetMarketLimitOrderManager is ReentrancyGuard,Ownable2Step {
    using L for L.Order;using SafeERC20 for IERC20;
    PinnedMarketPricing public immutable pricing;
    E public immutable vault;
    bytes32 private immutable pricingHash;bytes32 private immutable vaultHash;
    InternalSettlementPolicy private immutable settlementPolicy;bytes32 private immutable settlementPolicyHash;
    PassiveCrossMath private immutable passiveCrossMath;
    V2NativeQuoteAdapter private immutable internalQuoteAdapter;bytes32 private immutable internalQuoteAdapterHash;
    uint256 public immutable configuredChainId;
    uint16 public constant FEE_BPS=50;
    bool public paused;
    uint256 public nextOrder;
    bool public internalPositionExecution;
    mapping(uint256=>L.Order) private orders;
    mapping(address=>uint256[]) private ownerOrders;

    mapping(bytes32=>uint256[]) private activeOrders;
    mapping(uint256=>uint256) private activeIndex;
    function _marketKey(address base,address quote,bool sell) private pure returns(bytes32){return keccak256(abi.encode(base,quote,sell));}
    function activeOrderCount(address base,address quote,bool sell) external view returns(uint256){return activeOrders[_marketKey(base,quote,sell)].length;}
    function _activate(uint256 id,L.Order storage o) private {
        uint256[] storage ids=activeOrders[_marketKey(o.base,o.quote,o.sell)];
        ids.push(id);activeIndex[id]=ids.length;
    }
    function _deactivateIfEmpty(uint256 id,L.Order storage o) private {
        if(o.remaining!=0)return;
        uint256 position=activeIndex[id];if(position==0)revert InvalidRequest();
        uint256[] storage ids=activeOrders[_marketKey(o.base,o.quote,o.sell)];
        uint256 last=ids[ids.length-1];
        if(position!=ids.length){ids[position-1]=last;activeIndex[last]=position;}
        ids.pop();delete activeIndex[id];
    }
    mapping(address=>uint256) public liabilities;
    mapping(address=>uint256) public fees;
    error InvalidRequest();error Unauthorized();error AssetTransfer();error PriceChanged();error TradingPaused();
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

    function setPaused(bool value) external onlyOwner nonReentrant {paused=value;emit TradingPauseChanged(value);}
    function _identity() private view {
        if(paused)revert TradingPaused();
        if(block.chainid!=configuredChainId||address(pricing).codehash!=pricingHash||address(vault).codehash!=vaultHash||address(settlementPolicy).codehash!=settlementPolicyHash)revert InvalidRequest();
    }
    function createWithRegistration(address base,address quote,bool sell,uint256 amount,uint256 lower,uint256 upper,uint16 steps,bytes calldata permission) external payable nonReentrant returns(uint256 id){
        _identity();

        if(quote!=address(0)&&quote!=pricing.usdg())revert InvalidRequest();
        ILimitTokenAdmission(address(vault)).prepareLimitToken(msg.sender,base,permission);

        id=++nextOrder;L.Order storage o=orders[id];
        o.open(msg.sender,base,quote,sell,IERC20Metadata(base).decimals(),amount,lower,upper,steps);
        _activate(id,o);ownerOrders[msg.sender].push(id);
        address input=sell?base:quote;_collect(input,msg.sender,amount);liabilities[input]+=amount;_solvent(input);
        emit Opened(id,msg.sender,base,quote,sell,amount,lower,upper,steps);
        (,P.Ratio memory usd)=pricing.read(base,quote);
        S snapshot=S(settlementPolicy.settlementSnapshot());
        E.Side side=sell?E.Side.Sell:E.Side.Buy;
        for(uint16 bucketIndex;bucketIndex<steps;++bucketIndex){
            if(!snapshot.hasCounterparty(base,quote,side))break;
            if(o.eligible(bucketIndex,usd)){
                this.executeInternal(id,bucketIndex,o.available(bucketIndex),0,block.timestamp);
            }
        }
    }
    function status(uint256 id) external view returns(address owner,uint256 remaining,uint256 executed,uint256 withdrawn,uint256 claimable,uint256 claimed,uint256 revision){
        L.Order storage o=orders[id];return(o.owner,o.remaining,o.executed,o.withdrawn,o.claimable,o.claimed,o.revision);
    }
    function orderMarket(uint256 id) external view returns(address base,address quote,bool sell,uint16 steps,uint256 remaining){
        L.Order storage o=orders[id];return(o.base,o.quote,o.sell,o.steps,o.remaining);
    }

    function orderDetails(uint256 id) external view returns(uint256 lower,uint256 upper,uint256 total,uint8 decimals,uint256 prepaidClaimable){
        L.Order storage o=orders[id];if(o.owner==address(0))revert InvalidRequest();
        return(o.lower,o.upper,o.total,o.decimals,o.prepaidClaimable);
    }
    function bucketBalance(uint256 id,uint16 index) external view returns(uint256 level,uint256 amount){
        L.Order storage o=orders[id];if(o.owner==address(0))revert InvalidRequest();return(o.level(index),o.available(index));
    }

    function ownerOrderPage(address owner,uint256 cursor,uint16 size) external view returns(uint256[] memory ids,uint256 next,bool done){
        uint256[] storage all=ownerOrders[owner];if(size==0||size>64||cursor>all.length)revert InvalidRequest();
        next=cursor+Math.min(size,all.length-cursor);ids=new uint256[](next-cursor);
        for(uint256 i=cursor;i<next;i++)ids[i-cursor]=all[i];done=next==all.length;
    }

    function eligibleLiquidity(uint256 id) external view returns(uint256[] memory amounts){
        L.Order storage o=orders[id];_identity();
        if(o.owner==address(0))revert InvalidRequest();
        (,P.Ratio memory usd)=pricing.read(o.base,o.quote);amounts=new uint256[](o.steps);
        for(uint16 i=0;i<o.steps;i++)if(o.eligible(i,usd))amounts[i]=o.available(i);
    }
    struct EligibleSource {uint256 id;uint16 bucket;uint8 kind;uint256 amount;}
    struct EligiblePage {
        P.Ratio rate;P.Ratio usd;EligibleSource[] sources;
        uint256 nextOrder;uint16 nextBucket;uint256 activeCount;uint256 visited;bool done;
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
    function _scan(uint256[] storage ids,EligiblePage memory p,uint256 maxVisits) private view {
        EligibleSource[] memory rows=new EligibleSource[](maxVisits);
        uint256 count;
        while(p.nextOrder<ids.length&&p.visited<maxVisits){
            uint256 id=ids[p.nextOrder];L.Order storage o=orders[id];
            if(p.nextBucket>=o.steps||o.remaining==0)revert InvalidRequest();
            uint16 i=p.nextBucket;
            if(o.eligible(i,p.usd))rows[count++]=EligibleSource(id,i,o.steps==1?1:2,o.available(i));
            ++p.visited;++p.nextBucket;
            if(p.nextBucket==o.steps){++p.nextOrder;p.nextBucket=0;}
        }
        assembly ("memory-safe") { mstore(rows,count) }
        p.sources=rows;p.done=p.nextOrder==ids.length;
    }
    function eligibleGroup(address base,address quote,E.Side activeSide) external view
        returns(P.Ratio memory rate,P.Ratio memory usd,EligibleSource[] memory sources){
        _identity();
        uint256[] storage ids=activeOrders[_marketKey(base,quote,activeSide==E.Side.Buy)];
        EligiblePage memory page;
        (page.rate,page.usd)=pricing.read(base,quote);
        uint256 visits;
        for(uint256 i;i<ids.length;i++)visits+=orders[ids[i]].steps;
        _scan(ids,page,visits);
        return(page.rate,page.usd,page.sources);
    }
    function bucket(uint256 id,uint16 index) external view returns(uint256 level,uint256 amount,bool eligible){
        L.Order storage o=orders[id];level=o.level(index);amount=o.available(index);
        _identity();(,P.Ratio memory usd)=pricing.read(o.base,o.quote);eligible=o.eligible(index,usd);
    }
    function _price(L.Order storage o,uint16 index) private view returns(P.Ratio memory rate){
        _identity();P.Ratio memory usd;(rate,usd)=pricing.read(o.base,o.quote);
        if(!o.eligible(index,usd))revert L.Ineligible();
    }

    function executeDirect(uint256 id,uint16 index,uint256 budget,uint256 minOutput,uint256 deadline,address recipient)
        external payable nonReentrant returns(E.Result memory r){
        if(budget==0||block.timestamp>deadline||recipient==address(0)||recipient==address(this))revert InvalidRequest();
        L.Order storage o=orders[id];uint256 net;
        address input=o.sell?o.quote:o.base;address output=o.sell?o.base:o.quote;
        {
            P.Ratio memory rate=_price(o,index);(r,net)=_plan(o,index,budget,rate);
            if(net==0||r.netOutput==0||r.netOutput<minOutput)revert InvalidRequest();
            _collect(input,msg.sender,budget);

            P.Ratio memory afterRate=_price(o,index);if(afterRate.n!=rate.n||afterRate.d!=rate.d)revert PriceChanged();
        }
        o.fill(index,r.netOutput,net,false);_deactivateIfEmpty(id,o);liabilities[output]-=r.netOutput;liabilities[input]+=net;_recordLimitFee(input,r.grossInputUsed-net,_limitFeePayer(msg.sender));
        _send(output,recipient,r.netOutput);_send(input,msg.sender,r.inputRefund);_solvent(input);
        emit Filled(id,index,msg.sender,false,r.netOutput,net);
    }
    function _limitFeePayer(address caller) internal view virtual returns(address){return caller;}
    function _recordLimitFee(address asset,uint256 amount,address) internal virtual {fees[asset]+=amount;}
    function _beginVaultFeeExecution(address) internal virtual {}
    function _endVaultFeeExecution() internal virtual {}
    function _plan(L.Order storage o,uint16 index,uint256 budget,P.Ratio memory rate) private view returns(E.Result memory r,uint256 net){
        return passiveCrossMath.planLimit(o.sell,o.available(index),budget,rate,msg.sender==address(vault)?0:FEE_BPS);
    }
    event InternalGroupFilled(uint256 indexed id,uint16 indexed bucket,uint256 sourceCount,uint256 principal,uint256 proceeds);
    event InternalQuoteConverted(address indexed input,address indexed output,uint256 inputUsed,uint256 outputReceived);
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

    function _verifyPassiveGroup(S snapshot,E.DirectRequest memory q,G.Plan memory plan,bool filled) private view {
        passiveCrossMath.verifyGroup(snapshot,q,plan,filled);
    }
    function _planInternalGroup(S snapshot,E.DirectRequest memory q) private view returns(G.Plan memory){
        G math=settlementPolicy.groupMath();
        return math.planPassiveFor(snapshot,q);
    }
    function _passiveVaultLeg(E.DirectRequest memory request,uint256 input,uint256 output) private {
        address outputAsset=request.side==E.Side.Buy?request.baseToken:request.canonicalQuote;
        uint256 beforeInput=_balance(request.inputAsset);uint256 beforeOutput=_balance(outputAsset);
        if(request.inputAsset!=address(0))IERC20(request.inputAsset).forceApprove(address(vault),input);
        E.DirectRequest memory leg=E.DirectRequest(request.chainId,request.baseToken,request.canonicalQuote,
            request.inputAsset,request.side,input,input,output,request.deadline,payable(address(this)),false);
        E.Result memory result=vault.executeDirect{value:request.inputAsset==address(0)?input:0}(leg,"","");
        if(request.inputAsset!=address(0))IERC20(request.inputAsset).forceApprove(address(vault),0);
        if(result.grossInputUsed!=input||result.netOutput!=output||result.inputRefund!=0
            ||beforeInput-_balance(request.inputAsset)!=input||_balance(outputAsset)-beforeOutput!=output)revert AssetTransfer();
    }
    function _settlementCaller(uint256 id) private view returns(address){
        return msg.sender==address(this)?orders[id].owner:msg.sender;
    }
    function _fillPassiveGroup(uint256 id,S snapshot,E.DirectRequest memory q,G.Plan memory plan) private returns(bool viaVault){
        if(plan.netInput!=plan.grossInput||plan.feeAdjustment!=0||plan.grossInput>q.maxGrossInput)revert InvalidRequest();
        _verifyPassiveGroup(snapshot,q,plan,false);
        address output=q.side==E.Side.Buy?q.baseToken:q.canonicalQuote;
        for(uint256 i;i<plan.sources.length;i++)if(plan.grossInputs[i]!=0){
            S.Source memory source=plan.sources[i];
            if(source.kind==0){_passiveVaultLeg(q,plan.grossInputs[i],plan.outputs[i]);viaVault=true;}
            else{
                L.Order storage opposite=orders[source.id];
                if(source.id==id||opposite.base!=q.baseToken||opposite.quote!=q.canonicalQuote||opposite.sell!=(q.side==E.Side.Buy)
                    ||source.kind!=(opposite.steps==1?1:2)||opposite.available(source.bucket)!=source.available
                    ||!opposite.eligible(source.bucket,plan.usd))revert InvalidRequest();
                opposite.fill(source.bucket,plan.outputs[i],plan.grossInputs[i],false);_deactivateIfEmpty(source.id,opposite);
                liabilities[output]-=plan.outputs[i];liabilities[q.inputAsset]+=plan.grossInputs[i];
                emit Filled(source.id,source.bucket,_settlementCaller(id),false,plan.outputs[i],plan.grossInputs[i]);
            }
        }
        _verifyPassiveGroup(snapshot,q,plan,true);
    }
    function _exhausted(G.Plan memory plan) private pure returns(bool){
        for(uint256 i;i<plan.sources.length;i++)if(plan.sources[i].available!=plan.outputs[i])return false;return true;
    }
    function _convertInternal(address input,address output,uint256 amount,uint256 bound,uint256 deadline,bool exactOutput)
        private returns(uint256 used,uint256 received){
        if(address(internalQuoteAdapter).codehash!=internalQuoteAdapterHash)revert InvalidRequest();
        uint256 beforeIn=_balance(input);uint256 beforeOut=_balance(output);
        uint256 budget=exactOutput?bound:amount;
        if(input!=address(0))IERC20(input).forceApprove(address(internalQuoteAdapter),budget);
        if(exactOutput){
            used=internalQuoteAdapter.swapExactOutput{value:input==address(0)?budget:0}(input==address(0),amount,budget,deadline);
            received=amount;
        }else{
            received=internalQuoteAdapter.swapExactInput{value:input==address(0)?budget:0}(input==address(0),amount,bound,deadline);
            used=amount;
        }
        if(input!=address(0))IERC20(input).forceApprove(address(internalQuoteAdapter),0);
        if(used==0||used>budget||received==0||beforeIn-_balance(input)!=used||_balance(output)-beforeOut!=received
            ||address(internalQuoteAdapter).codehash!=internalQuoteAdapterHash)revert AssetTransfer();
        emit InternalQuoteConverted(input,output,used,received);
    }
    struct CrossResult {uint256 input;uint256 output;uint256 sources;bool viaVault;}
    function _crossPassive(uint256 id,uint16 index,S snapshot,E.DirectRequest memory original,E.Result memory current) private returns(CrossResult memory r){
        uint256 remaining=current.inputRefund;
        address usd=pricing.usdg();address other=original.canonicalQuote==address(0)?usd:address(0);
        uint256 inventory;
        (,inventory)=vault.availableLiquidity(original.baseToken,other,original.side);
        if(inventory==0&&activeOrders[_marketKey(original.baseToken,other,original.side==E.Side.Buy)].length==0)return r;
        if(address(internalQuoteAdapter).codehash!=internalQuoteAdapterHash)revert InvalidRequest();
        bytes32 checkpoint=settlementPolicy.conversionFingerprint(original.baseToken);
        E.DirectRequest memory leg=E.DirectRequest(original.chainId,original.baseToken,other,
            original.side==E.Side.Buy?other:original.baseToken,original.side,remaining,0,0,original.deadline,payable(address(this)),false);
        if(original.side==E.Side.Buy)leg.maxGrossInput=passiveCrossMath.affordable(internalQuoteAdapter,original.canonicalQuote==address(0),remaining);
        G.Plan memory plan=_planInternalGroup(snapshot,leg);
        if(plan.grossInput==0)return r;
        L.Order storage initiator=orders[id];
        (uint256 maxInput,uint256 minConverted)=passiveCrossMath.conversionBounds(internalQuoteAdapter,pricing,
            PassiveCrossMath.QuoteRequest(original.baseToken,original.canonicalQuote,initiator.sell,initiator.decimals,initiator.level(index),
                current.grossInputUsed,current.netOutput,remaining,plan.grossInput,plan.output));
        if(maxInput==0)return r;
        if(original.side==E.Side.Buy){
            (r.input,)=_convertInternal(original.canonicalQuote,other,plan.grossInput,maxInput,original.deadline,true);

            leg.maxGrossInput=plan.grossInput;r.viaVault=_fillPassiveGroup(id,snapshot,leg,plan);r.output=plan.output;
        }else{
            r.viaVault=_fillPassiveGroup(id,snapshot,leg,plan);
            (,r.output)=_convertInternal(other,original.canonicalQuote,plan.output,minConverted,original.deadline,false);r.input=plan.grossInput;
        }
        if(checkpoint!=settlementPolicy.conversionFingerprint(original.baseToken))revert PriceChanged();
        _verifyPassiveGroup(snapshot,leg,plan,true);r.sources=plan.sources.length;_solvent(other);
    }
    function _executeInternal(uint256 id,uint16 index,uint256 budget,uint256 minOutput,uint256 deadline)
        private returns(E.Result memory result){
        L.Order storage initiator=orders[id];_price(initiator,index);
        if(budget==0||budget>initiator.available(index)||block.timestamp>deadline)revert InvalidRequest();
        InternalSettlementPolicy policy=settlementPolicy;
        S snapshot=S(policy.settlementSnapshot());
        address input=initiator.sell?initiator.base:initiator.quote;
        address output=initiator.sell?initiator.quote:initiator.base;
        E.DirectRequest memory request=E.DirectRequest(configuredChainId,initiator.base,initiator.quote,input,
            initiator.sell?E.Side.Sell:E.Side.Buy,budget,0,0,deadline,payable(address(this)),false);
        G.Plan memory first=_planInternalGroup(snapshot,request);
        if(first.grossInput!=0&&!passiveCrossMath.limitSatisfied(initiator.sell,initiator.decimals,initiator.level(index),
            first.grossInput,first.output,first.rate,first.usd)){
            if(minOutput==0)return E.Result(0,0,budget);
            revert InvalidRequest();
        }
        internalPositionExecution=true;_beginVaultFeeExecution(initiator.owner);
        bool viaVault=_fillPassiveGroup(id,snapshot,request,first);
        result=E.Result(first.grossInput,first.output,budget-first.grossInput);uint256 sourceCount=first.sources.length;
        if(result.inputRefund!=0&&_exhausted(first)){
            CrossResult memory second=_crossPassive(id,index,snapshot,request,result);
            if(second.input!=0){
                result.grossInputUsed+=second.input;result.inputRefund-=second.input;result.netOutput+=second.output;
                sourceCount+=second.sources;viaVault=viaVault||second.viaVault;
                if(!passiveCrossMath.limitSatisfied(initiator.sell,initiator.decimals,initiator.level(index),
                    result.grossInputUsed,result.netOutput,first.rate,first.usd))revert InvalidRequest();
            }
        }
        if(result.grossInputUsed==0&&minOutput==0){
            _endVaultFeeExecution();internalPositionExecution=false;return result;
        }
        if(result.grossInputUsed==0||result.netOutput<minOutput)revert InvalidRequest();
        _verifyPassiveGroup(snapshot,request,first,true);

        _price(initiator,index);
        initiator.fill(index,result.grossInputUsed,result.netOutput,false);_deactivateIfEmpty(id,initiator);
        liabilities[input]-=result.grossInputUsed;liabilities[output]+=result.netOutput;
        _endVaultFeeExecution();internalPositionExecution=false;_solvent(input);_solvent(output);
        emit Filled(id,index,_settlementCaller(id),viaVault,result.grossInputUsed,result.netOutput);
        emit InternalGroupFilled(id,index,sourceCount,result.grossInputUsed,result.netOutput);
    }

    function claim(uint256 id,uint256 amount) external nonReentrant {
        L.Order storage o=orders[id];if(o.owner!=msg.sender)revert Unauthorized();
        uint256 fee=o.claim(amount,FEE_BPS);address asset=o.sell?o.quote:o.base;
        liabilities[asset]-=amount;_recordLimitFee(asset,fee,msg.sender);_send(asset,msg.sender,amount-fee);emit Claimed(id,amount,fee);
    }
    function withdraw(uint256 id,uint16 index,uint256 amount) external nonReentrant {
        L.Order storage o=orders[id];if(o.owner!=msg.sender)revert Unauthorized();o.withdraw(index,amount);_deactivateIfEmpty(id,o);
        address asset=o.sell?o.base:o.quote;liabilities[asset]-=amount;_send(asset,msg.sender,amount);emit Withdrawn(id,index,amount);
    }

    function withdrawRemaining(uint256 id) external nonReentrant {
        L.Order storage o=orders[id];if(o.owner!=msg.sender)revert Unauthorized();
        uint256 amount=o.remaining;if(amount==0)revert InvalidRequest();
        for(uint16 i=0;i<o.steps;i++){uint256 part=o.available(i);if(part==0)continue;o.withdraw(i,part);emit Withdrawn(id,i,part);}
        _deactivateIfEmpty(id,o);address asset=o.sell?o.base:o.quote;
        liabilities[asset]-=amount;_send(asset,msg.sender,amount);
    }
    function _balance(address asset) private view returns(uint256){return asset==address(0)?address(this).balance:IERC20(asset).balanceOf(address(this));}
    function _collect(address asset,address from,uint256 amount) private {
        if(asset==address(0)){if(msg.value!=amount)revert AssetTransfer();}
        else{if(msg.value!=0)revert AssetTransfer();uint256 b=_balance(asset);IERC20(asset).safeTransferFrom(from,address(this),amount);if(_balance(asset)-b!=amount)revert AssetTransfer();}
    }
    function _send(address asset,address to,uint256 amount) private {
        if(amount!=0){if(asset==address(0)){(bool ok,)=payable(to).call{value:amount}("");if(!ok)revert AssetTransfer();}
        else{uint256 b=_balance(asset);uint256 r=IERC20(asset).balanceOf(to);IERC20(asset).safeTransfer(to,amount);if(b-_balance(asset)!=amount||IERC20(asset).balanceOf(to)-r!=amount)revert AssetTransfer();}}
        _solvent(asset);
    }
    function _solvent(address asset) private view {if(_balance(asset)<liabilities[asset]+fees[asset])revert AssetTransfer();}
    receive() external payable {if(msg.sender!=address(vault)&&!(internalPositionExecution&&msg.sender==address(internalQuoteAdapter)))revert Unauthorized();}
}
