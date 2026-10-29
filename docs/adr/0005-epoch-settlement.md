# ADR 0005: Base epoch settlement

**Status:** Accepted; provisional where marked [P].
**Date:** 2026-10-28 · **Config:** v5.5.0 · **Code:** `contracts/src/forge/ForgeEmissions.sol`, records in `ForgePool.sol` · **Reference:** `scripts/settlement-model.ts`

## Context

Spec v5.5 §10 and `CONTRACTS.md` ("Epoch implementation chosen") pick time-integrated measures per daily epoch, settled in bounded on-chain pages:
1. Append authoritative checkpoint state.
2. Freeze the epoch's budget.
3. Sum measures with a deterministic cursor over ≤32 lots per page, so a duplicate page cannot count twice.
4. Pay from final totals.
5. Exits never wait on any of this.

The custody PR stored one *cumulative* S/W per position. A position touched after an epoch ended, but before that epoch was settled, would lose its boundary value, and rebuilding it would take an unbounded catch-up loop on the user's next action. ADR 0004 left the read path to this ADR.

## Decisions

**1. Checkpoint records in `ForgePool`** (see ADR 0004 §3).
- Each slot keeps a head plus an append-only history of superseded heads. Its record count lives in the head, so no array-length slot is written.
- A change at the same instant overwrites in place.
- `epochMeasure(id, t0, t1)` integrates any past interval exactly. It reverts unless the position is synced past `t1`, so every lapse due by then has its back-dated record.
- The refactor reproduces all 16 custody scenarios to the same state hashes as before.

**2. `ForgeEmissions` is the Mantle's distributor and the Forge's index.**
- Immutables: the Mantle, EMBER, its `START`, and the four pools in config order. Their `IS_LP` flags are checked against the generated config.
- The pools never reference it.
- No owner, pause or upgrade path. Every step is permissionless.

**3. Opening an epoch.**
- `openEpoch()` handles the next epoch, once the Mantle has finalized it.
- It splits the Mantle's **global** base by alloc points (1000/400/400/200), with floors.
- It admits each pool's share as `accruedPoolBudget(target, occupied(e), EPOCH)`, where `occupied` comes from the pool's occupancy log at the epoch bounds.
- Everything not admitted, plus the split's floor residue, goes back through one `releaseBase`. ADR 0003 releases never re-issue it.
- `N` is fixed to the pool's position count at that moment.
- A pool with nothing admitted is done at once.

**4. Measure pages are bounded and resumable.**
- `advance(e, i)` walks position ids with a monotone cursor. On entering a position it calls `pool.poke(id)` once, resolving lapses due by now.
- It then measures the position slot by slot with `pool.measureSlot`.
- A page examines at most 32 lot slots and **at most `SEGMENTS_PER_PAGE` = 256 record segments [P]**.
- A position or a slot that does not fit resumes on the next page. Progress is `{id, slot, segment, partial S, partial W}`, kept in memory during a page and stored once at its end.
- Resuming is exact:
  - records are append-only;
  - lapses due by the epoch end were resolved on entry;
  - anything written later starts after the epoch.
- Earners (`S_i > 0`) are stored and added to the totals. Each position is counted exactly once.
- **Due lapses cost budget.** Entering a position syncs it, and the sync resolves every lapse due by now. A page therefore charges `LAPSE_UNITS` = 64 **[P]** per due lapse (`pool.dueLapses`) before entering the position.
  - A sync that does not fit waits to be the next page's first work, so a page pays for at most one oversized sync.
  - Without this charge, 32 positions with 8 due lapses each could have put about 1M gas each into one page (found while building Seals; ADR 0006).

**Why resumable: record spam.**
- An owner can pile records into one slot within an epoch, for example by requesting 1 wei and cancelling each second; the slice merges back each time.
- That costs the attacker about **179k gas per record** (each call its own transaction).
- Before this change, a page measured a whole position at once. 1,200 records made one **20.9M-gas** page, and roughly 3,000 would exceed a block and freeze that pool-epoch for everyone.
- Now the same epoch settles in 5 pages, the heaviest 5.3M gas (`SettlementGrief.t.sol`, isolated).
- The keeper spends about 21k gas per spammed segment against the attacker's 179k, so the spam costs its sender several times what it costs settlement.

