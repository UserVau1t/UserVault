// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PositionCompoundController,PositionFunding,GasReimbursement,PositionObserver,IExitPriority,LMPoolKey} from "./PositionCompoundController.sol";
import {PositionRangeFunding} from "./PositionRangeFunding.sol";
import {PayoutCallback,PositionPayoutHandler} from "./PositionPayoutHandler.sol";

contract PositionStrategyController is PositionCompoundController {
    struct Offsets {int24 lower; int24 upper;}
    mapping(uint256 => Offsets) public rangeOffsets;
    bytes32 private activeRange;
    uint256 private replacement;
    // Zero is the original strategy for every existing mandate. 1 = ETH, 2 = USDG, 3 = both pool currencies.
    mapping(uint256 => uint8) public payoutMode;
    address public immutable payoutHandler;
    mapping(uint256 => uint48) private requestedUntil;
    event PayoutCompleted(uint256 indexed id,uint64 indexed nonce,address indexed gasCurrency,uint256 chargedWei,uint256 tokenPaid);
    bytes32 private constant RANGE=keccak256("UserVault.SponsoredRange.v1");
    event RangeCompleted(uint256 indexed id,uint64 indexed nonce,uint256 indexed newId,address gasCurrency,uint256 chargedWei,uint256 tokenPaid);

    constructor(PositionFunding funding_,GasReimbursement gas_,address keeper_,PositionObserver observer_)
        PositionCompoundController(funding_,gas_,keeper_,observer_,IExitPriority(address(0))) {
        payoutHandler=address(new PositionPayoutHandler(funding_,gas_,keeper_,observer_));
    }

    function moduleBinding() external view returns(bytes32) {
        return keccak256(abi.encode("PositionStrategyController.storage.v1",funding,gasModule,keeper,observer,exitModule,reviewer));
    }

    function configureMinted(uint256 id,address owner,Policy calldata policy,int24 low,int24 high,uint48 deadline) external locked(deadline) {
        if(msg.sender!=address(funding)) revert Unauthorized();
        _configureStrategy(id,owner,policy,low,high);
    }
    function configureStrategy(uint256 id,Policy calldata policy,int24 low,int24 high,uint48 deadline) external locked(deadline) {
        _configureStrategy(id,msg.sender,policy,low,high);
    }
    function configureRebalanceNow(uint256 id,Policy calldata policy,int24 low,int24 high,uint48 deadline,uint8 mode) external locked(deadline) {
        if(low>=0 || high<=0 || mode>3 || (mode!=0 && policy.thresholdUsd==0) || deadline>block.timestamp+300) revert InvalidInput();
        _configureStrategy(id,msg.sender,policy,low,high);
        payoutMode[id]=mode;
        requestedUntil[id]=deadline;
    }
    function rangeSettings(uint256 id) external view returns(int24 lower,int24 upper,uint48 until) {
        Offsets memory o=rangeOffsets[id];
        return(o.lower,o.upper,requestedUntil[id]);
    }
    function rangePayoutPolicy(uint256 id) external view returns(uint8 mode,uint16 slippage) {
        return (payoutMode[id],mandates[id].policy.maxSlippageBps);
    }
    function configurePayout(uint256 id,address owner,Policy calldata p,int24 low,int24 high,uint48 deadline,uint8 mode) external locked(deadline) {
        if(msg.sender!=owner && msg.sender!=address(funding)) revert Unauthorized();
        if(mode==0 || mode>3 || p.thresholdUsd==0) revert InvalidInput();
        _configureStrategy(id,owner,p,low,high);
        payoutMode[id]=mode;
    }
    function _configureStrategy(uint256 id,address owner,Policy calldata policy,int24 low,int24 high) private {
        delete requestedUntil[id];
        delete payoutMode[id];
        if(policy.thresholdUsd!=0 && policy.thresholdUsd<10e18) revert InvalidInput();
        bool range=low!=0 || high!=0;
        if(range){
            (LMPoolKey memory key,)=PM.getPoolAndPositionInfo(id);
            if(low>=0 || high<=0 || low%key.tickSpacing!=0 || high%key.tickSpacing!=0 ||
                !PM.isApprovedForAll(owner,address(funding))) revert InvalidInput();
        }
        rangeOffsets[id]=Offsets(low,high);
        _configure(id,owner,policy,range && policy.thresholdUsd==0);
    }
    function configureCompound(uint256 id,Policy calldata p,uint48 deadline) external override locked(deadline) {
        delete requestedUntil[id];
        delete payoutMode[id];
        if(p.thresholdUsd<10e18) revert InvalidInput();
        delete rangeOffsets[id];
        _configure(id,msg.sender,p,false);
    }
    function _disable(uint256 id) internal override {
        delete requestedUntil[id];
        delete payoutMode[id];
        delete rangeOffsets[id];
        super._disable(id);
    }
    function _reinvestEnabled(uint256 id) internal view override returns(bool) {
        return payoutMode[id]==0 && super._reinvestEnabled(id);
    }
    receive() external payable {
        if(msg.sender!=address(funding) && msg.sender!=address(gasModule)) revert Unauthorized();
    }
    fallback() external {
        if(msg.sig!=PositionPayoutHandler.payout.selector && msg.sig!=PositionPayoutHandler.payoutTicket.selector) revert InvalidInput();
        _delegatePayout();
    }
    function _delegatePayout() private {
        address target=payoutHandler;
        assembly ("memory-safe") {
            let ptr:=mload(0x40)
            calldatacopy(ptr,0,calldatasize())
            let ok:=delegatecall(gas(),target,ptr,calldatasize(),0,0)
            returndatacopy(ptr,0,returndatasize())
            if iszero(ok) {revert(ptr,returndatasize())}
            return(ptr,returndatasize())
        }
    }

    function rangeTarget(uint256 id,bytes calldata proof,bytes memory route) public view returns(bool ready,int24 lower,int24 upper) {
        Offsets memory offsets=rangeOffsets[id];
        if(offsets.lower==0) return(false,0,0);
        (LMPoolKey memory key,uint256 info)=PM.getPoolAndPositionInfo(id);
        int24 oldLower=int24(uint24(info>>8));
        int24 oldUpper=int24(uint24(info>>32));
        if(address(gasModule.referenceReader()).codehash!=gasModule.referenceCodeHash()) revert InvalidInput();
        int24 tick=gasModule.referenceReader().rebalanceTickForRoute(key,proof,route);
        if(tick>=oldLower && tick<oldUpper && requestedUntil[id]<block.timestamp) return(false,oldLower,oldUpper);
        int256 center=int256(tick)/key.tickSpacing*key.tickSpacing;
        if(tick<0 && tick%key.tickSpacing!=0) center-=key.tickSpacing;
        int256 lo=center+offsets.lower;
        int256 hi=center+offsets.upper;
        int24 min=TickMath.minUsableTick(key.tickSpacing);
        int24 max=TickMath.maxUsableTick(key.tickSpacing);
        lower=lo<min?min:int24(lo);
        upper=hi>max?max:int24(hi);
        ready=lower<upper && (lower!=oldLower || upper!=oldUpper);
    }
    function rangeGasTicket(PositionRangeFunding.RangePlan calldata p,address currency) public view returns(GasReimbursement.Ticket memory){
        return _ticket(p.id,p.nonce,keccak256(abi.encode(RANGE,block.chainid,address(this),p,currency)),currency);
    }
    function rebalance(PositionRangeFunding.RangePlan calldata p,address currency,GasReimbursement.SaleQuote calldata sale,
        bytes calldata signature) external locked(p.deadline) returns(uint256 newId) {
        if(msg.sender!=keeper || p.deadline>block.timestamp+90) revert Unauthorized();
        GasReimbursement.Ticket memory t=rangeGasTicket(p,currency);
        if(ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(t.operation),signature)!=reviewer) revert Unauthorized();
        bytes memory referenceRoute=p.marketRoute;
        uint8 mode=payoutMode[p.id];
        // A converted range signs both the market reference route and the fee swap routes.
        if(mode==1 || mode==2) (referenceRoute,)=abi.decode(p.marketRoute,(bytes,bytes));
        (bool ready,int24 lower,int24 upper)=rangeTarget(p.id,p.marketProof,referenceRoute);
        if(!ready || lower!=p.lower || upper!=p.upper) revert InvalidInput();
        Mandate memory m=mandates[p.id];
        if(p.swap.input==0){
            if(p.expectedOut!=0 || p.swap.minimumOut!=0 || p.swap.branches.length!=0) revert InvalidInput();
        }else if(p.swap.minimumOut==0 || p.swap.minimumOut>p.expectedOut ||
            uint256(p.swap.minimumOut)*10000<uint256(p.expectedOut)*(10000-m.policy.maxSlippageBps)) revert InvalidInput();
        Offsets memory offsets=rangeOffsets[p.id];
        activeRange=t.operation;
        (uint256 cost,uint256 paid)=gasModule.execute(t,sale,abi.encode(p));
        newId=replacement;
        delete replacement;
        if(activeRange!=0 || newId==0 || newId==p.id || PM.ownerOf(newId)!=t.owner ||
            mandates[p.id].nonce!=p.nonce || !PM.isApprovedForAll(t.owner,address(funding))) revert Unauthorized();
        (LMPoolKey memory key,)=PM.getPoolAndPositionInfo(newId);
        int24 settled=gasModule.referenceReader().rebalanceTickForRoute(key,p.marketProof,referenceRoute);
        if(settled<p.lower || settled>=p.upper) revert InvalidInput();
        funding.attachAutomation(newId,address(observer));
        m.epoch=observer.epoch(newId);
        if(m.epoch==0) revert Unauthorized();
        _disable(p.id);
        if(mode!=0) payoutMode[newId]=mode;
        m.nonce=mandates[newId].nonce+1;
        m.policy.remainingWei-=uint128(cost);
        mandates[newId]=m;
        rangeOffsets[newId]=offsets;
        emit CompoundConfigured(newId,t.owner,m.nonce,m.policy);
        emit RangeCompleted(p.id,p.nonce,newId,currency,cost,paid);
    }
    function executeReserved(bytes32 operation,address currency,uint256 reserve,bytes calldata action) public override {
        if(PayoutCallback.operation()!=0){_delegatePayout();return;}
        if(activeRange==0){super.executeReserved(operation,currency,reserve,action);return;}
        if(msg.sender!=address(gasModule) || activeRange!=operation) revert Unauthorized();
        delete activeRange;
        PositionRangeFunding.RangePlan memory p=abi.decode(action,(PositionRangeFunding.RangePlan));
        Mandate storage m=mandates[p.id];
        replacement=PositionRangeFunding(payable(address(funding))).moveRange(p,
            PositionRangeFunding.Reserve(m.owner,currency,msg.sender,reserve,_reinvestEnabled(p.id)));
    }
}
