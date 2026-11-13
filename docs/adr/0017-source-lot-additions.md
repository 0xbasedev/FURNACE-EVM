# ADR 0017: Source-lot additions, the compounder's hook in ForgePool

Status: accepted for this repository. Not audited, not deployed.

## Context

**What the spec requires** (v5.5 §4, §7; `DECISIONS.md`; the config's `casting` and `forge.lots`):
- **Back to the source lot.** A Cast "returns to the source lot at that lot's age. Ember Vault and Cold Storage receive liquid EMBER instead" (§102).
- **No new slot.** "Source-lot compounding and compatible Casting increase their existing source cohort and do not consume another timestamp slot" (§80). The config says the same: `castLot: 'sourceLot'`, `entersAs: 'sourceLotAge'`, `compoundProvenance: 'sourceLot'`.
- **Provenance.**
  - "Only internally earned, unconsumed, source-identified reward receipts retain age. Tokens arriving from an external wallet are deposits" (§98).
  - "Internally earned source-lot additions retain provenance; external top-ups start their own actual-participation clock" (§118).
  - "Source-provenance compounds retain the source cohort, subject to closed-lot and spent-receipt checks" (`DECISIONS.md`).
- **Only an active source counts.** "Closed source lots are not resurrected with old age" (§98). "If the source is no longer compatible or active, the uncovered reward remains liquid" (§108). The config's execution policy sets `requiresActiveSourceLot: true`.
- **Fees.** "Claim and owner Compound remain 0%" (§78).
- **Consumers.** One receipt-consumption authority covers Claim, Stoke, Casting, emergency routes and Deed settlement (`CONTRACTS.md`). ADR 0013 requires Casting and Stoke into LP to go through a single consumer fixed before deployment.

**Why it must exist now.**
- ForgePool is immutable. Before this ADR, a pool could only take principal as a new lot at age 0 (`open`, `deposit`, Flow's `openFor`, `depositFor`).
- A Cast or a Stoke into LP built later would then have no lawful destination. It would either take a slot as a fresh lot, which the spec forbids, or need a migration.
- ADR 0010 listed source-lot additions among the pool's remaining hooks. ADR 0012 allowed them in the annex, because they add principal and are not exits.

**What the code already had.**
- `Lot` keeps financial age and actual participation in separate fields that share one `since` (ADR 0007).
- A cooling slice that returns to its parent merges into it at the parent's state (`_resume`).
- So an addition at a lot's own age is a head rewrite at now with a larger amount. Nothing is backdated: backdating would pay past intervals and break the records' time order (ADR 0005).

## Decision

**1. One immutable caller, `COMPOUNDER`.**
- ForgePool and its annex take a seventh constructor argument. The annex receives the pool's own, so their immutables stay equal (ADR 0012).
- It is the same address Flow names for the Compound waiver (ADR 0016): the single consumer that ADR 0013 requires.
- Only an LP pool may set one; any other pool reverts with `CompounderNeedsLp`. Single-asset pools pay liquid EMBER instead (§102).
- A zero `COMPOUNDER` means no addition is possible, by anyone.

**2. `addToLot(id, slot, amount)`.** It runs in the annex, and the pool keeps a delegating stub.
- **Who.** `COMPOUNDER` only (`NotCompounder`). `amount` must be nonzero.
- **Where.** The position must exist and be neither closed (`Closed`) nor listed (`Listed`).
  - The slot must hold an active head (`NotActiveLot`).
  - A slot that is empty, past 31, or wholly frozen in a cooling ticket refuses. Wholly frozen means its amount is 0 and the ticket holds the slot.
  - A lot only partly in cooling may grow: its active remainder is the source.
- **What.**
  - The lot's age and participation at now become the state of a new head at now, with the amount increased by exactly what was pulled from the compounder.
  - The Seal tag is the slot's, as for any head write. A running Seal's cohort keeps earning on the addition; a paused Seal tags nothing.
  - The Streak is unchanged.
  - No fee is charged or booked, so no burn credit can arise.
  - Active principal grows by the amount.
  - A bonus is diluted exactly as `deposit` dilutes it (ADR 0008).
- **Bounds.**
  - The lot's amount stays a `uint96`; a larger one reverts in the cast.
  - The lot's record count is held under `BOOST_RECORD_LIMIT`, as for BOOST's rewrites. That leaves the rest of the counter to the owner's own actions.
- **Event.** `AddedToLot(id, slot, amount)`.

**3. What the pool does not decide.**
- **The split.** The config says rewards "compound back INTO THAT LOT" that earned them. Settlement pays per position, though, so the split of a position's reward across its lots is the compounder's computation. The pool accepts any active slot the compounder names.
- **The rest of a Cast.** Whether a reward is internally earned, unconsumed and eligible, and the 25% match from the reserve, are the compounder's rules. So are the seven-epoch reservations and the refusal of a dry reserve. The pool only refuses a destination that is not an active lot.

**4. Provisional readings [P].** Each is a deploy blocker until the project owner confirms it.
- **[P] An addition may enter a running Seal's cohort.** "Retain the source cohort" (`DECISIONS.md`) reads that way. The alternative is to refuse additions into sealed slots while a Seal runs. The rule "later deposits never join a Seal" concerns deposits, which start their own lot.
- **[P] The compounder names the slot.** The pool does not check that the slot "earned" the reward; see 3.
- **[P] A listing refuses an addition.** The reward then travels with the Deed as an unclaimed credit, as a Stoke's does (ADR 0013).

## Size and gas

- **Size.**
  - ForgePool is 21,644 runtime bytes, 75 more than ADR 0016 left (2,932 under EIP-170).
  - Its initcode, which embeds the annex, is 37,091 of 49,152.
  - The annex grows from 12,290 to 13,988 bytes: it now compiles the head-write, pull and dilution helpers that the hook uses.
  - Storage is unchanged (`pnpm check:layout`).
- **Gas** (`pnpm gas`, isolated):

| Path | Gas |
|---|---:|
| `addToLot`, no bonus | 100,380 |
| `addToLot`, diluting a bonus across 32 lots (worst case) | 1,179,429 |

## Verification

- **Model.** `scripts/forge-model.ts` gains `addToLot`.
  - Nine new differential scenarios replay exactly against the contract. The contract and model states hash identically after every step, measures included. There are 52 scenarios in all.
  - The six scripted scenarios cover:
    - the lot's own age;
    - the refusals;
    - a partly cooling lot, a wholly frozen one, and the same lot after its lapse;
    - a Seal's cohort, a paused Seal and a completed one;
    - a listing, a sale with its 80% carry, and an emergency exit;
    - a single-asset pool;
    - 32 lots.
  - Three seeded random walks add additions among every other action, Deeds and Taps included.
- **Unit tests:**
  - the caller, including a zero compounder;
  - only LP pools taking one;
  - age, participation, Streak, fee, slot count and pull exactness;
  - measures counting only from the addition onward;
  - the Seal tag;
  - every refusal;
  - a partly cooling lot;
  - 32 lots;
  - dilution equal to a deposit's;
  - the amount width and the record limit;
  - the annex's immutables and a direct call to the annex.
- **Invariants.** The pool's handler makes additions among its other actions. A ghost check verifies that no successful addition moved its lot's age or participation, used a slot, booked a fee, or touched the Streak. Custody, conservation and measure monotonicity hold.
- **Kit.** The testnet kit passes the operator as pools 0 and 1's compounder and zero to pools 2 and 3, and its wiring check enforces that. The smoke run adds one lot through it.
- **Rehearsal.** `pnpm testnet:dry-run` on a fork of LiteForge, with the smoke actions, ran 44 transactions: 79.7M gas, about 0.0016 zkLTC at 0.02 gwei.
  - The largest transaction is a ForgePool deployment at 10.98M, up from 10.44M, because its initcode embeds the larger annex.
  - The smoke addition cost 98,917 gas.
- **Mutations:** 24 planted bugs, run in a separate worktree so the main tree never holds one. **All 24 are caught**, none needing a new test. They cover:
  - the caller: open to anyone, open to a zero compounder, a compounder on a single-asset pool, the annex or the immutable left without the compounder, a stub that does not delegate;
  - the refusals: a zero amount, a closed position, a listed one, an unbounded slot, an empty slot, the record limit;
  - the lot's state: a fresh age, fresh participation, a backdated head, a new slot instead of the source lot, a Streak reset;
  - the books: active principal not raised, a fee charged and booked, nothing pulled, the dilution dropped or wrong;
  - the kit: a compounder on every pool, or on none.

## Consequences

- **Casting and Stoke into LP now have their destination.** The compounder itself, its reservation from the match reserve, and its use of Flow's waiver are still unbuilt. The mainnet gate keeps its slot.
- **The pools' remaining hooks** are Kindling positions, First Flame and the head start (ADR 0011 §4).
- **Not audited or deployed.**
