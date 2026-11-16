pragma solidity ^0.8.30;
import {CrossSellVault} from "./CrossSellVault.sol";
import {IUserVaultExecution as E} from "./interfaces/IUserVaultExecution.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

abstract contract CrossBuyVault is CrossSellVault {
    event BuyQuoteConverted(address indexed input,address indexed output,uint256 grossInput,uint256 fee,uint256 exactOutput);

    function executeDirect(E.DirectRequest calldata q,bytes calldata referenceHints,bytes calldata conversionHints) public payable virtual override nonReentrant returns(E.Result memory r){
        if(q.side==E.Side.Sell)return _executeCrossSell(q,referenceHints,conversionHints);
        if(!q.allowCrossQuote)return _executeSameQuote(q,referenceHints,conversionHints);
        _checkBuy(q);
        _collect(q.inputAsset,msg.sender,q.maxGrossInput);
        r=_matchCrossBuy(q,referenceHints,conversionHints);
        _sendDirectOutput(q,r);_send(q.inputAsset,msg.sender,r.inputRefund);
        emit E.DirectExecuted(msg.sender,q.recipient,q.baseToken,q.canonicalQuote,q.side,r.grossInputUsed,r.netOutput,r.inputRefund);
    }

    function createPosition(E.DirectRequest calldata q,bytes calldata referenceHints,uint256 minPositionAmount) public payable virtual override nonReentrant returns(CreateResult memory){
        _prepareToken(q.baseToken,referenceHints);
        if(q.side==E.Side.Sell)return _createCrossSell(q,referenceHints,"",minPositionAmount);
        return _createCrossBuy(q,referenceHints,"",minPositionAmount);
    }
    function createCrossBuyPosition(E.DirectRequest calldata q,bytes calldata referenceHints,bytes calldata conversionHints,uint256 minPositionAmount) public payable virtual nonReentrant returns(CreateResult memory){
        _prepareToken(q.baseToken,referenceHints);
        if(q.side!=E.Side.Buy)revert E.UnsupportedRoute();
        return _createCrossBuy(q,referenceHints,conversionHints,minPositionAmount);
    }
    function _checkBuy(E.DirectRequest calldata q) private view {
        E.DirectRequest memory checked=q;checked.allowCrossQuote=false;
        _checkDirectRequest(checked,"");
    }
    function _otherQuote(address quote) internal view returns(address){return quote==address(0)?_s().usdg:address(0);}

    function _createCrossBuy(E.DirectRequest calldata q,bytes calldata referenceHints,bytes memory conversionHints,uint256 minPositionAmount) private returns(CreateResult memory result){
        _checkBuy(q);
        (,uint256 first)=_matchingLiquidity(q.baseToken,q.canonicalQuote,E.Side.Buy);
        (,uint256 second)=_matchingLiquidity(q.baseToken,_otherQuote(q.canonicalQuote),E.Side.Buy);
        if(first==0&&second==0&&!_meetsCreationMinimum(q.baseToken,q.canonicalQuote,Side.Buy,q.maxGrossInput))revert CreationBelowMinimum();
        _collect(q.inputAsset,msg.sender,q.maxGrossInput);
        result.trade=_matchCrossBuy(q,referenceHints,conversionHints);
        (,first)=_matchingLiquidity(q.baseToken,q.canonicalQuote,E.Side.Buy);
        (,second)=_matchingLiquidity(q.baseToken,_otherQuote(q.canonicalQuote),E.Side.Buy);
        uint256 remainder=result.trade.inputRefund;

        if(first==0&&second==0&&remainder!=0&&_meetsCreationMinimum(q.baseToken,q.canonicalQuote,Side.Buy,remainder)){
            result.positionId=_open(msg.sender,q.baseToken,q.canonicalQuote,Side.Buy,remainder);
            result.positionAmount=remainder;result.trade.inputRefund=0;
        }
        if(result.positionAmount<minPositionAmount)revert PositionBelowMinimum();
        bytes32 payoutCheckpoint=_beforeCreatePayout(q);
        _creditCreation(q,result);_send(q.inputAsset,msg.sender,result.trade.inputRefund);
        _afterCreatePayout(q,payoutCheckpoint);
        emit CreateProcessed(msg.sender,result.positionId,result.positionAmount,result.trade.grossInputUsed,result.trade.netOutput,result.trade.inputRefund);
    }

    function _matchCrossBuy(E.DirectRequest calldata q,bytes calldata referenceHints,bytes memory conversionHints) private returns(E.Result memory r){
        E.DirectRequest memory leg=q;leg.allowCrossQuote=false;leg.minNetOutput=0;leg.minGrossInputFilled=0;
        r=_matchCollected(leg,referenceHints);
        (,uint256 first)=_matchingLiquidity(q.baseToken,q.canonicalQuote,E.Side.Buy);
        if(q.allowCrossQuote&&first==0&&r.inputRefund!=0){
            leg.canonicalQuote=_otherQuote(q.canonicalQuote);leg.inputAsset=leg.canonicalQuote;
            (,uint256 inventory)=_matchingLiquidity(q.baseToken,leg.canonicalQuote,E.Side.Buy);
            if(inventory!=0){
                (uint256 spent,uint256 output)=_buySecond(leg,inventory,r.inputRefund,referenceHints,conversionHints);
                r.grossInputUsed+=spent;r.inputRefund-=spent;r.netOutput+=output;
                if(output!=0)_validateCrossBuySettlement(q,r.grossInputUsed,r.netOutput);
            }
        }
        if(r.grossInputUsed<q.minGrossInputFilled)revert E.ExecutionLimit();
        if(r.netOutput<q.minNetOutput)revert E.OutputBelowMinimum();
    }

    function _buySecond(E.DirectRequest memory leg,uint256 inventory,uint256 budget,bytes calldata referenceHints,bytes memory conversionHints) internal virtual returns(uint256 spent,uint256 output){

        leg.maxGrossInput=_affordableBuyQuote(leg.canonicalQuote,budget,conversionHints);
        if(leg.maxGrossInput==0)return(0,0);
        (uint256 required,,uint256 expected)=plan(leg,inventory,_directReference(leg.baseToken,leg.canonicalQuote,referenceHints));
        if(required==0)return(0,0);
        _checkpointConversion(leg.baseToken);
        spent=_convertBuyInput(_otherQuote(leg.canonicalQuote),leg.canonicalQuote,required,budget,conversionHints);
        leg.maxGrossInput=required;
        E.Result memory second=_matchCollected(leg,referenceHints);

        if(second.grossInputUsed!=required||second.netOutput!=expected)revert E.ExecutionLimit();
        output=second.netOutput;
    }

    function _buyConversionBps() private view returns(uint16 bps){bps=_conversionFeeBps();if((bps!=0&&bps<20)||bps>100)revert E.InvalidRequest();}
    function _affordableBuyQuote(address output,uint256 budget,bytes memory hints) internal view returns(uint256){
        uint256 maxNetInput=budget-Math.mulDiv(budget,_buyConversionBps(),10000);
        (bool safe,uint256 affordable)=_quoteCrossBuyBudget(_otherQuote(output),output,maxNetInput,hints);
        return safe?affordable:0;
    }
    function _convertBuyInput(address input,address output,uint256 required,uint256 budget,bytes memory hints) internal returns(uint256 gross){
        uint16 bps=_buyConversionBps();
        uint256 maxNetInput=budget-Math.mulDiv(budget,bps,10000);
        uint256 net;
        {
            uint256 beforeIn=_balance(input);uint256 beforeOut=_balance(output);
            _swapQuoteExactOutput(input,output,required,maxNetInput,hints);
            uint256 afterIn=_balance(input);uint256 afterOut=_balance(output);
            if(afterIn>=beforeIn||beforeIn-afterIn>maxNetInput||afterOut<beforeOut||afterOut-beforeOut!=required)revert AssetTransfer();
            net=beforeIn-afterIn;
        }
        gross=net==maxNetInput?budget:Math.mulDiv(net-1,10000,10000-bps)+1;
        if(gross>budget||gross-Math.mulDiv(gross,bps,10000)!=net)revert E.ExecutionLimit();
        uint256 fee=gross-net;_recordProtocolFee(input,fee,_feePayer(msg.sender));
        _solvent(input);_solvent(output);
        emit BuyQuoteConverted(input,output,gross,fee,required);
    }

    function _quoteCrossBuyBudget(address input,address output,uint256 maxNetInput,bytes memory hints) internal view virtual returns(bool,uint256);

    function _swapQuoteExactOutput(address input,address output,uint256 exactOutput,uint256 maxNetInput,bytes memory hints) internal virtual;
    function _validateCrossBuySettlement(E.DirectRequest calldata request,uint256 totalGrossInput,uint256 totalNetOutput) internal view virtual;
}
