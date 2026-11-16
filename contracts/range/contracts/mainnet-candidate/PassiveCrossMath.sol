pragma solidity ^0.8.30;
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";
import {V2NativeQuoteAdapter as A} from "../adapters/V2NativeQuoteAdapter.sol";
import {PinnedMarketPricing} from "../reference/PinnedMarketPricing.sol";
import {CreateGroupMath as G} from "./CreateGroupMath.sol";
import {MainnetMarketLiquiditySnapshot as S} from "./MainnetMarketLiquiditySnapshot.sol";
import {IUserVaultExecution as E} from "../interfaces/IUserVaultExecution.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
interface IInternalAmountsIn {function getAmountsIn(uint256,address[] calldata) external view returns(uint256[] memory);}

contract PassiveCrossMath {
    error PriceChanged();
    function planLimit(bool sell,uint256 inventory,uint256 budget,P.Ratio calldata rate,uint256 bps)
        external pure returns(E.Result memory r,uint256 net){
        uint256 available=budget-Math.mulDiv(budget,bps,10000);
        if(sell){r.netOutput=Math.min(inventory,P.consideration(available,P.Ratio(rate.d,rate.n),false));net=P.consideration(r.netOutput,rate,true);}
        else{net=P.atMost(available,rate,inventory)?available:P.consideration(inventory,P.Ratio(rate.d,rate.n),false);r.netOutput=P.consideration(net,rate,false);}
        if(net==0||r.netOutput==0)return(r,0);
        r.grossInputUsed=net==available?budget:Math.mulDiv(net-1,10000,10000-bps)+1;r.inputRefund=budget-r.grossInputUsed;
    }
    function verifyGroup(S snapshot,E.DirectRequest calldata q,G.Plan calldata plan,bool filled) external view {
        _verify(snapshot,q,plan,filled,true);
    }
    function verifyLimits(S snapshot,E.DirectRequest calldata q,G.Plan calldata plan,bool filled) external view {
        _verify(snapshot,q,plan,filled,false);
    }
    function _verify(S snapshot,E.DirectRequest calldata q,G.Plan calldata plan,bool filled,bool includeCurrentPrice) private view {
        (P.Ratio memory rate,P.Ratio memory usd,S.Source[] memory current)=snapshot.snapshotScoped(q.baseToken,q.canonicalQuote,q.side,includeCurrentPrice);
        if(rate.n!=plan.rate.n||rate.d!=plan.rate.d||usd.n!=plan.usd.n||usd.d!=plan.usd.d)revert PriceChanged();
        uint256 next;
        for(uint256 i;i<plan.sources.length;i++){
            uint256 remaining=plan.sources[i].available-(filled?plan.outputs[i]:0);
            if(remaining==0)continue;
            if(next==current.length||current[next].key!=plan.sources[i].key||current[next].available!=remaining)revert PriceChanged();
            ++next;
        }
        if(next!=current.length)revert PriceChanged();
    }
    function limitSatisfied(bool sell,uint8 decimals,uint256 level,uint256 input,uint256 output,
        P.Ratio memory rate,P.Ratio memory usd) public pure returns(bool){
        if(decimals>36||input==0||output==0)return false;
        if(level==0||rate.n==0||rate.d==0||usd.n==0||usd.d==0)revert P.InvalidRatio();

        uint256[4] memory left=_product4(sell?input:output,level,rate.n,usd.d);
        uint256[4] memory right=_product4(sell?output:input,10**decimals,rate.d,usd.n);
        for(uint256 i=4;i!=0;){
            --i;
            if(left[i]!=right[i])return sell?left[i]<right[i]:left[i]>right[i];
        }
        return true;
    }

    function _product4(uint256 a,uint256 b,uint256 c,uint256 d) private pure returns(uint256[4] memory r){
        r[0]=a;uint256[3] memory factors=[b,c,d];
        for(uint256 k=0;k<3;++k){
            uint256 carry;
            for(uint256 j=0;j<=k;++j){
                (uint256 high,uint256 low)=Math.mul512(r[j],factors[k]);
                unchecked {uint256 sum=low+carry;carry=high+(sum<low?1:0);r[j]=sum;}
            }
            r[k+1]=carry;
        }
    }
    struct QuoteRequest {
        address base;address quote;bool sell;uint8 decimals;uint256 level;
        uint256 firstInput;uint256 firstOutput;uint256 remaining;uint256 plannedInput;uint256 plannedOutput;
    }
    error InvalidConversionQuote();
    function _inputQuote(A adapter,bool nativeInput,uint256 output) private view returns(uint256){
        A.Config memory c=adapter.configuration();address[] memory path=new address[](2);
        path[0]=nativeInput?c.wrappedNative:c.usdg;path[1]=nativeInput?c.usdg:c.wrappedNative;
        uint256[] memory amounts=IInternalAmountsIn(c.router).getAmountsIn(output,path);
        if(amounts.length!=2||amounts[0]==0||amounts[1]!=output)revert InvalidConversionQuote();return amounts[0];
    }
    function affordable(A adapter,bool nativeInput,uint256 budget) external view returns(uint256 output){
        output=adapter.quoteExactInput(nativeInput,budget);

        if(output!=0&&_inputQuote(adapter,nativeInput,output)>budget)--output;
        if(output!=0&&_inputQuote(adapter,nativeInput,output)>budget)revert InvalidConversionQuote();
    }
    function conversionBounds(A adapter,PinnedMarketPricing pricing,QuoteRequest calldata q) external view returns(uint256 input,uint256 output){
        if(q.sell){input=q.plannedInput;output=adapter.quoteExactInput(q.quote!=address(0),q.plannedOutput);}
        else{
            bool nativeInput=q.quote==address(0);input=_inputQuote(adapter,nativeInput,q.plannedInput);output=q.plannedOutput;

            if(input>q.remaining||adapter.quoteExactInput(nativeInput,input)<q.plannedInput)revert InvalidConversionQuote();
        }
        (P.Ratio memory rate,P.Ratio memory usd)=pricing.read(q.base,q.quote);
        if(!limitSatisfied(q.sell,q.decimals,q.level,q.firstInput+input,q.firstOutput+output,rate,usd))return(0,0);
    }
}
