# ADR 0008: The ordinary Heat bonus (Capstone + Pyre) in ForgePool

Status: accepted for this repository. Not audited, not deployed. Rules marked **[P]** are provisional readings of this repo, not canonical v5.5 rules.

## Context

- **Spec v5.5:**
  - §6: Capstone adds at most +0.5 ordinary Heat, reached at a held-value/LP-value ratio of 0.5. Its valuation must use "the pool's protected valuation checkpoint, not an arbitrary caller price".
  - §8: Pyre is a permanent, account-wide Heat boost, capped at 0.15 (`forge.pyre.maxBoost`).
  - §12: "Capstone and Pyre bring the ordinary maximum to 3.65."
- **Canonical `accounting.ts`** takes the bonus in three places:
  - `integrateHeat(age, dt, ordinaryBonus)` adds `bonus·dt`, with a ceiling of 0.65.
  - `segmentMeasures` forms the Seal candidate as `weighted × sealBonus`, where `weighted` already includes the ordinary bonus.
  - `squaredHeatPrimitive(age, ordinaryBonus)` gives the Ashfall weight, Heat² with the bonus inside the square.
- **`CONTRACTS.md`:**
  - "Actions checkpoint pool occupied-time accrual, affected lots and owner-dependent bonus segments."
  - "Capstone/Pyre ordinary boosts require checkpointed valuation/ownership changes."
- **ForgePool is immutable.** Its measures passed a bonus of 0. ADR 0007 listed the hook as a deploy blocker.

## Decisions

**1. One authority, one number per position.**
- **Authority.** ForgePool takes an immutable `BOOST` address, which must be nonzero, as its fourth constructor argument. Only `BOOST` may call `setOrdinaryBonus(id, units)`.
- **[P] Units.** The bonus is stored as a `uint16` in units of 1e-5 (`ORDINARY_BONUS_UNIT_RAY` = 1e22).
  - The ceiling is `MAX_ORDINARY_BONUS_UNITS` = 65,000, which is 0.65.
  - `pnpm gen` fails unless `capstone.maxBonus + pyre.maxBoost` equals 0.65 and the ceiling is a whole number of units that fits 16 bits.
- **The pool does not know how the number is made.**
  - The Capstone ratio, the Pyre tiers and the valuation checkpoint belong to a Boost contract, which is not built yet.
  - The pool checks only the authority and the ceiling.
- **Edge cases:**
  - An unknown position reverts.
  - A value above the ceiling reverts.
  - A closed position is a no-op: no sync, no write, no event. Its measures end at the emergency exit, so changing its head's bonus would rewrite the past.
- **No exit depends on Boost.** The pool never calls `BOOST`, and every exit still makes exactly one external call, the token transfer.

**2. The records carry the bonus.**
- **Storage:**
  - `Record` gains `ordinaryBonus` (`uint16`). `participated` narrows to `uint24`, because it saturates at the 30-day Ashfall minimum, and `pnpm gen` checks that it fits. The record is still one 256-bit slot.
  - `Position.ordinaryBonus` takes the 16 spare bits of the slot that holds `owner`, `lastCheckpoint` and `streakStart`.
  - A head's own bonus is the position's current one. The measure library receives it, with the Streak start, as one packed anchor (`ForgeMeasures.anchorOf`).
- **Why it is exact.** This is the argument of ADR 0007's Streak anchor:
  - `_setBonus` runs after the position syncs, so every lapse due by now is resolved, back-dated.
  - It then rewrites every active head at now (`_rewriteActive`, which `_haircut` now shares), and only then moves the bonus.
  - So an active record segment never spans a change.
  - A second change at the same instant overwrites the head in place.
  - Frozen slices are not rewritten. They earn nothing, and they take the current bonus when they resume.
- **What the bonus enters.** Each segment's bonus enters:
  - **W**;
  - **the sealed W**, so `C = ⌊sealed W × Seal bonus⌋` carries it, as canonical `segmentMeasures` does;
  - **the Ashfall Heat²**.

  `HeatMath` already took the bonus: ADR 0007 kept the Heat² port exact for any bonus up to 0.65. `ForgeEmissions` is unchanged: its measures are full 256-bit values, and every ratio uses `mulDiv`.
