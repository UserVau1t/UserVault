pragma solidity ^0.8.30;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CachedTokenPricing as SharedTokenPricing} from "cached/CachedTokenPricing.sol";
import {SharedPoolReader} from "./SharedPoolReader.sol";
import {V4StateReader} from "./V4StateReader.sol";
interface ISharedV2Swap {
    function token0() external view returns(address);
    function getReserves() external view returns(uint112,uint112,uint32);
    function swap(uint256,uint256,address,bytes calldata) external;
}
interface ISharedV3Swap {
    function token0() external view returns(address);
    function swap(address,bool,int256,uint160,bytes calldata) external returns(int256,int256);
}
interface ISharedV4Swap {
    struct Params {bool zeroForOne;int256 amountSpecified;uint160 sqrtPriceLimitX96;}
    function unlock(bytes calldata) external returns(bytes memory);
    function swap(V4StateReader.PoolKey calldata,Params calldata,bytes calldata) external returns(int256);
    function sync(address) external;
    function settle() external payable returns(uint256);
    function take(address,address,uint256) external;
}

contract CachedTokenSwap is ReentrancyGuard {
    using SafeERC20 for IERC20;
    SharedTokenPricing public immutable pricing;
    bytes32 public immutable pricingHash;
    uint256 public immutable configuredChainId;
    address public immutable manager;
    bytes32 public immutable managerHash;
    struct Request {address base;SharedPoolReader.Pool pool;bool exactOutput;bool quoting;uint256 amount;uint256 limit;}
    bytes32 private active;
    address private callbackSender;
    error InvalidSwap();error InvalidCallback();error BalanceMismatch();
    error QuoteResult(uint256 used,uint256 output);
    constructor(SharedTokenPricing p){
        if(address(p).code.length==0||p.configuredChainId()!=block.chainid)revert InvalidSwap();
        pricing=p;pricingHash=address(p).codehash;configuredChainId=block.chainid;
        (,,,,,address m,bytes32 h,,,,)=p.reader().roots();manager=m;managerHash=h;
    }
    function _pin() private view {if(block.chainid!=configuredChainId||address(pricing).codehash!=pricingHash)revert InvalidSwap();}
    function supported(address base) external view returns(bool){
        _pin();(bytes32 h,,,)=pricing.tokens(base);
        if(h==bytes32(0)||base.codehash!=h)return false;
        SharedTokenPricing.Selection memory s=pricing.selection(base,address(0));
        return s.present&&s.pool.kind>=2&&s.pool.kind<=5;
    }
    function _selection(address base,bool conversion) private view returns(address token,SharedPoolReader.Pool memory pool){
        _pin();pricing.read(base,address(0));
        SharedTokenPricing.Selection memory s=pricing.selection(base,address(0));
        if(!s.present||s.pool.kind<2||s.pool.kind>5)revert InvalidSwap();
        if(conversion)return pricing.conversionSource(base);return(base,s.pool);
    }
    function _amount(uint256 amount) private pure {if(amount==0||amount>uint256(uint128(type(int128).max)))revert InvalidSwap();}
    function quoteSource(address base,bool conversion,bool exactOutput,uint256 amount) external nonReentrant returns(address quoteAsset,uint256 used,uint256 output){
        _amount(amount);(address token,SharedPoolReader.Pool memory pool)=_selection(base,conversion);Request memory r=Request(token,pool,exactOutput,true,amount,uint256(uint128(type(int128).max)));
        if(!exactOutput)r.limit=1;
        if(r.pool.kind==2)(used,output)=_v2Amounts(r);
        else {
            try this.simulate(r) {revert InvalidSwap();}
            catch(bytes memory reason){
                if(reason.length!=68||bytes4(reason)!=QuoteResult.selector){assembly("memory-safe"){revert(add(reason,32),mload(reason))}}
                assembly("memory-safe"){used:=mload(add(reason,36)) output:=mload(add(reason,68))}
            }
        }
        _selection(base,conversion);return(r.pool.quote,used,output);
    }
    function simulate(Request calldata r) external {
        if(msg.sender!=address(this)||!r.quoting)revert InvalidCallback();_execute(r);revert InvalidSwap();
    }
    function sellSource(address sourceBase,bool conversion,bool exactOutput,uint256 amount,uint256 limit,uint256 deadline)
        external nonReentrant returns(address quoteAsset,uint256 used,uint256 output){
        if(block.timestamp>deadline)revert InvalidSwap();_amount(amount);_amount(limit);
        (address base,SharedPoolReader.Pool memory pool)=_selection(sourceBase,conversion);
        Request memory r=Request(base,pool,exactOutput,false,amount,limit);
        uint256 budget=exactOutput?limit:amount;
        uint256 beforeBase=IERC20(base).balanceOf(address(this));uint256 beforeQuote=_balance(r.pool.quote);uint256 beforePayer=IERC20(base).balanceOf(msg.sender);
        IERC20(base).safeTransferFrom(msg.sender,address(this),budget);
        if(IERC20(base).balanceOf(address(this))!=beforeBase+budget||IERC20(base).balanceOf(msg.sender)!=beforePayer-budget)revert BalanceMismatch();
        (used,output)=_execute(r);_selection(sourceBase,conversion);
        if(IERC20(base).balanceOf(address(this))!=beforeBase+budget-used||_balance(r.pool.quote)!=beforeQuote+output)revert BalanceMismatch();
        if(budget>used)IERC20(base).safeTransfer(msg.sender,budget-used);
        if(IERC20(base).balanceOf(msg.sender)!=beforePayer-used)revert BalanceMismatch();
        _pay(r.pool.quote,output);
        if(IERC20(base).balanceOf(address(this))!=beforeBase||_balance(r.pool.quote)!=beforeQuote)revert BalanceMismatch();
        return(r.pool.quote,used,output);
    }
    function _checkAmounts(Request memory r,uint256 used,uint256 output) private pure {
        if(used==0||output==0||(r.exactOutput?(output!=r.amount||used>r.limit):(used!=r.amount||output<r.limit)))revert InvalidSwap();
    }
    function _v2Amounts(Request memory r) private view returns(uint256 used,uint256 output){
        ISharedV2Swap pair=ISharedV2Swap(r.pool.pool);(uint112 a,uint112 b,)=pair.getReserves();
        (uint256 rin,uint256 rout)=pair.token0()==r.base?(uint256(a),uint256(b)):(uint256(b),uint256(a));

        if(rin==0||rout==0)revert InvalidSwap();
        if(r.exactOutput){if(r.amount>=rout)revert InvalidSwap();used=rin*r.amount*1000/((rout-r.amount)*997)+1;output=r.amount;}
        else{used=r.amount;output=used*997*rout/(rin*1000+used*997);}
        _checkAmounts(r,used,output);
    }
    function _execute(Request memory r) private returns(uint256 used,uint256 output){
        if(r.pool.kind==2){
            (used,output)=_v2Amounts(r);IERC20(r.base).safeTransfer(r.pool.pool,used);
            bool zeroForOne=ISharedV2Swap(r.pool.pool).token0()==r.base;
            ISharedV2Swap(r.pool.pool).swap(zeroForOne?0:output,zeroForOne?output:0,address(this),"");
        }else{
            bytes memory data=abi.encode(r);active=keccak256(data);callbackSender=r.pool.kind==3?r.pool.pool:manager;
            if(r.pool.kind==3){
                bool z=ISharedV3Swap(r.pool.pool).token0()==r.base;
                (int256 a,int256 b)=ISharedV3Swap(r.pool.pool).swap(address(this),z,r.exactOutput?-int256(r.amount):int256(r.amount),_sqrt(z),data);
                int256 input=z?a:b;int256 out=z?b:a;
                if(input<=0||out>=0||out==type(int256).min)revert InvalidSwap();used=uint256(input);output=uint256(-out);
            }else{
                if(manager.codehash!=managerHash)revert InvalidSwap();
                (used,output)=abi.decode(ISharedV4Swap(manager).unlock(data),(uint256,uint256));
            }
            if(active!=bytes32(0))revert InvalidCallback();callbackSender=address(0);_checkAmounts(r,used,output);
        }
    }
    function _consume(bytes calldata data) private returns(Request memory r){
        if(msg.sender!=callbackSender||active==bytes32(0)||keccak256(data)!=active)revert InvalidCallback();
        active=bytes32(0);r=abi.decode(data,(Request));
    }
    function uniswapV3SwapCallback(int256 a,int256 b,bytes calldata data) external {
        Request memory r=_consume(data);if(r.pool.kind!=3)revert InvalidCallback();
        bool z=ISharedV3Swap(msg.sender).token0()==r.base;int256 input=z?a:b;int256 out=z?b:a;
        if(input<=0||out>=0||out==type(int256).min)revert InvalidSwap();uint256 used=uint256(input);uint256 output=uint256(-out);
        _checkAmounts(r,used,output);if(r.quoting)revert QuoteResult(used,output);
        IERC20(r.base).safeTransfer(msg.sender,used);
    }
    function unlockCallback(bytes calldata data) external returns(bytes memory){
        Request memory r=_consume(data);if(r.pool.kind!=4&&r.pool.kind!=5)revert InvalidCallback();
        bool z=r.pool.key.currency0==r.base;ISharedV4Swap m=ISharedV4Swap(manager);
        int256 packed=m.swap(r.pool.key,ISharedV4Swap.Params(z,r.exactOutput?int256(r.amount):-int256(r.amount),_sqrt(z)),"");
        int128 a=int128(packed>>128);int128 b=int128(packed);int128 input=z?a:b;int128 out=z?b:a;
        if(input>=0||out<=0)revert InvalidSwap();uint256 used=uint256(-int256(input));uint256 output=uint256(int256(out));
        _checkAmounts(r,used,output);if(r.quoting)revert QuoteResult(used,output);
        m.sync(r.base);IERC20(r.base).safeTransfer(manager,used);if(m.settle()!=used)revert BalanceMismatch();
        m.take(r.pool.quote,address(this),output);return abi.encode(used,output);
    }
    function _sqrt(bool z) private pure returns(uint160){return z?4295128740:1461446703485210103287273052203988822378723970341;}
    function _balance(address asset) private view returns(uint256){return asset==address(0)?address(this).balance:IERC20(asset).balanceOf(address(this));}
    function _pay(address asset,uint256 amount) private {
        if(asset==address(0)){(bool ok,)=msg.sender.call{value:amount}("");if(!ok)revert BalanceMismatch();}
        else{uint256 beforeBalance=IERC20(asset).balanceOf(msg.sender);IERC20(asset).safeTransfer(msg.sender,amount);if(IERC20(asset).balanceOf(msg.sender)!=beforeBalance+amount)revert BalanceMismatch();}
    }
    receive() external payable {if(msg.sender!=manager||callbackSender!=manager||manager.codehash!=managerHash)revert InvalidCallback();}
}
