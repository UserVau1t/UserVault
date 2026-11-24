// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LiquidityMath} from "../LiquidityMath.sol";
import {PositionPayment} from "./PositionPayment.sol";
import {PositionFeeSwap} from "./PositionFeeSwap.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {ILMPositionManager, ILMStateView, ILMPermit2, LMPoolKey} from "../LiquidityControllerV2.sol";

interface IInitializeFundingPool {
    function initialize(LMPoolKey calldata key, uint160 price) external returns (int24);
}
interface IFundingSubscriber {
    function subscribe(uint256 id,address observer,bytes calldata data) external payable;
}

/// Owner-directed mint, top-up and claim on the Robinhood v4 PositionManager.
/// Wallet capital and earned fees remain separate through the final settlement.
contract PositionFunding {
    using SafeERC20 for IERC20;

    ILMPositionManager internal constant PM = ILMPositionManager(0x58daec3116aae6D93017bAAea7749052E8a04fA7);
    ILMStateView internal constant STATE = ILMStateView(0xF3334192D15450CdD385c8B70e03f9A6bD9E673b);
    ILMPermit2 internal constant PERMIT = ILMPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address private constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address public immutable treasury;
    address public immutable automationController;
    LiquidityMath public immutable liquidityMath = new LiquidityMath();
    bool private entered;

    struct Deposit {
        uint128 wallet0;
        uint128 wallet1;
        uint128 minimumLiquidity;
        uint48 deadline;
    }
    struct Asset {
        address currency;
        uint256 baseline;
        uint256 walletCap;
        uint256 earned;
        uint256 used;
        uint256 walletUsed;
        uint256 reinvested;
        uint256 fee;
    }
    struct Settlement {
        address owner;
        address reserveCurrency;
        address gasModule;
        uint256 reserve;
        uint256 minimumEarnedUsd;
        uint256 minimumAddedUsd;
        uint256 usd0;
        uint256 usd1;
        uint256 unit0;
        uint256 unit1;
    }
    error InvalidInput();
    error Unauthorized();
    error UnexpectedSettlement();
    event Funded(uint256 indexed tokenId, address indexed owner, uint128 liquidityAdded,
        uint256 wallet0, uint256 wallet1, uint256 reinvested0, uint256 reinvested1, uint256 fee0, uint256 fee1);
    event FeesClaimed(uint256 indexed tokenId, address indexed owner, uint256 amount0, uint256 amount1);
    event EarnedFeesSwapped(uint256 indexed tokenId, address indexed input, address indexed output, uint256 spent, uint256 received);
    event ClaimConverted(uint256 indexed tokenId, address indexed owner, address indexed target, uint256 received);

    constructor(address treasury_, address automationController_) {
        if (block.chainid != 4663 || treasury_ == address(0) || treasury_ == address(this) ||
            PM.poolManager() != POOL_MANAGER || STATE.poolManager() != POOL_MANAGER ||
            PM.permit2() != address(PERMIT)) revert InvalidInput();
        treasury = treasury_;
        automationController = automationController_;
    }
    modifier locked(uint48 deadline) {
        if (entered || deadline < block.timestamp || deadline > block.timestamp + 10 minutes) revert InvalidInput();
        entered = true;
        _;
        entered = false;
    }
    receive() external payable {}

    function attachAutomation(uint256 id,address observer) public virtual {
        if (msg.sender != automationController) revert Unauthorized();
        IFundingSubscriber(address(PM)).subscribe(id,observer,"");
    }
    /// Automation entry accepts zero wallet capital; the released gas reserve and the reinvest
    /// must both fit the fees collected from this NFT during this call.
    function compoundFor(uint256 id,uint128 minimumLiquidity,uint48 deadline,bool forward,
        PositionFeeSwap.Quote calldata quote,Settlement calldata s) external locked(deadline)
    {
        if (msg.sender != automationController || s.gasModule == address(0) || s.owner != PM.ownerOf(id) ||
            s.reserve == 0 || minimumLiquidity == 0) revert Unauthorized();
        (LMPoolKey memory key,uint256 info) = PM.getPoolAndPositionInfo(id);
        _fund(key,id,int24(uint24(info >> 8)),int24(uint24(info >> 32)),Deposit(0,0,minimumLiquidity,deadline),
            false,true,forward,quote,s);
    }

    function create(LMPoolKey calldata key, int24 lower, int24 upper, uint160 initialPrice, Deposit calldata d)
        public payable locked(d.deadline) returns (uint256 id)
    {
        if (key.currency0 >= key.currency1 || lower >= upper || d.minimumLiquidity == 0) revert InvalidInput();
        if (initialPrice != 0) IInitializeFundingPool(POOL_MANAGER).initialize(key, initialPrice);
        id = PM.nextTokenId();
        PositionFeeSwap.Quote memory noSwap;
        Settlement memory s;
        s.owner = msg.sender;
        _fund(key, id, lower, upper, d, true, false, false, noSwap, s);
    }

    function add(uint256 id, Deposit calldata d, bool reinvestEarned) external payable locked(d.deadline) {
        if (PM.ownerOf(id) != msg.sender) revert Unauthorized();
        if (d.minimumLiquidity == 0) revert InvalidInput();
        (LMPoolKey memory key, uint256 info) = PM.getPoolAndPositionInfo(id);
        PositionFeeSwap.Quote memory noSwap;
        Settlement memory s;
        s.owner = msg.sender;
        _fund(key, id, int24(uint24(info >> 8)), int24(uint24(info >> 32)), d, false, reinvestEarned, false, noSwap, s);
    }
    function addWithFeeSwap(uint256 id, Deposit calldata d, bool forward, PositionFeeSwap.Quote calldata quote)
        external payable locked(d.deadline)
    {
        if (PM.ownerOf(id) != msg.sender) revert Unauthorized();
        if (d.minimumLiquidity == 0 || quote.input == 0) revert InvalidInput();
        (LMPoolKey memory key, uint256 info) = PM.getPoolAndPositionInfo(id);
        Settlement memory s;
        s.owner = msg.sender;
        _fund(key, id, int24(uint24(info >> 8)), int24(uint24(info >> 32)), d, false, true, forward, quote, s);
    }

    function claimOriginal(uint256 id, uint48 deadline) external locked(deadline) {
        if (PM.ownerOf(id) != msg.sender) revert Unauthorized();
        (LMPoolKey memory key,) = PM.getPoolAndPositionInfo(id);
        if ((uint160(key.hooks) & 3) != 0) revert InvalidInput();
        uint128 beforeL = PM.getPositionLiquidity(id);
        Asset memory a = _asset(key.currency0, 0);
        Asset memory b = _asset(key.currency1, 0);
        _collect(id, a, b, deadline);
        PositionPayment.pay(a.currency, msg.sender, a.earned);
        PositionPayment.pay(b.currency, msg.sender, b.earned);
        if (PM.ownerOf(id) != msg.sender || PM.getPositionLiquidity(id) != beforeL ||
            _balance(a.currency) != a.baseline || _balance(b.currency) != b.baseline) revert UnexpectedSettlement();
        emit FeesClaimed(id, msg.sender, a.earned, b.earned);
    }
    /// Swap only this claim. Legs already denominated in the payout currency are passed through.
    function claimConverted(uint256 id, address target, PositionFeeSwap.Quote[2] calldata quotes,
        uint256 minimumReceived, bool acceptOriginalRemainder, uint48 deadline) external locked(deadline)
    {
        if (PM.ownerOf(id) != msg.sender) revert Unauthorized();
        if (minimumReceived == 0) revert InvalidInput();
        (LMPoolKey memory key,) = PM.getPoolAndPositionInfo(id);
        if ((uint160(key.hooks) & 3) != 0) revert InvalidInput();
        uint128 beforeL = PM.getPositionLiquidity(id);
        Asset memory a = _asset(key.currency0, 0);
        Asset memory b = _asset(key.currency1, 0);
        uint256 targetBaseline = _balance(target);
        _collect(id, a, b, deadline);
        _convertClaim(id, key, a, target, quotes[0], acceptOriginalRemainder, deadline);
        _convertClaim(id, key, b, target, quotes[1], acceptOriginalRemainder, deadline);
        uint256 received = _balance(target) - targetBaseline;
        if (received < minimumReceived) revert UnexpectedSettlement();
        PositionPayment.pay(target, msg.sender, received);
        if (_balance(target) != targetBaseline || _balance(a.currency) != a.baseline ||
            _balance(b.currency) != b.baseline || PM.ownerOf(id) != msg.sender ||
            PM.getPositionLiquidity(id) != beforeL) revert UnexpectedSettlement();
        emit FeesClaimed(id, msg.sender, a.earned, b.earned);
        emit ClaimConverted(id, msg.sender, target, received);
    }
    function _convertClaim(uint256 id, LMPoolKey memory key, Asset memory source, address target,
        PositionFeeSwap.Quote calldata q, bool acceptOriginalRemainder, uint48 deadline) private
    {
        if (source.currency == target || source.earned == 0) {
            if (q.input != 0 || q.branches.length != 0 || q.minimumOut != 0) revert InvalidInput();
            return;
        }
        // Fees can accrue between quoting and execution. Pay any excess in its original
        // currency instead of giving the executor permission to enlarge a signed swap.
        if (q.input == 0 || q.input > source.earned || (!acceptOriginalRemainder && q.input != source.earned)) revert InvalidInput();
        bool forward = source.currency < target;
        if ((forward ? key.currency0 : key.currency1) != source.currency ||
            (forward ? key.currency1 : key.currency0) != target) {
            key = LMPoolKey(forward ? source.currency : target, forward ? target : source.currency, 0, 0, address(0));
        }
        uint256 received = PositionFeeSwap.execute(key, forward, q, source.earned, deadline);
        PositionPayment.pay(source.currency, msg.sender, source.earned - q.input);
        emit EarnedFeesSwapped(id, source.currency, target, q.input, received);
    }

    function _asset(address currency, uint128 cap) private view returns (Asset memory a) {
        a.currency = currency;
        a.walletCap = cap;
        a.baseline = _balance(currency) - (currency == address(0) ? msg.value : 0);
    }
    function _balance(address currency) private view returns (uint256) {
        return PositionFeeSwap.balance(currency);
    }
    function _collect(uint256 id, Asset memory a, Asset memory b, uint48 deadline) private {
        uint256 before0 = _balance(a.currency);
        uint256 before1 = _balance(b.currency);
        bytes[] memory args = new bytes[](2);
        args[0] = abi.encode(id, uint256(0), uint128(0), uint128(0), bytes(""));
        args[1] = abi.encode(a.currency, b.currency, address(this));
        PM.modifyLiquidities(abi.encode(hex"0111", args), deadline);
        a.earned = _balance(a.currency) - before0;
        b.earned = _balance(b.currency) - before1;
    }

    // Largest net x for which x + floor(x/100) <= earned. At most one raw unit differs
    // from floor(earned * 100 / 101). This form never multiplies a token balance.
    function reinvestBudget(uint256 earned) public pure returns (uint256) {
        return earned - earned / 101 - (earned % 101 == 100 ? 1 : 0);
    }
    function _budget(Asset memory a, bool reinvest) private pure returns (uint256) {
        return a.walletCap + (reinvest ? reinvestBudget(a.earned) : 0);
    }
    function _prepare(Asset memory a, bool reinvest, uint48 deadline) private {
        if (a.used > type(uint128).max) revert InvalidInput();
        uint256 eligible = reinvest ? reinvestBudget(a.earned) : 0;
        a.reinvested = a.used < eligible ? a.used : eligible;
        a.walletUsed = a.used - a.reinvested;
        a.fee = a.reinvested / 100;
        if (a.walletUsed > a.walletCap) revert InvalidInput();
        if (a.currency == address(0)) return;
        IERC20 token = IERC20(a.currency);
        if (a.walletUsed != 0) {
            uint256 before = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), a.walletUsed);
            if (token.balanceOf(address(this)) != before + a.walletUsed) revert UnexpectedSettlement();
        }
        if (a.used != 0) {
            PositionPayment.approveManager(a.currency, uint160(a.used), deadline);
        }
    }
    function _settle(Asset memory a, uint48 deadline, address owner) private {
        if (a.currency != address(0) && a.used != 0) {
            PositionPayment.approveManager(a.currency, 0, deadline);
        }
        uint256 ownerRemainder = a.earned - a.reinvested - a.fee;
        if (a.currency == address(0)) ownerRemainder += a.walletCap - a.walletUsed;
        if (_balance(a.currency) != a.baseline + ownerRemainder + a.fee) revert UnexpectedSettlement();
        PositionPayment.pay(a.currency, treasury, a.fee);
        PositionPayment.pay(a.currency, owner, ownerRemainder);
        if (_balance(a.currency) != a.baseline) revert UnexpectedSettlement();
    }
    function _fund(LMPoolKey memory key, uint256 id, int24 lower, int24 upper, Deposit memory d,
        bool mint, bool reinvest, bool forward, PositionFeeSwap.Quote memory quote, Settlement memory s) internal
    {
        if (msg.value != (key.currency0 == address(0) ? d.wallet0 : 0)) revert InvalidInput();
        // Delta-returning add/remove hooks can alter the attribution of principal vs fees.
        // Require unambiguous v4 settlement for this funding adapter.
        if ((uint160(key.hooks) & 3) != 0) revert InvalidInput();
        Asset memory a = _asset(key.currency0, d.wallet0);
        Asset memory b = _asset(key.currency1, d.wallet1);
        uint128 previous;
        if (!mint) {
            previous = PM.getPositionLiquidity(id);
            if (previous != 0) _collect(id, a, b, d.deadline);
        }
        if (s.gasModule != address(0)) {
            if (mint || !reinvest || d.wallet0 != 0 || d.wallet1 != 0 || msg.value != 0 ||
                (s.reserveCurrency != a.currency && s.reserveCurrency != b.currency)) revert InvalidInput();
            if (FullMath.mulDiv(a.earned,s.usd0,s.unit0) + FullMath.mulDiv(b.earned,s.usd1,s.unit1) < s.minimumEarnedUsd)
                revert InvalidInput();
            Asset memory gasAsset = s.reserveCurrency == a.currency ? a : b;
            if (gasAsset.earned < s.reserve) revert InvalidInput();
            gasAsset.earned -= s.reserve;
            PositionPayment.pay(gasAsset.currency, s.gasModule, s.reserve);
        }
        if (quote.input != 0) {
            Asset memory source = forward ? a : b;
            Asset memory target = forward ? b : a;
            uint256 received = PositionFeeSwap.execute(key, forward, quote, source.earned, d.deadline);
            source.earned -= quote.input;
            target.earned += received;
            emit EarnedFeesSwapped(id, source.currency, target.currency, quote.input, received);
        }
        (uint160 price,,,) = STATE.getSlot0(keccak256(abi.encode(key)));
        uint128 liquidity;
        (liquidity, a.used, b.used) = liquidityMath.mintAmounts(price, lower, upper, _budget(a, reinvest), _budget(b, reinvest));
        if (liquidity < d.minimumLiquidity) revert InvalidInput();
        _prepare(a, reinvest, d.deadline);
        _prepare(b, reinvest, d.deadline);
        if (s.gasModule != address(0) &&
            FullMath.mulDiv(a.reinvested,s.usd0,s.unit0) + FullMath.mulDiv(b.reinvested,s.usd1,s.unit1) < s.minimumAddedUsd)
            revert InvalidInput();
        bytes[] memory args = new bytes[](2);
        args[0] = mint
            ? abi.encode(key, lower, upper, uint256(liquidity), uint128(a.used), uint128(b.used), s.owner, bytes(""))
            : abi.encode(id, uint256(liquidity), uint128(a.used), uint128(b.used), bytes(""));
        args[1] = abi.encode(key.currency0, key.currency1);
        uint256 pmEth = address(PM).balance;
        PM.modifyLiquidities{value: key.currency0 == address(0) ? a.used : 0}(
            abi.encode(mint ? hex"020d" : hex"000d", args), d.deadline);
        if (address(PM).balance != pmEth || PM.ownerOf(id) != s.owner ||
            PM.getPositionLiquidity(id) != previous + liquidity) revert UnexpectedSettlement();
        _settle(a, d.deadline, s.owner);
        _settle(b, d.deadline, s.owner);
        emit Funded(id, s.owner, liquidity, a.walletUsed, b.walletUsed, a.reinvested, b.reinvested, a.fee, b.fee);
    }
}
