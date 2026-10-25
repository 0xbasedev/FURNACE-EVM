# ADR 0004: Forge custody core

**Status:** Accepted. The project owner chose the capacity rule (decision 8) on 2026-10-25; the rest is provisional where marked [P].
**Date:** 2026-10-25 · **Config:** v5.5.0 · **Code:** `contracts/src/forge/ForgePool.sol`, `LapseHeap.sol` · **Reference model:** `scripts/forge-model.ts`

## Context

v5.5 orders the build as follows: integer ports first (done in PR #1), then "Forge in-kind custody exits, cooling tickets and Seal transitions with reward debt archived independently", then settlement.

This ADR covers custody: deposits, lots, cooling plans, execution, cancel and lapse, emergency exit, and the per-position measures that settlement will read.

**Not built here:** epoch settlement and Conviction, Seals, Claim, Compound and Casting, Deeds, Capstone, Taps and Relics, and the FeeRouter.

**Principal paths depend on nothing external.** No oracle, swap, bridge, reward pass or fee router is involved. The only external call on any exit is `STAKE_TOKEN.safeTransfer(owner, net)`.

## Decisions

**1. One `ForgePool` per pool.**
- Immutables: `STAKE_TOKEN`, `IS_LP` and `FEE_COLLECTOR`.
- There is no owner, pause, rescue or upgrade path.
- Every protocol number comes from the generated `FurnaceParams`: fees, tiers, window, plan horizon, lot limit, `minStakeLp` and the 30-day participation threshold.
- `pnpm gen` refuses to generate if the config selects a cooling policy this contract does not implement. It checks, among others, `earnsWhileCooling`, `onCancelOrLapse`, `cancelConsumesPlanQuota`, `freeze`, `exitAsset` and `withdrawCooling`.

**2. Positions and lots.**
- A position has at most 32 lots. A lot is `{amount, financialAge, participated, heldBy}`.
- **Financial age** is stored saturating at the 365-day cap. Every Heat function caps first, so nothing is lost.
- **Actual participation** is a separate chronological counter. Frozen slices pause it, and haircuts never touch it.
- Positions are non-transferable until Deeds arrive.

**3. Measures.**
- Every touch first resolves due lapses (item 6), then accrues each active lot. `S += a·dt` and `W += a·HeatMath.integrateHeat(age, dt, 0)`.
- Accrual is exact, and it telescopes under any checkpoint subdivision (tested).
- `S` and `W` are kept per position, not per lot, because settlement groups lots by position and per-lot accumulators would cost about 64 more SSTOREs per action.
- Measures are never deleted, even after exit.
- **PR 3 owns the epoch-split read path.** That includes how a settlement page obtains a position's measures for epoch *e* when its last checkpoint is older. PR 3 may extend the checkpoint write.

**4. Fees are booked, never pushed.**
- Deposit (1%), execution (1%) and emergency (8%) add to `feesOwed[kind]`.
- `collectFees()` is callable only by `FEE_COLLECTOR`. A reverting or hostile collector therefore cannot block an exit (tested).

**5. The cooling plan.**
- The first request opens a plan. Its `reference` is the position's principal at that moment.
- Each request adds to the cumulative `requested`, and the tier is the first one with `requested·100 ≤ reference·maxPct`. **[P]** This is exact cross-multiplication, not a floored percentage.
- Cancelling still consumes quota.
- A plan resets only once its 72h horizon has passed and no ticket is pending.
- A new ticket never changes an existing ticket's maturity.
- **[P]** `requested ≤ reference`. A top-up made during a plan waits for the reset, or leaves through emergency exit.
- **[P]** At most 8 tickets can be pending per position.

**6. Freeze, execute, cancel and lapse.**
- **[P] Freeze basis:** a request freezes `floor(a_j·r/A)` of each active lot in slot order. The floor dust goes one unit at a time to the first lots with room. A later deposit is not part of an earlier slice.
  - A frozen slice keeps its own `{amount, age, participated}` and neither earns nor ages.
  - `coolingPausedSeconds` advances while any ticket is pending. This is the hook Seals need to extend their terms.
- **Execute:** allowed only in `[maturity, maturity+24h)`. It pays out in kind minus the 1% fee and resets Streak.
  - **[P] Haircut basis:** every surviving lot and every other pending slice gets `cooledAge(age, w, balance)`. Here `balance` is the full custody principal: active plus all frozen, including this ticket.
- **Cancel or lapse** resumes the frozen state, adjusted by any haircut that happened in between. A slice that emptied its lot goes back into that lot's slot (`heldBy`). Any other slice takes its own slot, unless the parent's state is identical, in which case sharing storage is exact. Averaging two ages is never used (spec §4).
- **Lapse needs no transaction.** On the next touch the slice resumes *as of* `maturity + 24h`, and it accrues and ages from then on.

**7. Pool occupancy (the input to `accruedPoolBudget`).**
- An append-only log of on/off transitions with cumulative seconds. `occupiedSecondsAt(t)` is a binary search.
- The pool counts *active* principal only, so cooling slices don't count.
- A lapse can re-activate an idle pool without any transaction. `LapseHeap` is an indexed min-heap of pending deadlines with eager deletion. While no principal is active, the earliest due entry re-activates the pool at its exact deadline: one entry is enough, since occupancy only depends on active > 0. The view includes a due entry that no transaction has processed yet.
- Every heap operation is O(log n) and nothing loops over the population.

**8. Capacity rule (confirmed by the project owner, 2026-10-25).**
- Each lot that a request splits (leaving both an active remainder and a slice) reserves one slot. Deposits cannot use reserved slots.
- A slot is released when its slice executes, or when it resumes into an exactly equal parent.
- A request that empties a lot needs no reservation, so a 100% request is always accepted.
- **Cost:** a position whose request would split more lots than it has free slots must cool 100% at once. For example, 17 or more young lots can't take a partial request. Emergency exit is always available, so principal is never locked.
- The rejected alternative merged at the slice's lower age; that touches unrelated stake, by up to about 4 days of age.

**9. Emergency exit.**
- Always callable for an open position with principal.
- It resolves due lapses, then pays all active plus frozen principal in kind minus 8%.
- It consumes every pending ticket, closes the position and sets `ashfallForfeited`.
- The FeeRouter applies the 50/25/25 routing later.

## Provisional defaults

| Topic | Default here | Why |
|---|---|---|
| Tier comparison | `requested·100 ≤ reference·maxPct` | Exact; a floored percentage would let 10.9% count as 10% |
| Freeze dust | First lots with room, in slot order | Deterministic, and the total is exact |
| Haircut basis | Full custody principal (active + all frozen) | Frozen slices are still part of the position's receipt |
| Pending tickets per position | 8 | Bounds gas on sync, haircut and emergency |
| Top-up during a plan | Not withdrawable until the plan resets | The spec freezes the reference; emergency exit remains |
| Single-asset minimum | Nonzero net | The config only defines `minStakeLp` |
| Fee rounding | Floor, in the user's favor | No canonical rule |
| Participation storage | Saturates at the 30-day Ashfall threshold | The only consumer v5.5 defines; it makes capped cohorts mergeable |
| Emergency exit | Closes the position | Simplest state; measures remain readable |

## Gas (forge, optimizer 10,000 runs, solc-js 0.8.28)

| Path | Gas |
|---|---:|
| `requestCooling`, 16 lot splits | 730,423 |
| `requestCooling` 100%, 32 lots | 1,048,053 |
| `executeWithdrawal`, 16 lots | 238,507 |
| `executeWithdrawal`, 4 lots + 6 pending haircut | 193,584 |
| `executeWithdrawal`, 32 lots | 97,305 |
| `cancelCooling`, 4 slices to reserved slots | 119,693 |
| `poke`, resolving 5 lapses | 868,056 |
| `poke`, 32 lots | 400,637 |
| `emergencyExit`, all lots frozen | 60,514 |

- The heaviest costs come from writing fresh slice storage (about 22k per new slot) and from per-lot age writes.
- Packing slices, or storing a slice as a fraction of its lot until a haircut forces materialization, are possible optimizations. Both need the same differential evidence before they replace this version.

## Verification

- **Differential:**
  - 16 scenarios (10 scripted edge cases, 6 seeded random walks; 793 actions, 218 of them expected to revert) run through `scripts/forge-model.ts`.
  - After every action the Solidity state hash must equal the model's: every lot, slice, ticket, plan, measure, fee, occupancy entry, queue size and token balance. Reverts must match too.
  - The scripted cases cover tiers, overlapping tickets, a haircut between freeze and cancel, a late touch after a lapse, a lapse while the pool holds only frozen principal, capped merges, the 16/17-lot capacity edge, the 32-lot cap and emergency exit with pending tickets.
- **Invariants** (64 runs × 200 calls):
  - custody is backed by the token balance;
  - tokens are conserved;
  - pool totals equal the positions' lots and slices;
  - the queue holds exactly the unprocessed tickets;
  - slot masks are consistent and ages are bounded;
  - measures and occupancy are monotone;
  - emergency exit succeeds, and pays exactly, for every open position at every step.
- **Mutation checks** (each one fails the suite):
  - cancel refunds quota;
  - the haircut basis excludes frozen slices;
  - pending slices skip the haircut;
  - a lapse resumes at touch time;
  - a slice merges at its parent's age;
  - the tier uses a floored percentage;
  - an idle pool re-activates at touch time;
  - a merge keeps its reservation;
  - participation doesn't saturate.
- **CI gate fix:** the `@foundry-rs/forge` 1.7.1 npm wrapper never propagates forge's exit status, so failing tests exited 0. `tools/forge.mjs` runs the same platform binary and forwards its status. `pnpm forge:gate` proves it on every check with a deliberately failing test (`contracts/test/meta/ExitCode.t.sol`).

## Consequences and limits

- **Not yet implemented:**
  - the authenticated Flow LP deposit-fee exemption;
  - Taps (youngest-first, no haircut, quota);
  - Deeds (transfer with an 80% age carry and a Streak reset);
  - Seals (pause and extend, using `coolingPausedSeconds`);
  - Capstone and Pyre ordinary bonuses (`integrateHeat` already takes the bonus);
  - founder phantom age.
- Matching the model proves the port is consistent with this ADR's readings. It does not make any [P] rule canonical.
- Nothing here is audited or deployed.
