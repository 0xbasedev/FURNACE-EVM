# ADR 0025: The Hearth, where staked ASH earns the Vent's fee share

Status: accepted for this repository. Not audited, not deployed.

## Context

**The Vent's `HEARTH`** (ADR 0020) receives 10% of the standard Forge fees, owed in kind. It is pushed by the permissionless `release(Hearth, token)`.
- The fees come as EMBER and as each pair's quote asset. LP fees are unwound at once; the single-asset pools pay in EMBER and USDC.
- Until now the kit's operator wallet stood in for the Hearth. Its mainnet address is mined (`0xEA27…`), and the gate's `Hearth` slot was unbuilt.

**What the spec fixes:**
- **§15:** "Hearth distributes only realized, funded fee-asset liabilities to staked ASH."
  - It uses a global per-asset reward index with checkpointed stake changes, "so a new staker cannot capture an old batch".
  - "The 24h ASH exit cooldown is retained."
  - Fees are chain-local: "global fee aggregation is not inferred from OFT transport".
- **`CONTRACTS.md`:** "Funded local fee-asset indexes for staked ASH. No implicit cross-chain fee promise; no new fee claim against old batches."
- **DECISIONS §11:** keep Hearth fees local at the initial release.
- **Config `execution.hearth`:** `feeScope: chainLocalFundedLiabilities` and `crossChainFeeAggregation: false`.
- **§20:** governance stays the Safe through the 48 h timelock. No tokenholder voting interface is represented as controlling contracts.

## Decision

**1. `contracts/src/hearth/Hearth.sol`.** It has no admin, pause or upgrade.
- **Immutables:**
  - `ASH`;
  - `TREASURY`;
  - one to four fee assets, fixed at construction: distinct, nonzero, and never ASH.
