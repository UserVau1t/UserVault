pragma solidity ^0.8.30;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
library AggregateIndexMath {
    error IndexOverflow();
    function product(uint256 x,uint256 y) internal pure returns(uint256 low,uint256 high){
        assembly ("memory-safe") {
            let mm := mulmod(x,y,not(0))
            low := mul(x,y)
            high := sub(sub(mm,low),lt(mm,low))
        }
    }
    function quotient(uint256 low,uint256 high,uint256 denominator) internal pure returns(uint256 value,uint256 remainder){
        if(denominator==0||high>=denominator)revert IndexOverflow();
        if(high==0)return(low/denominator,low%denominator);
        value=Math.mulDiv(high,type(uint256).max,denominator)+low/denominator;
        uint256 r=mulmod(high,type(uint256).max,denominator);
        if(r>=denominator-high)++value;
        r=addmod(r,high,denominator);
        uint256 tail=low%denominator;
        if(r>=denominator-tail)++value;
        remainder=addmod(r,tail,denominator);
    }
    function ratio(uint256 x,uint256 y,uint256 denominator) internal pure returns(uint256 low,uint256 high){
        (uint256 pLow,uint256 pHigh)=product(x,y);
        if(denominator==0)revert IndexOverflow();
        high=pHigh/denominator;
        (low,)=quotient(pLow,pHigh%denominator,denominator);
    }
    function add(uint256 low,uint256 high,uint256 extraLow,uint256 extraHigh) internal pure returns(uint256,uint256){
        uint256 result;
        unchecked{result=low+extraLow;}
        return(result,high+extraHigh+(result<low?1:0));
    }
    function subtract(uint256 low,uint256 high,uint256 priorLow,uint256 priorHigh) internal pure returns(uint256,uint256){
        uint256 result;
        unchecked{result=low-priorLow;}
        return(result,high-priorHigh-(low<priorLow?1:0));
    }
    function weighted(uint256 weight,uint256 low,uint256 high,uint256 denominator) internal pure returns(uint256,uint256){
        (uint256 pLow,uint256 pHigh)=product(weight,low);
        pHigh+=weight*high;
        return quotient(pLow,pHigh,denominator);
    }
}