- **Invariant.** The handler logs every bonus change. `invariant_bonusAnchorsAlignWithRecords` checks that:
  - each active record carries the bonus in effect at its start;
  - no change falls strictly inside a segment;
  - no change falls under an open, active head.

**3. [P] A top-up dilutes the bonus.**
- **Why.** Boost never sees deposits. Without this rule, an owner could build a high Capstone ratio on a small stake, then top up. The new capital would earn the old bonus until someone refreshed it, and the beneficiary never would.
- **The rule.** A deposit into a position with a nonzero bonus rewrites the active heads, then sets `bonus ← ⌊bonus · custody / (custody + net)⌋`. Custody is active plus frozen principal before the deposit.
- **Effect:**
  - It is exact for Capstone's linear part, when Boost measures the ratio against custody.
  - It reads below the true value otherwise: Capstone at its cap, or Pyre's flat part.
  - So a stale bonus after a top-up only ever errs against its holder, who has every reason to refresh it.
- **Requirement on Boost:** the ratio's denominator is custody principal (active + frozen). Then:
  - a cooling request, a cancel or a lapse leaves the true value unchanged;
  - an executed withdrawal raises it, and the owner refreshes;
  - an emergency exit closes the position.

  Changes in the valuation itself (EMBER or LP price) are Boost's to checkpoint.

**4. [P] BOOST cannot exhaust a record counter.**
- **The risk:**
  - `Lot.records` is a `uint24`.
  - A cooling request, an execution, a cancel and a lapse each write a head, and that write is a checked `+1`. (The emergency exit writes no heads, so even a full counter never blocks it.)
  - Until now only an owner could grow its own records. A Boost with a permissionless refresh could push records onto someone else's position.
- **The limit:**
  - `setOrdinaryBonus` reverts with `RecordLimit(id, slot)` once an active slot holds `BOOST_RECORD_LIMIT` = 2²³ records. That leaves the other half of the counter for the owner's own actions.
  - The dilution rewrite in a deposit has no limit, because it is the owner's own action.
  - Same-instant rewrites overwrite, so a BOOST rewrite adds at most one record per active slot per second. (A single sync can add more, because each lapse it resolves is back-dated to its own deadline.)
- **Requirement on Boost:** rate-limit or quantize refreshes. For example, owner-triggered changes, plus at most one checkpointed refresh per position per epoch. That keeps ADR 0005's record-spam argument: the sender pays more per record than settlement does.

**5. Size.**
- The hook added about 830 bytes, which put ForgePool 125 bytes over EIP-170.
- The pool's two `mulDiv` calls became plain arithmetic, which removed OpenZeppelin's 512-bit `mulDiv` from its code. Both are exact for the pool's operands:
  - **The pro-rata split.** A lot amount is below 2⁹⁶, and the active principal is below 2¹⁰¹.
  - **The age haircut** (`HeatMath.cooledAge`). Ages are already capped, and custody is below 2¹³⁰.
- Every existing test passes unchanged, and the differential scenarios still match canonical `cooledAge` after every execution.
- ForgePool is now **24,401 bytes, 175 below the limit**.

## Provisional defaults

| Topic | Default here | Why |
|---|---|---|
| Bonus resolution | `uint16` units of 1e-5 (0.65 = 65,000) | Fits the spare 16 bits of the position's first slot and of each record |
| Closed position | Keeps its last bonus; no revert | Its measures ended at the exit |
| Top-up | Bonus × custody before ÷ custody after, floored | Exact for Capstone's linear part, otherwise errs against the holder |
| Record limit for BOOST | 2²³ per slot | Keeps half the counter for the owner's own actions |

## Still required before any deployment

These are **not built**:
- **The Boost contract,** at a mined address passed to all four pools. It needs:
  - Capstone deposits and withdrawals: fees of 1%, burned; the same cooling timer as withdrawals; no effect on Streak or age;
  - the protected valuation checkpoint;
  - Pyre's burn-to-mint badges;
  - the refresh policy in decision 4;
  - the custody denominator in decision 3.
- **Deed transfers.**
  - ForgePool has no owner transfer.
  - A Deed sale needs several changes inside this immutable pool, before deployment: an owner change; the buyer's 80% of capped age; a Streak reset for the new owner; and the seller's Pyre left behind, which is a bonus change.
  - Each must rewrite the active heads first, like the Streak anchor and the bonus. `_rewriteActive` is the reusable step.
  - The pool has 175 bytes of headroom, so this needs another structural change.
