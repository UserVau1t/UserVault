pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FeeAwareVaultCore} from "./MainnetFeeCollectors.sol";
import {MainnetFeeProcessing} from "./MainnetFeeProcessing.sol";
import {MainnetMarketLiquiditySnapshot as S} from "./MainnetMarketLiquiditySnapshot.sol";
import {InternalSettlementPolicy} from "./InternalSettlementPolicy.sol";
import {CreateGroupMath as G} from "./CreateGroupMath.sol";
import {PinnedMarketPricing} from "../reference/PinnedMarketPricing.sol";
import {V2NativeQuoteAdapter} from "../adapters/V2NativeQuoteAdapter.sol";
import {IUserVaultExecution as E} from "../interfaces/IUserVaultExecution.sol";
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";
import {VaultAccounting as A} from "../libraries/VaultAccounting.sol";

interface ICreateHost {
    function creditCreation(address owner,address base,address quote,uint8 side,uint256 matched,uint256 output) external returns(uint256);
    function administrator() external view returns(address);
    function pricing() external view returns(PinnedMarketPricing);
    function quoteAdapter() external view returns(V2NativeQuoteAdapter);
    function internalSettlementPolicy() external view returns(InternalSettlementPolicy);
}

contract SharedCreateModule is FeeAwareVaultCore {
    using SafeERC20 for IERC20;
    address public immutable host;
    S public immutable group;
    bytes32 private immutable groupHash;
    G private immutable groupMath;
    error WrongHost();error GroupChanged();error LegMismatch();
    constructor(ICreateHost host_,S group_,InternalSettlementPolicy policy)
        FeeAwareVaultCore(block.chainid,host_.administrator(),host_.pricing(),host_.quoteAdapter(),policy,address(host_)) {
        if(address(host_).code.length==0||address(group_).code.length==0
            ||address(host_.internalSettlementPolicy())!=address(policy)
            ||address(group_.vault())!=address(host_)||address(group_.limits())!=policy.manager()
            ||address(group_.pricing())!=address(host_.pricing()))revert WrongHost();
        host=address(host_);group=group_;groupHash=address(group_).codehash;groupMath=policy.groupMath();
    }
    modifier onlyHost(){if(address(this)!=host)revert WrongHost();_;}
    function createPosition(E.DirectRequest calldata q,bytes calldata referenceHints,uint256 minPositionAmount)
        public payable override onlyHost returns(CreateResult memory){return super.createPosition(q,referenceHints,minPositionAmount);}
    function createCrossBuyPosition(E.DirectRequest calldata q,bytes calldata referenceHints,bytes calldata conversionHints,uint256 minPositionAmount)
        public payable override onlyHost returns(CreateResult memory){return super.createCrossBuyPosition(q,referenceHints,conversionHints,minPositionAmount);}
    function createCrossSellPosition(E.DirectRequest calldata q,bytes calldata referenceHints,bytes calldata conversionHints,uint256 minPositionAmount)
        public payable override onlyHost returns(CreateResult memory){return super.createCrossSellPosition(q,referenceHints,conversionHints,minPositionAmount);}

    function executeDirect(E.DirectRequest calldata,bytes calldata,bytes calldata) public payable override returns(E.Result memory){revert WrongHost();}
    function claim(uint256,uint256) public pure override {revert WrongHost();}
    function withdraw(uint256,uint256) public pure override {revert WrongHost();}
    function withdrawAll(uint256) public pure override {revert WrongHost();}
    function exportFee(uint256) external pure override {revert WrongHost();}
    function bindFeeProcessor(MainnetFeeProcessing) external pure override {revert WrongHost();}
    function configureFeeParents(address[] calldata) external pure override {revert WrongHost();}
    function setPaused(bool) external pure override {revert WrongHost();}
    function position(uint256) external pure override returns(A.Position memory){revert WrongHost();}
    function epoch(uint256) external pure override returns(EpochInfo memory){revert WrongHost();}
    function accounted(address) external pure override returns(uint256,uint256){revert WrongHost();}
    function entitlement(uint256) public pure override returns(uint256,uint256){revert WrongHost();}
    function dustEligible(uint256,uint256) external pure override returns(bool){revert WrongHost();}
    function epochCarry(uint256) external pure override returns(uint256,uint256,uint256,uint256){revert WrongHost();}

    function _matchingLiquidity(address base,address quote,E.Side side) internal view override returns(uint256,uint256){
        if(address(group).codehash!=groupHash)revert GroupChanged();
        return(0,group.totalAvailable(base,quote,side));
    }
    function _groupPlan(E.DirectRequest memory q) private view returns(G.Plan memory){
        if(address(group).codehash!=groupHash)revert GroupChanged();
        return groupMath.planPassiveFor(group,q);
    }
    function _beforeCreatePayout(E.DirectRequest calldata q) internal view override returns(bytes32){
        if(address(group).codehash!=groupHash)revert GroupChanged();
        return group.creationFingerprint(q.baseToken,q.side);
    }
    function _afterCreatePayout(E.DirectRequest calldata q,bytes32 checkpoint) internal view override {
        if(checkpoint!=_beforeCreatePayout(q))revert GroupChanged();
    }
    function _matchCollected(E.DirectRequest memory q,bytes calldata) internal override returns(E.Result memory){
        G.Plan memory p=_groupPlan(q);return _executeGroup(q,p);
    }
    function _verify(E.DirectRequest memory q,G.Plan memory p,bool afterFill) private view {
        internalSettlementPolicy.crossMath().verifyGroup(group,q,p,afterFill);
    }
    function _conversionFeeBps() internal pure override returns(uint16){return 0;}
    function _creditCreation(E.DirectRequest calldata q,CreateResult memory result) internal override {
        if(result.trade.netOutput==0)return;
        uint256 proceedsId=ICreateHost(host).creditCreation(q.recipient,q.baseToken,q.canonicalQuote,uint8(q.side),result.trade.grossInputUsed,result.trade.netOutput);
        if(result.positionId==0)result.positionId=proceedsId;
    }
    function _executeGroup(E.DirectRequest memory q,G.Plan memory p) private returns(E.Result memory r){
        _verify(q,p,false);
        r=E.Result(p.grossInput,p.output,q.maxGrossInput-p.grossInput);
        if(r.grossInputUsed<q.minGrossInputFilled||r.netOutput<q.minNetOutput)revert E.ExecutionLimit();
        _enterResolvedFeePayer();
        address output=q.side==E.Side.Buy?q.baseToken:q.canonicalQuote;
        for(uint256 i;i<p.sources.length;i++)if(p.grossInputs[i]!=0){
            E.Result memory legResult;
            if(p.sources[i].kind==0){
                (uint256 eid,)=availableLiquidity(q.baseToken,q.canonicalQuote,q.side);
                _validateDirectExecution(q,eid,p.grossInputs[i],p.outputs[i]);
                _recordFill(eid,p.outputs[i],p.grossInputs[i]);
                legResult=E.Result(p.grossInputs[i],p.outputs[i],0);
            }else{
                uint256 beforeInput=_balance(q.inputAsset);uint256 beforeOutput=_balance(output);
                address target=address(group.limits());
                if(q.inputAsset!=address(0))IERC20(q.inputAsset).forceApprove(target,p.grossInputs[i]);
                legResult=group.limits().executeDirect{value:q.inputAsset==address(0)?p.grossInputs[i]:0}
                    (p.sources[i].id,p.sources[i].bucket,p.grossInputs[i],p.outputs[i],q.deadline,address(this));
                if(q.inputAsset!=address(0))IERC20(q.inputAsset).forceApprove(target,0);
                if(beforeInput-_balance(q.inputAsset)!=legResult.grossInputUsed
                    ||_balance(output)-beforeOutput!=legResult.netOutput)revert LegMismatch();
            }
            if(legResult.grossInputUsed!=p.grossInputs[i]||legResult.netOutput!=p.outputs[i]||legResult.inputRefund!=0)revert LegMismatch();
        }
        if(p.feeAdjustment!=0||p.grossInput!=p.netInput)revert LegMismatch();
        _verify(q,p,true);_leaveFeePayer();
    }
    function _buySecond(E.DirectRequest memory leg,uint256,uint256 budget,bytes calldata,bytes memory conversionHints)
        internal override returns(uint256 spent,uint256 output){
        leg.maxGrossInput=_affordableBuyQuote(leg.canonicalQuote,budget,conversionHints);
        if(leg.maxGrossInput==0)return(0,0);
        G.Plan memory p=_groupPlan(leg);if(p.grossInput==0)return(0,0);
        _checkpointConversion(leg.baseToken);
        spent=_convertBuyInput(_otherQuote(leg.canonicalQuote),leg.canonicalQuote,p.grossInput,budget,conversionHints);
        leg.maxGrossInput=p.grossInput;
        E.Result memory r=_executeGroup(leg,p);
        if(r.inputRefund!=0)revert LegMismatch();return(spent,r.netOutput);
    }
}
