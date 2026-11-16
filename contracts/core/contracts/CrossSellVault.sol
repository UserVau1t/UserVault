pragma solidity ^0.8.30;
import {SameQuoteCreateVault} from "./SameQuoteCreateVault.sol";
import {IUserVaultExecution as E} from "./interfaces/IUserVaultExecution.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

abstract contract CrossSellVault is SameQuoteCreateVault {
    event QuoteConverted(address indexed input,address indexed output,uint256 inputUsed,uint256 grossOutput,uint256 fee);
    function executeDirect(E.DirectRequest calldata q,bytes calldata referenceHints,bytes calldata conversionHints) external payable virtual override nonReentrant returns(E.Result memory r){
        return _executeCrossSell(q,referenceHints,conversionHints);
    }
    function _executeCrossSell(E.DirectRequest calldata q,bytes calldata referenceHints,bytes calldata conversionHints) internal returns(E.Result memory r){
        if(!q.allowCrossQuote)return _executeSameQuote(q,referenceHints,conversionHints);
        if(q.side!=E.Side.Sell)revert E.UnsupportedRoute();
        E.DirectRequest memory leg=q;leg.allowCrossQuote=false;
        _checkDirectRequest(leg,"");_collect(q.inputAsset,msg.sender,q.maxGrossInput);
        r=_matchCrossSell(q,referenceHints,conversionHints);
        _send(q.canonicalQuote,q.recipient,r.netOutput);_send(q.baseToken,msg.sender,r.inputRefund);
        emit E.DirectExecuted(msg.sender,q.recipient,q.baseToken,q.canonicalQuote,q.side,r.grossInputUsed,r.netOutput,r.inputRefund);
    }
    function _matchCrossSell(E.DirectRequest calldata q,bytes calldata referenceHints,bytes memory conversionHints) internal returns(E.Result memory r){
        E.DirectRequest memory leg=q;leg.allowCrossQuote=false;
        leg.minNetOutput=0;leg.minGrossInputFilled=0;
        r=_matchCollected(leg,referenceHints);
        (,uint256 remainingFirst)=_matchingLiquidity(q.baseToken,q.canonicalQuote,E.Side.Sell);
        if(q.allowCrossQuote&&r.inputRefund!=0&&remainingFirst==0){
            leg.canonicalQuote=q.canonicalQuote==address(0)?_s().usdg:address(0);
            leg.maxGrossInput=r.inputRefund;
            E.Result memory second=_matchCollected(leg,referenceHints);
            if(second.netOutput!=0){
                _checkpointConversion(q.baseToken);
                r.netOutput+=_convertProceeds(leg.canonicalQuote,q.canonicalQuote,second.netOutput,conversionHints);
                _validateCrossSellSettlement(q,r.grossInputUsed+second.grossInputUsed,r.netOutput);
            }
            r.grossInputUsed+=second.grossInputUsed;r.inputRefund=second.inputRefund;
        }
        if(r.grossInputUsed<q.minGrossInputFilled)revert E.ExecutionLimit();
        if(r.netOutput<q.minNetOutput)revert E.OutputBelowMinimum();
    }
    function createPosition(E.DirectRequest calldata q,bytes calldata referenceHints,uint256 minPositionAmount) external payable virtual override nonReentrant returns(CreateResult memory result){
        if(q.side!=E.Side.Sell)return _createSameQuote(q,referenceHints,minPositionAmount);
        return _createCrossSell(q,referenceHints,"",minPositionAmount);
    }

    function createCrossSellPosition(E.DirectRequest calldata q,bytes calldata referenceHints,bytes calldata conversionHints,uint256 minPositionAmount) public payable virtual nonReentrant returns(CreateResult memory result){
        _prepareToken(q.baseToken,referenceHints);
        if(q.side!=E.Side.Sell)revert E.UnsupportedRoute();
        return _createCrossSell(q,referenceHints,conversionHints,minPositionAmount);
    }
    function _createCrossSell(E.DirectRequest calldata q,bytes calldata referenceHints,bytes memory conversionHints,uint256 minPositionAmount) internal returns(CreateResult memory result){
        E.DirectRequest memory checked=q;checked.allowCrossQuote=false;
        _checkDirectRequest(checked,"");
        address other=q.canonicalQuote==address(0)?_s().usdg:address(0);
        (,uint256 first)=_matchingLiquidity(q.baseToken,q.canonicalQuote,E.Side.Sell);
        (,uint256 second)=_matchingLiquidity(q.baseToken,other,E.Side.Sell);
        if(first==0&&second==0&&!_meetsCreationMinimum(q.baseToken,q.canonicalQuote,Side.Sell,q.maxGrossInput))revert CreationBelowMinimum();
        _collect(q.baseToken,msg.sender,q.maxGrossInput);
        result.trade=_matchCrossSell(q,referenceHints,conversionHints);
        (,first)=_matchingLiquidity(q.baseToken,q.canonicalQuote,E.Side.Sell);
        (,second)=_matchingLiquidity(q.baseToken,other,E.Side.Sell);
        uint256 remainder=result.trade.inputRefund;
        if(first==0&&second==0&&remainder!=0&&_meetsCreationMinimum(q.baseToken,q.canonicalQuote,Side.Sell,remainder)){
            result.positionId=_open(msg.sender,q.baseToken,q.canonicalQuote,Side.Sell,remainder);
            result.positionAmount=remainder;result.trade.inputRefund=0;
        }
        if(result.positionAmount<minPositionAmount)revert PositionBelowMinimum();
        bytes32 payoutCheckpoint=_beforeCreatePayout(q);
        _creditCreation(q,result);_send(q.baseToken,msg.sender,result.trade.inputRefund);
        _afterCreatePayout(q,payoutCheckpoint);
        emit CreateProcessed(msg.sender,result.positionId,result.positionAmount,result.trade.grossInputUsed,result.trade.netOutput,result.trade.inputRefund);
    }
    function _convertProceeds(address input,address output,uint256 amount,bytes memory hints) private returns(uint256 net){
        uint256 beforeIn=_balance(input);uint256 beforeOut=_balance(output);
        _swapQuoteExactInput(input,output,amount,hints);
        uint256 afterIn=_balance(input);uint256 afterOut=_balance(output);
        if(afterIn>beforeIn||beforeIn-afterIn!=amount||afterOut<=beforeOut)revert AssetTransfer();
        uint256 gross=afterOut-beforeOut;uint16 bps=_conversionFeeBps();
        if((bps!=0&&bps<20)||bps>100)revert E.InvalidRequest();
        uint256 fee=Math.mulDiv(gross,bps,10000);_recordProtocolFee(output,fee,_feePayer(msg.sender));net=gross-fee;
        _solvent(input);_solvent(output);emit QuoteConverted(input,output,amount,gross,fee);
    }
    function _balance(address asset) internal view returns(uint256){return asset==address(0)?address(this).balance:IERC20(asset).balanceOf(address(this));}
    receive() external payable virtual {if(msg.sender!=_conversionTarget())revert Unauthorized();}
    function _conversionTarget() internal view virtual returns(address);
    function _swapQuoteExactInput(address input,address output,uint256 amount,bytes memory hints) internal virtual;
    function _conversionFeeBps() internal view virtual returns(uint16);

    function _checkpointConversion(address) internal virtual {}

    function _validateCrossSellSettlement(E.DirectRequest calldata request,uint256 totalGrossInput,uint256 totalNetOutput) internal view virtual;
}
