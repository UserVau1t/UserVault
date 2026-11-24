// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {PositionRangeFunding,PositionFeeSwap,LMPoolKey} from "./PositionRangeFunding.sol";
import {ILMPositionManager,ILMStateView} from "../LiquidityControllerV2.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PositionPayment} from "./PositionPayment.sol";
import {PositionPayout} from "./PositionPayout.sol";

interface IRangePayoutPolicy {function rangePayoutPolicy(uint256 id) external view returns(uint8,uint16);}
/// Stateless execution restricted to the stable funding adapter.
contract PositionRangeExecution {
    ILMPositionManager private constant PM=ILMPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    ILMStateView private constant STATE=ILMStateView(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b);
    address public immutable fundingAddress;
    constructor(address funding_) {
        if(block.chainid!=4663 || funding_==address(0)) revert Unauthorized();
        fundingAddress=funding_;
    }
    function moduleBinding() external view returns(bytes32) {return keccak256(abi.encode("PositionRangeExecution.v1",fundingAddress));}
    function payoutFor(PositionPayout.Plan calldata p,PositionPayout.Terms calldata terms) external {
        PositionRangeFunding adapter=PositionRangeFunding(payable(fundingAddress));
        if(address(this)!=fundingAddress || msg.sender!=adapter.automationController()) revert Unauthorized();
        PositionPayout.pay(p,terms);
    }
    error Unauthorized();
    error InvalidInput();
    error UnexpectedSettlement();
    event RangeFunded(uint256 indexed oldId,uint256 indexed newId,uint128 liquidity,
        uint256 moved0,uint256 moved1,uint256 fee0,uint256 fee1);
    event FeesPaidOut(uint256 indexed id,address indexed owner,address indexed currency,uint256 net,uint256 protocolFee);

    function moveRange(PositionRangeFunding.RangePlan memory p,PositionRangeFunding.Reserve calldata r) external returns(uint256 newId) {
        PositionRangeFunding adapter=PositionRangeFunding(payable(fundingAddress));
        if(address(this)!=fundingAddress || msg.sender!=adapter.automationController() || r.owner!=PM.ownerOf(p.id) || p.minimumLiquidity==0 ||
            p.previousLiquidity==0 || PM.getPositionLiquidity(p.id)!=p.previousLiquidity) revert Unauthorized();
        (LMPoolKey memory key,)=PM.getPoolAndPositionInfo(p.id);
        if((uint160(key.hooks)&3)!=0 || (r.currency!=key.currency0 && r.currency!=key.currency1)) revert InvalidInput();
        uint256 base0=PositionFeeSwap.balance(key.currency0);
        uint256 base1=PositionFeeSwap.balance(key.currency1);
        (uint256 moved0,uint256 moved1)=_close(p,key,r,adapter.treasury(),base0,base1);
        PositionPayment.pay(key.currency0,adapter.treasury(),moved0/1000);
        PositionPayment.pay(key.currency1,adapter.treasury(),moved1/1000);
        uint256 available=r.currency==key.currency0?moved0-moved0/1000:moved1-moved1/1000;
        if(r.amount==0 || r.amount>available) revert InvalidInput();
        PositionPayment.pay(r.currency,r.module,r.amount);
        uint256 actualOut;
        if(p.swap.input!=0){
            uint256 spendable=p.forward?PositionFeeSwap.balance(key.currency0)-base0:PositionFeeSwap.balance(key.currency1)-base1;
            actualOut=PositionFeeSwap.execute(key,p.forward,p.swap,spendable,p.deadline);
        }
        (uint160 price,,,)=STATE.getSlot0(keccak256(abi.encode(key)));
        (uint128 liquidity,uint256 used0,uint256 used1)=adapter.liquidityMath().mintAmounts(price,p.lower,p.upper,
            PositionFeeSwap.balance(key.currency0)-base0,PositionFeeSwap.balance(key.currency1)-base1);
        if(liquidity<p.minimumLiquidity || used0>type(uint128).max || used1>type(uint128).max) revert InvalidInput();
        PositionPayment.approveManager(key.currency0,uint128(used0),p.deadline);
        PositionPayment.approveManager(key.currency1,uint128(used1),p.deadline);
        newId=PM.nextTokenId();
        bytes[] memory args=new bytes[](2);
        args[0]=abi.encode(key,p.lower,p.upper,uint256(liquidity),uint128(used0),uint128(used1),r.owner,bytes(""));
        args[1]=abi.encode(key.currency0,key.currency1);
        PM.modifyLiquidities{value:key.currency0==address(0)?used0:0}(abi.encode(hex"020d",args),p.deadline);
        PositionPayment.approveManager(key.currency0,0,p.deadline);
        PositionPayment.approveManager(key.currency1,0,p.deadline);
        if(PM.ownerOf(newId)!=r.owner || PM.getPositionLiquidity(newId)!=liquidity) revert UnexpectedSettlement();
        uint256 idle=adapter.liquidityMath().value1(PositionFeeSwap.balance(key.currency0)-base0,PositionFeeSwap.balance(key.currency1)-base1,price);
        uint256 invested=adapter.liquidityMath().value1(used0,used1,price);
        uint256 idleBps=100;
        if(actualOut!=p.expectedOut){
            uint256 larger=actualOut>p.expectedOut?actualOut:p.expectedOut;
            uint256 smaller=actualOut>p.expectedOut?p.expectedOut:actualOut;
            idleBps+=FullMath.mulDivRoundingUp(larger-smaller,10000,larger);
        }
        if(invested==0 || idle>FullMath.mulDiv(idle+invested,idleBps,10000)) revert UnexpectedSettlement();
        PositionPayment.pay(key.currency0,r.owner,PositionFeeSwap.balance(key.currency0)-base0);
        PositionPayment.pay(key.currency1,r.owner,PositionFeeSwap.balance(key.currency1)-base1);
        if(PositionFeeSwap.balance(key.currency0)!=base0 || PositionFeeSwap.balance(key.currency1)!=base1) revert UnexpectedSettlement();
        emit RangeFunded(p.id,newId,liquidity,moved0,moved1,moved0/1000,moved1/1000);
    }

    function _close(PositionRangeFunding.RangePlan memory p,LMPoolKey memory key,PositionRangeFunding.Reserve calldata r,
        address treasury,uint256 base0,uint256 base1) private returns(uint256 moved0,uint256 moved1) {
        bytes[] memory args=new bytes[](2);
        args[1]=abi.encode(key.currency0,key.currency1,address(this));
        uint256[2] memory fees;
        if(!r.includeFees){
            args[0]=abi.encode(p.id,uint256(0),uint128(0),uint128(0),bytes(""));
            PM.modifyLiquidities(abi.encode(hex"0111",args),p.deadline);
            fees=[PositionFeeSwap.balance(key.currency0)-base0,PositionFeeSwap.balance(key.currency1)-base1];
        }
        args[0]=abi.encode(p.id,uint128(0),uint128(0),bytes(""));
        PM.modifyLiquidities(abi.encode(hex"0311",args),p.deadline);
        moved0=PositionFeeSwap.balance(key.currency0)-base0-fees[0];
        moved1=PositionFeeSwap.balance(key.currency1)-base1-fees[1];
        if(!r.includeFees){
            _payFees(p,key,r.owner,treasury,fees);
            if(PositionFeeSwap.balance(key.currency0)!=base0+moved0 || PositionFeeSwap.balance(key.currency1)!=base1+moved1)
                revert UnexpectedSettlement();
        }
    }

    function _payFees(PositionRangeFunding.RangePlan memory p,LMPoolKey memory key,address owner,address treasury,uint256[2] memory fees) private {
        (uint8 mode,uint16 slippage)=IRangePayoutPolicy(msg.sender).rangePayoutPolicy(p.id);
        if(mode!=1 && mode!=2){
            PositionPayment.pay(key.currency0,owner,fees[0]);
            PositionPayment.pay(key.currency1,owner,fees[1]);
            return;
        }
        (,bytes memory routes)=abi.decode(p.marketRoute,(bytes,bytes));
        PositionPayout.Leg[2] memory legs=abi.decode(routes,(PositionPayout.Leg[2]));
        address target=mode==1?address(0):PositionPayout.USDG;
        uint256 gross=PositionPayout.convertFee(key,0,target,fees[0],legs[0],slippage,p.deadline);
        gross+=PositionPayout.convertFee(key,1,target,fees[1],legs[1],slippage,p.deadline);
        if(gross==0)return;
        uint256 fee=gross/100;
        PositionPayment.pay(target,treasury,fee);
        PositionPayment.pay(target,owner,gross-fee);
        emit FeesPaidOut(p.id,owner,target,gross-fee,fee);
    }
}
