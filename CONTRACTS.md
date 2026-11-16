# Current Vault contracts

Chain ID: **4663**. Deployment snapshot block: **115665222**, hash `0x4f3244cdda52530502e3ed0a7e8cd55188cca3e02b4ae2944b3e3e65de3b08a8`.

The source package contains 19 beacon-managed Vault components, two aggregate Range helper components, proxy/installer infrastructure, and the interfaces and libraries needed by those targets. Contract addresses are public identifiers; no operator wallets or credentials are included.

## Components

| Component | Purpose | Entry address | Replacement mechanism |
|---|---|---|---|
| FeeVaultMath | Reference ratios, fee-aware direct-fill calculations and inventory bounds | `0xc1264b8eb2d1211638533f346e1319dece8de42c` | Independent beacon implementation |
| CreateGroupMath | Position-creation matching calculations | `0x5da1f10ac423c7b259107f5fe9e9054db6e19975` | Independent beacon implementation |
| PassiveCrossMath | Cross-quote passive matching calculations | `0x4272a1f86e18589bbd8e662acfa4122ae8ac8563` | Independent beacon implementation |
| SharedPoolReader | Validated external pool-state reads | `0x879b32d0e9b89f3985be0a7772791483d5213f4e` | Independent beacon implementation |
| InternalSettlementPolicy | Internal settlement authorization and module bindings | `0x2f961145206afb25993433feb3dfb9f44e9c48f9` | Independent beacon implementation |
| CachedTokenPricing | Signed source registration and on-chain price contexts | `0xcf4da6edf1e21a252764491f7ac8e583bb1db23b` | Independent beacon implementation |
| FeeAwareGroupedVault | Current-position custody, accounting, creation and direct trades | `0x706c8a48a6c1230a18be9eff2c961dc5b9e3ffaa` | Independent beacon implementation |
| FeeAwareSameExecution | Same-quote execution over eligible liquidity | `0x5f6e818acb51d342141c3d843973fab63668a139` | Independent beacon implementation |
| FeeAwareCrossExecution | Cross-quote execution and quote conversion | `0xe6d329c73d5adcdb15f3bccc330da7c3b5758c12` | Independent beacon implementation |
| SharedCreateModule | Position creation and opposite-inventory matching | `0x87e7b17d98caa2dbdd5a69d6cf3d1e6a7904bb23` | Independent beacon implementation |
| PriceContextQuery | Read-only price-context queries | `0xe13906fcd47fc294a562dc520cc9e10f8cbbfd5d` | Independent beacon implementation |
| FeeAwareMarketLimitManager | Limit/Range custody, aggregate matching, claims and withdrawals | `0x599dd12ecf935f9e1d36ce713dfa6290436a63d8` | Independent beacon implementation |
| MainnetMarketLiquiditySnapshot | Current and aggregate Limit/Range liquidity snapshots | `0x75f7f507a9ef6a4a1a834e2557b33940227ce67d` | Independent beacon implementation |
| AggregateRangeAccounting | Linked aggregate price-level and share accounting | `0x0f90433fc71f7a0b444acb8dd9df00f4f3a0959d` | Redeploy helper and rebind through compatible manager implementation |
| RangeInternalExecution | Range internal settlement execution | `0x8ec62a8f91ee9536a3673f818f4c21b45768f668` | Redeploy helper and rebind through compatible manager implementation |
| CachedTokenSwap | Conversion of collected fee assets | `0x6ce1ffca62bbe284203ccc0849283b430df90b5c` | Independent beacon implementation |
| CachedFeeRoute | Fee conversion route coordination | `0xd42909410f3e3f55c69fddb1a0a82a6e9a899883` | Independent beacon implementation |
| CachedFeeProcessor | Fee attribution, conversion and forwarding | `0x09802c8d32167699c58627d1d544c33a63588e97` | Independent beacon implementation |
| MainnetSharedFeeDistribution | Fee distribution and claim entitlements | `0x619bcb0aaf0ebfeb0205fd0cbd20cac6e0ed4493` | Independent beacon implementation |
| MainnetDeferredBurnBridge | Deferred Burn reserve bridge | `0xc1ea9477bd1c2608021121fefe3319de155801ee` | Independent beacon implementation |
| ProtocolDualGasTreasury | Protocol gas-funding treasury | `0xc046a0c8a7732de12610a03be48683943eb35243` | Independent beacon implementation |

DEPLOYMENT.json records each proxy, beacon, current implementation, code hash and verified bindings. A proxy address is the calling address; an implementation address is not a substitute for it. The separate external-order executor is recorded as an active out-of-scope integration, not as a retired contract.

## Build

Use Node.js 22 or later and npm. From the repository root:

```sh
npm ci --ignore-scripts
npm run build
npm run audit
```

The pinned compiler is Solidity 0.8.30. OpenZeppelin 5.4.0 is installed from npm and is not copied into this repository. package-lock.json pins all package versions and integrity values. build-config.json preserves each compilation unit's optimizer, via-IR and EVM settings. Separate units are necessary because active modules were compiled in different source contexts.

Build output is written to the ignored build directory. It includes ABI, creation/runtime templates, link references, immutable references and storage layout. This command does not connect to an RPC endpoint or deploy anything. Tests are intentionally omitted from the public package; local publication checks are summarized in the verification report.

## Source scope

Only dependencies reachable from the selected targets are retained. Inheritance, types used in external calls, ABI structures, libraries and interfaces can be necessary even when their names are not independent deployed modules. A filename containing mainnet-candidate is an original compiler path, not a claim that the live contract is experimental.

Comments and unused top-level declarations/imports are removed from the public copy. Bodies of retained declarations, constants and constructor behavior are unchanged. Removing files/declarations can alter compiler identifiers and optimizer output. BUILD-VERIFICATION.json distinguishes source correspondence from byte-for-byte template reproduction; it does not disguise different bytes as an exact match. Solidity metadata also changes when source text changes.

## Independent upgrades

Each of the 19 beacon-managed components has its own beacon and can receive a separate compatible implementation. Storage layout, immutable bindings, protocol invariants and cross-module ABI compatibility must still be preserved. Some dependencies pin code identity or bind callers, so a module replacement can require coordinated validation or reconfiguration.

AggregateRangeAccounting is a linked library. RangeInternalExecution is a separate helper bound by the Range manager. Replacing these helpers requires deploying compatible helper code and updating the consuming manager implementation and its bindings. The liquidity snapshot has a separate beacon. The deployed installer is sealed; existing proxy addresses and user state are not recreated by this publication.

## Exclusions

Superseded Limit/Range manager and snapshot deployment targets, earlier aggregate prototypes, one-shot deployment factories, synthetic upgrade fixtures, unused executors, website/admin/operator interfaces, production service configuration, operational scripts and vendored dependencies are not publication targets. Required inherited or type dependencies are retained. The standalone external filler executor and separate Market swap integration are active but outside the requested Vault-only scope.

## Licensing

UserVault-authored material is governed by LICENSE. Installed third-party dependencies retain their own upstream licenses; the proprietary license does not replace their notices or ownership.
