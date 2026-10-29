# ADR 0006: Seals (Conviction tracks)

**Status:** Accepted; provisional where marked [P].
**Date:** 2026-10-29 · **Config:** v5.5.0 · **Code:** `ForgePool.sol` (Seal state), `ForgeMeasures.sol` (sealed measures), `ForgeEmissions.sol` (escrow) · **Reference:** `scripts/forge-model.ts`, `scripts/settlement-model.ts`

## Context

Spec v5.5 §10 and the config (`forge.convictionTracks`, `execution.seals`) describe Seals:
- **Terms and bonuses:** 30/90/180/365-day terms with +0.15/.25/.35/.50 marginal bonuses.
- **Membership:** fixed to the committed cohorts. Later deposits cannot join.
- **Pause:** a pending cooling request pauses accrual and extends the term.
- **Early exit:** an actual withdrawal forfeits only the unvested escrow, routed 50/25/25.
- **Completion:** a completed term pays its funded escrow into Capstone. There is no second mint at vesting.
- **Epoch measures:** `B_i = ∫ sealed s·b dt` and `C_i = ∫ sealed s·h·b dt`.
- **Escrow:** `min(⌊bucket·C_i/C⌋, ⌊L·B_i/W⌋)`. The unused bucket returns to Heat.

The canonical `settleBaseEpoch` is the oracle for the budget and payout math.

The Mantle's `DISTRIBUTOR` is immutable (ADR 0005), so Seal escrow had to be built into `ForgeEmissions` before any deployment.

## Decisions

**1. Seal state lives in ForgePool,** because custody events drive it. All of it is local storage writes; no exit path gains an external call.
- **`seal(id, track)`:**
  - Owner only. The position must be open, have no pending ticket, no active Seal, and active lots.
  - The cohort is the position's used slots at that moment.
- **Storage:**
  - One `Seal` struct per Seal, in one slot: track, status, start, pausedAt, pausedSeconds, endedAt, cohortMask.
  - `Position.sealCount` takes the 8 spare bits of an existing slot.

**2. Tags in the checkpoint records.**
- `Lot` and `Record` carry `seal`: the index of the Seal the lot earns under from `since`, or 0.
- `Lot` stays exactly one storage slot: the record counter narrows from uint32 to uint24, which still allows 16.7M records per slot.
- Every head write takes its tag from `_tag`: the running Seal's index for cohort slots, else 0.
- Extra rewrites happen only at three transitions. A rewrite at the same instant overwrites in place.
  1. A Seal starts.
  2. The first pending request pauses it. Its frozen heads lose the tag.
  3. The last resolution resumes it, at the resolution's time. That time is back-dated for a lapse, and the term extends by the pause.
- **Membership:**
  - Top-ups land in free slots outside the cohort and are never tagged.
  - A slice from a cohort slot that returns to a new slot joins the cohort: sealed capital stays sealed.

**3. Ends need no lot writes.**
- **Completion:** due at `start + term + pausedSeconds`.
  - `_sync` resolves lapses first, then completes a due Seal back-dated to its due time.
  - This order is safe: a running Seal has no pending ticket, and a paused one cannot complete.
- **Forfeit:** an executed withdrawal or an emergency exit forfeits at that moment. An open pause is closed at the forfeit.
- **Clipping:** measures clip every tagged segment at its Seal's end, so old tags never overpay.
- **Status view:** `ForgeEmissions.sealStatus` reads a running Seal past its due time as Completed without a pool sync. Nothing can change that outcome.

**4. Sealed measures.**
- `ForgeMeasures.slotMeasure` returns, per slot, the tagged stake-seconds `Ss` and Heat-seconds `Sw`, clipped and unscaled, next to S and W.
- The settlement page forms `B = Ss·b` and `C = ⌊Sw·b/RAY⌋` once per position-epoch.
- **[P] Flooring C once** makes it independent of how records subdivide the epoch. The canonical `segmentMeasures` floors per segment, so this is at most a few wei more exact.
- **[P] Reseal gap:** a new Seal starts at least one epoch after the previous one ended, so each position-epoch's bonus belongs to exactly one Seal.