- **The rest of ADR 0007's list:**
  - the matching, match-reserve and Sealed-pot stream contracts, at mined addresses;
  - the emergency exit's stayers' share;
  - Relic perks and Quote yield.

## Gas (`pnpm gas`: forge `--isolate`, optimizer 500 runs, solc-js 0.8.28)

Every call is its own transaction, so storage starts cold. The page benchmarks run with no bonus; the "ADR 0007" column is the same benchmark before this change.

| Path | ADR 0007 | Now |
|---|---:|---:|
| `setOrdinaryBonus`, 32 active lots (32 new records) | — | 1,132,396 |
| Measure page: 32 positions with 1 lot each | 3,925,366 | 4,004,342 |
| … with Ashfall | 5,480,677 | 5,564,421 |
| Measure page: 1 position with 32 lots | 831,843 | 845,471 |
| … with Ashfall | 1,766,863 | 1,785,259 |
| Credit page: 32 earners, base + Ashfall (two mints) | 1,319,016 | 1,392,666 |
| Record-spammed epoch, heaviest page (base / Ashfall) | 5,360,350 / 3,375,529 | 5,411,891 / 3,422,047 |
| Attacker gas per spammed record | ≈179,000 | 181,292 |

- **Pages cost 1–6% more.** Each record segment decodes a wider record and the packed anchor. Each Ashfall earner's credit reads `positionOf`, which now returns one more field.
- **A bonus change costs about one record per active lot,** in line with a cooling request over the same lots (1,323,327 for 32).

## Verification

- **Custody differential (24 scenarios).** Two are new:
  - `boostCycle` covers a change with a ticket pending, an unchanged value, a lapse due before a change, a change and a Streak reset at the same instant, the maximum bonus past the age cap, a closed position, the ceiling and an unknown position.
  - `boostSealDeposit` covers a change inside a Seal, a bonus across the Seal's end, top-ups at the same instant and with a slice pending, and a deposit into an emptied position.
  - Random walks include Boost actions, some of them above the ceiling.
  - After every action, the contract's record-based S, W, sealed S and W, and Ashfall weight must equal the model's independent accrual.
  - 8 scenarios run with boosted active lots. Generation fails if fewer than 6 do.
- **Settlement differential (19 scenarios).** The new `boostedHeat` scenario has a boosted and an unboosted position at equal stake, plus a sealed, boosted one, settled over three epochs. Random walks include Boost actions. The model checks every payout against canonical `settleBaseEpoch`.
- **Unit tests:**
  - the authority, the ceiling, an unknown position and the event;
  - an unchanged value: the position syncs, with no record and no event;
  - W and the Ashfall weight at the bonus rate, against `HeatMath` directly;
  - the closed no-op;
  - the diluted value;
  - `RecordLimit`, with the owner still able to request and execute.
- **Invariants.** ForgePool's bonus anchors, and the settlement suite (`fail_on_revert`) with random boosts.
- **Mutations:** 32 planted bugs, each run in its own worktree against every suite. **All 32 are caught.**
  - **The 15 new ones:**
    - the bonus set before the rewrite;
    - records storing no bonus;
    - the head's bonus read as zero;
    - records reading the head's bonus;
    - W, the sealed W or Ashfall without the bonus;
    - no dilution, or dilution by active principal only;
    - no record limit;
    - a closed position re-bonused;
    - an unguarded setter;
    - the ceiling off by one;
    - no sync before a change;
    - an unchanged value still rewriting.
  - **The 17 from ADR 0007** were re-run on this code, two of them with their patterns updated for the new record fields. All are still caught.
  - **One gap found and closed.** The sealed-W mutant was at first caught only by random walks, because `boostSealDeposit` had cleared its bonus before the Seal ended. The scenario now sets a bonus across the Seal's end, and catches it.

## Consequences and limits

- **Trust in BOOST.** A faulty or captured `BOOST` can set any open position's bonus anywhere in [0, 0.65]. That redistributes Heat and Ashfall rewards, but never touches principal, exits or the base budget. `BOOST` is fixed at deployment.
- **Not audited or deployed.** Matching the models proves consistency with this ADR, not canonical conformance of any [P] rule.
