pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IV2QuoteRouter {
    function factory() external view returns(address);
    function WETH() external view returns(address);
    function getAmountsOut(uint256,address[] calldata) external view returns(uint256[] memory);
    function swapExactETHForTokens(uint256,address[] calldata,address,uint256) external payable returns(uint256[] memory);
    function swapETHForExactTokens(uint256,address[] calldata,address,uint256) external payable returns(uint256[] memory);
    function swapExactTokensForETH(uint256,uint256,address[] calldata,address,uint256) external returns(uint256[] memory);
    function swapTokensForExactETH(uint256,uint256,address[] calldata,address,uint256) external returns(uint256[] memory);
}
interface IV2QuoteFactory {function getPair(address,address) external view returns(address);}
interface IV2QuotePair {
    function factory() external view returns(address);
    function token0() external view returns(address);
    function token1() external view returns(address);
}

contract V2NativeQuoteAdapter is ReentrancyGuard {
    using SafeERC20 for IERC20;
    struct Config {uint256 chainId;address router;address factory;address wrappedNative;address usdg;address pair;bytes32 routerHash;bytes32 factoryHash;bytes32 wrappedHash;bytes32 usdgHash;bytes32 pairHash;}
    Config public config;
    error InvalidConfig();error InvalidSwap();error BalanceMismatch();
    constructor(Config memory c){config=c;_identity();}
    function configuration() external view returns(Config memory){return config;}

    function _identity() private view {
        Config memory c=config;
        if(block.chainid!=c.chainId||c.usdg==c.wrappedNative||c.router==address(this))revert InvalidConfig();
        _pin(c.router,c.routerHash);_pin(c.factory,c.factoryHash);_pin(c.wrappedNative,c.wrappedHash);_pin(c.usdg,c.usdgHash);_pin(c.pair,c.pairHash);
        if(IV2QuoteRouter(c.router).factory()!=c.factory||IV2QuoteRouter(c.router).WETH()!=c.wrappedNative||IV2QuoteFactory(c.factory).getPair(c.usdg,c.wrappedNative)!=c.pair)revert InvalidConfig();
        IV2QuotePair p=IV2QuotePair(c.pair);
        (address a,address b)=c.usdg<c.wrappedNative?(c.usdg,c.wrappedNative):(c.wrappedNative,c.usdg);
        if(p.factory()!=c.factory||p.token0()!=a||p.token1()!=b)revert InvalidConfig();
    }
    function _pin(address target,bytes32 hash) private view {if(target.code.length==0||hash==bytes32(0)||target.codehash!=hash)revert InvalidConfig();}
    function _path(bool nativeInput) private view returns(address[] memory path){
        path=new address[](2);path[0]=nativeInput?config.wrappedNative:config.usdg;path[1]=nativeInput?config.usdg:config.wrappedNative;
    }

    function quoteExactInput(bool nativeInput,uint256 amount) external view returns(uint256){
        _identity();if(amount==0)revert InvalidSwap();
        uint256[] memory quoted=IV2QuoteRouter(config.router).getAmountsOut(amount,_path(nativeInput));
        if(quoted.length!=2||quoted[0]!=amount)revert InvalidSwap();return quoted[1];
    }
    function swapExactInput(bool nativeInput,uint256 amount,uint256 minOutput,uint256 deadline) external payable nonReentrant returns(uint256 output){
        (,output)=_swap(nativeInput,false,amount,minOutput,deadline);
    }
    function swapExactOutput(bool nativeInput,uint256 amount,uint256 maxInput,uint256 deadline) external payable nonReentrant returns(uint256 inputUsed){
        (inputUsed,)=_swap(nativeInput,true,maxInput,amount,deadline);
    }
    function _swap(bool nativeInput,bool exactOutput,uint256 budget,uint256 outputLimit,uint256 deadline) private returns(uint256 used,uint256 output){
        _identity();if(block.timestamp>deadline||budget==0||outputLimit==0||msg.value!=(nativeInput?budget:0))revert InvalidSwap();
        uint256 nativeBefore=address(this).balance-msg.value;
        uint256 tokenBefore=IERC20(config.usdg).balanceOf(address(this));
        if(!nativeInput){
            IERC20(config.usdg).safeTransferFrom(msg.sender,address(this),budget);
            if(IERC20(config.usdg).balanceOf(address(this))-tokenBefore!=budget)revert BalanceMismatch();
            IERC20(config.usdg).forceApprove(config.router,budget);
        }
        _route(nativeInput,exactOutput,budget,outputLimit,deadline);
        if(!nativeInput)IERC20(config.usdg).forceApprove(config.router,0);
        _identity();
        uint256 nativeAfter=address(this).balance;uint256 tokenAfter=IERC20(config.usdg).balanceOf(address(this));
        if(nativeAfter<nativeBefore||tokenAfter<tokenBefore)revert BalanceMismatch();
        uint256 refund=nativeInput?nativeAfter-nativeBefore:tokenAfter-tokenBefore;
        output=nativeInput?tokenAfter-tokenBefore:nativeAfter-nativeBefore;
        if(refund>=budget||output<outputLimit||(exactOutput&&output!=outputLimit)||(!exactOutput&&refund!=0))revert BalanceMismatch();
        used=budget-refund;
        _pay(nativeInput,refund);_pay(!nativeInput,output);
        if(address(this).balance!=nativeBefore||IERC20(config.usdg).balanceOf(address(this))!=tokenBefore)revert BalanceMismatch();
    }
    function _route(bool nativeInput,bool exactOutput,uint256 budget,uint256 limit,uint256 deadline) private {
        IV2QuoteRouter router=IV2QuoteRouter(config.router);address[] memory path=_path(nativeInput);

        if(nativeInput){
            if(exactOutput)router.swapETHForExactTokens{value:budget}(limit,path,address(this),deadline);
            else router.swapExactETHForTokens{value:budget}(limit,path,address(this),deadline);
        }else{
            if(exactOutput)router.swapTokensForExactETH(limit,budget,path,address(this),deadline);
            else router.swapExactTokensForETH(budget,limit,path,address(this),deadline);
        }
    }
    function _pay(bool nativeAsset,uint256 amount) private {
        if(amount==0)return;
        if(nativeAsset){(bool ok,)=msg.sender.call{value:amount}("");if(!ok)revert BalanceMismatch();}
        else {
            uint256 beforeBalance=IERC20(config.usdg).balanceOf(msg.sender);
            IERC20(config.usdg).safeTransfer(msg.sender,amount);
            if(IERC20(config.usdg).balanceOf(msg.sender)-beforeBalance!=amount)revert BalanceMismatch();
        }
    }
    receive() external payable {if(msg.sender!=config.router)revert InvalidSwap();}
}
