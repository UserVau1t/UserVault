pragma solidity ^0.8.30;
import {SameQuoteDirectVault} from "./SameQuoteDirectVault.sol";
import {IUserVaultExecution as E} from "./interfaces/IUserVaultExecution.sol";

abstract contract SameQuoteCreateVault is SameQuoteDirectVault {
    function _creditCreation(E.DirectRequest calldata q,CreateResult memory result) internal virtual {
        _sendDirectOutput(q,result.trade);
    }
    function _prepareToken(address base,bytes calldata permission) internal virtual {}
    struct CreateResult {E.Result trade;uint256 positionId;uint256 positionAmount;}
    error CreationBelowMinimum();error PositionBelowMinimum();
    event CreateProcessed(address indexed owner,uint256 indexed positionId,uint256 positionAmount,uint256 matchedGross,uint256 output,uint256 refund);
    function createPosition(E.DirectRequest calldata q,bytes calldata referenceHints,uint256 minPositionAmount) external payable virtual nonReentrant returns(CreateResult memory result){
        return _createSameQuote(q,referenceHints,minPositionAmount);
    }
    function _createSameQuote(E.DirectRequest calldata q,bytes calldata referenceHints,uint256 minPositionAmount) internal returns(CreateResult memory result){
        address input=_checkDirectRequest(q,"");
        address other=q.canonicalQuote==address(0)?_s().usdg:address(0);
        (,uint256 crossInventory)=availableLiquidity(q.baseToken,other,q.side);
        if(crossInventory!=0)revert E.UnsupportedRoute();
        (,uint256 opposite)=availableLiquidity(q.baseToken,q.canonicalQuote,q.side);
        if(opposite==0&&!_meetsCreationMinimum(q.baseToken,q.canonicalQuote,Side(uint8(q.side)),q.maxGrossInput))revert CreationBelowMinimum();
        _collect(input,msg.sender,q.maxGrossInput);
        result.trade=_matchCollected(q,referenceHints);
        uint256 remainder=result.trade.inputRefund;
        (,uint256 remainingOpposite)=availableLiquidity(q.baseToken,q.canonicalQuote,q.side);
        if(remainder!=0&&remainingOpposite==0&&_meetsCreationMinimum(q.baseToken,q.canonicalQuote,Side(uint8(q.side)),remainder)){
            result.positionId=_open(msg.sender,q.baseToken,q.canonicalQuote,Side(uint8(q.side)),remainder);
            result.positionAmount=remainder;result.trade.inputRefund=0;
        }
        if(result.positionAmount<minPositionAmount)revert PositionBelowMinimum();
        _creditCreation(q,result);_send(input,msg.sender,result.trade.inputRefund);
        emit CreateProcessed(msg.sender,result.positionId,result.positionAmount,result.trade.grossInputUsed,result.trade.netOutput,result.trade.inputRefund);
    }

    function _meetsCreationMinimum(address base,address quote,Side side,uint256 amount) internal view virtual returns(bool);
}
