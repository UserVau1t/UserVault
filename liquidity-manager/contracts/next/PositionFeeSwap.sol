// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LMPoolKey} from "../LiquidityControllerV2.sol";

interface IPositionSwapGateway {
    function swapPosition(LMPoolKey calldata source, bool forward, uint128 amount, uint128 minimum,
        bytes calldata route, uint256 deadline) external payable;
}

/// Uses the public exact-input swap entry on the immutable Robinhood V4.1 gateway.
/// The gateway constructs the Universal Router commands and always pays its caller.
library PositionFeeSwap {
    using SafeERC20 for IERC20;
    address internal constant GATEWAY = address(uint160(0x00dd29f8b5aea76aca1754c91743646f92c0d84b36));
    bytes32 internal constant GATEWAY_HASH = 0xb45183659d87912cc6b197ca23ed479e8e065c3b9680c02e9a164297728a2e6a;
    struct Branch {uint128 input; bytes path;}
    struct Quote {uint128 input; uint128 minimumOut; Branch[] branches;}
    error InvalidSwap();

    function balance(address token) internal view returns (uint256) {
        return token == address(0) ? address(this).balance : IERC20(token).balanceOf(address(this));
    }
    function execute(LMPoolKey memory pair, bool forward, Quote memory q, uint256 available, uint48 deadline)
        internal returns (uint256 output)
    {
        if (q.input == 0 || q.input > available || q.minimumOut == 0 || q.branches.length == 0 ||
            q.branches.length > 16 || GATEWAY.codehash != GATEWAY_HASH) revert InvalidSwap();
        address inputToken = forward ? pair.currency0 : pair.currency1;
        address outputToken = forward ? pair.currency1 : pair.currency0;
        if (inputToken == outputToken) revert InvalidSwap();
        uint256 beforeIn = balance(inputToken);
        uint256 beforeOut = balance(outputToken);
        if (inputToken != address(0)) IERC20(inputToken).forceApprove(GATEWAY, q.input);
        uint256 remaining = q.input;
        for (uint256 i; i < q.branches.length; ++i) {
            Branch memory branch = q.branches[i];
            if (branch.input == 0 || branch.input > remaining) revert InvalidSwap();
            remaining -= branch.input;
            IPositionSwapGateway(GATEWAY).swapPosition{value: inputToken == address(0) ? branch.input : 0}(
                pair, forward, branch.input, 1, branch.path, deadline);
        }
        if (inputToken != address(0)) IERC20(inputToken).forceApprove(GATEWAY, 0);
        output = balance(outputToken) - beforeOut;
        if (remaining != 0 || beforeIn - balance(inputToken) != q.input || output < q.minimumOut) revert InvalidSwap();
    }
}
