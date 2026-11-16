pragma solidity ^0.8.30;
import {CrossBuyVault} from "./CrossBuyVault.sol";
import {V2NativeQuoteAdapter} from "./adapters/V2NativeQuoteAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IUserVaultExecution as E} from "./interfaces/IUserVaultExecution.sol";

abstract contract V2ConversionVault is CrossBuyVault {
    using SafeERC20 for IERC20;
    V2NativeQuoteAdapter public immutable quoteAdapter;
    bytes32 private immutable adapterHash;
    struct ConversionHints {uint256 minOutput;uint256 deadline;}
    constructor(V2NativeQuoteAdapter adapter){
        if(address(adapter).code.length==0)revert E.InvalidRequest();
        quoteAdapter=adapter;adapterHash=address(adapter).codehash;
        _initializeAccounting(adapter.configuration().usdg);
    }
    function _conversionTarget() internal view override returns(address){return address(quoteAdapter);}
    function _hints(bytes memory hints) private view returns(ConversionHints memory h){
        if(address(quoteAdapter).codehash!=adapterHash||hints.length!=64)revert E.UnsupportedRoute();
        h=abi.decode(hints,(ConversionHints));if(h.deadline<block.timestamp)revert E.InvalidRequest();
    }
    function _pair(address input,address output) private view {if(!((input==address(0)&&output==_s().usdg)||(input==_s().usdg&&output==address(0))))revert E.UnsupportedRoute();}
    function _quoteCrossBuyBudget(address input,address output,uint256 maxInput,bytes memory hints) internal view override returns(bool,uint256){
        _pair(input,output);ConversionHints memory h=_hints(hints);
        try quoteAdapter.quoteExactInput(input==address(0),maxInput) returns(uint256 amount){
            if(amount==0||!_admitV2Conversion(input,output,true,maxInput,amount,h.deadline))return(false,0);
            return(true,amount);
        }catch{return(false,0);}
    }
    function _swapQuoteExactInput(address input,address output,uint256 amount,bytes memory hints) internal override {
        _pair(input,output);ConversionHints memory h=_hints(hints);
        if(h.minOutput==0||!_admitV2Conversion(input,output,false,amount,h.minOutput,h.deadline))revert E.PriceNotAdmitted();
        if(input!=address(0))IERC20(input).forceApprove(address(quoteAdapter),amount);
        quoteAdapter.swapExactInput{value:input==address(0)?amount:0}(input==address(0),amount,h.minOutput,h.deadline);
        if(input!=address(0))IERC20(input).forceApprove(address(quoteAdapter),0);
    }
    function _swapQuoteExactOutput(address input,address output,uint256 amount,uint256 maxInput,bytes memory hints) internal override {
        _pair(input,output);ConversionHints memory h=_hints(hints);
        if(!_admitV2Conversion(input,output,true,maxInput,amount,h.deadline))revert E.PriceNotAdmitted();
        if(input!=address(0))IERC20(input).forceApprove(address(quoteAdapter),maxInput);
        quoteAdapter.swapExactOutput{value:input==address(0)?maxInput:0}(input==address(0),amount,maxInput,h.deadline);
        if(input!=address(0))IERC20(input).forceApprove(address(quoteAdapter),0);
    }

    function _admitV2Conversion(address input,address output,bool exactOutput,uint256 maxInput,uint256 outputLimit,uint256 deadline) internal view virtual returns(bool);
}