**5. Escrow phase in ForgeEmissions.**
- The phases are `Measuring → Escrowing → Crediting`.
- When the totals are final:
  - `bucket = ⌊E·10%⌋`;
  - `flat = ⌊(E − bucket)·30%⌋`;
  - `L = E − bucket − flat`.
- Escrow pages visit ≤32 sealed positions each and set `min(⌊bucket·C_i/C⌋, ⌊L·B_i/W⌋)`.
- After the last escrow page, `heat = L + bucket − Σescrow`.
- With `C = 0` the phase is skipped, which gives the canonical 27/73.

**6. Escrow custody.**
- Each credit page mints ordinary rewards plus escrow in one `mintBase`, as the spec's "minted per epoch into escrow".
- Escrow follows its Seal's status at credit time:
  - **Running:** locked in `sealEscrow[pool][id][k]`.
  - **Completed:** to `capstoneOwed[pool][id]`.
  - **Forfeited:** routed 50/25/25 at once.
- `settleSeal(pool, id, k)` is permissionless. It releases a Seal's locked escrow once the Seal has ended.

## Provisional defaults

| Topic | Default here | Why |
|---|---|---|
| Vested escrow | Held in `capstoneOwed`, never liquid | Capstone is not built. The spec pays escrow into Capstone so the bonus never sells |
| Burn share (50%) | Held in `burnLane`; nothing is burned | A burn is irreversible, and Seal forfeits are not among the config's Ashfall sources, so `burnRegistered` would wrongly credit Ashfall. Which burn lane receives it is undecided |
| Match reserve share (25%) | Held in `matchReserve` | Casting and matching are not built |
| Sealed pot share (25%) | Held in `sealedPot[pool]` (it also receives the floor dust) | The config defines no stream period. This repo does not invent one |
| Partial withdrawal | Forfeits the whole Seal | The spec: "A Tap during an active Seal forfeits its unvested bonus." A normal withdrawal is no milder |
| New Seal while cooling | Not allowed | Simplest cohort definition: every used slot is an active lot |
| Reseal gap | One epoch after the previous Seal ended | One Seal per position-epoch |
| Seals per position | At most 255 | uint8 tag |
| C rounding | Floored once per position-epoch | Independent of subdivision |

## Before any deployment

`ForgeEmissions` is immutable, and the Mantle's `DISTRIBUTOR` is fixed at deploy time. Like Ashfall (ADR 0005), each of these must be inside `ForgeEmissions`, or wired into it, before deployment. None can be added later:
- **Capstone handoff:** moving `capstoneOwed` into each position's Capstone.
- **Forfeit consumers:**
  - the burn lane (and whether it registers its burns);
  - the match reserve (Casting);
  - the Sealed pot's stream to running Seals, once the config defines its period.
- **Keystone and Seal Scar** need Deeds and Relics. Today a position cannot change owner, so whole-term ownership holds trivially.

## Settlement fix found here: due lapses cost page budget

- **The problem:** a measure page pokes each position it enters, and that poke resolves every lapse due by now. Before this change the poke was not charged to the page budget.
  - Thirty-two positions with 8 due lapses each could put about 1M gas each into one page, approaching the block limit.
  - Seal unpause retags add to that cost.
- **The fix:**
  - The page reads `pool.dueLapses(id)` and charges `LAPSE_UNITS` = 64 **[P]** per due lapse before entering a position.
  - A sync that does not fit waits to be the next page's first work, so a page pays for at most one oversized sync.
- **Proof:**
  - `Seals.t.sol` builds that worst case. It settles in 32 pages, the heaviest about 1.5M gas.
  - The `lapseBudget` differential scenario checks the page split against the model.

## Gas

Measured with `pnpm gas` (`forge test --isolate`: every call is its own transaction, so slots start cold). Optimizer runs 500, solc-js 0.8.28.

