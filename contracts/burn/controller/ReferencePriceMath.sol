pragma solidity ^0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

library ReferencePriceMath {
    struct Ratio { uint256 n; uint256 d; }
    error InvalidRatio();
    error UnrepresentableRatio();
    error InvalidDeviation();

    function gcd(uint256 a,uint256 b) private pure returns(uint256) {
        while(b!=0){uint256 r=a%b;a=b;b=r;}return a;
    }
    function ratio(uint256 n,uint256 d) internal pure returns(Ratio memory) {
        if(n==0||d==0)revert InvalidRatio();
        uint256 g=gcd(n,d);return Ratio(n/g,d/g);
    }
    function compose(Ratio memory a,Ratio memory b) internal pure returns(Ratio memory) {
        a=ratio(a.n,a.d);b=ratio(b.n,b.d);
        uint256 g=gcd(a.n,b.d);a.n/=g;b.d/=g;
        g=gcd(b.n,a.d);b.n/=g;a.d/=g;
        if(a.n>type(uint256).max/b.n||a.d>type(uint256).max/b.d)revert UnrepresentableRatio();
        return Ratio(a.n*b.n,a.d*b.d);
    }
    function route(Ratio[] memory hops) internal pure returns(Ratio memory result) {
        if(hops.length==0)revert InvalidRatio();result=Ratio(1,1);
        for(uint256 i=0;i<hops.length;i++)result=compose(result,hops[i]);
    }
    function consideration(uint256 amount,Ratio memory r,bool buy) internal pure returns(uint256) {
        r=ratio(r.n,r.d);
        return Math.mulDiv(amount,r.n,r.d,buy?Math.Rounding.Ceil:Math.Rounding.Floor);
    }

    function productLte(uint256 a,uint256 b,uint256 c,uint256 d) private pure returns(bool) {
        uint256 ah;uint256 al;uint256 ch;uint256 cl;
        assembly ("memory-safe") {
            let am := mulmod(a,b,not(0))
            al := mul(a,b)
            ah := sub(sub(am,al),lt(am,al))
            let cm := mulmod(c,d,not(0))
            cl := mul(c,d)
            ch := sub(sub(cm,cl),lt(cm,cl))
        }
        return ah<ch||(ah==ch&&al<=cl);
    }
    function atLeast(uint256 amount,Ratio memory r,uint256 threshold) internal pure returns(bool) {
        r=ratio(r.n,r.d);return productLte(threshold,r.d,amount,r.n);
    }
    function atMost(uint256 amount,Ratio memory r,uint256 threshold) internal pure returns(bool) {
        r=ratio(r.n,r.d);return productLte(amount,r.n,threshold,r.d);
    }
    function withinDeviation(Ratio memory current,Ratio memory anchor,uint256 bps) internal pure returns(bool) {
        if(bps>10000)revert InvalidDeviation();
        if(current.n==0||current.d==0||anchor.n==0||anchor.d==0)revert InvalidRatio();

        return tripleLte(current.n,anchor.d,10000,anchor.n,current.d,10000+bps)
            &&tripleLte(anchor.n,current.d,10000-bps,current.n,anchor.d,10000);
    }
    function triple(uint256 a,uint256 b,uint256 c) private pure returns(uint256[3] memory r){
        (uint256 high,uint256 low)=Math.mul512(a,b);
        (uint256 carry,uint256 bottom)=Math.mul512(low,c);
        (uint256 top,uint256 middle)=Math.mul512(high,c);
        unchecked {uint256 merged=middle+carry;r[0]=top+(merged<middle?1:0);r[1]=merged;r[2]=bottom;}
    }
    function tripleLte(uint256 a,uint256 b,uint256 c,uint256 d,uint256 e,uint256 f) private pure returns(bool){
        uint256[3] memory left=triple(a,b,c);uint256[3] memory right=triple(d,e,f);
        for(uint256 i=0;i<3;i++){if(left[i]<right[i])return true;if(left[i]>right[i])return false;}
        return true;
    }
}