- **The kit's fee assets** are EMBER, tUSDC (BlastPool's quote) and tWETH (SmelterPool's). These are the assets the Vent owes the Hearth in kind.

**2. Funded fees only, by a per-asset index.**
- `book(asset)` takes what the Hearth holds of an asset beyond its `liability`, the booked and unpaid amount. That is the realized batch.
- It adds the batch to `liability` and moves `indexOf[asset]` by `floor(batch · 1e36 / totalStaked)`.
- A wallet's accrual since its last checkpoint is `floor(stake · (index − paid) / 1e36)`. Only booked fees can be paid. A donation is booked like any batch, so it can only reach stakers.

**3. No new stake against an old batch.**
- `stake`, `requestExit` and `cancelExit` book every fee asset before the stake changes. They then checkpoint the wallet at the old stake. `claim` and `claimAll` book first too.
- So a batch that has arrived always goes to the stake that was there when it arrived. A newcomer's stake never meets an unbooked balance.

**4. The ASH exit cooldown.**
- `requestExit(amount)` takes ASH out of `totalStaked` at once, so it earns nothing from then on. It unlocks `HEARTH_EXIT_COOLDOWN` (24 h, spec §15) later.
- Once unlocked, `withdraw()` returns it to its owner. That needs nobody's approval, and nothing can pause it.

**5. Provisional readings [P].** Each was taken as recommended, per the owner's standing rule. Each is a deploy blocker until confirmed, and listed in [PROVISIONAL.md](../PROVISIONAL.md).
- **[P] A batch booked while nothing is staked is owed to the Treasury.** Anyone may release it with `releaseToTreasury(asset)`. It had no stakeholder when it was realized, and the first staker after it must not capture it.
- **[P] A wallet has one pending exit.** A second request adds to it and restarts the 24 h clock for the whole amount.
- **[P] A pending exit can be cancelled back into stake** at any time until it is withdrawn. It earns again from the cancel, not for its time in the cooldown.
- **[P] The fee assets are fixed at deployment.** Anything else sent to the Hearth, ASH included, stays there: there is no rescue path to abuse.
- **[P] Claims pay the staker that calls,** for any asset or all of them. Unclaimed fees never expire.

**6. Not built.**
- **Governance weight and the Relic multipliers** (2× at Eternal Flame, 3× at Bedrock, from v5.4). §20 builds no tokenholder voting.
- **Satellite Hearths.** Each needs its own funded local policy before it admits stake.

**7. The kit.**
- The Hearth deploys at a CREATE3 address in every mode, and the Vent's `HEARTH` names it. The wiring check requires its ASH, Treasury and three assets.
- The smoke run stakes 1,000 of the operator's test ASH. The operator stands in for Ignition and for the Treasury.

## Size and gas

- **Size:** 6,311 runtime bytes.
- **Gas** (isolated):

  | Call | Gas |
  |---|---|
  | `stake` (books three assets) | 299,380 |
  | `book` | 43,665 |
  | `claim` | 102,971 |
  | `requestExit` | 113,126 |
  | `withdraw` | 40,470 |

## Verification

- **Model.** `scripts/hearth-model.ts` (BigInt) has 9 scenarios:
  - an old batch against a new staker;
  - zero-stake batches going to the Treasury;
  - exits, cancels and the cooldown;
  - 6 decimals beside 18;
  - ASH as a non-asset;
  - four seeded walks.
  - **The replay.** `Hearth.t.sol` replays each exactly on mock EMBER, 6-decimal USDC, WETH and ASH. It checks every output, every revert selector and an 83-word state hash after every step.
  - **The model** restores its state on a revert, as the EVM does. It also checks after every step that each asset is funded, that nothing is promised past what was booked, and that ASH is backed.
- **Unit and fuzz tests:**
  - a newcomer captures nothing from a batch that arrived before it (fuzzed);
  - a zero-stake batch is the Treasury's, and the first staker takes none of it;
  - exiting ASH earns nothing and unlocks exactly at the cooldown;
  - a cancelled exit earns again from its cancel;
  - claims never pass what was booked, short only by the floors (fuzzed);
  - the constructor refuses zero, duplicate, too many and ASH assets;
  - a fee-on-transfer ASH is refused;
  - `pending` shows what a stake change settled, and the claim pays exactly that.
- **Invariants** (`HearthInvariant.t.sol`, 3, 128 runs × 64 calls):
  - every asset's balance covers its liability, and stakers' pending fees plus the Treasury's never exceed it;
  - ASH held equals stake plus exits, and the totals are the wallets' sums;
  - every exit unlocks within 24 h of its last request.
  - **The handler also asserts** that a fresh stake captures nothing, and that every matured exit pays in full.
  - **Coverage:** claims in every run (1,068 in all), matured withdrawals in 59 runs, and 266 fresh stakes.
- **Mutations:** 41 planted bugs, run in separate worktrees:
  - every booking rule: the zero and unknown-asset refusals, the liability, the Treasury branch, the index's rounding, and what counts as unbooked;
  - the booking before every claim and stake change, and every checkpoint;
  - the exit's amount, clock, cooldown and totals, cancels, and every withdrawal gate;
  - every payment's zeroing and liability, and the Treasury release;
  - the constructor's refusals, the `pending` view, and the kit's wiring and smoke stake.
  - **40 were caught.** The 41st, dropping what a wallet has already settled from `pending`, survived: no test read the view after a stake change had settled fees. `test_pendingShowsWhatAStakeChangeSettled` now does, and fails against the mutant.
- **Kit.**
  - The first-epoch test has the Vent release its Hearth EMBER to the real Hearth. The staker claims it, to the wei, and nothing goes to the Treasury.
  - **LiteForge fork dry runs, smoke on:**
    - 62 transactions and 104.4M gas by default;
    - 40 and 105.2M with the real Kindling;
    - 42 and 112.1M with Ignition.
    - The largest transaction is 12.54M.

## Consequences

- **The Vent's last unbuilt recipient is built:** every fee share now has a contract that pays it.
- **The mainnet gate's `Hearth` slot reads built.** The blockers stay at 31: the record still has no addresses.
- **What remains of the seal's finish line:**
  - the match reserve and the compounder;
  - the valuation source and Relics;
  - the Deeds market;
  - TreasuryVesting and Timelock;
  - v1.0.
