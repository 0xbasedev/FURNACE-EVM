# ADR 0026: Casting and the idle auto-pair, the Compounder

Status: accepted for this repository. Not audited, not deployed.

## Context

**What the spec fixes** (§7, §13, §16; `DECISIONS.md` §3; config `forge.casting`, `execution.casting`, `execution.matching`, `fees.liquidityLane`):
- **Casting** targets 25% of *ordinary base rewards after the Conviction allocation*, on compatible active LP lots.
  - It returns to the source lot at that lot's age.
  - Ember Vault and Cold Storage receive liquid EMBER instead.
  - Ashfall, ASH, Quote yield, Conviction escrow and the Sealed pot are never cast.
- **The cast LP is 100% the user's.** The quote side is a disclosed reserve subsidy, never inflation.
- **Matching budgets:**
  - they are frozen per epoch, pool and quote asset from unencumbered balances;
  - automatic Casts are pro-rata to eligible ordinary-base demand;
  - a reward unit receives at most one match;
  - no mint fills a dry reserve.
- **Reservations last seven epochs.**
  - Expiry releases only the unspent quote, never the reward.
  - An inactive source leaves the reward liquid.
  - A stale oracle or a failed safe execution releases nothing to the caller.
- **The idle auto-pair** is the only path to permanent LP.
  - After seven idle epochs, unreserved quote pairs with funded Treasury match-seed EMBER, and the LP is irretrievable.
  - It never uses reserved quote, principal, refundable fees or unpaid rewards.
  - An insufficient seed waits.
  - Matching and idle pairing are accounted apart, and the reserve's quote is not Treasury-spendable.
- **The hooks already built:**
  - the Vent's liquidity lane, drawn only by its `COMPOUNDER` (ADR 0020);
  - ForgeEmissions' match ledger (25% of Seal forfeits), pulled only by its `MATCH_RESERVE` (ADR 0007);
  - the LP pools' `addToLot`, callable only by their `COMPOUNDER` (ADR 0017);
  - the permanent sink (ADR 0021).

**What was missing:** a contract to fill those slots, and a way to keep the Cast share out of every other consumer's reach. Claim and the Capstone took all of `unclaimed` (ADR 0013), so a Cast share would have been claimable twice.

## Decision

**1. ForgeEmissions withholds the Cast share at credit.**
- **Which pools cast.** A pool casts when it is an LP pool whose `COMPOUNDER` is ForgeEmissions' `MATCH_RESERVE`. That is read once at construction into `CAST_POOLS`. Any other pool pays its credit liquid, exactly as before.
- **The share.** On a casting pool, `_credit` withholds `⌊ordinary · CASTING_LP_SHARE_PCT / 100⌋` of each position's ordinary credit, the flat share plus the Heat share. The pool-epoch's `castTotal` is the sum.
  - Escrow and Ashfall are untouched.
  - Nothing is stored per position: `castOf(epoch, pool, id)` recomputes the same floor from the stored measures once the pool-epoch is Done.
- **`takeCast(epoch, pool, id, used)`** consumes a share.
  - Only `MATCH_RESERVE` may call it, once per position-epoch, with `used ≤ share`.
  - It sends `used` EMBER and returns the rest to the position's `unclaimed`.
- **ForgeEmissions stays the single receipt authority** (`CONTRACTS.md`). A Claim or a Stoke can take only what Casting leaves.

**2. `contracts/src/match/Compounder.sol`** fills both slots: every LP pool's, Flow's and the Vent's `COMPOUNDER`, and ForgeEmissions' `MATCH_RESERVE` (§5).
- **Shape:** no admin, pause, upgrade or rescue; `ReentrancyGuardTransient`, `SafeERC20`, and exact-amount pulls.
- **Inventories, accounted apart:**
  - per pair, `free` (unreserved) and `reserved` quote;
  - a shared `seed` of EMBER.
- **Feeding them:**
  - `refill(j)` draws the Vent's whole liquidity lane into `free`;
  - `pullForfeits()` takes ForgeEmissions' match ledger into the seed;
  - `fundSeed(amount)` takes EMBER from anyone.