**5. Budget.**
- When the cursor reaches `N`: `bucket = ⌊E·10/100⌋`, `flat = ⌊(E−bucket)·30/100⌋`, `L = E − bucket − flat`.
- If any lot was sealed (`C > 0`), escrow pages set each sealed position's capped escrow first (ADR 0006). Then `heat = L + bucket − Σescrow`.
- With no Seals the whole bucket returns to Heat. That is the canonical 27/73 split (spec §10: "With no eligible Seals it yields 27/73").
- If `S == 0`, `E` is released.

**6. Credit pages, with one mint per page.**
- Each earner gets `⌊flat·S_i/S⌋ + ⌊heat·W_i/W⌋` added to `unclaimed[pool][id]`. Its escrow, if any, goes to its Seal (ADR 0006).
- The page's sum, escrow included, is minted once, with `mintBase(e, this, sum)`.
- When the last earner is credited, the floor residue `E − paid` is released, tagged with its epoch and pool (`ResidueReleased`).
- Every base wei of a fully settled epoch is therefore minted or released. The invariant suite checks this.
- Claims stay O(1) however long a holder is away.

**7. Claims (spec §11).**
- `requestClaim` (owner only) snapshots `unclaimed` and starts the 24h timer from `cooldowns.claim`.
- Rewards credited later stay unclaimed: they never join a pending claim.
- `executeClaim` pays the snapshot to the current owner. No fee. One pending claim per position.
- Closed (exited) positions keep their earned rewards.

**8. Generator gates.**
- Generation fails unless the config selects `weightBasis = timeIntegratedPerLot`, `budgetAccrual = onlyWhilePoolHasActiveStake`, `aggregateAuthority = onchainCheckpoints`, `exitsDependOnSettlement = false` and `snapshotAtRequest = true`, with exactly four pools.
- It emits the pool weights and kinds, `CLAIM_SECONDS` and `SETTLEMENT_MAX_LOTS_PER_PAGE`.

## Provisional defaults

| Topic | Default here | Why |
|---|---|---|
| When rewards are minted | At credit time, one mint per credit page; held by `ForgeEmissions` until claimed | Bounded Mantle calls; claims O(1). Supply counts credited-but-unclaimed rewards |
| Floor residue | Released at the end of the credit pass, with an event | Exact and never re-paid; the alternative leaves dust reserved forever |
| Split residue (alloc-point floors) | Released at `openEpoch` | No pool can claim it |
| Keepers | Permissionless, with no bounty | No bounty source is defined yet. Users can page their own epochs |
| `N` | Fixed at `openEpoch` | Positions opened after the epoch ended measure zero |
| Claim timer | Fixed 24h | Relic perks (20h/16h/12h) arrive with Relics |
| Segment budget per page | 256 | About 5.3M gas worst case per page (isolated), with headroom under a block |
| Charge per due lapse | 64 units | A lapse rewrites up to 32 heads; one oversized sync per page at most |

## Not in scope (later PRs)

**Before any deployment, `ForgeEmissions` itself must gain Ashfall distribution**, plus the Seal escrow consumers listed in ADR 0006. The Mantle's `DISTRIBUTOR` is immutable, and only it can call `mintAshfall` or `rollAshfall`. So none of these can be bolted on later as a separate contract. Today any Ashfall budget simply stays reserved in the Mantle. It is zero until burn registrars exist.

- **Seals** are built (ADR 0006).
- **Compound and Stoke.**
- **Casting and matching.** With no funded match reserve the spec keeps rewards liquid ("No prefunded quote means no match"), so paying liquid now conforms.
- **Ashfall distribution** (Heat²), **Quote yield**, **Relic perks**, **Deeds**.

