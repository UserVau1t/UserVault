pragma solidity ^0.8.30;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";
import {PinnedMarketPricing} from "../reference/PinnedMarketPricing.sol";
import {SharedPricingFingerprint} from "../reference/SharedPricingFingerprint.sol";
import {IUserVaultExecution as E} from "../interfaces/IUserVaultExecution.sol";

contract FeeVaultMath {
    error CapacityExceeded();
    function checkCapacity(uint256[3] calldata amounts,P.Ratio[3] calldata rates) external pure {
        uint256 cap=100000e18;uint256 whole;uint256 fractionN;uint256 fractionD=1;
        for(uint256 i=0;i<3;i++){
            P.Ratio memory r=rates[i];
            if(!P.atMost(amounts[i],r,cap))revert CapacityExceeded();
            whole+=P.consideration(amounts[i],r,false);
            uint256 rem=mulmod(amounts[i],r.n,r.d);
            if(rem!=0){
                P.Ratio memory f=P.ratio(rem,r.d);
                uint256 common=_gcd(fractionD,f.d);
                uint256 a=f.d/common;uint256 b=fractionD/common;
                fractionN=fractionN*a+f.n*b;fractionD*=a;
                whole+=fractionN/fractionD;fractionN%=fractionD;
                if(fractionN==0)fractionD=1;
                else {common=_gcd(fractionN,fractionD);fractionN/=common;fractionD/=common;}
            }
            if(whole>cap)revert CapacityExceeded();
        }
        if(whole==cap&&fractionN!=0)revert CapacityExceeded();
    }
    function _gcd(uint256 a,uint256 b) private pure returns(uint256){while(b!=0){uint256 r=a%b;a=b;b=r;}return a;}
    function fingerprint(PinnedMarketPricing pricing,address base,address usdg) external view returns(bytes32){
        return SharedPricingFingerprint.compute(address(pricing),base,usdg);
    }
    function plan(E.DirectRequest calldata q,uint256 inventory,P.Ratio calldata rate,uint256 bps) external pure returns(uint256 gross,uint256 net,uint256 output){
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
}
