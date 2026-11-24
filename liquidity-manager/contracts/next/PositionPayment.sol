// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {IERC20,SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LiquidityPermitAllowance} from "../LiquidityPermitAllowance.sol";
import {ILMPermit2} from "../LiquidityControllerV2.sol";

library PositionPayment {
    using SafeERC20 for IERC20;
    error InvalidPayment();
    ILMPermit2 private constant PERMIT=ILMPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);
    address private constant PM=0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    function pay(address currency, address to, uint256 amount) internal {
        if (amount == 0) return;
        if (currency == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert InvalidPayment();
        } else {
            uint256 before = IERC20(currency).balanceOf(to);
            IERC20(currency).safeTransfer(to, amount);
            if (IERC20(currency).balanceOf(to) != before + amount) revert InvalidPayment();
        }
    }
    function approveManager(address currency,uint160 amount,uint48 deadline) internal {
        if (currency == address(0)) return;
        if (amount == 0) PERMIT.approve(currency,PM,0,deadline);
        if (!LiquidityPermitAllowance.hasUnlimited(currency)) IERC20(currency).forceApprove(address(PERMIT),amount);
        if (amount != 0) PERMIT.approve(currency,PM,amount,deadline);
    }
}
