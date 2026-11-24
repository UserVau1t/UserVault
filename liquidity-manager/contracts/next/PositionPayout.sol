// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {PositionFeeSwap,LMPoolKey} from "./PositionFeeSwap.sol";
import {PositionPayment} from "./PositionPayment.sol";
import {ILMPositionManager} from "../LiquidityControllerV2.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

library PositionPayout {
    // Internal marker for settlement in the pool currencies.
    address internal constant PAIR = address(1);
    address internal constant USDG = address(uint160(0x005fc5360d0400a0fd4f2af552add042d716f1d168));
    ILMPositionManager private constant PM = ILMPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    struct Plan {uint256 id; uint64 nonce; uint48 deadline; bytes details;}
    struct Leg {uint128 expected; PositionFeeSwap.Quote quote;}
    struct Details {uint256[2] usd; uint256[2] unit; Leg[2] legs;}
    struct Terms {address owner; address target; address gasModule; address gasCurrency; uint256 reserve; uint128 threshold; uint16 slippage;}
    error InvalidPayout();

    function pay(Plan calldata plan,Terms calldata t) internal {
        if(PM.ownerOf(plan.id)!=t.owner || (t.target!=address(0)&&t.target!=USDG&&t.target!=PAIR) || t.threshold==0) revert InvalidPayout();
        (LMPoolKey memory key,)=PM.getPoolAndPositionInfo(plan.id);
        bool pairPayout=t.target==PAIR;
        if((uint160(key.hooks)&3)!=0 || (pairPayout
            ? (t.gasCurrency!=key.currency0 && t.gasCurrency!=key.currency1)
            : t.gasCurrency!=t.target)) revert InvalidPayout();
        address[2] memory currencies=[key.currency0,key.currency1];
        uint256[2] memory before=[PositionFeeSwap.balance(currencies[0]),PositionFeeSwap.balance(currencies[1])];
        uint256 baseline=pairPayout ? 0 : PositionFeeSwap.balance(t.target);
        uint128 liquidity=PM.getPositionLiquidity(plan.id);
        bytes[] memory args=new bytes[](2);
        args[0]=abi.encode(plan.id,uint256(0),uint128(0),uint128(0),bytes(""));
        args[1]=abi.encode(key.currency0,key.currency1,address(this));
        PM.modifyLiquidities(abi.encode(hex"0111",args),plan.deadline);
        Details memory d=abi.decode(plan.details,(Details));
        uint256[2] memory earned;
        uint256 value;
        for(uint256 i;i<2;++i){
            earned[i]=PositionFeeSwap.balance(currencies[i])-before[i];
            if(d.usd[i]==0 || d.unit[i]==0) revert InvalidPayout();
            value+=FullMath.mulDiv(earned[i],d.usd[i],d.unit[i]);
        }
        if(value<t.threshold || t.reserve==0) revert InvalidPayout();
        for(uint256 i;i<2;++i){
            Leg memory leg=d.legs[i];
            if(pairPayout){
                if(leg.expected!=0 || leg.quote.input!=0 || leg.quote.minimumOut!=0 || leg.quote.branches.length!=0) revert InvalidPayout();
            }else convertFee(key,i,t.target,earned[i],leg,t.slippage,plan.deadline);
        }
        if(pairPayout){
            uint256 side=t.gasCurrency==currencies[0]?0:1;
            if(earned[side]<t.reserve) revert InvalidPayout();
            earned[side]-=t.reserve;
            PositionPayment.pay(t.gasCurrency,t.gasModule,t.reserve);
            for(uint256 i;i<2;++i) PositionPayment.pay(currencies[i],msg.sender,earned[i]);
        }else{
            uint256 gross=PositionFeeSwap.balance(t.target)-baseline;
            if(gross<=t.reserve) revert InvalidPayout();
            PositionPayment.pay(t.target,t.gasModule,t.reserve);
            PositionPayment.pay(t.target,msg.sender,gross-t.reserve);
        }
        if((!pairPayout && PositionFeeSwap.balance(t.target)!=baseline) || PositionFeeSwap.balance(currencies[0])!=before[0] ||
            PositionFeeSwap.balance(currencies[1])!=before[1] || PM.getPositionLiquidity(plan.id)!=liquidity ||
            PM.ownerOf(plan.id)!=t.owner) revert InvalidPayout();
    }

    function convertFee(LMPoolKey memory key,uint256 side,address target,uint256 earned,Leg memory leg,uint16 slippage,uint48 deadline)
        internal returns(uint256)
    {
        address input=side==0?key.currency0:key.currency1;
        if(input==target || earned==0){
            if(leg.expected!=0 || leg.quote.input!=0 || leg.quote.minimumOut!=0 || leg.quote.branches.length!=0) revert InvalidPayout();
            return earned;
        }
        if(leg.quote.input==0 || leg.expected==0 || leg.quote.minimumOut==0 || leg.quote.minimumOut>leg.expected ||
            uint256(leg.quote.minimumOut)*10000<uint256(leg.expected)*(10000-slippage)) revert InvalidPayout();
        bool forward=input<target;
        if(key.currency0!=target && key.currency1!=target) key=LMPoolKey(forward?input:target,forward?target:input,0,0,address(0));
        return PositionFeeSwap.execute(key,forward,allEarned(leg.quote,earned),earned,deadline);
    }

    // Trades can add fees between review and inclusion. Keep the signed route
    // proportions and minimum exchange rate for every additional unit collected.
    function allEarned(PositionFeeSwap.Quote memory q,uint256 amount) private pure returns(PositionFeeSwap.Quote memory) {
        if(amount==q.input) return q;
        if(amount<q.input || amount>type(uint128).max || q.branches.length==0 || q.branches.length>16) revert InvalidPayout();
        uint256 minimum=FullMath.mulDivRoundingUp(q.minimumOut,amount,q.input);
        if(minimum>type(uint128).max) revert InvalidPayout();
        uint256 total;
        uint256 allocated;
        for(uint256 j;j<q.branches.length;++j){
            uint256 weight=q.branches[j].input;
            if(weight==0) revert InvalidPayout();
            total+=weight;
            if(total>q.input) revert InvalidPayout();
            uint256 cumulative=amount*total/q.input;
            q.branches[j].input=uint128(cumulative-allocated);
            allocated=cumulative;
        }
        if(total!=q.input) revert InvalidPayout();
        q.minimumOut=uint128(minimum);
        q.input=uint128(amount);
        return q;
    }
}
