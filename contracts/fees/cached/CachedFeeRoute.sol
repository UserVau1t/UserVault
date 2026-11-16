pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CachedTokenSwap} from "contracts/reference/CachedTokenSwap.sol";
import {CachedTokenPricing} from "cached/CachedTokenPricing.sol";
import {V2NativeQuoteAdapter} from "contracts/adapters/V2NativeQuoteAdapter.sol";
import {ReferencePriceMath as R} from "contracts/libraries/ReferencePriceMath.sol";
import {PriceContextConsumer} from "cached/PriceContextConsumer.sol";
interface ICachedFeeWETH {function withdraw(uint256) external;}

contract CachedFeeRoute is ReentrancyGuard,PriceContextConsumer {
    using SafeERC20 for IERC20;
    CachedTokenSwap public immutable swapper;
    CachedTokenPricing public immutable pricing;
    V2NativeQuoteAdapter public immutable quoteAdapter;
    bytes32 public immutable swapperHash;
    bytes32 public immutable pricingHash;
    bytes32 public immutable adapterHash;
    address public immutable usdg;
    address public immutable wrappedNative;
    uint256 public immutable configuredChainId;
    bool private receiving;
    error InvalidRoute();error BalanceMismatch();
    constructor(CachedTokenSwap s,V2NativeQuoteAdapter a){
        CachedTokenPricing p=s.pricing();V2NativeQuoteAdapter.Config memory c=a.configuration();
        if(block.chainid!=4663||s.configuredChainId()!=block.chainid||c.chainId!=block.chainid||c.usdg!=p.usdg()||c.wrappedNative!=p.wrappedNative())revert InvalidRoute();
        swapper=s;pricing=p;quoteAdapter=a;swapperHash=address(s).codehash;pricingHash=address(p).codehash;adapterHash=address(a).codehash;
        usdg=c.usdg;wrappedNative=c.wrappedNative;configuredChainId=block.chainid;
    }
    function _pin() private view {
        if(block.chainid!=configuredChainId||address(swapper).codehash!=swapperHash||address(pricing).codehash!=pricingHash||address(quoteAdapter).codehash!=adapterHash)revert InvalidRoute();
    }
    function _contextPricing() internal view override returns(address){_pin();return address(pricing);}
    function _root(address asset) private view returns(bool){return asset==address(0)||asset==usdg||asset==wrappedNative;}
    function supportsAsset(address asset) public view returns(bool){_pin();return _root(asset)||swapper.supported(asset);}
    function keeperAuthorizationRequired() external pure returns(bool){return true;}
    function valuationRatio(address asset) public view returns(R.Ratio memory rate){
        _pin();if(_root(asset))return pricing.quoteUsd(asset);(,rate)=pricing.read(asset,address(0));
    }
    function valueUsd(address asset,uint256 amount) external view returns(uint256){return R.consideration(amount,valuationRatio(asset),false);}
    function _validate(address asset,uint256 amount,bytes calldata route) private view {
        if(asset==address(0)||amount==0||route.length!=0||!supportsAsset(asset))revert InvalidRoute();valuationRatio(asset);pricing.quoteUsd(address(0));
    }
    function minimumETH(address asset,uint256 amount,bytes calldata route) external view returns(uint256){_validate(asset,amount,route);return 1;}
    function validateAfter(address asset,uint256 amount,uint256 output,bytes calldata route) external view {_validate(asset,amount,route);if(output==0)revert InvalidRoute();}
    function quoteETH(address token,uint256 amount) external nonReentrant returns(uint256 output){
        if(token==address(0)||amount==0||!supportsAsset(token))revert InvalidRoute();valuationRatio(token);
        address quote=token;output=amount;
        if(!_root(token)){
            uint256 used;(quote,used,output)=swapper.quoteSource(token,false,false,amount);if(used!=amount)revert InvalidRoute();
            if(!_root(quote)){uint256 input=output;(quote,used,output)=swapper.quoteSource(token,true,false,input);if(used!=input)revert InvalidRoute();}
        }
        if(!_root(quote))revert InvalidRoute();return quote==usdg?quoteAdapter.quoteExactInput(false,output):output;
    }
    function _swap(address source,address input,bool conversion,uint256 amount,uint256 deadline) private returns(address quote,uint256 output){
        uint256 beforeInput=IERC20(input).balanceOf(address(this));IERC20(input).forceApprove(address(swapper),amount);
        uint256 used;(quote,used,output)=swapper.sellSource(source,conversion,false,amount,1,deadline);
        IERC20(input).forceApprove(address(swapper),0);
        if(used!=amount||beforeInput-IERC20(input).balanceOf(address(this))!=amount)revert BalanceMismatch();
    }
    function convert(address token,uint256 amount,uint256 minimum,uint256 deadline,bytes calldata route) external nonReentrant returns(uint256 output){
        _validate(token,amount,route);if(minimum==0||deadline<block.timestamp)revert InvalidRoute();
        uint256 beforeBase=IERC20(token).balanceOf(address(this));uint256 beforePayer=IERC20(token).balanceOf(msg.sender);uint256 beforeETH=address(this).balance;
        uint256 beforeUsd=IERC20(usdg).balanceOf(address(this));uint256 beforeWrapped=IERC20(wrappedNative).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender,address(this),amount);
        if(IERC20(token).balanceOf(address(this))!=beforeBase+amount||IERC20(token).balanceOf(msg.sender)!=beforePayer-amount)revert BalanceMismatch();
        receiving=true;address quote=token;uint256 intermediate=amount;
        if(!_root(token)){
            quote=pricing.selection(token,address(0)).pool.quote;
            uint256 beforeQuote=quote==address(0)?beforeETH:IERC20(quote).balanceOf(address(this));
            (address actual,uint256 received)=_swap(token,token,false,amount,deadline);if(actual!=quote)revert InvalidRoute();intermediate=received;
            if((quote==address(0)?address(this).balance:IERC20(quote).balanceOf(address(this)))!=beforeQuote+received)revert BalanceMismatch();
            if(!_root(quote)){
                address intermediateAsset=quote;uint256 intermediateBefore=beforeQuote;
                (quote,intermediate)=_swap(token,intermediateAsset,true,intermediate,deadline);
                if(IERC20(intermediateAsset).balanceOf(address(this))!=intermediateBefore)revert BalanceMismatch();
            }
        }
        if(quote==wrappedNative){ICachedFeeWETH(wrappedNative).withdraw(intermediate);output=intermediate;}
        else if(quote==address(0))output=intermediate;
        else if(quote==usdg){IERC20(usdg).forceApprove(address(quoteAdapter),intermediate);output=quoteAdapter.swapExactInput(false,intermediate,minimum,deadline);IERC20(usdg).forceApprove(address(quoteAdapter),0);}
        else revert InvalidRoute();
        receiving=false;_pin();valuationRatio(token);
        if(output<minimum||address(this).balance!=beforeETH+output||IERC20(token).balanceOf(address(this))!=beforeBase
            ||IERC20(usdg).balanceOf(address(this))!=beforeUsd||IERC20(wrappedNative).balanceOf(address(this))!=beforeWrapped)revert BalanceMismatch();
        (bool ok,)=msg.sender.call{value:output}("");if(!ok||address(this).balance!=beforeETH||IERC20(token).balanceOf(msg.sender)!=beforePayer-amount)revert BalanceMismatch();
    }
    receive() external payable {if(!receiving||(msg.sender!=address(swapper)&&msg.sender!=wrappedNative&&msg.sender!=address(quoteAdapter)))revert InvalidRoute();}
}
