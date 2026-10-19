# ADR 0002: Exact integer emission schedule

**Status:** Accepted (implementation choice; it does not change the config or its hash)
**Date:** 2026-10-19 · **Config:** v5.5.0

## Context

Spec v5.5 §1 says: "Daily epochs use the schedule value at epoch start; a production fixed-point schedule evaluator must match its pinned test vectors."

The canonical package ships only a floating-point helper (`baseEmissionPerDay`) and no pinned integer vectors. The first Solidity port used an exponential approximation and matched the float helper only to about 1e-12. That is not an exact, reproducible definition.

## Decision

This repo defines the integer evaluator and pins its vectors:

```
H = halfLifeDays (365)
F[r] = floor(1e18 · 2^(−r/H))   for r = 0..H−1
       = the largest x with x^H · 2^r ≤ 10^(18·H)    (exact BigInt root, no floats)
q = floor(day / H),  r = day mod H
curve(day) = floor(START · F[r] / 1e18) >> q        (0 once q ≥ 256)
emission(day) = max(FLOOR, curve(day))
```

The pieces:
- **Reference:** `scripts/schedule.ts`.
- **Table:** `pnpm gen` writes `contracts/src/generated/ScheduleTable.sol`, 365 big-endian uint64 entries.
- **Port:** `EmissionMath.baseEmissionPerDay`, tested with exact equality on every day from 0 to 1700 plus far-out days.

Nested floor divisions commute (⌊⌊x/a⌋/b⌋ = ⌊x/ab⌋), so the order of the division and the shift cannot change any value.

## Consequences

- **Exact halvings:** day 365 is exactly 10,800 EMBER and day 730 exactly 5,400 EMBER.
- **Floor and monotonicity:** the floor (1,000/day) is first reached on day 1,619. Values never increase from one day to the next; this is checked exhaustively.
- **Agreement with the float helper:** `pnpm gen` aborts if any pinned day deviates from v5.5's float `baseEmissionPerDay` by more than 1e-12 relative. The observed maximum is about 5e-16, which is float precision.
- **Dependency removed:** solady is no longer needed, since `expWad` is gone.
- **Spec follow-up:** these pins are defined by this repo, not by the canonical package. A future canonical revision should adopt them, or supply its own pins. Either way the Solidity port follows the canonical package's pins.
