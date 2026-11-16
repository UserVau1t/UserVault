pragma solidity ^0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ReferencePriceMath as R} from "./ReferencePriceMath.sol";

interface IBurnToken {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function burnFrom(address account, uint256 amount) external;
}

interface IBurnPricing {
    function configuredChainId() external view returns (uint256);
    function usdg() external view returns (address);
    function wrappedNative() external view returns (address);
    function openContext(bytes[] calldata proofs) external;
    function closeContext() external;
    function read(address base, address quote) external view returns (R.Ratio memory, R.Ratio memory);
    function quoteUsd(address quote) external view returns (R.Ratio memory);
}

interface IBurnReserveBridge {
    function controller() external view returns (address);
    function controllerHash() external view returns (bytes32);
    function availableBurnETH() external view returns (uint256);
    function payBurn(address recipient, uint256 amount) external;
}

contract DeferredTokenBurnAndClaim is ReentrancyGuard {
    struct Policy {
        uint128 minimumBurnUsd;
        uint128 maximumBurnUsd;
        uint128 dailyPayoutUsd;
        uint32 walletCooldown;
        uint32 globalCooldown;
        uint16 bonusBps;
    }

    address public immutable administrator;
    IBurnPricing public immutable pricing;
    bytes32 public immutable pricingHash;
    IBurnToken public user;
    bytes32 public userHash;
    uint8 public tokenDecimals;
    IBurnReserveBridge public treasury;
    bytes32 public treasuryHash;
    Policy public policy;
    bool public paused;
    uint256 public nextGlobalAt;
    mapping(address => uint256) public nextWalletAt;
    mapping(uint256 => uint256) public dailyPaidUsd;
    uint256 public totalBurnedUSER;
    uint256 public totalPaidETH;

    error Unauthorized();
    error InvalidConfiguration();
    error AlreadyBound();
    error NotReady();
    error BurnPaused();
    error InvalidAmount();
    error Cooldown();
    error Capacity();
    error Constraint();
    error BurnMismatch();

    event TokenBound(address indexed token, bytes32 codeHash, uint8 decimals);
    event TreasuryBound(address indexed treasury, bytes32 codeHash);
    event PolicyConfigured(Policy policy);
    event PauseChanged(bool paused);
    event BurnedAndClaimed(address indexed owner, uint256 amountUSER, uint256 payoutETH, uint256 chargedUsd, uint256 indexed utcDay);

    constructor(address admin, IBurnPricing prices) {
        if (block.chainid != 4663 || admin == address(0) || address(prices).code.length == 0
            || prices.configuredChainId() != 4663) revert InvalidConfiguration();
        administrator = admin;
        pricing = prices;
        pricingHash = address(prices).codehash;
        policy = Policy(100e18, 1000e18, 20000e18, 12 hours, 30 minutes, 2000);
    }

    modifier onlyAdministrator() {
        if (msg.sender != administrator) revert Unauthorized();
        _;
    }

    function bindToken(address token, bytes32 expectedCodeHash) external onlyAdministrator nonReentrant {
        if (address(user) != address(0)) revert AlreadyBound();
        if (block.chainid != 4663 || address(pricing).codehash != pricingHash
            || token.code.length == 0 || token.codehash != expectedCodeHash
            || token == address(this) || token == address(pricing) || token == address(treasury)
            || token == pricing.usdg() || token == pricing.wrappedNative()) revert InvalidConfiguration();
        IBurnToken selected = IBurnToken(token);
        uint8 decimals = selected.decimals();
        selected.totalSupply();
        selected.balanceOf(address(this));
        user = selected;
        userHash = expectedCodeHash;
        tokenDecimals = decimals;
        emit TokenBound(token, expectedCodeHash, decimals);
    }

    function bindTreasury(IBurnReserveBridge funds, bytes32 expectedCodeHash) external onlyAdministrator nonReentrant {
        if (address(treasury) != address(0)) revert AlreadyBound();
        if (block.chainid != 4663 || address(funds).code.length == 0
            || address(funds) == address(this) || address(funds) == address(user) || address(funds) == address(pricing)
            || address(funds).codehash != expectedCodeHash || funds.controller() != address(this)
            || funds.controllerHash() != address(this).codehash) revert InvalidConfiguration();
        treasury = funds;
        treasuryHash = expectedCodeHash;
        emit TreasuryBound(address(funds), expectedCodeHash);
    }

    function configurePolicy(Policy calldata next) external onlyAdministrator nonReentrant {
        if (next.minimumBurnUsd == 0 || next.maximumBurnUsd < next.minimumBurnUsd
            || next.dailyPayoutUsd < R.consideration(next.minimumBurnUsd, R.Ratio(10000 + uint256(next.bonusBps), 10000), true)) {
            revert InvalidConfiguration();
        }
        policy = next;
        emit PolicyConfigured(next);
    }

    function setPaused(bool value) external onlyAdministrator nonReentrant {
        paused = value;
        emit PauseChanged(value);
    }

    function remainingDailyUsd() public view returns (uint256) {
        uint256 spent = dailyPaidUsd[block.timestamp / 1 days];
        return spent >= policy.dailyPayoutUsd ? 0 : uint256(policy.dailyPayoutUsd) - spent;
    }

    function _identity() private view {
        if (paused) revert BurnPaused();
        if (block.chainid != 4663 || address(user) == address(0) || address(treasury) == address(0)
            || address(user).codehash != userHash || user.decimals() != tokenDecimals
            || address(pricing).codehash != pricingHash || address(treasury).codehash != treasuryHash
            || treasury.controller() != address(this) || treasury.controllerHash() != address(this).codehash) revert NotReady();
    }

    function _rates() private view returns (R.Ratio memory usd, R.Ratio memory cost, R.Ratio memory eth) {
        (, usd) = pricing.read(address(user), address(0));
        cost = R.compose(usd, R.Ratio(10000 + uint256(policy.bonusBps), 10000));
        R.Ratio memory ethUsd = pricing.quoteUsd(address(0));
        eth = R.compose(cost, R.Ratio(ethUsd.d, ethUsd.n));
    }

    function _quote(address owner, uint256 amount) private view returns (uint256 payoutETH, uint256 chargedUsd) {
        if (owner == address(0) || amount == 0) revert InvalidAmount();
        if (block.timestamp < nextGlobalAt || block.timestamp < nextWalletAt[owner]) revert Cooldown();
        (R.Ratio memory usd, R.Ratio memory cost, R.Ratio memory eth) = _rates();
        if (!R.atLeast(amount, usd, policy.minimumBurnUsd) || !R.atMost(amount, usd, policy.maximumBurnUsd)) revert InvalidAmount();
        payoutETH = R.consideration(amount, eth, false);
        chargedUsd = R.consideration(amount, cost, true);
        if (payoutETH == 0 || !R.atMost(amount, eth, treasury.availableBurnETH()) || chargedUsd > remainingDailyUsd()) revert Capacity();
    }

    function quote(address owner, uint256 amount, bytes[] calldata proofs) external nonReentrant returns (uint256 payoutETH, uint256 chargedUsd) {
        _identity();
        pricing.openContext(proofs);
        (payoutETH, chargedUsd) = _quote(owner, amount);
        pricing.closeContext();
    }

    function maximumBurnUSER(bytes[] calldata proofs) external nonReentrant returns (uint256 amount) {
        _identity();
        pricing.openContext(proofs);
        (R.Ratio memory usd, R.Ratio memory cost, R.Ratio memory eth) = _rates();
        amount = R.consideration(policy.maximumBurnUsd, R.Ratio(usd.d, usd.n), false);
        uint256 byFunds = R.consideration(treasury.availableBurnETH(), R.Ratio(eth.d, eth.n), false);
        uint256 byDay = R.consideration(remainingDailyUsd(), R.Ratio(cost.d, cost.n), false);
        if (byFunds < amount) amount = byFunds;
        if (byDay < amount) amount = byDay;
        if (!R.atLeast(amount, usd, policy.minimumBurnUsd)) amount = 0;
        pricing.closeContext();
    }

    function burnAndClaim(uint256 amount, uint256 minimumETH, uint256 deadline, bytes[] calldata proofs) external nonReentrant {
        _identity();
        if (minimumETH == 0 || block.timestamp > deadline) revert Constraint();
        pricing.openContext(proofs);
        (uint256 payout, uint256 charged) = _quote(msg.sender, amount);
        pricing.closeContext();
        if (payout < minimumETH) revert Constraint();
        uint256 balance = user.balanceOf(msg.sender);
        uint256 supply = user.totalSupply();
        if (balance < amount || supply < amount) revert InvalidAmount();
        uint256 day = block.timestamp / 1 days;
        dailyPaidUsd[day] += charged;
        nextGlobalAt = block.timestamp + policy.globalCooldown;
        nextWalletAt[msg.sender] = block.timestamp + policy.walletCooldown;
        totalBurnedUSER += amount;
        totalPaidETH += payout;
        user.burnFrom(msg.sender, amount);
        if (user.balanceOf(msg.sender) != balance - amount || user.totalSupply() != supply - amount) revert BurnMismatch();
        treasury.payBurn(msg.sender, payout);
        emit BurnedAndClaimed(msg.sender, amount, payout, charged, day);
    }
}
