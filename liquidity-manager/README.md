# Liquidity Manager contracts

Liquidity Manager manages owner-held Uniswap v4 position NFTs on Robinhood Chain (chain ID 4663). The owner authorizes a fee strategy and optional range management for each NFT. An administrator can update a bound module at its existing proxy address without a timelock.

[Workflow, diagram and fee schedule](../README.md#liquidity-manager) · [User guide](https://uservault.fun/docs#liquidity-manager)

## Contract map

| Contract | Responsibility |
| --- | --- |
| [PositionDeployment](contracts/next/PositionDeployment.sol) | Creates the observer and module proxies. Receives protocol fees. |
| [PositionModuleProxy](contracts/next/PositionModuleProxy.sol) | Preserves module state and verifies implementation identity during upgrades. |
| [PositionObserver](contracts/next/PositionObserver.sol) | Tracks NFT subscription generations used to validate the owner's mandate. |
| [PositionStrategyController](contracts/next/PositionStrategyController.sol) | Stores the authorized strategy and validates each automation request. Carries strategy settings to a replacement NFT. |
| [PositionRangeFunding](contracts/next/PositionRangeFunding.sol) | Handles deposits, NFT enrollment, liquidity additions and routing to the range module. |
| [PositionRangeExecution](contracts/next/PositionRangeExecution.sol) | Closes the old NFT, settles fees and mints the replacement to its owner. |
| [PositionPayoutHandler](contracts/next/PositionPayoutHandler.sol) | Settles standalone automatic fee claims and distributes the net proceeds. |
| [PositionKeeperGas](contracts/next/PositionKeeperGas.sol) | Measures billable gas and reimburses successful work within the position's limits. |

The Solidity tree includes the first-party imports required to build these eight contracts. Earlier controller types supply shared interfaces. The deployed modules also call the chain's Uniswap contracts and existing reference-price and swap gateways.

### Public module addresses

| Role | Robinhood Chain address |
| --- | --- |
| Strategy controller proxy | `0x4e5c005f90d99eee5298032a248361bf58891957` |
| Funding proxy | `0xc097b53859b4e9173aeed23571d69ca410dbe05b` |
| Range execution proxy | `0xd5eaa42ee06245effe3e254430c36957f05d3997` |
| Gas reimbursement proxy | `0x6053e2bb6f7e25f206d88015912504beb0ce81fe` |

Read `moduleImplementation()` on a proxy to find its current implementation.

## Verify the release build

From the repository root, using Node.js 22 or later, run:

```sh
npm ci --ignore-scripts
node liquidity-manager/verify.mjs
```

The verifier uses the repository's locked Solidity 0.8.30 compiler and OpenZeppelin 5.4.0. It reads nine Uniswap source files from pinned upstream revisions, verifies every compiler input by SHA-256 and restores the release's line endings. It compiles each entry for Cancun with the IR pipeline. Optimizer runs and artifact hashes are recorded in [build.json](build.json).

The comparison covers creation bytecode and the compiled runtime template before constructor immutables are filled. Seven entries reproduce both release artifacts byte for byte. For the retained funding implementation, the verifier checks both artifacts after substituting the original Solidity metadata footer. That exception is specific to `PositionRangeFunding`. It leaves every executable instruction subject to the comparison.