- **`freeze(epoch, pool)`**, once, inside the window, after the pool-epoch is Done:
  - it refills, then prices the demand at the pair's 1800 s TWAP: `need = ⌊D · twap / 2¹¹²⌋`;
  - it reserves `B = min(free, need)`.
- **`cast(epoch, pool, id)`**, by anyone, inside the window:
  - a share `c` is covered `e = ⌊c · B / need⌋` EMBER against `q = ⌊B · c / D⌋` quote;
  - the spot must sit within the Vent's 2% band of a fresh TWAP;
  - the Compounder takes the most the pair accepts at the spot ratio, `eUsed`, adds liquidity, and calls `addToLot` on the source lot;
  - the unpaired EMBER returns to the owner through `takeCast`, and the unpaired quote returns to `free`.
- **What returns whole, as a `CastReleased` with its reason:**
  - an uncovered share;
  - a closed position;
  - no qualifying lot;
  - a share too small to form LP;
  - an expired window.
  - A listed position waits instead.
- **`close(epoch, pool)`** returns an expired budget's unspent quote to `free`, once.
- **`autoPair(j)`** runs after `IDLE_EPOCHS_BEFORE_AUTO_PAIR` epochs with no Cast on the pair:
  - it pairs `free` with the seed at the spot ratio inside the band;
  - the LP goes to the sink;
  - `reserved` is never touched.

**3. The generator.**
- **Constants:** `CASTING_LP_SHARE_PCT` (25), `MATCH_RESERVATION_EPOCHS` (7) and `IDLE_EPOCHS_BEFORE_AUTO_PAIR` (7).
- **Policy asserts fail the build** unless the config keeps:
  - ordinary base as the only class, with the post-Conviction denominator;
  - liquid single-token pools;
  - user-owned LP, returned to the source lot at its age;
  - Cast priority, pro-rata epoch budgets and one use per reward;
  - a quote-only expiry;
  - an idle pair from unreserved quote and treasury seed, with burned (permanent) LP;
  - full-range permanent LP;
  - the Capstone fallback.

**4. The kit.**
- The Compounder deploys at a CREATE3 address in every mode. The permanent sink now deploys in every mode too.
- Pools 0 and 1, Flow and the Vent name the Compounder as `COMPOUNDER`, and ForgeEmissions names it as `MATCH_RESERVE`. The wiring check requires all of it, `CAST_POOLS == 3` and the Compounder's own addresses.
- The smoke run no longer adds to a lot as the operator. It refills BlastPool's lane, and the operator funds 100 test EMBER of seed, standing in for the Treasury's match-seed bucket.

**5. Provisional readings [P].** Each was taken as recommended, per the owner's standing rule. Each is a deploy blocker until confirmed, and listed in [PROVISIONAL.md](../PROVISIONAL.md).
- **[P] One contract fills two slots,** `Compounder` and `MatchReserve`. The match ledger's EMBER and the matching quote then sit with the one consumer that can spend them.
- **[P] A pool casts only when it is an LP pool naming ForgeEmissions' `MATCH_RESERVE` as its `COMPOUNDER`.** Elsewhere the whole credit is liquid. Its share is the floor of 25% of each position's ordinary credit, withheld when credited.
- **[P] A withheld share becomes liquid only through the Compounder:** cast short, released, or expired. Anyone may trigger it, so the owner always can.
- **[P] A budget is priced at the pair's 1800 s TWAP when it is frozen.** A stale or missing oracle defers the freeze, and an uncovered share returns liquid.
- **[P] A Cast executes at the spot ratio inside the Vent's 2% band of a fresh TWAP.** What the pair does not take returns, EMBER to its owner and quote to the unreserved inventory. There is no other slippage bound, because adding liquidity sells nothing.
- **[P] Anyone may cast, with no keeper tip.** A Cast is automatic (§7), and AutoStoke's tip covers only Stokes (§18).
- **[P] The source lot** is the position's youngest active lot whose age now is at least the time since the epoch ended, among those that can still take an addition; with none, the share returns liquid. Per-lot reward shares are not recorded, so for a multi-lot position this never ages a reward into older Heat. It is exact for a single lot.
- **[P] A listed position's Cast waits** until the listing ends or the window passes, because `addToLot` refuses a listed position (ADR 0017).
- **[P] A reservation ends `MATCH_RESERVATION_EPOCHS` epochs after its earning epoch ends.**
- **[P] The match ledger's EMBER joins the seed** beside the Treasury's match-seed funding. Anyone may fund the seed, and nothing withdraws it.
- **[P] A pair is idle** after `IDLE_EPOCHS_BEFORE_AUTO_PAIR` full epochs since its last Cast, with deployment counting as epoch 0. The auto-pair then pairs as much unreserved quote as the seed covers, and the rest waits. It has no throughput chunk beyond the band, and it does not end the idle state.

