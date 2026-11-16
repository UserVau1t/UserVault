# Filler API

The public endpoint is **https://uservault.fun/api/v1/fillers**. It requires no API key or filler registration. The API reads liquidity and prepares simulated transactions. Each independent filler supplies its own input assets and submits transactions through its own wallet or execution contract.

The API never receives signing keys, signs transactions, broadcasts transactions or grants access to position owners' wallets. This directory contains the HTTP API description, a small client and current Vault ABIs. Server code, operational configuration and tests are not included.

## Endpoints

| Method | Path | Result |
|---|---|---|
| GET | `/api/v1/fillers` | Network, public contract addresses and integration capabilities |
| GET | `/api/v1/fillers/openapi.json` | OpenAPI 3.1 description |
| GET | `/api/v1/fillers/liquidity?baseToken=...&quote=...&side=BUY` | Opposite-side Current Vault inventory at an identified block |
| POST | `/api/v1/fillers/quote` | Simulated fill, minimum output, refund, allowance requirements and unsigned transaction calldata |

[OpenAPI schema](openapi.json) · [JavaScript client](client.mjs) · [Contract ABIs](abi)

`side` is the filler action: `BUY` consumes deposited SELL inventory, and `SELL` consumes deposited BUY inventory. `quote` is the zero address for native ETH or the supported USDG contract returned by metadata. Amounts are decimal **strings in raw token units**, not human-readable token quantities or JavaScript floating-point numbers.

## Integration sequence

1. Read metadata and verify chain ID `4663` and the intended Vault contract.
2. Read liquidity for the base token, quote asset and action. The returned inventory is a snapshot, not a reservation.
3. Fund the actual calling address. For ERC-20 input, that address must approve the Vault before the quote can simulate successfully. For native ETH input, it needs the input amount and gas funding. Do not send an approval transaction without checking the token, spender and amount.
4. Request a quote with the calling address as `taker` and the intended receiver as `recipient`.
5. Check the destination, calldata, ETH value, input/output amounts, minimum fill and minimum output. The returned calldata includes the price-source proof wrapper; do not remove it.
6. Re-simulate the exact transaction using the filler's own RPC provider and estimate gas immediately before submission. Obtain a new quote if it expires or state changes.
7. Submit through the filler's own signer. Reconcile the receipt and nonce before retrying an uncertain submission.

The existing quote endpoint performs two simulations at the same canonical block: the initial fill and the final transaction containing the slippage-adjusted minimum output. It does not reserve inventory or guarantee execution in a later block.

## Quote request

```json
{
  "baseToken": "<BASE_TOKEN_CONTRACT>",
  "quote": "0x0000000000000000000000000000000000000000",
  "side": "BUY",
  "taker": "<CALLING_FILLER_ADDRESS>",
  "recipient": "<OUTPUT_RECIPIENT>",
  "maxGrossInput": "10000000000000000",
  "minGrossInputFilled": "1",
  "slippageBps": 50
}
```

Replace the angle-bracket placeholders. Extra request fields are rejected. `slippageBps` is an integer from 0 to 1000; `50` means 0.5%. `minGrossInputFilled` is the smallest acceptable filled input, in raw units. Use the full input amount when a partial fill is unacceptable.

The response includes `grossInputUsed`, `netOutput`, `inputRefund`, `minNetOutput`, `deadline`, an identified `block`, `approval`, and `transaction`. The transaction contains `from`, `to`, `value`, `data` and `chainId`. It does not include a signature. Its deadline is short-lived, normally bounded to 30 seconds by the current implementation and further limited by source validity.

For a contract-based filler, `taker` must be the contract that will call the Vault. Embed the returned calldata and ETH value in that contract's execution. Setting a transaction's `from` field to another address does not authorize spending that address's funds.

## JavaScript

Node.js 22 or later is recommended. The HTTP client itself has no external dependencies.

```js
import {createFillerClient} from './api/client.mjs';

const api = createFillerClient();
const metadata = await api.metadata();
const liquidity = await api.liquidity({
  baseToken,
  quote: metadata.supportedQuotes[0],
  side: 'BUY'
});

const quote = await api.quote({
  baseToken,
  quote: metadata.supportedQuotes[0],
  side: 'BUY',
  taker,
  recipient: taker,
  maxGrossInput: '10000000000000000',
  minGrossInputFilled: '1',
  slippageBps: 50
});
```

The client does not sign or broadcast transactions. Supply asset and caller addresses locally.

## Current coverage

Version 1 quotes **same-quote direct Current Vault trades** in token/ETH and token/USDG. It does not aggregate Limit/Range liquidity through the pro-rata coordinator, perform cross-quote conversion, automatically send an unfilled remainder to an AMM, or wrap WETH for the caller. Its liquidity endpoint reports Current inventory, not every position type in the protocol.

The on-chain ABIs for the broader snapshot, same-quote/cross-quote coordinators and the Limit/Range manager are included separately. Advanced integrations can use those interfaces after implementing their own route construction, price-context handling, funding and simulation. A UniswapX order is not a valid input to this HTTP quote endpoint; the external executor has its own `fill(order, plan)` interface.

## Errors and availability

- `400`: invalid fields, market, address, amount or slippage.
- `422`: simulation rejected; check caller balance, allowance, minimum fill and contract state.
- `503`: temporary source, RPC, canonical-state or capacity unavailability.

Use bounded retries with backoff for read requests. The client does not automatically retry or submit transactions. A fresh request may return different inventory or prices. API availability does not imply guaranteed liquidity or priority execution.

