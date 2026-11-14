# ADR 0019: The Ignition head start, the pools' last immutable hook

Status: accepted for this repository. Not audited, not deployed.

## Context

**What the spec requires** (v5.5 §2; the config's `ignition.heatHeadStart: 'ignitionStart'` and `principalAtClose`):
- **The credit.** "The Heat head start (age dated to Ignition start) applies to the first Forge Deed the depositor opens or funds within `headStartWindowDays` [7] of Kindling close, up to the USD value they kept in Ignition through close."
- **Its limits.** "The finite head-start credit remains limited to retained contributing value and its seven-day claim window. It cannot be reused for multiple new deposits or sold as financial age through a Deed" (§49). "New deposits cannot borrow old capital's age except through explicitly specified founder/head-start rules."
- **Phantom age.** It is never participation for Ashfall, Seal membership or rebates (§49). It is a separate mechanism from First Flame (v5.4: "two permanent things").

**What ADR 0011 §4 bound in advance:**
- `Position.headStartActive` and `headStart` (seconds) already exist.
- Settlement clears the flag and keeps the amount, so the seller's records stay measurable.
- Phantom age never enters `Lot.age`.

**Two choices, decided by the project owner** (November 2026):
- **The value cap applies to a whole lot, enforced by Ignition.** Ignition grants only a lot it has checked is within the retained value. The pool applies the credit to that lot, all or nothing, and never prices or splits.
- **The head start stacks with First Flame.** A founder's head-started lot reads its real age plus the head start plus 15 days, capped at the age cap.

## Decision

**1. One immutable caller, `IGNITION`.**
- It is the tenth constructor argument, and the annex gets the same one.
- Any pool may set it, since a depositor's first Deed may be in any pool. The testnet kit sets the operator on all four.
- A zero `IGNITION` grants nothing, to anyone.

**2. `grantHeadStart(id, slot, seconds)`.** It is `IGNITION` only and runs in the annex.
- **Once per position, ever** (`HeadStartUsed`): neither a later grant nor a sale can reset it.
- **The amount.** `0 < seconds ≤ HEAT_AGE_CAP` (`BadHeadStart`). Ignition computes it as the lot's open time minus Ignition's start.
- **Refusals.** It refuses a closed or listed position, and a slot that is empty, past 31 or wholly frozen (`NotActiveLot`). The slot's record limit is checked.
- **The write.** The slot's segment closes at now under its old anchors. Then `headStart`, `headStartActive` and `headStartMask = 1 << slot` are set, and `HeadStartGranted(id, slot, seconds)` is emitted.
- **What the pool leaves to Ignition.** Ignition keeps the seven-day window, the "first Deed" rule and the retained-value cap: it grants only a lot it has checked.

**3. The head start covers the granted principal, wherever it goes.**
- `Position.headStartMask` is a new field in the position's third word. It took free bytes, so no slot moved; `check:layout` and `ForgeView` follow.
- **Later deposits take other slots and never read it**, which is the spec's "cannot be reused for multiple new deposits".
- **A cooling slice of a covered slot** that returns to a free slot carries the bit, as a Seal cohort's does.
- **A covered slot freed** by an executed withdrawal of its whole lot loses the bit, so a later deposit there is new capital.
- **A source-lot addition** to the covered lot is internally earned (ADR 0017) and keeps it.
- **A Deed sale ends it.** `headStartActive` clears and the amount stays, as ADR 0011 bound.

**4. The measures.**
- **Where the flag lives.** Bit 38 of a record's Streak anchor, `ForgeMeasures.HEADSTART_FLAG`, marks a segment of a covered slot. `slotAnchor` sets it on a covered slot's open head.
- **The anchor word** now also packs the position's head-start seconds and its active mask.
- **What it changes.** W and the sealed W read `min(age + FIRST_FLAME_AGE·founder + headStart·covered, HEAT_AGE_CAP)`.
- **What never sees it:** lot ages and participation, the Ashfall clock (`STREAK_MASK` now strips both flags), the Ashfall weight (as for First Flame, ADR 0018 [P]), the Seal cohort, Taps and the Deed carry.

**5. Provisional readings [P].** Each is a deploy blocker until the owner confirms it.
- **[P] A source-lot addition keeps the head start.** It is internally earned, not a deposit. The cap Ignition checked applied at grant time, so a Cast can grow a covered lot past that value.
- **[P] Once per position, not per wallet.** A depositor with several positions could be granted once on each. Ignition must keep the spec's "first Deed" per wallet; the pool cannot see wallets across positions.

## Size and gas

- **Size.**
  - ForgePool is 22,335 runtime bytes, 318 more than ADR 0018 left (2,241 under EIP-170).
  - Its initcode, which embeds the annex, is 40,142 of 49,152.
  - The annex is 15,942 bytes, and ForgeMeasures 6,345.
- **Gas** (`pnpm gas`, isolated): `grantHeadStart` costs 95,700.

## Verification

- **Model.** `scripts/forge-model.ts` gains the head start: the seconds, flag and mask on positions; the flag on records; the offset stacked in the accrued W and in `measureSlot`; the mask's travel with slices and its clearing on release; and `grantHeadStart`.
  - The scenario words carry all three fields.
  - Six new differential scenarios replay exactly, with the state hash, W and the Ashfall weight compared after every step. There are 66 scenarios in all.
  - The scripted ones cover:
    - a grant with its refusals, a later deposit, stacking with First Flame, and an addition;
    - slices returning to free slots, and a whole covered lot leaving with a deposit into its freed slot;
    - a grant while listed, a sale, a refused regrant, and an emergency exit.
  - Three seeded random walks grant head starts among every other action, including Deeds, Taps, additions, First Flame and Kindling.
- **Unit tests:**
  - only the granted lot reads it, while a later deposit, a twin, lot ages, participation and the Ashfall weight do not;
  - stacking with First Flame, and the cap;
  - every gate: the caller, a zero `IGNITION`, the bounds, the slot, once, listed and closed;
  - a sale ending it, with the amount kept and no regrant;
  - a freed slot losing it;
  - the annex's immutables.
- **Invariants.** The pool handler grants head starts. A new invariant checks that:
  - the granted amount never changes;
  - the mask covers used slots only;
  - a record carries the flag only after a grant;
  - a grant never moves a lot's age or participation.

  The decoding check runs with an `IGNITION` and decodes `headStartMask`.
- **Kit.** The operator stands in for Ignition on every pool, and the wiring check enforces it. The smoke run grants the pool-0 position's first lot 30 days. The mainnet gate gains an `Ignition` slot.
- **Rehearsal.** `pnpm testnet:dry-run` on a fork of LiteForge, with the smoke actions, ran 49 transactions: 85.3M gas, about 0.0017 zkLTC at 0.02 gwei.
  - The largest transaction is a ForgePool deployment at 12.48M.
  - The grant cost 70,132.
- **`pnpm check`:** 351/351 Forge tests, in a clean worktree.
- **Mutations:** 23 planted bugs, run in a separate worktree so the main tree never holds one. **All 23 are caught**, none needing a new test. They cover:
  - the grant's gates: any caller, a zero `IGNITION`, zero or uncapped seconds, a closed or listed position, a second grant, an empty or wholly frozen slot;
  - its write: no segment close at grant, every slot masked;
  - the mask's travel: a freed slot keeping the bit, a slice returning to a free slot dropping it;
  - the anchors: the mask read while inactive, the seconds dropped, the wrong flag bit, `measureSlot` without the slot anchor;
  - the measures: the head start ignored or applied to every lot, no stacking with First Flame, the flag leaking into the Ashfall clock;
  - the sale keeping the head start, and the kit without `IGNITION`.

## Consequences

- **ForgePool has every immutable hook ADR 0010 listed.** Deeds, Taps, source-lot additions, Kindling positions, First Flame and the head start are all built. Its remaining dependencies are modules at mined addresses: Ignition, Kindling, the compounder, the Deed market, the Vent and Relics.
- **Ignition owns the rest of the head-start rules:** the window, the first Deed per wallet, and the retained-value cap in LP terms. *Update:* Ignition is built (ADR 0023). It grants once per wallet, within 7 days of Kindling's close, to a lot opened from Ignition's close, worth at most the USDC kept. Cold Storage USDC counts at $1; pool-0 LP at its fair TWAP value. The seconds are the lot's open time less Ignition's start.
- **Not audited or deployed.**
