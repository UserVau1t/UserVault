// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library LiquidityPermitAllowance {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Some tokens permanently grant Permit2 a maximum allowance and reject finite
    // approvals, including zero. The caller still sets the spender's cap in Permit2.
    function hasUnlimited(address currency) internal view returns (bool) {
        return IERC20(currency).allowance(address(this), PERMIT2) == type(uint256).max;
    }
}
