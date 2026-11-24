// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

library LiquidityDepositFee {
    // Largest amount n such that n + floor(n / 100) fits in the earned balance.
    function reinvestBudget(uint256 earned) internal pure returns(uint256) {
        return earned-earned/101-(earned%101==100?1:0);
    }
    /// The gross payment includes the fee. A raw-unit rounding remainder stays with the depositor.
    function fromPrincipal(uint256 principal,uint256 grossCap) internal pure returns(uint256) {
        uint256 room=grossCap-principal;
        uint256 fee=principal/99;
        return fee<room?fee:room;
    }
}
