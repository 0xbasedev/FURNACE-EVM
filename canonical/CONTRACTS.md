# FURNACE v5.5 - Contract implementation map

This package supplies TypeScript config, validators and accounting references. It does not supply these production Solidity/Anchor modules.

| Module | Selected responsibility | Non-negotiable boundary |
|---|---|---|
| Mantle | Global accounted issuance, reserved budgets, epoch authorization | Transport never creates economic headroom; no arbitrary recipient mint |
| EmberToken / AshToken | Local balances and later authenticated OFT transport | Satellite transport authority is not economic mint discretion |
| Burn-credit registry (Mantle subsystem) | Unique authenticated economic burns and consumed-credit counters | Exclude transport and LP redemption; no duplicate categories |
| Forge | Receipt custody,32 source lots, Streak, cooling plans, reward checkpoints, Seals | Principal exits never depend on an oracle, swap, bridge or reward pass |
| GenesisFeeEscrow | Kindling/Fissure principal and fee liabilities | No Treasury spending of live refund backing; mutually exclusive success/failure |
| Ignition | Bootstrap positions and41k ASH allocation | No fictitious LP identity; no reuse of withdrawn balance-time |
| Kindling | Safe aggregate pool initialization,90/10 LP split, lazy position entitlements | No all-user finalization loop or Treasury redirect after failure |
| BlastPool / SmelterPool | Separate full-range CPMM receipts | Explicit collateral identity for each pool |
| FeeRouter (Vent) | Fee liabilities, protected conversion, window throughput, match reservations | No issuance authority; no public arbitrary recipient/route |
| Hearth | Funded local fee-asset indexes for staked ASH | No implicit cross-chain fee promise; no new fee claim against old batches |
| Relics | Wallet history and activity-derived perks | Metadata never supplies financial age or active eligibility |
| Deeds | Auction and receipt ownership transition via Forge | No reward Claim bypass; no double settlement/callback withdrawal |
| Flow | Authenticated swaps and optional owner-authorized zaps | Waivers are action capabilities, never user-provided flags |
| TreasuryVesting | Cumulative exact allocation release | No rounded daily overissue or anticipatory spend |
| Timelock | Delayed authorized parameter/periphery changes | No core upgrade, balance seizure, fee-liability redirect or exit pause |

## Epoch implementation chosen

1. Actions checkpoint pool occupied-time accrual, affected lots and owner-dependent bonus segments. Empty-time budget is retained, not retroactively credited to the first later deposit. Historic checkpoint records remain authoritative after closure or transfer.
2. Each pool epoch freezes the eligibility interval and authorized budget. A deterministic indexed cursor visits at most32lots per call, summing integrated stake/ordinary/Seal measures. Duplicate pages cannot count twice.
3. A bounded position pass determines each candidate/capped escrow and sums the unused bucket. No offchain reporter supplies these totals.
4. Once final totals exist, claim/Compound/Cast executes against the position's unspent receipt. Ordinary payouts use final Heat budget; the cap used pre-return Heat budget. State transitions record rounding liabilities.
5. Cooling or exiting principal before settlement archives a beneficiary/reward claim; it does not require finishing steps2-4. A failed computation cannot hold principal hostage.

The reference allocator is not the gas-scalable production pass implementation. Test onchain against it with different page boundaries, empty epochs, late claims, ownership changes, partial cooling, epoch skips and concurrent asset failures. Implementing a bounded call count does not eliminate the total O(population) workload; require liveness and gas evidence.

## Integer domains and payout order

Money uses native smallest units. Rates use integer ppm/bps (half-bps swap components require ppm or exact rational handling). Heat uses1e27scale, time seconds. Solidity/Anchor ports need checked bounds and full-width multiplication/division; JavaScript BigInt does not model VM overflow.

Capstone/Pyre ordinary boosts require checkpointed valuation/ownership changes. Ashfall Heat-squared measures use the separately supplied canonical antiderivative; squaring an epoch's average Heat is not equivalent. The Solidity/Anchor port and full-width arithmetic analysis are not included. Confirm quote-asset funded liabilities, credit expiry and integer dust before any external transfer.

## Principal and markets

Use checks-effects-interactions and a single receipt-consumption authority across Claim, Stoke, Casting, liquidation-like emergency routes and Deed settlement. Listing prevents seller mutations until cancellation, but cancellation remains callable before settlement and refunds are pull-based. Onchain delivery can go to a safe buyer claim record if a receiver callback fails. Test smart-wallet beneficiaries and nonstandard token rejection.

## Deployment model

The new null registry entries expose missing module identities rather than pretend an old9-entry list deploys the whole protocol. Constructors may take arguments; whatever initializer is required executes atomically under authenticated authority. Safe prediction is a separate factory-specific computation. Verify runtime hashes, owners, thresholds, initializer storage, token authorities and peer libraries against signed release artifacts. No private key files belong in this bundle.
