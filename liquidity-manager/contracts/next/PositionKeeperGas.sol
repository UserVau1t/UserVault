// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import {GasReimbursement} from "./GasReimbursement.sol";

/// Direct Keeper transactions contain exactly one sponsored position action. The EOA
/// requirement excludes nested batches and delegated accounts from charging base gas twice.
contract PositionKeeperGas is GasReimbursement {
    constructor(address target,address signer,address reader,bytes32 readerHash)
        GasReimbursement(target,signer,reader,readerHash) {}

    function _intrinsicUnits(address executor) internal view override returns(uint256) {
        if(tx.origin!=executor || executor.code.length!=0) revert Unauthorized();
        return 21000;
    }
    // Refund counters settle after the transaction. Even at the EIP-3529 maximum
    // refund the position cannot be billed more than the net gas for the transaction.
    function _billableUnits(uint256 measured) internal pure override returns(uint256) {
        return measured*4/5;
    }
    function moduleBinding() external view override returns(bytes32) {
        return keccak256(abi.encode("PositionKeeperGas.storage.v1",controller,reviewer,referenceReader,referenceCodeHash));
    }
}
