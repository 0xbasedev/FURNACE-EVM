# FURNACE v5.5 - Decisions made under delegated authority

These are decisions for subsequent implementation, not a menu of optional patches. The v5.4 files are the retained source baseline. This document supersedes contrary wording in prior review proposals, especially the earlier 50/50 user/permanent matching alternative and fresh-age Casting proposal.

## 1. Preserve the established monetary and loyalty profile

Keep FURNACE/EMBER/ASH, Ethereum home, 21M live EMBER ceiling, 21,600/day and365-day half-life/1,000 target floor,420k seed/500k Treasury/zero team, and41k/1k/28k ASH. Keep exact fees, proportional cooling, source-age compounding, user-owned matching,90/10 Genesis LP,25% compatible Casting, and the additive-correct10% Conviction bucket. No reversion to the Tephra fast curve, total age resets, principal-locking lanes, or governance redeemable LP.

## 2. Launch one chain, without changing the home chain

Ethereum gets100% initially. Disable other chains, Fissures, transport channels and the gauge. There is no reason to expose unfinished satellite identities and global accounting at the initial launch. Their definitions remain for a separate audited activation. This is a new staging decision, not the old45/20/15/10/10 activation table.

## 3. Take the user-owned matching choice seriously

Compatible Cast/Stoke LP is100% user-owned; matching quote is a reserve expense. Keep a distinct idle permanent-liquidity lane. Only ordinary-base receipts are matching-eligible. Automatic Cast reservation comes first, optional Stoke from the remainder, both pro-rata per asset/pool/epoch. A receipt can use its reservation once; a wallet transfer cannot impersonate it. Seven-epoch expiry releases unused quote, not earned rewards. No prefunded quote means no match.

An owner can always compound into Capstone without waiting for matching. Automatic selling is removed as the default dry-reserve response. An owner-authorized zap is a separate visible action. This changes the v5.4 `fallback:'zap'` selection to `fallback:'capstone'`.

## 4. Pin every reward category

Automatic Casting applies to post-Conviction ordinary-base rewards from compatible active LP lots only. Single-token positions stay single-token principal positions and receive liquid EMBER. Ashfall, ASH, Quote yield, vested Conviction and the Sealed pot do not also consume the automatic25% subsidy. This resolves the previous denominator ambiguity while preserving the25% parameter and source-lot policy.

## 5. Use a dedicated Kindling/Fissure fee escrow

A3% fee economically earmarked for Treasury is not spendable until successful atomic settlement. The escrow is immutable, event/asset-specific, and cannot approve arbitrary spenders or rescue refund backing. Cancellation remains possible until settlement; fees on cancelled contributions are refunded if the event fails. Failed raises and a72h safe-settlement timeout pay refundable liabilities once. Ignition's separately disclosed nonrefundable3% is not retroactively changed. Treasury fallback is a new funded event, not a redirect of failed-event funds.

## 6. Choose an implementable reward convention

Select ratios of time-integrated stake and Heat measures per daily epoch, with an analytic capped-sqrt antiderivative and1e27 fixed-point scale. That is a new accounting convention; do not describe it as mathematically identical to an integral of instantaneous reward fractions or a terminal snapshot.

Use authoritative onchain checkpoints, deterministic page totals, capped escrow computation, and finalized per-position payout claims. Base budgets accrue only while that pool has active stake; empty time remains unallocated and cannot be awarded retroactively to the first late entrant. Cap pages at32lots. No admin or offchain signer can invent the global denominator. Total work is still population-dependent; benchmark it. User principal exits never wait for epoch settlement; preserve historical liabilities after exit. The complete-cohort reference is a correctness oracle for the port, not the onchain algorithm.

## 7. Keep exits genuinely independent

Direct in-kind principal exit must work without Flow, Vent conversion, oracle freshness, bridge delivery, a rendered NFT, or reward finalization. Freeze only requested slices. Use frozen-reference cumulative cooling plans, preserve earlier matured tickets, and consume the plan quota on cancellation. No new principal lock is introduced. Active Seal accrual pauses while a cooling request is unresolved; the bonus term extends by that interval. Executed early Taps break the unvested Seal bonus even though they preserve Streak.

## 8. Prevent new money inheriting old eligibility

External top-ups do not join an old Seal or inherit30-day actual-participation eligibility from dust in an old Deed. Require active qualifying Streak plus each lot's actual participation. Phantom founder age affects financial Heat only. Source-provenance compounds retain the source cohort, subject to closed-lot and spent-receipt checks.

## 9. Bound fee-processing throughput and keep safety guards binding

Retain0.5% per-call chunk, add0.5% of fixed starting quote reserves per1800s processing window across calls. Retain30m TWAP,2% average band and1% slippage.72h means alert, not permission to weaken those guards. Idle permanent pairing cannot borrow user matching reservations. The provisional cumulative limit is deliberately conservative and must be stress-tested against backlog and pool liquidity before any separate policy revision.

## 10. Make auctions compatible with principal access

Seller mutations require cancelling the listing first. Cancellation is allowed until atomic settlement, with pull-based bid refunds. No bid is advertised as irrevocable before settlement. This avoids an auction-induced principal lock while preserving reserve price,24h discovery and bounded extensions. Rewards go with the Deed, not through an implicit Claim bypass. Buyer delivery callbacks cannot trap seller proceeds.

## 11. Keep Hearth fees local at initial release

OFT compatibility does not aggregate fee assets. The first Hearth distributes its actual Ethereum fee liabilities. Global fee sharing is not enabled or promised. Use checkpointed per-asset indexes to keep historic batches away from new stake. Future satellites need explicit, funded policies.

## 12. Enforce identity without faking deployment readiness

Use stable diagnostic codes and two stages. Economic/template checks allow explicitly missing operators but reject altered economics and incorrect supplied derivations. Deployment checks require real addresses, a3-of-5 Safe, exact registry, collateral bindings and start time. EVM addresses use EIP-55; SVM addresses decode to32bytes. Compare actual supplied salts against CREATE3 predictions. No placeholder is replaced with a made-up signature authority.

The code/config/source/runtime/initialized-state hashes are distinct. Tests are not an audit. Real signers, keys, start time, external pool identity and signed audit reports remain operational facts, not philosophical decisions to guess.

## Source and authority boundary

Retained rules are sourced from the uploaded FURNACE v5.4 config and specification. The decisions above are the assistant's selected resolutions under the user's explicit delegation. Configurations are local files only; no wallet transaction, repository commit, library overwrite or network deployment was performed.

Technical interfaces used for offline checking: official EIP-55, the CreateX project sender-guard/CREATE3 calculation, LayerZero OFT debit-credit semantics, and Solana account-address encoding. These interfaces support verification rules; they do not validate a live deployment's address, code, or authority.
