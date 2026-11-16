pragma solidity ^0.8.30;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReferencePriceMath as P} from "./ReferencePriceMath.sol";

library ProjectedQuoteMath {
    error ProjectionPrecisionUnavailable();
    function gcd(uint256 a,uint256 b) private pure returns(uint256){
        while(b!=0){uint256 r=a%b;a=b;b=r;}return a;
    }
    function bits(uint256 hi,uint256 lo) private pure returns(uint256){
        return hi==0?Math.log2(lo)+1:Math.log2(hi)+257;
    }
    function shifted(uint256 hi,uint256 lo,uint256 s) private pure returns(uint256 q,bool remainder){
        if(s<256){q=(hi<<(256-s))|(lo>>s);remainder=(lo&((uint256(1)<<s)-1))!=0;}
        else if(s==256){q=hi;remainder=lo!=0;}
        else{uint256 r=s-256;q=hi>>r;remainder=lo!=0||(hi&((uint256(1)<<r)-1))!=0;}
    }
    function compose(P.Ratio memory a,P.Ratio memory b) internal pure returns(P.Ratio memory){
        a=P.ratio(a.n,a.d);b=P.ratio(b.n,b.d);
        uint256 g=gcd(a.n,b.d);a.n/=g;b.d/=g;
        g=gcd(b.n,a.d);b.n/=g;a.d/=g;
        (uint256 nh,uint256 nl)=Math.mul512(a.n,b.n);
        (uint256 dh,uint256 dl)=Math.mul512(a.d,b.d);
        if(nh==0&&dh==0)return P.Ratio(nl,dl);

        uint256 s=Math.max(bits(nh,nl),bits(dh,dl))-255;
        (uint256 n,)=shifted(nh,nl,s);
        (uint256 d,bool remainder)=shifted(dh,dl,s);
        if(remainder)++d;
        if(n<(uint256(1)<<128)||d<(uint256(1)<<128))revert ProjectionPrecisionUnavailable();
        return P.ratio(n,d);
    }
}
