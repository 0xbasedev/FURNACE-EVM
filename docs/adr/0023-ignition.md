# ADR 0023: Ignition, the genesis farm, First Flame and the head start

Status: accepted for this repository. Not audited, not deployed.

## Context

**What the spec requires** (v5.5 §2, §3; `CONTRACTS.md` "Ignition"; the config's `ignition`):
- **The farm.**
  - It runs 120 hours (bounds 48 h to 14 days).
  - Its pools are USDC, WETH, WBTC and the WETH/USDC LP, weighted 100/100/100/150.
  - It pays ASH's 41,000 Ignition leaf "per second pro rata", with no vesting.
  - The LP stays unset until it is verified, and WETH never stands in for it.
- **The fee.** Deposits pay 3% "straight to the treasury, no splits", never refunded.
- **Withdrawals.** "Nothing is ever locked": principal may leave at any time during the window. Withdrawn principal stops earning, and a return deposit is new.
- **The early bird.** Reward weight "decays from +10% at the first second to +0% at close", linearly, "on top of the per-second pro-rata" (`ignitionWeight`).
- **The close.** "USDC auto-stakes into Cold Storage (unless the depositor opted out at deposit); WETH, WBTC and WETH/USDC LP become claimable fee-free." A 24-hour exit window with a 0% exit fee follows.
- **First Flame.** The founder badge is a wallet's, worth 15 days of phantom age (ADR 0018).
- **The head start.** It is "age dated to Ignition start" and applies to "the first Forge Deed the depositor opens or funds within 7 days of Kindling close, up to the USD value they kept in Ignition through close" (ADR 0019).

**What exists.**
- Every pool names an immutable `IGNITION`, the head start's only granter (ADR 0019), and `FOUNDERS`, the First Flame record (ADR 0018).
- The ASH ledger names `IGNITION` and releases the 41,000 to it once (ADR 0022).
- Kindling records `closedAt` (ADR 0021).
- BlastPool keeps a TWAP (ADR 0015).

## Decision

**1. One immutable contract, `contracts/src/ignition/Ignition.sol`.**
- It is the farm, every pool's `FOUNDERS` and every pool's `IGNITION`.
- It has no admin, pause or upgrade.
- Its constructor stores addresses only, so the ledger, the pools, BlastPool and Kindling can deploy at predicted addresses.

**2. The farm.**
- **Budgets.** Each bound pool's share is `41,000 · w / Σw` over the bound pools.
  - A pool releases `floor(budget · elapsed / 120 h)` cumulatively, the same shape as ASH's `V(t)`, never anticipated.
  - Units are never added across assets: each pool has its own accumulator.
- **Deposits** run in `[START, END)`.
  - 3% of the gross goes to the Treasury in the same call, floored. A deposit whose fee would floor to zero is refused (`BelowMinimum`), so splitting a deposit cannot dodge the fee.
  - The net becomes a lot at the second's entry weight, `1e6 + 1e5 · (END − t) / 120 h` ppm: the canonical `ignitionWeight`, floored. It is checked against the float at fixed points.
  - A lot of the same weight merges with the youngest.
- **Rewards** accrue on `Σ amount · ppm` per pool, a MasterChef accumulator at 1e24 scale, settled on every change.
- **Withdrawals** are fee-free and take the youngest lot first. Withdrawn principal stops earning at once.
- **The accumulator's floors** strand a bounded dust; the model checks the bound on every scenario.

**3. The close.**
- **`finalize()`:** permissionless, once, from `END`. A claim also triggers it.
  - It brings every pool to `END`.
  - It takes the 41,000 from the ledger. The release is permissionless, so whoever releases first, Ignition only checks that the ASH arrived (`FundingMismatch`).
  - It burns what accrued to nobody, plus the budgets' rounding.
- **`claim(wallet)` and `claimMany`:** permissionless, paid only to the wallet.
- **The free-exit window.** For 24 hours after `END` every asset may leave.
- **After the window,** a wallet's USDC that did not opt out goes only to Cold Storage, through the permissionless `stakeUsdc(wallet)` or `stakeUsdcMany`.
  - That is pool 3's new `IGNITION`-only `openIgnition(owner, amount)`, which opens the wallet's own position at the standard 1% fee.
  - WETH, WBTC, LP and opted-out USDC stay withdrawable, fee-free, forever.

**4. First Flame.**
- `isFounder(wallet)` holds once `END` has passed, for a wallet that had principal in any pool at `END`.
- Nothing can be deposited from `END`. So a wallet's live principal is its principal at `END` until its first post-close action, which records the flag (and its kept USDC) before it moves anything.
- No snapshot loop is needed.

**5. The head start: `grantHeadStart(pool, id, slot)`.** The caller must own the position. The pool must be Cold Storage or pool 0.
- **When:** from Kindling's `closedAt` to 7 days after it.
- **How often:** once per wallet. The pool already allows only once per position.
- **Which lot:** one whose age-zero time is at or after Ignition's `END`. This is new capital, the auto-staked lot included.
- **The cap:** the lot's value must be at most the USDC the wallet kept through `END`.
  - Cold Storage USDC counts at $1.
  - Pool-0 LP counts at its fair value, `2·sqrt(rE·rQ·P_twap)` per supply, from BlastPool's 1,800 s TWAP. That value refuses a TWAP older than 3,600 s (`StaleOracle`). Neither a skewed pool nor a donation raises it.
- **The credit:** `seconds = openedAt − START`, the lot dated to Ignition's start.

**6. Provisional readings [P].** Each was taken as recommended, per the owner's standing rule. Each is a deploy blocker until confirmed.
- **[P] An unbound LP pool gives its weight to the other three** (13,666.67 ASH each), rather than burning a third of the leaf.
- **[P] Time a pool sits empty accrues to nobody** and is burned at close, as the Forge's empty pools are (`accruedPoolBudget`).
- **[P] The entry weight is linear in admission time, in ppm, floored.** The config says `linear`.
- **[P] Withdrawals take the youngest lot first.** A wallet keeps its earliest, heaviest lots.
- **[P] At most 16 lots per wallet per pool.** Same-weight deposits merge. A 17th weight is refused rather than merged at a weight it did not earn.
- **[P] Opting out is sticky and wallet-wide.** Any USDC deposit with the flag sets it for the wallet's USDC.
- **[P] Auto-staked positions pay Cold Storage's standard 1% fee,** as Kindling positions do (ADR 0018).
- **[P] Founders are wallets with principal in at `END`**, read lazily, as in §4.
- **[P] The head start's cap counts only kept USDC.** WETH, WBTC and LP have no valuation source yet, so they give no head-start room.
- **[P] Only Cold Storage and pool-0 LP are eligible for the head start.** Those are the two pools a USD value can be given without the valuation source.
- **[P] "New capital" means a lot whose age-zero time is from `END`.** The window runs from Kindling's close. A Kindling that never settles opens no window.
- **[P] The accumulator scale is 1e24.** It is exact enough for 6-, 8- and 18-decimal stakes; the model bounds the dust.
- **Not built here:**
  - the bound WETH/USDC LP;
  - the valuation source;
  - the dApp's Ignition tab (next);
  - the Forge's ASH distributor and the Hearth.

**7. The pool hook.** `ForgePool.openIgnition(owner, amount)` sits beside `openKindling`: `IGNITION` only, through `_open(owner, amount, false)`, fee included. ForgePool is 22,514 runtime bytes, 2,062 under the limit. The storage layout is unchanged.

**8. The kit.**
- **`FURNACE_TESTNET_IGNITION=1`** deploys the real Ignition at its CREATE3 address, and needs the real Kindling (`IgnitionNeedsKindling`). Every pool's `IGNITION` and `FOUNDERS`, and the ASH ledger's `IGNITION`, name it.
- **What it farms:** tUSDC (BlastPool's quote), tWETH (SmelterPool's) and a new tWBTC stand-in. The LP stays unbound.
- **The timeline:** Kindling and the Mantle default to opening where Ignition's free-exit window ends, and the wiring check refuses an earlier Kindling.
- **The smoke run** farms 1,000 tUSDC and 0.1 tWBTC.
- **`IgnitionClose`** (`pnpm testnet:ignition:close`) finalizes the farm, claims the caller's ASH and, after the window, stakes the caller's USDC.

## Size and gas

- **Size:** Ignition is 15,042 runtime bytes.
- **Gas** (isolated):
  - a first deposit: 233,407;
  - a later lot: 196,320;
  - a withdrawal across two lots: 91,953;
  - `finalize` (release and burn): 335,228;
  - `claim`: 175,194;
  - `stakeUsdc` into the real Cold Storage: 314,028;
  - `grantHeadStart`: 110,275.

## Verification

- **Model.** `scripts/ignition-model.ts` (BigInt) has 15 scenarios:
  - the early bird, every pool's decimals, the unbound LP, youngest-first withdrawals and empty-pool burns;
  - the lot cap;
  - the close, with its window, auto-stakes and opt-outs;
  - founders, and an early release;
  - six seeded walks.
  - **What `Ignition.t.sol` checks after every step:** each output, each revert selector and a hash of the whole state, exactly.
  - **The model also checks:** the ledgers' identities after every step, and that the dust left after every claim is within its bound.
- **Unit and fuzz tests** (`Ignition.t.sol`, 17 with the gas rows):
  - zero inputs, the budgets, the fee, a fee-on-transfer token refused;
  - a ledger paying elsewhere refused;
  - the whole leaf paid or burned, never more (fuzzed);
  - auto-staking into a real Cold Storage;
  - `openIgnition` only from `IGNITION`;
  - the head start on real pools 3 and 0 and a real BlastPool: the window's edges, once per wallet, the owner, eligible pools, new capital, the cap, the fair LP value under a same-block skew, and a stale TWAP;
  - no head start before Kindling closes, even on a clock younger than the window.
- **Invariants** (`IgnitionInvariant.t.sol`, 5, 128 runs × 64 calls, seeded):
  - each token's balance is principal plus donations;
  - principal is conserved per wallet;
  - paid + owed + burned never passes 41,000, and ASH held covers what is owed;
  - no deposit from `END`, and free principal always leaves;
  - Cold Storage holds what was staked.
- **Kit.** `DeployTestnet.t.sol` runs the whole genesis on the real core: farm, close, claims, auto-stake into pool 3, Kindling's settlement, a head start dated to Ignition's start, and First Flame read from Ignition.
  - **LiteForge fork dry runs, smoke on:**
    - 55 transactions and 92.1M gas by default;
    - 33 and 92.8M with the real Kindling;
    - 37 and 100.1M with Ignition.

- **Mutations:** 56 planted bugs, run in separate worktrees so the main tree never held one. 55 are caught.
  - **They cover:**
    - deposits: the window, the minimum, the fee and its rounding, merging, the lot cap, the early bird and the opt-out;
    - withdrawals: the exit rule, the youngest lot's weight, settling before a change, and the snapshot;
    - the accumulator: empty-pool time, the recorded budget, anticipation and the snapshot;
    - `finalize`: the dust and empty-pool burns, the release, the funding check and its timing;
    - claims: zeroing, the recipient and the empty claim;
    - auto-stakes: the opt-out, the weight, settlement, the snapshot and the window;
    - founders and the kept USDC;
    - the entry weight and the LP's budget;
    - every head-start gate, the cap and its slack, the seconds, the stale TWAP and the fair value;
    - the exact pull;
    - `openIgnition`'s caller and fee.
  - **One gap was found and closed.** Dropping the `closedAt == 0` guard survived. On any real chain the clock is already past the 7-day window, so an unsettled Kindling still failed the window check; on a fresh local chain it would not. `test_noHeadStartBeforeKindlingClosesEvenOnAYoungClock` runs a farm from t = 1 hour and fails against that mutant.

## Consequences

- **Genesis is built:** Ignition, then Kindling, then the Forge. The mainnet gate's `Ignition` and `Founders` slots are built (they hold one address), so the blockers stay at 31.
- **The head start's per-wallet rule and value cap,** which ADR 0019 left to Ignition, are kept.
- **Still to come:** the dApp's Ignition tab, then the Forge's ASH distributor (`ForgeAsh`) and the Hearth.