**6. Not built here (seal step 4b).**
- Stoke into LP: the remainder budget's source-bound entitlements, an ordinary-base `matchable` ledger, and the consented selling zap through Flow's waiver.

## Size and gas

- **Sizes:**
  - the Compounder is 13,405 runtime bytes;
  - ForgeEmissions grows from 18,165 to 19,636 bytes (4,940 under the limit).
- **Gas** (isolated):

  | Call | Gas |
  |---|---|
  | `freeze` (with its refill) | 195,665 |
  | `cast` (poke, lots read, pair, `addToLot`) | 356,535 |
  | `autoPair` | 157,947 |

## Verification

- **Model.** `scripts/compounder-model.ts` (BigInt) runs on the pair model and the pool model, with a cast ledger and a Vent lane.
  - **The replay.** `Compounder.t.sol` replays every scenario exactly on two real EmberPairs (6- and 18-decimal quotes) and two real ForgePools. It checks every output, every revert selector, and a hash of the whole state after every step: reserves, inventories, budgets, ledger shares, unclaimed, and every lot's amount and age.
  - **Ten scenarios:**
    - full coverage;
    - partial and dry coverage, and dust;
    - price drift both ways, the band and a stale TWAP;
    - the source lot (a later deposit is not one; a cooling lot is skipped);
    - closed, listed and expired positions, including the window's last second;
    - the idle auto-pair with a short seed;
    - four seeded walks of twelve epochs each.
  - **Totals:** 55 casts, 75 shares returned liquid (every reason occurs), 72 freezes and 3 auto-pairs. The model also checks its own books after every step.
- **The settlement differential** gains the withholding: 23 scenarios, three new, `castWithheld` and two seeded `castWalk`s, with `takeCast` in any split.
- **Unit tests:**
  - a covered Cast lands in the source lot at its age;
  - a dry reserve returns the whole share and pairs nothing;
  - a short budget is pro-rata;
  - the source lot is the youngest open at the epoch's end;
  - a stale oracle or an out-of-band spot releases nothing;
  - expiry returns the share and the quote once;
  - the auto-pair never spends reserved quote;
  - only LP pools naming the match reserve cast;
  - `takeCast`'s consumer, bound and once-only rules;
  - the constructor's refusals.
- **Invariants** (`CompounderInvariant.t.sol`, 128 runs × 64 calls):
  - quote held equals `free + reserved`, and `reserved` equals what the budgets still hold;
  - no budget holds more than it reserved, or reserved more than its demand needed;
  - EMBER held equals the seed;
  - no LP stays.
  - **The handler also asserts:**
    - every consumed share is paired or returned, exactly;
    - no Cast uses more than its budget covers;
    - the auto-pair leaves reserved quote alone, runs only when idle, and its LP reaches the sink.
  - **Coverage** (counted by a temporary probe): Casts in 256 of 258 runs (2,650 in all), releases in 190 (340, 102 of them dry), and auto-pairs in 256 (898).
- **Kit.** The first-epoch test finds pool 0's withheld share and pool 2's none. On a fresh TWAP the Compounder freezes a budget from the smoke run's fees and casts the share into the position's existing lot. The Compounder keeps no LP.

## Consequences

- **ForgeEmissions' LP-pool rewards now arrive three ways:** three quarters liquid, and a quarter as LP in the earning lot, or returned liquid when no match exists.
- **The gate's `Compounder` and `MatchReserve` slots read built.** The blockers stay at 31: the record still has no addresses.
- **What remains of the seal's finish line:**
  - Stoke into LP (4b);
  - the valuation source and Relics;
  - the Deeds market;
  - TreasuryVesting and Timelock;
  - v1.0.
