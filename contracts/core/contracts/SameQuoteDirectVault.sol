pragma solidity ^0.8.30;
import {SharedVault} from "./SharedVault.sol";
import {IUserVaultExecution as E} from "./interfaces/IUserVaultExecution.sol";
import {ReferencePriceMath as P} from "./libraries/ReferencePriceMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

abstract contract SameQuoteDirectVault is SharedVault {
    function availableLiquidity(address base,address quote,E.Side activeSide) public view returns(uint256 eid,uint256 inventory){
        eid=_s().markets[marketId(base,quote)].activeEpoch;
        if(eid==0)return(0,0);
        EpochInfo storage e=_s().epochs[eid];
        if(e.ledger.closed||uint8(e.side)==uint8(activeSide))return(eid,0);
        return(eid,e.ledger.inventory);
    }
    function executeDirect(E.DirectRequest calldata q,bytes calldata referenceHints,bytes calldata conversionHints) external payable virtual nonReentrant returns(E.Result memory r){
        return _executeSameQuote(q,referenceHints,conversionHints);
    }
    function _executeSameQuote(E.DirectRequest calldata q,bytes calldata referenceHints,bytes calldata conversionHints) internal returns(E.Result memory r){
        address input=_checkDirectRequest(q,conversionHints);
        _collect(input,msg.sender,q.maxGrossInput);
        r=_matchCollected(q,referenceHints);
        _sendDirectOutput(q,r);
        _send(input,msg.sender,r.inputRefund);
        emit E.DirectExecuted(msg.sender,q.recipient,q.baseToken,q.canonicalQuote,q.side,r.grossInputUsed,r.netOutput,r.inputRefund);
    }
    function _checkDirectRequest(E.DirectRequest memory q,bytes memory conversionHints) internal view returns(address input){
        if(_s().paused)revert Paused();
        if(!_s().initialized||q.chainId!=block.chainid||block.timestamp>q.deadline||q.maxGrossInput==0||q.minGrossInputFilled>q.maxGrossInput||q.recipient==address(0)||q.recipient==address(this))revert E.InvalidRequest();
        if(q.baseToken==address(0)||q.baseToken.code.length==0||q.baseToken==_s().usdg||(q.canonicalQuote!=address(0)&&q.canonicalQuote!=_s().usdg))revert E.InvalidRequest();
        input=q.side==E.Side.Buy?q.canonicalQuote:q.baseToken;
        if(q.inputAsset!=input||q.allowCrossQuote||conversionHints.length!=0)revert E.UnsupportedRoute();
    }

    function _matchCollected(E.DirectRequest memory q,bytes calldata referenceHints) internal virtual returns(E.Result memory r){
        (uint256 eid,uint256 inventory)=availableLiquidity(q.baseToken,q.canonicalQuote,q.side);
        uint256 netInput;
        if(inventory!=0){
            P.Ratio memory rate=_directReference(q.baseToken,q.canonicalQuote,referenceHints);
            (r.grossInputUsed,netInput,r.netOutput)=plan(q,inventory,rate);
        }
        if(r.grossInputUsed<q.minGrossInputFilled)revert E.ExecutionLimit();
        if(r.netOutput<q.minNetOutput)revert E.OutputBelowMinimum();
        if(r.netOutput!=0){
            _validateDirectExecution(q,eid,netInput,r.netOutput);
            _recordProtocolFee(q.inputAsset,r.grossInputUsed-netInput,_feePayer(msg.sender));
            _recordFill(eid,r.netOutput,netInput);
        }
        r.inputRefund=q.maxGrossInput-r.grossInputUsed;
    }
    function _sendDirectOutput(E.DirectRequest memory q,E.Result memory r) internal {
        _send(q.side==E.Side.Buy?q.baseToken:q.canonicalQuote,q.recipient,r.netOutput);
    }
    function plan(E.DirectRequest memory q,uint256 inventory,P.Ratio memory rate) internal view virtual returns(uint256 gross,uint256 net,uint256 output){
        uint256 bps=30;
        uint256 available=q.maxGrossInput-Math.mulDiv(q.maxGrossInput,bps,10000);
        if(q.side==E.Side.Buy){
            P.Ratio memory inverse=P.Ratio(rate.d,rate.n);
            output=P.atLeast(available,inverse,inventory)?inventory:P.consideration(available,inverse,false);
            if(output==0)return(0,0,0);
            net=P.consideration(output,rate,true);
        }else{
            net=P.atMost(available,rate,inventory)?available:P.consideration(inventory,P.Ratio(rate.d,rate.n),false);
            if(net==0)return(0,0,0);
            output=P.consideration(net,rate,false);
            if(output==0)return(0,0,0);
        }

        gross=net==available?q.maxGrossInput:Math.mulDiv(net-1,10000,10000-bps)+1;
        assert(gross<=q.maxGrossInput&&output<=inventory&&gross-Math.mulDiv(gross,bps,10000)==net);
    }
    function _matchingLiquidity(address base,address quote,E.Side side) internal view virtual returns(uint256,uint256){
        return availableLiquidity(base,quote,side);
    }
    function _beforeCreatePayout(E.DirectRequest calldata) internal view virtual returns(bytes32){return bytes32(0);}
    function _afterCreatePayout(E.DirectRequest calldata,bytes32) internal view virtual {}
    function _directReference(address base,address quote,bytes calldata hints) internal view virtual returns(P.Ratio memory);
    function _validateDirectExecution(E.DirectRequest memory request,uint256 epochId,uint256 netInput,uint256 output) internal view virtual;
}