## Gas (forge, optimizer 1,000 runs, solc-js 0.8.28)

| Path | Gas |
|---|---:|
| `openEpoch` (4 pools) | 238,259 |
| Measure page: 1 position with 32 lots | 582,930 |
| Measure page: 32 positions with 1 lot each | 3,054,876 |
| Heaviest page of a record-spammed epoch (1,200 records in one slot) | 4,702,133 |
| Credit page: 1 earner | 124,875 |
| Credit page: 32 earners, one mint | 948,151 |
| `requestClaim` | 35,279 |

- Every `measureSlot` call now pays a DELEGATECALL into `ForgeMeasures` (ADR 0004 §3). That adds about 6% to a page that measures 32 lots of one position, and about 1% to other pages.

- Total work grows with population, as the spec says. Settling an epoch takes about ⌈slots/32⌉ measure pages plus ⌈earners/32⌉ credit pages per pool, plus one page per 256 extra record segments.
- **The cursor walks every position id ever opened.** That includes closed and emptied positions and dust positions in the single-asset pools, so per-epoch work grows with the pool's *history*, not only its live stake. Each such position costs a `poke` and a mask read: cheap, but unbounded over time. Pruning closed positions, or indexing live ones, is a follow-up.

## Verification

- **Differential:**
  - 17 scenarios (14 scripted, 3 seeded random walks) replay custody and Seal actions in four pools, Mantle finalization, epoch opening, measure, escrow and credit pages, `settleSeal`, and claims.
  - After every action, a keccak of the settlement state must equal `SettlementModel`'s, and reverts must match. The state covers the pools' occupancy, every Mantle budget, every pool-epoch, every measure, every credit and claim, and EMBER balances.
  - The model mirrors the contract's records and page loop, segment for segment, so page progress is compared too.
  - When each position finishes, its record-based sum must equal the model's own epoch-split accrual. Each budget and payout is asserted equal to canonical `settleBaseEpoch` at generation time.
  - Named cases:
    - a position touched after its epoch ended but before its page ran;
    - a lapse due inside an epoch with no transaction;
    - partial occupancy plus an empty pool;
    - an emergency exit mid-epoch, still credited;
    - a keeper five epochs late;
    - claim snapshots;
    - pages split by lot count;
    - record spam that resumes across pages;
    - due lapses that split a page (`lapseBudget`);
    - the Seal cases listed in ADR 0006.
- **Invariants** (48 runs × 120 calls, `fail_on_revert` on): a random keeper finalizes, opens and pages between random custody and claim actions.
  - `minted + released ≤ base`, and `= base` once all pools are done;
  - `admitted ≤ target` and `paid ≤ admitted`;
  - each position counted at most once;
  - EMBER held equals unclaimed plus pending plus every Seal escrow and forfeit ledger;
  - EMBER supply equals the Mantle's minted total;
  - emergency exit always works.
- **Mutation checks:** all 13 fail the suite.
  - a finished position is counted again;
  - a resumed slot restarts from its first segment;
  - progress is not kept between pages;
  - a page ignores the segment budget;
  - the measure runs to the touch time instead of the epoch end;
  - admission ignores occupancy;
  - the unused bucket is kept;
  - a pending claim absorbs later credits;
  - a lapse record is not back-dated;
  - a head is overwritten without pushing history;
  - the same-instant shortcut is inverted;
  - a page measures without syncing;
  - the Heat share is weighted by stake.
- **Stake tokens are mocks in every pool,** ember-single included, which really stakes EMBER. These tests do not cover the EMBER-in/EMBER-out pool.

## Consequences and limits

- **Keeper liveness:** rewards wait for pages, but nothing else does. Principal paths never call `ForgeEmissions`.
- **Supply timing:** EMBER supply includes credited rewards still held by `ForgeEmissions`, which is what the Mantle's ledger counts as minted.
- **Not audited or deployed:** none of this is. Matching the model proves consistency with this ADR, not canonical conformance of any [P] rule.