| Path | Gas |
|---|---:|
| `seal`, 32 lots (tags every lot) | 1,161,313 |
| `requestCooling` 100% + pause, 32 lots, a day after sealing | 2,134,134 |
| `cancelCooling` + resume retag, 32 lots | 1,409,392 |
| Escrow page, 32 sealed earners | 467,302 |
| Credit page, 32 sealed earners (ordinary + escrow, one mint) | 2,271,698 |
| `settleSeal` (forfeit routing) | 100,952 |
| Heaviest measure page, 32 positions × 8 due lapses (32 pages) | 1,490,044 |

- **The pause is nearly free:** it rides on the freeze's own head writes. The same 100% request without a Seal costs 2,098,958 gas (ADR 0004), so the pause adds about 1.7%.
- **The resume retag and `seal` itself** each write up to one head per cohort lot: about 1.2–1.4M gas on a 32-lot position.

## Verification

- **Custody differential** (21 scenarios: 5 Seal-specific, plus Seals in all 6 random walks).
  - After every action, a keccak of the full state, including Seal state and every head's tag, must equal `forge-model.ts`.
  - The model accrues sealed stake-seconds and Heat-seconds **independently of the records**, from its own Seal state. The contract's record-based sums must match them.
  - Named cases:
    - a pause that extends the term;
    - a lapse whose back-dated unpause moves the due time;
    - a forfeit by execute;
    - cohort join and non-join;
    - top-ups;
    - a forfeit while paused by emergency exit;
    - every guard: gap, active, pending, closed, unknown track, nothing to seal.
- **Settlement differential** (17 scenarios).
  - Every budget, escrow and payout equals canonical `settleBaseEpoch` with nonzero B and C, asserted at generation time.
  - Cases:
    - the cap binding (a small 30-day sealer);
    - the candidate binding (two sealers alone);
    - a late credit after completion;
    - forfeits by execute and by emergency exit, with late credits routed directly;
    - a pause inside an epoch;
    - the lapse-budget page split.
- **Invariants:**
  - **Custody suite:** a running Seal is paused exactly while cooling is pending; only the latest Seal tags heads, and only on its cohort; the cohort is real history; sealed measures never exceed measures.
  - **Settlement suite** (`fail_on_revert`):
    - EMBER held equals unclaimed + pending claims + Seal escrow + Capstone ledger + burn lane + match reserve + Sealed pots;
    - escrow ≤ bucket;
    - sealed earners ≤ earners;
    - every settled epoch's base is minted or released.
- **Unit tests** (`Seals.t.sol`): cap and candidate binding, pause extension and back-dated completion, top-ups, forfeit routing, vesting with late credits, emergency exit, guards, the 27/73 path, near-uint96 stakes.
- **Mutations:** each of these 15 planted Seal bugs fails the suite. The 13 settlement mutations of ADR 0005 were re-run on this code and still fail it.
  - a top-up joins the Seal;
  - a cooling request does not pause it;
  - the pause does not extend the term;
  - a lapse's unpause is not back-dated;
  - completion is not back-dated;
  - tagged segments are not clipped at the Seal's end;
  - C is formed from stake instead of Heat;
  - the cap uses the post-return Heat budget;
  - running escrow becomes claimable;
  - a forfeit vests like a completion;
  - there is no gap between Seals;
  - an executed withdrawal does not forfeit;
  - an emergency exit does not forfeit;
  - a returning cohort slice leaves the cohort;
  - due lapses cost the page nothing.

## Consequences and limits

- **Size:** ForgePool is 23,534 bytes (optimizer runs 500), about 1 KB under EIP-170.
  - Taps, Deeds or the Capstone Heat bonus will need a structural split, for example a separate module for transfers. Lowering optimizer runs further buys little.
- **Retag gas:** `seal` and the last resolution each pay for up to 32 head writes, about 1.2–1.4M gas on a 32-lot position. The first request barely pays for its pause, which reuses the freeze's writes.
- **Not audited or deployed.** Matching the models proves consistency with this ADR, not canonical conformance of any [P] rule.
