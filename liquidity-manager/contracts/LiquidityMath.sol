pragma solidity 0.8.30;
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
interface ILMMathState {
    function getSlot0(bytes32 pool) external view returns(uint160,int24,uint24,uint24);
}
contract LiquidityMath {
    function depositTerms(bytes32 pool,int24 spacing,int24 low,int24 high,uint128 nativeLiquidity) external view returns(int24,int24,uint256 cost){
        (uint160 price,int24 tick,,)=ILMMathState(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b).getSlot0(pool);
        int24 center=tick/spacing*spacing;
        if(tick<0&&tick%spacing!=0)center-=spacing;
        if(nativeLiquidity!=0){
            uint160 upper=TickMath.getSqrtPriceAtTick(high);
            uint160 lower=TickMath.getSqrtPriceAtTick(low);
            if(price<upper)cost=SqrtPriceMath.getAmount0Delta(price<lower?lower:price,upper,nativeLiquidity,true);
        }
        return (low-center,high-center,cost);
    }
    function tickAtSqrtPrice(uint160 price) external pure returns(int24){return TickMath.getTickAtSqrtPrice(price);}
    function sqrtPriceAtTick(int24 tick) external pure returns(uint160){return TickMath.getSqrtPriceAtTick(tick);}
    function liquidityFor(uint160 price,int24 lower,int24 upper,uint256 amount0,uint256 amount1) external pure returns(uint128){
        return LiquidityAmounts.getLiquidityForAmounts(price,TickMath.getSqrtPriceAtTick(lower),TickMath.getSqrtPriceAtTick(upper),amount0,amount1);
    }
    function mintAmounts(uint160 price,int24 lower,int24 upper,uint256 amount0,uint256 amount1)
        external pure returns(uint128 liquidity,uint256 used0,uint256 used1){
        uint160 low=TickMath.getSqrtPriceAtTick(lower);
        uint160 high=TickMath.getSqrtPriceAtTick(upper);
        liquidity=LiquidityAmounts.getLiquidityForAmounts(price,low,high,amount0,amount1);
        uint160 inside=price<low?low:price>high?high:price;
        used0=SqrtPriceMath.getAmount0Delta(inside,high,liquidity,true);
        used1=SqrtPriceMath.getAmount1Delta(low,inside,liquidity,true);
    }
    function value1(uint256 a0,uint256 a1,uint160 price) external pure returns(uint256){
        if(price<=type(uint128).max)return FullMath.mulDiv(a0,uint256(price)*price,1<<192)+a1;
        return FullMath.mulDiv(a0,FullMath.mulDiv(price,price,1<<64),1<<128)+a1;
    }
    function value0(uint256 a1,uint160 price) external pure returns(uint256){
        if(price<=type(uint128).max)return FullMath.mulDiv(a1,1<<192,uint256(price)*price);
        return FullMath.mulDiv(a1,1<<128,FullMath.mulDiv(price,price,1<<64));
    }
}
