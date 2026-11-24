// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PositionFunding, ILMPositionManager, LMPoolKey, PositionFeeSwap} from "./PositionFunding.sol";
import {GasReimbursement, IReimbursedPositionAction} from "./GasReimbursement.sol";

import {PositionObserver} from "./PositionObserver.sol";

interface IExitPriority {
    function trigger(uint256 id) external view returns (uint8 side,int24 tick);
}

/// Owner-approved, fee-only compounding. A separate adapter settles the position.
contract PositionCompoundController is IReimbursedPositionAction {
    ILMPositionManager internal constant PM = ILMPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    PositionFunding public immutable funding;
    GasReimbursement public immutable gasModule;
    PositionObserver public immutable observer;
    IExitPriority public immutable exitModule;
    address public immutable keeper;
    address public immutable reviewer;
    bytes32 private constant PLAN = keccak256("UserVault.NetCompound.v1");
    struct Policy {
        uint128 thresholdUsd;
        uint128 minimumAddedUsd;
        uint128 maximumWei;
        uint128 remainingWei;
        uint128 maxToken0;
        uint128 maxToken1;
        uint96 gasPriceCap;
        uint32 gasUnitsCap;
        uint16 maxSaleLossBps;
        uint16 maxSlippageBps;
        uint48 expiresAt;
    }
    struct Mandate {address owner; uint64 nonce; uint64 epoch; Policy policy;}
    struct Plan {
        uint256 id;
        uint64 nonce;
        uint48 deadline;
        uint128 minimumLiquidity;
        uint128 expectedOut;
        bool forward;
        uint256 usd0;
        uint256 usd1;
        uint256 unit0;
        uint256 unit1;
        PositionFeeSwap.Quote swap;
    }
    mapping(uint256 => Mandate) internal mandates;
    bytes32 private activeOperation;
    bool private entered;
    error InvalidInput();
    error Unauthorized();
    modifier locked(uint48 deadline) {
        if (address(this) != gasModule.controller() || entered || deadline < block.timestamp || deadline > block.timestamp + 10 minutes) revert InvalidInput();
        entered = true;
        _;
        entered = false;
    }
    event CompoundConfigured(uint256 indexed id, address indexed owner, uint64 nonce, Policy policy);
    event CompoundDisabled(uint256 indexed id, uint64 nonce);
    event CompoundCompleted(uint256 indexed id, uint64 indexed nonce, address indexed gasCurrency, uint256 chargedWei, uint256 tokenPaid);

    constructor(PositionFunding funding_, GasReimbursement gasModule_, address keeper_, PositionObserver observer_, IExitPriority exit_) {
        if (funding_.automationController() == address(0) || funding_.automationController() != gasModule_.controller() ||
            keeper_ == address(0) || keeper_ == gasModule_.reviewer() || address(observer_).code.length == 0 ||
            (address(exit_) != address(0) && address(exit_).code.length == 0)) revert InvalidInput();
        observer = observer_;
        exitModule = exit_;
        funding = funding_;
        gasModule = gasModule_;
        keeper = keeper_;
        reviewer = gasModule_.reviewer();
    }
    function mandate(uint256 id) public view returns (Mandate memory m) {
        m = mandates[id];
        if (m.epoch != observer.epoch(id)) m.owner = address(0);
    }

    function configureCompound(uint256 id, Policy calldata p, uint48 deadline) external virtual locked(deadline) {
        _configure(id,msg.sender,p,false);
    }
    function _configure(uint256 id,address owner,Policy calldata p,bool rangeOnly) internal {
        if (PM.ownerOf(id) != owner || id == 0) revert Unauthorized();
        if ((!rangeOnly && (p.thresholdUsd == 0 || p.minimumAddedUsd == 0)) || p.minimumAddedUsd > p.thresholdUsd ||
            p.maximumWei == 0 || p.remainingWei == 0 || p.gasPriceCap == 0 || p.gasUnitsCap == 0 ||
            (p.maxToken0 == 0 && p.maxToken1 == 0) || p.maxSaleLossBps >= 10000 ||
            p.maxSlippageBps >= 10000 || p.expiresAt <= block.timestamp) revert InvalidInput();
        if (PM.getApproved(id) != address(funding) && !PM.isApprovedForAll(owner,address(funding))) revert Unauthorized();
        if (observer.epoch(id) == 0) funding.attachAutomation(id,address(observer));
        Mandate storage m = mandates[id];
        m.epoch = observer.epoch(id);
        if (m.epoch == 0) revert Unauthorized();
        m.owner = owner;
        ++m.nonce;
        m.policy = p;
        emit CompoundConfigured(id,owner,m.nonce,p);
    }
    function disableCompound(uint256 id) external {
        if (PM.ownerOf(id) != msg.sender) revert Unauthorized();
        _disable(id);
    }
    function _disable(uint256 id) internal virtual {
        Mandate storage m = mandates[id];
        if (m.owner != address(0)) {
            delete m.owner;
            emit CompoundDisabled(id,++m.nonce);
        }
    }
    function planDigest(Plan calldata p,address gasCurrency) public view returns (bytes32) {
        return keccak256(abi.encode(PLAN,block.chainid,address(this),p,gasCurrency));
    }
    function gasTicket(Plan calldata p,address currency) public view returns (GasReimbursement.Ticket memory t) {
        if (!_reinvestEnabled(p.id)) revert Unauthorized();
        return _ticket(p.id,p.nonce,planDigest(p,currency),currency);
    }
    function _reinvestEnabled(uint256 id) internal view virtual returns(bool) {
        return mandates[id].policy.thresholdUsd!=0;
    }
    function _ticket(uint256 id,uint64 nonce,bytes32 digest,address currency) internal view returns (GasReimbursement.Ticket memory t) {
        Mandate storage m = mandates[id];
        if (m.owner == address(0) || m.nonce != nonce || PM.ownerOf(id) != m.owner ||
            m.epoch != observer.epoch(id) ||
            m.policy.expiresAt < block.timestamp) revert Unauthorized();
        if(address(exitModule)!=address(0)){
            (uint8 exitSide,) = exitModule.trigger(id);
            if (exitSide != 0) revert InvalidInput();
        }
        (LMPoolKey memory key,) = PM.getPoolAndPositionInfo(id);
        if (currency != key.currency0 && currency != key.currency1) revert InvalidInput();
        Policy storage policy = m.policy;
        t = GasReimbursement.Ticket(
            digest,currency,keeper,m.owner,
            GasReimbursement.Limits(policy.maximumWei,policy.remainingWei,policy.gasPriceCap,policy.gasUnitsCap,
                currency == key.currency0 ? policy.maxToken0 : policy.maxToken1,policy.maxSaleLossBps));
    }
    function compound(Plan calldata p,address gasCurrency,GasReimbursement.SaleQuote calldata sale,bytes calldata signature)
        external locked(p.deadline)
    {
        if (msg.sender != keeper || p.deadline > block.timestamp + 90 || p.minimumLiquidity == 0 ||
            p.usd0 == 0 || p.usd1 == 0 || p.unit0 == 0 || p.unit1 == 0) revert Unauthorized();
        GasReimbursement.Ticket memory t = gasTicket(p,gasCurrency);
        if (ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(t.operation),signature) != reviewer) revert Unauthorized();
        Mandate storage m = mandates[p.id];
        if (p.swap.input == 0) {
            if (p.expectedOut != 0 || p.swap.minimumOut != 0 || p.swap.branches.length != 0) revert InvalidInput();
        } else if (p.expectedOut == 0 || p.swap.minimumOut == 0 || p.swap.minimumOut > p.expectedOut ||
            uint256(p.swap.minimumOut)*10000 < uint256(p.expectedOut)*(10000-m.policy.maxSlippageBps)) revert InvalidInput();
        activeOperation = t.operation;
        (uint256 cost,uint256 paid) = gasModule.execute(t,sale,abi.encode(p));
        if (activeOperation != bytes32(0) || m.nonce != p.nonce || m.owner != t.owner ||
            m.epoch != observer.epoch(p.id) || PM.ownerOf(p.id) != t.owner) revert Unauthorized();
        m.policy.remainingWei -= uint128(cost);
        ++m.nonce;
        emit CompoundCompleted(p.id,p.nonce,gasCurrency,cost,paid);
    }
    function executeReserved(bytes32 operation,address currency,uint256 reserve,bytes calldata action) public virtual {
        if (msg.sender != address(gasModule) || operation == bytes32(0) || activeOperation != operation) revert Unauthorized();
        delete activeOperation;
        Plan memory p = abi.decode(action,(Plan));
        Mandate storage m = mandates[p.id];
        PositionFunding.Settlement memory s = PositionFunding.Settlement(m.owner,currency,msg.sender,reserve,m.policy.thresholdUsd,m.policy.minimumAddedUsd,
            p.usd0,p.usd1,p.unit0,p.unit1);
        funding.compoundFor(p.id,p.minimumLiquidity,p.deadline,p.forward,p.swap,s);
    }
}
