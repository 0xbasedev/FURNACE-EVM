# ADR 0013: Stoke into the Capstone, and opt-in keepers

Status: accepted for this repository. Not audited, not deployed.

## Context

**What the spec requires** (§6, §210; `DECISIONS.md`; the config's `forge.compound`, `fees.compoundPct` and `autoStoke`):
- Stoke defaults to the Capstone first. It goes to compatible LP only when a funded matching reservation exists.
- Without a reservation, a Stoke never sells: rewards stay in the Capstone or stay claimable.
- An owner can always compound into the Capstone without waiting for matching.
- The protocol Compound fee is zero.

**AutoStoke** (§210):
- It is opt-in per position.
- The tip is 0.1–1% (0.5% by default). Keeper Stokes are at least 24h apart (7 days by default), and the minimum is 100 EMBER by default.
- Tips are disclosed compensation, separate from the zero Compound fee.
- A keeper cannot change anything beyond the owner's settings.
- Manual owner compounding never earns the tip.

**Why this must be built now.** Boost and ForgeEmissions are both immutable, so whatever consumes a position's unclaimed rewards has to exist at deployment.

## Decision

**1. ForgeEmissions gains one consumer of unclaimed rewards, the Capstone.**
- `takeUnclaimed(pool, id)` is callable only by `CAPSTONE`, which is Boost.
- It takes the position's credited, unclaimed rewards and leaves any pending Claim's snapshot untouched.

**2. `Boost.stoke(pool, id)`.**
- The owner moves those rewards into the position's Capstone. There is no fee: the generator fails unless the config's `compoundPct` is 0 and `lpMatch.fallback` is `capstone`.
- There is no timer, and there is no sale.
- A listing locks it (ADR 0011): the rewards travel with the Deed.
- A closed position's rewards stay claimable rather than entering the Capstone (§6).

**3. A Stoke's raise is rationed.** Deposits raise the bonus without rationing because each one pays a burned fee; vested escrow raises it because it arrives once per Seal. A Stoke has neither limit. Unrationed, every reward credit would give the owner an extra raise at a price moment of their choosing, outside ADR 0009's once-per-epoch-per-side rule. So:
- the owner's Stoke spends the owner's allowance, and a keeper's spends the public one;
- once the allowance is spent, the Capstone still grows, `RaiseDeferred` is emitted, and the next raise picks the difference up;
- lowering needs no allowance, as before.

**4. Keepers.**
- **Settings.** `setKeeper(pool, id, tipBps, interval, minSize)` lets the owner opt in; `tipBps == 0` means off.
  - The tip must be 10–100 bps.
  - The interval must be at least 24h.
  - The minimum must be at least 100 EMBER. [P] The config documents `minSize` as "the smallest amount a keeper may compound", and the spec calls it a "default minimum". This reads it as a floor.
  - The defaults (0.5%, 7 days, 100 EMBER) are generated for the UI.
- **The keeper's call.** `keeperStoke(pool, id)` lets anyone Stoke a position that has opted in, once its interval has passed since the last keeper Stoke and its unclaimed rewards reach the minimum.
  - The caller receives the tip; the owner calling it gets none.
  - The destination is always the Capstone.
- **When settings end.**
  - The settings end at a sale. Boost sees the pool's sale count change and clears them with the raise allowance and the plan.
  - `setKeeper` syncs that count before it writes, so a buyer's first settings are not cleared afterwards.
- **While listed and around changes.**
  - A listing locks keeper Stokes. The owner can still change or end the settings while listed: no keeper Stoke runs until the listing ends, and a sale clears them.
  - Changing the settings does not restart the interval. [P]

## Deploy blockers and provisional readings

- **One authority consumes unclaimed rewards** (`CONTRACTS.md`: "a single receipt-consumption authority across Claim, Stoke, Casting…").
  - With this PR, Claim and the Capstone are the only consumers, and ForgeEmissions is immutable.
  - So Stoke into LP and Casting, which converts 25% of compatible rewards into LP through the match reserve, must go through Boost or a ForgeEmissions consumer fixed before deployment.
  - Neither is built, and no consumer address is invented here.
- **[P] Stoke takes all of `unclaimed`.** `DECISIONS.md` gives the automatic Cast reservation priority ("Automatic Cast reservation comes first, optional Stoke from the remainder").
  - Once Casting is designed, a Stoke may take only what Casting leaves.
  - Until then this reading is provisional, and it is a deploy blocker together with Casting.
  - *Update:* Casting is built (ADR 0026). ForgeEmissions withholds the Cast share at credit, outside `unclaimed`, so a Stoke can take only what Casting leaves, by construction. The Compounder is ForgeEmissions' second consumer, through `takeCast`.
- **Stoke into LP** needs a funded matching reservation and the pool's source-lot additions (ADR 0010). The additions are built (ADR 0017: `addToLot`, callable only by the pool's `COMPOUNDER`). The reservation and the compounder are not. *Update:* the compounder and Casting's reservations are built (ADR 0026); Stoke into LP is seal step 4b.

## Gas (`pnpm gas`, isolated)

| Path | Gas |
|---|---:|
| `keeperStoke`, raising 32 lots (the keeper's worst case) | 1,286,832 |
| `refresh`, raising 32 lots, for comparison | 1,232,156 |

A manual `stoke` follows the same path without the tip transfer.

## Verification

- **Settlement differential:** the new scenario `stokeTakesUnclaimed` replays against the BigInt model. It covers:
  - a pull while a Claim is pending, where the snapshot pays in full afterwards;
  - an empty pull;
  - an unknown pool;
  - credits accruing again after a pull.
  The settlement invariant's consumer pulls now include `takeUnclaimed`. EMBER held still equals every ledger.
- **Unit tests:**
  - the Stoke itself, with no fee and the Claim snapshot kept;
  - its guards: owner only, the Capstone only, the listing lock, a closed position;
  - the rationed raise;
  - the keeper's off state and its bounds at their edges;
  - the tip, the interval, the minimum, and no tip for the owner;
  - settings ending at a sale, and a buyer's first settings surviving;
  - the listing lock on keepers.
- **Boost's invariant handler** now Stokes and keeper-Stokes, so the Capstone backing (tips leave both sides) and the bonus ceiling hold across them.
- **`pnpm check`:** 224/224 Solidity tests.
- **Mutations:** 22 planted bugs on these paths. **All 22 are caught.** They cover:
  - the consumer check, the ledger, the Claim snapshot and the pool check;
  - the Stoke's lock, closure, fee, empty-Stoke check and rationing;
  - the shared allowance;
  - the keeper's owner tip, interval, minimum, last-Stoke time and lock;
  - settings surviving a sale, a missing sync, the bound edges and the owner check.
- **One gap found and closed.** A keeper's raise that read the owner's allowance survived at first. A test now shows that a spent owner side does not hold back the keeper's raise.

## Consequences

- **Rewards compound without a sale, a fee or a timer.** Keepers can do it for owners who opt in, within the canonical limits.
- **Casting and Stoke into LP must respect this ADR's consumer rule** before deployment.
- **Not audited or deployed.**
