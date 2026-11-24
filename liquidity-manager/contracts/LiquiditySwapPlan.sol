// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

bytes32 constant LM_ROUTED_SWAP = keccak256("UserVault.UniswapSplit.v1");
bytes32 constant LM_COMPOUND_ROUTE = keccak256("UserVault.CompoundRoute.v1");
bytes32 constant LM_COMPOUND_QUOTE = keccak256("UserVault.CompoundAutoQuote.v1");
bytes32 constant LM_AUTO_QUOTE = keccak256("UserVault.UniswapAutoSlippage.v1");
// The low bits retain the separately configured limit for standalone compounding.
uint16 constant LM_AUTO_REBALANCE = 1 << 15;
struct LMAutoTerms {uint16 bps; uint256 tokenId; uint64 nonce; uint128 minimum; uint64 until;}
// Local route encoding for a V4 hop that settles the exact input before swap.
uint8 constant LM_V4_PREPAID = 0x84;

/// Amounts are finalized by the funding quoter after the old position is withdrawn.
struct LMFundingFill { uint128 amount; bytes path; }
