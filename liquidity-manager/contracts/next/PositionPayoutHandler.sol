// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PositionCompoundController,PositionFunding,GasReimbursement,PositionObserver,IExitPriority,LMPoolKey} from "./PositionCompoundController.sol";
import {PositionRangeFunding} from "./PositionRangeFunding.sol";
import {PositionPayout} from "./PositionPayout.sol";
import {PositionFeeSwap} from "./PositionFeeSwap.sol";
import {PositionPayment} from "./PositionPayment.sol";

interface IFeeMode {function payoutMode(uint256 id) external view returns(uint8);}
library PayoutCallback {
    bytes32 private constant SLOT=keccak256("UserVault.activeFeePayout.v1");
    function operation() internal view returns(bytes32 op) {
        bytes32 slot=SLOT;
        assembly ("memory-safe") {op:=tload(slot)}
    }
    function set(bytes32 op) internal {
        bytes32 slot=SLOT;
        assembly ("memory-safe") {tstore(slot,op)}
    }
}
// The strategy delegates only the two payout selectors and an active gas callback.
// All persistent mandate storage comes from the same controller base.
contract PositionPayoutHandler is PositionCompoundController {
    bytes32 private constant PAYOUT=keccak256("UserVault.FeePayout.v1");
    event PayoutCompleted(uint256 indexed id,uint64 indexed nonce,address indexed gasCurrency,uint256 chargedWei,uint256 tokenPaid);
    event FeesPaidOut(uint256 indexed id,address indexed owner,address indexed currency,uint256 net,uint256 protocolFee);
    constructor(PositionFunding f,GasReimbursement g,address k,PositionObserver o)
        PositionCompoundController(f,g,k,o,IExitPriority(address(0))) {}
    function payoutTicket(PositionPayout.Plan calldata p,address currency) public view returns(GasReimbursement.Ticket memory) {
        uint8 mode=IFeeMode(address(this)).payoutMode(p.id);
        (LMPoolKey memory key,)=PM.getPoolAndPositionInfo(p.id);
        if(mode==0 || mode>3 || (mode==3 ? currency!=key.currency0 && currency!=key.currency1 :
            currency!=(mode==1?address(0):PositionPayout.USDG))) revert Unauthorized();
        GasReimbursement.Ticket memory t=_ticket(p.id,p.nonce,keccak256(abi.encode(PAYOUT,block.chainid,address(this),p,currency)),
            currency==key.currency1?key.currency1:key.currency0);
        if(currency!=key.currency0 && currency!=key.currency1) t.limits.maximumTokenAmount=type(uint128).max;
        t.currency=currency;
        // Return any unused reserve here and settle it with the rest of this payout.
        t.owner=address(this);
        return t;
    }
    function payout(PositionPayout.Plan calldata p,address currency,GasReimbursement.SaleQuote calldata sale,
        bytes calldata signature) external locked(p.deadline) {
        if(msg.sender!=keeper || p.deadline>block.timestamp+90) revert Unauthorized();
        GasReimbursement.Ticket memory t=payoutTicket(p,currency);
        if(ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(t.operation),signature)!=reviewer) revert Unauthorized();
        bool pairPayout=IFeeMode(address(this)).payoutMode(p.id)==3;
        address other;
        uint256 otherBaseline;
        if(pairPayout){
            (LMPoolKey memory key,)=PM.getPoolAndPositionInfo(p.id);
            other=currency==key.currency0?key.currency1:key.currency0;
            otherBaseline=PositionFeeSwap.balance(other);
        }
        uint256 baseline=PositionFeeSwap.balance(currency);
        address owner=mandates[p.id].owner;
        PayoutCallback.set(t.operation);
        (uint256 cost,uint256 paid)=gasModule.execute(t,sale,abi.encode(p));
        Mandate storage m=mandates[p.id];
        if(PayoutCallback.operation()!=0 || m.nonce!=p.nonce || m.owner!=owner || m.epoch!=observer.epoch(p.id) || PM.ownerOf(p.id)!=owner) revert Unauthorized();
        m.policy.remainingWei-=uint128(cost);
        ++m.nonce;
        bool received=_distribute(p.id,owner,currency,baseline);
        if(pairPayout && _distribute(p.id,owner,other,otherBaseline)) received=true;
        if(!received) revert InvalidInput();
        emit PayoutCompleted(p.id,p.nonce,currency,cost,paid);
    }

    function _distribute(uint256 id,address owner,address currency,uint256 baseline) private returns(bool){
        uint256 realized=PositionFeeSwap.balance(currency)-baseline;
        if(realized==0) return false;
        uint256 fee=realized/100;
        PositionPayment.pay(currency,funding.treasury(),fee);
        PositionPayment.pay(currency,owner,realized-fee);
        if(PositionFeeSwap.balance(currency)!=baseline) revert InvalidInput();
        emit FeesPaidOut(id,owner,currency,realized-fee,fee);
        return true;
    }

    function executeReserved(bytes32 operation,address currency,uint256 reserve,bytes calldata action) public override {
        if(msg.sender!=address(gasModule)||operation==0 || operation!=PayoutCallback.operation()) revert Unauthorized();
        PayoutCallback.set(0);
        PositionPayout.Plan memory payoutPlan=abi.decode(action,(PositionPayout.Plan));
        Mandate storage mandate_=mandates[payoutPlan.id];
        uint8 mode=IFeeMode(address(this)).payoutMode(payoutPlan.id);
        address target=mode==3?PositionPayout.PAIR:mode==1?address(0):PositionPayout.USDG;
        PositionRangeFunding(payable(address(funding))).payoutFor(payoutPlan,PositionPayout.Terms(
            mandate_.owner,target,msg.sender,currency,reserve,mandate_.policy.thresholdUsd,mandate_.policy.maxSlippageBps));
    }
}
