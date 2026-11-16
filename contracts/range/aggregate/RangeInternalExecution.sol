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

import {AggregateManagerCore} from "aggregate/AggregateManagerCore.sol";
import {FeeAttributedCollector} from "contracts/mainnet-candidate/FeeAttribution.sol";
import {PriceContextConsumer} from "cached/PriceContextConsumer.sol";
contract RangeInternalExecution is AggregateManagerCore,FeeAttributedCollector,PriceContextConsumer {
    using L for L.Order;using SafeERC20 for IERC20;
    address public immutable host;
    error WrongHost();
    constructor(uint256 chain,PinnedMarketPricing p,E v,address host_) AggregateManagerCore(chain,p,v){if(host_.code.length==0)revert WrongHost();host=host_;}
    function run(uint256 id,uint16 index,uint256 budget,uint256 minOutput,uint256 deadline) external returns(E.Result memory){
        if(address(this)!=host)revert WrongHost();return _executeInternal(id,index,budget,minOutput,deadline);
    }
    function _contextPricing() internal view override returns(address){return address(pricing);}
    function _limitFeePayer(address caller) internal view override returns(address){return _resolveFeePayer(caller);}
    function _recordLimitFee(address asset,uint256 amount,address payer) internal override {super._recordLimitFee(asset,amount,payer);_capturePaidFee(payer,asset,amount);}
    function _beginVaultFeeExecution(address payer) internal override {_enterFeePayer(payer);}
    function _endVaultFeeExecution() internal override {_leaveFeePayer();}
    function _debitProtocolFee(address asset,uint256 amount) internal override {fees[asset]-=amount;}
    function _checkFeeSolvency(address asset) internal view override {_solvent(asset);}
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
        _verifyPassiveGroup(snapshot,q,plan,false);address output=q.side==E.Side.Buy?q.baseToken:q.canonicalQuote;
        for(uint256 i;i<plan.sources.length;i++)if(plan.grossInputs[i]!=0){
            S.Source memory source=plan.sources[i];
            if(source.kind==0){_passiveVaultLeg(q,plan.grossInputs[i],plan.outputs[i]);viaVault=true;}
            else{
                AggregateGroup storage opposite=_aggregate().groups[source.id];
                if(source.id==id||!_isAggregate(source.id)||!opposite.exists||opposite.base!=q.baseToken||opposite.quote!=q.canonicalQuote
                    ||opposite.sell!=(q.side==E.Side.Buy)||source.kind!=2||source.bucket!=0||_groupAvailable(opposite,plan.usd)!=source.available)revert InvalidRequest();
                _fillAggregate(source.id,plan.outputs[i],plan.grossInputs[i],plan.usd);
                liabilities[output]-=plan.outputs[i];liabilities[q.inputAsset]+=plan.grossInputs[i];
                emit Filled(source.id,0,_settlementCaller(id),false,plan.outputs[i],plan.grossInputs[i]);
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
function _crossPassive(uint256 id,uint16 index,S snapshot,E.DirectRequest memory original,E.Result memory current) private returns(CrossResult memory r){
        uint256 remaining=current.inputRefund;
        address usd=pricing.usdg();address other=original.canonicalQuote==address(0)?usd:address(0);
        uint256 inventory;
        (,inventory)=vault.availableLiquidity(original.baseToken,other,original.side);
        if(inventory==0&&this.aggregateInventory(original.baseToken,other,original.side==E.Side.Buy)==0)return r;
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
        L.Order storage initiator=orders[id];_price(id,index);
        if(budget==0||budget>_bucketAvailable(id,index)||block.timestamp>deadline)revert InvalidRequest();
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

        _price(id,index);
        (,P.Ratio memory executionUsd)=pricing.read(initiator.base,initiator.quote);
        if(_ledgerOrder(id))R.fillOrder(_aggregate().ledger,id,index,executionUsd,result.grossInputUsed,result.netOutput);
        else{initiator.fill(index,result.grossInputUsed,result.netOutput,false);_deactivateIfEmpty(id,initiator);}
        liabilities[input]-=result.grossInputUsed;liabilities[output]+=result.netOutput;
        _endVaultFeeExecution();internalPositionExecution=false;_solvent(input);_solvent(output);
        emit Filled(id,index,_settlementCaller(id),viaVault,result.grossInputUsed,result.netOutput);
        emit InternalGroupFilled(id,index,sourceCount,result.grossInputUsed,result.netOutput);
    }
}
