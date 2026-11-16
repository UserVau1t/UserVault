pragma solidity ^0.8.30;
import {ProtocolGasTreasury} from "contracts/mainnet/ProtocolGasTreasury.sol";

contract ProtocolDualGasTreasury is ProtocolGasTreasury {
    address payable public immutable executor;
    uint256 public totalExecutorFunding;
    event ExecutorFunded(uint256 amountETH, uint256 balanceAfter);
    event ExecutorFundingDeferred(uint256 requestedETH);

    constructor(address funds, address administrator, address payable feeKeeper,
        address payable positionExecutor, uint256 below, uint256 target)
        ProtocolGasTreasury(funds, administrator, feeKeeper, below, target) {
        if(positionExecutor == address(0) || positionExecutor == feeKeeper
            || positionExecutor == administrator || positionExecutor == funds
            || positionExecutor == address(this)) revert InvalidConfiguration();
        executor = positionExecutor;
    }

    function refillExecutor() external nonReentrant returns(uint256 amount) {
        if(address(distribution).codehash != distributionHash) revert DistributionChanged();
        uint256 balance = executor.balance;
        if(balance >= refillBelow) return 0;
        uint256 needed = refillTarget - balance;
        if(address(this).balance < needed) {
            uint256 credit = distribution.claimableModuleFee(address(this));
            uint256 missing = needed - address(this).balance;
            if(credit > missing) credit = missing;
            if(credit != 0) {
                uint256 beforeBalance = address(this).balance;
                distribution.claimModuleFee(credit);
                if(address(this).balance != beforeBalance + credit) revert PaymentFailed();
                emit ProjectFundsCollected(credit);
            }
        }
        amount = address(this).balance;
        if(amount > needed) amount = needed;
        if(amount == 0) return 0;
        (bool ok,) = executor.call{value:amount, gas:30000}("");
        if(!ok) { emit ExecutorFundingDeferred(amount); return 0; }
        totalExecutorFunding += amount;
        emit ExecutorFunded(amount, executor.balance);
    }
}
