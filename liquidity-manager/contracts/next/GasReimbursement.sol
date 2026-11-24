// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LMPoolKey} from "../LiquidityControllerV2.sol";
import {PositionFeeSwap} from "./PositionFeeSwap.sol";

interface IReviewedGasReference {
    function rebalanceTickForRoute(LMPoolKey calldata key, bytes calldata proof, bytes calldata path) external view returns (int24);
}
interface IReimbursedPositionAction {
    /// Only the reimbursement module may call this function. The controller must authenticate the
    /// owner mandate, allowed token, action and executor; fund the reserve only from this NFT.
    function executeReserved(bytes32 operation, address currency, uint256 reserve, bytes calldata action) external;
}

/// Settlement module with no allowance on wallets/NFTs. The controller owns per-NFT budgets.
/// Measures the action around a single callback. Reverted actions cannot collect compensation.
contract GasReimbursement {
    using SafeERC20 for IERC20;
    address private constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    bytes32 private constant QUOTE_TYPE = keccak256("UserVault.PositionGasQuote.v1");
    address public immutable controller;
    address public immutable reviewer;
    IReviewedGasReference public immutable referenceReader;
    bytes32 public immutable referenceCodeHash;
    mapping(bytes32 operation => bool) public settled;
    bool private entered;

    struct Limits {
        uint128 maximumWei;
        uint128 remainingWei;
        uint96 gasPriceCap;
        uint32 gasUnitsCap;
        uint128 maximumTokenAmount;
        uint16 maxSaleLossBps;
    }
    struct SaleQuote {
        uint128 input;
        uint128 minimumWeiOut;
        uint48 validUntil;
        bytes signature;
        bytes marketProof;
        bytes marketRoute;
    }
    struct Ticket {
        bytes32 operation;
        address currency;
        address executor;
        address owner;
        Limits limits;
    }
    error Unauthorized();
    error InvalidQuote();
    error BudgetExceeded();
    error SettlementFailed();
    event GasReimbursed(bytes32 indexed operation, address indexed executor, address indexed currency,
        uint256 measuredUnits, uint256 reimbursedWei, uint256 paidRaw, uint256 returnedRaw);

    constructor(address controller_, address reviewer_, address referenceReader_, bytes32 expectedReferenceHash) {
        if (block.chainid != 4663 || controller_ == address(0) || reviewer_ == address(0) ||
            referenceReader_.code.length == 0 || referenceReader_.codehash != expectedReferenceHash) revert Unauthorized();
        controller = controller_;
        reviewer = reviewer_;
        referenceReader = IReviewedGasReference(referenceReader_);
        referenceCodeHash = expectedReferenceHash;
    }
    receive() external payable {}

    function moduleBinding() external view virtual returns(bytes32) {
        return keccak256(abi.encode("GasReimbursement.storage.v1",controller,reviewer,referenceReader,referenceCodeHash));
    }

    function quoteDigest(Ticket calldata ticket, bytes32 actionHash, SaleQuote calldata sale) public view returns (bytes32) {
        return keccak256(abi.encode(QUOTE_TYPE, block.chainid, address(this), controller, ticket,
            actionHash, sale.input, sale.minimumWeiOut, sale.validUntil, keccak256(sale.marketProof), keccak256(sale.marketRoute)));
    }

    // sqrt(token raw / wei) * 2^96, identical scale for tokens with 6, 8 or 18 decimals.
    function tokenForWei(uint256 weiAmount, uint160 sqrtPriceX96) public pure returns (uint256) {
        if (sqrtPriceX96 <= type(uint128).max)
            return FullMath.mulDiv(weiAmount, uint256(sqrtPriceX96) * sqrtPriceX96, 1 << 192);
        return FullMath.mulDiv(weiAmount, FullMath.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64), 1 << 128);
    }

    function _rate(Ticket calldata t, SaleQuote calldata q, bytes32 actionHash) private view returns (uint160 rate) {
        if (t.currency == address(0) || t.currency == WETH) return uint160(1 << 96);
        if (t.limits.maxSaleLossBps >= 10000 || q.input == 0 || q.minimumWeiOut == 0 ||
            q.validUntil < block.timestamp || q.validUntil > block.timestamp + 90 ||
            address(referenceReader).codehash != referenceCodeHash || t.executor == reviewer) revert InvalidQuote();
        if (ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(quoteDigest(t, actionHash, q)), q.signature) != reviewer)
            revert InvalidQuote();
        // Reference attests the selected external ETH/token path. No registry entry for the
        // token in the user's vault and no trade in the NFT's own pool are required.
        LMPoolKey memory gasPair = LMPoolKey(address(0), t.currency, 0, 1, address(0));
        int24 tick = referenceReader.rebalanceTickForRoute(gasPair, q.marketProof, q.marketRoute);
        rate = TickMath.getSqrtPriceAtTick(tick);
        // Include one reference tick of quantization. A large loss in an executable sale
        // makes the token ineligible; it must not inflate the user's token reimbursement.
        uint160 upper = tick == TickMath.MAX_TICK ? rate : TickMath.getSqrtPriceAtTick(tick + 1);
        if (tokenForWei(q.minimumWeiOut, upper) <
            FullMath.mulDivRoundingUp(q.input, 10000 - t.limits.maxSaleLossBps, 10000)) revert InvalidQuote();
    }
    function _tokens(uint256 cost, uint160 rate, SaleQuote calldata q, bool nativeValue) private pure returns (uint256) {
        uint256 atReference = tokenForWei(cost, rate);
        if (nativeValue) return atReference;
        uint256 atSale = FullMath.mulDiv(cost, q.input, q.minimumWeiOut);
        return atReference < atSale ? atReference : atSale;
    }
    function _pay(address currency, address recipient, uint256 amount) private {
        if (amount == 0) return;
        if (currency == address(0)) {
            (bool ok,) = recipient.call{value:amount}("");
            if (!ok) revert SettlementFailed();
        } else {
            IERC20 token = IERC20(currency);
            uint256 before = token.balanceOf(recipient);
            token.safeTransfer(recipient, amount);
            if (token.balanceOf(recipient) != before + amount) revert SettlementFailed();
        }
    }

    /// Caller debits returned chargedWei from its mandate budget in this same transaction.
    /// Direct Keeper modules may include intrinsic units. The executor cannot supply gasUsed.
    function execute(Ticket calldata t, SaleQuote calldata q, bytes calldata action)
        external returns (uint256 chargedWei, uint256 tokenPaid)
    {
        uint256 start = gasleft();
        uint256 intrinsic = _intrinsicUnits(t.executor);
        if (msg.sender != controller || entered || settled[t.operation] || t.operation == bytes32(0) ||
            t.executor == address(0) || t.executor == address(this) || t.owner == address(0) || t.owner == address(this))
            revert Unauthorized();
        if (tx.gasprice == 0 || tx.gasprice > t.limits.gasPriceCap || t.limits.gasUnitsCap == 0) revert BudgetExceeded();
        entered = true;
        settled[t.operation] = true;
        uint160 rate = _rate(t, q, keccak256(action));
        uint256 cap = uint256(t.limits.gasUnitsCap) * tx.gasprice;
        if (cap > t.limits.maximumWei) cap = t.limits.maximumWei;
        if (cap > t.limits.remainingWei) cap = t.limits.remainingWei;
        bool nativeValue = t.currency == address(0) || t.currency == WETH;
        uint256 reserve = _tokens(cap, rate, q, nativeValue);
        if (reserve == 0 || reserve > t.limits.maximumTokenAmount || (!nativeValue && reserve > q.input)) revert BudgetExceeded();
        uint256 baseline = PositionFeeSwap.balance(t.currency);
        if (intrinsic == 0) start = gasleft();
        IReimbursedPositionAction(controller).executeReserved(t.operation, t.currency, reserve, action);
        uint256 units = start - gasleft() + intrinsic;
        // The operator bears any execution over its approved ceilings and costs outside the callback.
        chargedWei = _billableUnits(units) * tx.gasprice;
        if (chargedWei > cap) chargedWei = cap;
        tokenPaid = _tokens(chargedWei, rate, q, nativeValue);
        if (tokenPaid == 0 || PositionFeeSwap.balance(t.currency) != baseline + reserve) revert SettlementFailed();
        _pay(t.currency, t.executor, tokenPaid);
        _pay(t.currency, t.owner, reserve - tokenPaid);
        if (PositionFeeSwap.balance(t.currency) != baseline) revert SettlementFailed();
        emit GasReimbursed(t.operation, t.executor, t.currency, units, chargedWei, tokenPaid, reserve - tokenPaid);
        entered = false;
    }
    function _intrinsicUnits(address) internal view virtual returns(uint256) {return 0;}
    function _billableUnits(uint256 measured) internal pure virtual returns(uint256) {return measured;}
}
