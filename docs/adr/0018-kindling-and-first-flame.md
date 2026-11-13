# ADR 0018: Kindling positions and First Flame in ForgePool

Status: accepted for this repository. Not audited, not deployed.

## Context

**What the spec requires** (v5.5 §2, §3, §4; `DECISIONS.md`; `CONTRACTS.md`; the config's `kindling` and `ignition.founderBadge`):
- **Kindling.** After a successful Kindling, "90% of distributable LP is allocated pro-rata to contributor-owned auto-staked Deeds". "Entitlements are initialized in aggregate and materialized in bounded pages or on demand; finalization never loops over every contributor" (§63). The LP is EMBER/USDC (`polPair`), which Forge pool 0 stakes.
- **First Flame.** It "remains a wallet-bound founder record with the existing 15-day financial-Heat floor. Phantom age is never actual participation time for Ashfall, Seal membership, or rebate eligibility" (§49).
  - "Phantom founder age affects financial Heat only" (`DECISIONS.md`).
  - "Wallet Relics, Pyre, and First Flame do not transfer" (§84).
  - "Metadata never supplies financial age or active eligibility" (`CONTRACTS.md`).
  - The config sets `founderFloorCountsAsParticipation: false`.
- **The head start** is a separate mechanism: age dated to Ignition's start for the first Deed opened within 7 days, up to the value kept (§49). It is not built here; see Consequences.

**Two gaps, decided by the project owner** (November 2026):
- **The deposit fee on Kindling positions.** §78 exempts only Flow's same-route LP. §63's worked example reads as if no second fee applies. **Decision: Kindling positions pay the standard 1% deposit fee**, the literal §78.
- **What "15 days" means.** v5.5 calls it a "floor". v5.4 says a founder's stake "accumulates from day 15 instead of day 0" and that a founder's wallet "stays superior forever", and the config key is `phantomAgeBonusDays`. **Decision: an offset.** A founder's financial Heat reads the real age plus 15 days, capped like any age. It is exactly integrable with `HeatMath`.

**The rules ADR 0011 §4 already set for this hook:**
- `Position.founder` exists and is cleared at Deed settlement after the seller's segments close.
- Phantom age never enters `Lot.age`: the 80% carry would sell it, and nothing could remove it later.
- The measures read the flag from spare high bits of each record's Streak anchor.

## Decision

**1. Two immutables.** ForgePool and its annex take an eighth and a ninth constructor argument; the annex gets the pool's own.
- **`KINDLING`.** It is the only caller of `openKindling`. Only an LP pool may set one; any other pool reverts with `KindlingNeedsLp`. The testnet kit sets it on pool 0 only, where the Kindling LP is staked.
- **`FOUNDERS`.** It is the founder record that every pool reads: Ignition's First Flame badge, behind `IFounders.isFounder(wallet)`. Zero means nobody holds First Flame in that pool.

**2. `openKindling(owner, amount)`.** It is `KINDLING` only, in the pool, and it is `open` for `owner` with LP pulled from Kindling:
- the 1% deposit fee, booked like any deposit;
- `MIN_STAKE_LP`;
- age 0, a Streak from now, and nothing backdated (ADR 0014, ADR 0017).

Materializing positions lazily or in pages is Kindling's own design. Each call opens one position, so a contributor's Heat starts when its position exists.

**3. `refreshFounder(id)`.** Anyone may call it; it runs in the annex.
- It reads `isFounder(owner)` by staticcall. A revert, missing code, or anything other than exactly 32 bytes encoding `true` counts as no founder.
- If the answer differs from the position's flag, every active segment closes at now (`_rewriteActive` at full weight, ages unchanged), and then the flag flips. Each record segment therefore has one founder state, as ADR 0008 does for the bonus.
- An unchanged answer writes nothing.
- A closed position refuses with `Closed`.
- A listed position may be refreshed: its custody does not change. A sale clears the flag (ADR 0011), and the buyer's own record applies once refreshed.
- It returns the flag and emits `FounderSet(id, founder)` when the flag changes.

**4. The measures.**
- **Where the flag lives.** It rides bit 39 of a record's `streak`, `ForgeMeasures.FOUNDER_FLAG`; a timestamp never reaches it. `_setHead` writes it into each superseded head, and `_anchor` writes it into the open head's anchor.
- **What it changes.** The segment's financial Heat reads `min(age + FIRST_FLAME_AGE, HEAT_AGE_CAP)`, in W and the sealed W.
- `FIRST_FLAME_AGE` is generated from `ignition.founderBadge.phantomAgeBonusDays` (15 days). The generator fails if the badge is disabled.
- **What never sees it:**
  - `Lot.age` and `participated`;
  - the Ashfall clock, which masks the flag off before reading the Streak;
  - [P] the Ashfall weight, Heat², which takes the real age;
  - the Seal cohort, Tap tiers, the Deed carry, and rebates (outside the pool).

**5. Provisional readings [P].** Each is a deploy blocker until the owner confirms it.
- **[P] The Ashfall weight excludes the offset.** "Phantom age is never actual participation time for Ashfall" covers eligibility for certain. Whether the Heat² weight of an eligible founder should read the offset is not stated, and excluding it is the conservative choice.
- **[P] The record is pulled.** First Flame follows the founder record only when someone refreshes the position, including just after it opens. The interface does that for founders. The alternative, reading the record inside every `open` and `deposit`, would add an external call to principal paths and bytes to a full pool.
- **[P] A founder's later deposits read the offset too.** v5.4 says "a founder's fresh stake accumulates from day 15". The flag is per position, and the position belongs to the founder's wallet.

## Size and gas

- **Size.**
  - ForgePool is 22,017 runtime bytes, 373 more than ADR 0017 left (2,559 under EIP-170).
  - Its initcode, which embeds the annex, is 38,523 of 49,152.
  - The annex is 14,726 bytes, and ForgeMeasures 6,246.
  - Storage is unchanged (`pnpm check:layout`): `founder` already existed.
- **Gas** (`pnpm gas`, isolated):

| Path | Gas |
|---|---:|
| `openKindling` | 136,783 |
| `refreshFounder`, rewriting 32 lots | 1,110,157 |

## Verification

- **Model.** `scripts/forge-model.ts` gains the founder flag on positions and records, the offset in its accrued W and in its record-based `measureSlot`, `openKindling` and `refreshFounder`.
  - The scenario words carry the flag.
  - Eight new differential scenarios replay exactly, with the state hash, W and the Ashfall weight compared after every step. There are 60 scenarios in all.
  - The scripted ones cover:
    - twins differing only in First Flame;
    - a revoke, a refresh while listed, a sale clearing the flag, and a refresh by a founder buyer;
    - an emergency exit;
    - a Seal under First Flame;
    - Kindling positions with the fee and the minimum;
    - a single-asset pool.
  - Three seeded random walks refresh founders and open Kindling positions among every other action, including Deeds, Taps and source-lot additions.
- **Unit tests:**
  - the fee and the pull from Kindling, nothing backdated, and the caller and zero-address checks;
  - LP pools only for Kindling, while any pool may name a founder record;
  - W exactly from day 15, with equal S, ages, participation and Ashfall weight;
  - the cap;
  - the sealed W;
  - revoke, sale, refresh, and closed;
  - a reverting, codeless or malformed record counting as none;
  - the annex's immutables.
- **Invariants.**
  - The pool handler refreshes founders and opens Kindling positions.
  - A new invariant checks that every record carries the founder flag of its start, and that the flag never changes inside a record segment or under an active head.
  - The Streak-anchor invariant masks the flag.
  - The decoding check, `ForgeViewTest`, now runs with a founder record.
- **Kit.**
  - A `TestnetFounders` stand-in is the founder record of all four pools, and `KINDLING` is the operator on pool 0 only. The wiring check enforces both.
  - The smoke run opens a Kindling position, marks the operator a founder and refreshes.
  - The mainnet gate gains a `Founders` slot.
- **Rehearsal.** `pnpm testnet:dry-run` on a fork of LiteForge, with the smoke actions, ran 48 transactions: 83.4M gas, about 0.0017 zkLTC at 0.02 gwei.
  - The largest transaction is a ForgePool deployment at 11.99M, up from 10.98M, because its initcode embeds the larger annex.
  - On the fork, `openKindling` cost 185,523 gas and `refreshFounder` 213,782.
- **`pnpm check`:** 337/337 Forge tests, in a clean worktree.
- **Mutations:** 24 planted bugs, run in a separate worktree so the main tree never holds one. **All 24 are caught**, none needing a new test. They cover:
  - the measures: the offset ignored or always applied, the flag leaking into the Ashfall clock, the Ashfall weight or participation;
  - the anchors: a record or the head anchor dropping the flag;
  - the refresh: no segment rewrite, a closed position allowed, the record ignored, a malformed answer accepted, a reverting record propagating, a sale keeping the flag;
  - Kindling: open to anyone, open to a zero `KINDLING`, fee-free, a zero owner, on a single-asset pool;
  - the wiring: the annex or the immutable without the founder record, the generated offset zero or 14 days;
  - the kit: Kindling on every LP pool, no founder record.

## Consequences

- **The pools' remaining immutable hook is the head start.**
  - It must be scoped to the principal present when it is granted, so later deposits cannot reuse it (§49). The flag and the amount already exist; the per-lot scoping is unbuilt.
  - It needs Ignition's retained-value record.
- **Kindling itself is unbuilt:** the aggregate settlement, lazy entitlements, the GenesisFeeEscrow and the LP sink. So is Ignition's founder record. Both are mainnet gate slots.
- **The deployment-verification list gains `KINDLING` and `FOUNDERS`** for every pool and its annex.
- **Not audited or deployed.**
