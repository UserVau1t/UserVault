pragma solidity ^0.8.30;
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ProRataAllocation as A} from "../libraries/ProRataAllocation.sol";
import {ReferencePriceMath as P} from "../libraries/ReferencePriceMath.sol";
import {IUserVaultExecution as E} from "../interfaces/IUserVaultExecution.sol";
import {MainnetMarketLiquiditySnapshot as S} from "./MainnetMarketLiquiditySnapshot.sol";

contract CreateGroupMath {
    struct Plan {
        S.Source[] sources;uint256[] grossInputs;uint256[] outputs;
        P.Ratio rate;P.Ratio usd;
        uint256 grossInput;uint256 netInput;uint256 output;uint256 feeAdjustment;
    }
    error InvalidPlan();
    function _gross(uint256 net,uint256 feeBps) private pure returns(uint256) {
        return feeBps==0?net:net==0?0:Math.mulDiv(net-1,10000,9970)+1;
    }
    function _size(uint256 wanted,uint256 inventory,E.Side side,P.Ratio memory rate,uint256 feeBps)
        private pure returns(uint256 gross,uint256 net,uint256 output) {
        if(wanted==0)return(0,0,0);
        if(side==E.Side.Buy){
            net=P.consideration(wanted,rate,true);
            output=Math.min(inventory,P.consideration(net,P.Ratio(rate.d,rate.n),false));
            net=P.consideration(output,rate,true);
        }else{
            net=P.consideration(wanted,P.Ratio(rate.d,rate.n),true);
            output=P.consideration(net,rate,false);
        }
        if(output<wanted||output>inventory||net==0)revert InvalidPlan();
        gross=_gross(net,feeBps);
    }
    function plan(E.DirectRequest calldata q,S.Source[] memory sources,P.Ratio memory rate,P.Ratio memory usd)
        public pure returns(Plan memory p) {return _plan(q,sources,rate,usd,30);}
    function planPassive(E.DirectRequest calldata q,S.Source[] memory sources,P.Ratio memory rate,P.Ratio memory usd)
        public pure returns(Plan memory p) {return _plan(q,sources,rate,usd,0);}
    function _plan(E.DirectRequest calldata q,S.Source[] memory sources,P.Ratio memory rate,P.Ratio memory usd,uint256 feeBps)
        private pure returns(Plan memory p) {
        if(rate.n==0||rate.d==0)revert InvalidPlan();
        p.sources=sources;p.rate=rate;p.usd=usd;
        A.Source[] memory weights=new A.Source[](sources.length);uint256 capacity;
        for(uint256 i;i<sources.length;i++){
            uint256 available=sources[i].available;
            if(q.side==E.Side.Sell)
                available=P.consideration(P.consideration(available,P.Ratio(rate.d,rate.n),false),rate,false);
            weights[i]=A.Source(sources[i].key,available);capacity+=available;
        }
        uint256 netBudget=q.maxGrossInput-Math.mulDiv(q.maxGrossInput,feeBps,10000);
        P.Ratio memory outputRate=q.side==E.Side.Buy?P.Ratio(rate.d,rate.n):rate;
        uint256 target=P.atLeast(netBudget,outputRate,capacity)?capacity:P.consideration(netBudget,outputRate,false);
        uint256 upper=target;
        p.grossInputs=new uint256[](sources.length);p.outputs=new uint256[](sources.length);
        while(true){
            _populate(p,q,weights,target,netBudget,feeBps);
            if(p.grossInput<=q.maxGrossInput)break;

            if(target==0||p.netInput==0)revert InvalidPlan();
            target=Math.min(target-1,Math.mulDiv(target,netBudget,p.netInput));
        }
        if(target==upper)return p;

        uint256 seed=target;uint256 lo=target+1;uint256 hi=upper;
        uint256[256] memory lows;uint256[256] memory highs;uint256 depth;
        P.Ratio memory inputRate=q.side==E.Side.Buy?rate:P.Ratio(rate.d,rate.n);
        while(true){
            if(lo<=hi)hi=_upperBound(lo,hi,weights,capacity,inputRate,netBudget);
            if(lo<=hi){
                _populate(p,q,weights,hi,netBudget,feeBps);
                if(p.grossInput<=q.maxGrossInput)return p;
                --hi;
                if(lo<=hi){
                    uint256 middle=lo+(hi-lo)/2;
                    assert(depth<256);lows[depth]=lo;highs[depth]=middle;++depth;
                    lo=middle+1;continue;
                }
            }
            if(depth==0)break;
            --depth;lo=lows[depth];hi=highs[depth];
        }
        _populate(p,q,weights,seed,netBudget,feeBps);return p;
    }
    function _populate(Plan memory p,E.DirectRequest calldata q,A.Source[] memory weights,uint256 target,uint256 netBudget,uint256 feeBps) private pure {
        (uint256[] memory allocated,,)=A.allocate(weights,target);
        p.netInput=0;p.output=0;uint256 sourceGross;
        for(uint256 i;i<p.sources.length;i++){
            uint256 net;
            (p.grossInputs[i],net,p.outputs[i])=_size(allocated[i],p.sources[i].available,q.side,p.rate,feeBps);
            p.netInput+=net;p.output+=p.outputs[i];sourceGross+=p.grossInputs[i];
        }
        p.grossInput=_gross(p.netInput,feeBps);
        if(p.netInput!=0&&p.netInput==netBudget)p.grossInput=q.maxGrossInput;
        if(sourceGross>p.grossInput)revert InvalidPlan();
        p.feeAdjustment=p.grossInput-sourceGross;
    }
    function _upperBound(uint256 lo,uint256 hi,A.Source[] memory w,uint256 total,P.Ratio memory rate,uint256 budget)
        private pure returns(uint256){
        uint256 active;for(uint256 i;i<w.length;i++)if(w[i].available!=0)++active;
        if(active==0)return hi;
        uint256 threshold=Math.mulDiv(total,active-1,active);
        uint256 baseCost;uint256 guaranteedCost;uint256 seats;uint256 remainderSum;uint256 cheap;
        uint256 maximumSeats;uint256 maximumRemainderSum;
        uint256[] memory minimumRemainders=new uint256[](w.length);
        uint256[] memory cheapMaximumRemainders=new uint256[](w.length);
        uint256 minimumIncrement=rate.n/rate.d;
        for(uint256 i;i<w.length;i++){
            uint256 weight=w[i].available;if(weight==0)continue;
            uint256 floorLo=Math.mulDiv(lo,weight,total);uint256 floorHi=Math.mulDiv(hi,weight,total);
            uint256 remLo=mulmod(lo,weight,total);
            uint256 cost=P.consideration(floorLo,rate,true);
            if(cost>budget-baseCost)return 0;baseCost+=cost;

            uint256 guaranteed=P.consideration(floorLo+(remLo>threshold?1:0),rate,true);
            if(guaranteed>budget-guaranteedCost)return 0;guaranteedCost+=guaranteed;
            uint256 minRemainder;uint256 maxRemainder=total-1;bool isCheap;
            if(floorLo==floorHi){
                minRemainder=remLo;maxRemainder=mulmod(hi,weight,total);
                isCheap=P.consideration(floorLo+1,rate,true)-cost==minimumIncrement;
            }else{
                isCheap=true;
                uint256 complement=total-weight;
                if(Math.mulDiv(lo,complement,total)==Math.mulDiv(hi,complement,total)
                    &&mulmod(lo,complement,total)!=0){
                    minRemainder=total-mulmod(hi,complement,total);
                    maxRemainder=total-mulmod(lo,complement,total);
                }
            }
            minimumRemainders[i]=minRemainder;
            if(isCheap)cheapMaximumRemainders[i]=maxRemainder+1;

            if(minRemainder>=total-remainderSum){++seats;remainderSum=minRemainder-(total-remainderSum);}
            else remainderSum+=minRemainder;
            if(maxRemainder>=total-maximumRemainderSum){++maximumSeats;maximumRemainderSum=maxRemainder-(total-maximumRemainderSum);}
            else maximumRemainderSum+=maxRemainder;
        }
        if(remainderSum!=0)++seats;

        if(seats!=0)for(uint256 i;i<w.length;i++)if(cheapMaximumRemainders[i]!=0){
            uint256 above;uint256 maximum=cheapMaximumRemainders[i]-1;
            for(uint256 j;j<w.length;j++)if(i!=j&&minimumRemainders[j]>maximum){
                ++above;if(above>=maximumSeats)break;
            }
            if(above<maximumSeats)++cheap;
        }
        uint256 left=budget-baseCost;
        if(seats!=0&&minimumIncrement>left/seats)return 0;
        left-=seats*minimumIncrement;
        if(seats>cheap&&seats-cheap>left)return 0;

        uint256 extraCost=seats*minimumIncrement+(seats>cheap?seats-cheap:0);
        if(hi<=maximumSeats)return hi;
        P.Ratio memory inverse=P.Ratio(rate.d,rate.n);
        if(P.atLeast(budget-extraCost,inverse,hi-maximumSeats))return hi;
        return P.consideration(budget-extraCost,inverse,false)+maximumSeats;
    }
    function planPassiveFor(S snapshot,E.DirectRequest calldata q) external view returns(Plan memory){
        (P.Ratio memory rate,P.Ratio memory usd,S.Source[] memory sources)=snapshot.snapshotPriced(q.baseToken,q.canonicalQuote,q.side);
        return planPassive(q,sources,rate,usd);
    }
    function planLimitOrdersFor(S snapshot,E.DirectRequest calldata q) external view returns(Plan memory){
        (P.Ratio memory rate,P.Ratio memory usd,S.Source[] memory rows)=snapshot.snapshotScoped(q.baseToken,q.canonicalQuote,q.side,false);
        return planPassive(q,rows,rate,usd);
    }
    function planFor(S snapshot,E.DirectRequest calldata q) external view returns(Plan memory){
        (P.Ratio memory rate,P.Ratio memory usd,S.Source[] memory sources)=snapshot.snapshotPriced(q.baseToken,q.canonicalQuote,q.side);
        return plan(q,sources,rate,usd);
    }
}
