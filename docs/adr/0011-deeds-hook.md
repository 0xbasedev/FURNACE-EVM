# ADR 0011: Deeds in ForgePool, with one listing lock, one settlement and an ownership log

Status: accepted for this repository. Not audited, not deployed.

## Context

**What the spec requires of a Deed** (§5, `DECISIONS.md`, `deeds` in the config):
- A Deed carries the position's receipt, Capstone, outstanding rewards and eligible Seal state.
- A completed sale carries 80% of capped financial age. The Streak resets for the buyer.
- Wallet Relics, Pyre and First Flame do not transfer. The Seal Scar does transfer.
- The Keystone requires continuous ownership for the whole completed term.
- A pending Claim or withdrawal blocks listing.
- Listing suspends the seller's mutations (`cancelListingFirst`). The seller can cancel until the sale settles atomically.
- Price, ownership, reward beneficiary and age haircut each change exactly once.
- No callback can trap the seller's proceeds.

**Why the pool needs this now.** ForgePool is immutable. Whatever the auction needs from custody must exist in the pool at deployment. The auction itself is a separate contract, the `DEEDS` market, which is not built. It holds:
- bids, the reserve and anti-sniping;
- the 1% fee routed 50/50;
- pull refunds and buyer delivery.

## Decision

**1. The pool holds the lock and the settlement; the market holds the auction.** The pool takes an immutable `DEEDS` address and adds three functions:
- `list(id, seller)`:
  - callable by DEEDS only;
  - syncs first, then requires that `seller` owns the position, that it is open, that no cooling ticket is pending, and that it is not already listed;
  - returns the listing nonce, which is odd while listed.
- `unlist(id)`: callable by DEEDS on the seller's behalf, or by the owner directly. No state in the market can therefore keep a position locked.
- `settle(id, buyer, listing)`: callable by DEEDS only, and only with the current odd nonce. A nonce from an earlier listing, or from one that an exit ended, reverts.

**2. The lock.**

| | Locked while listed | Stays open |
|---|---|---|
| **ForgePool** | Deposit, cooling requests and Seals (`_touchOwned`). Executing and cancelling a ticket are locked too, but cannot arise: listing requires that no ticket is pending, and requests are locked. | Emergency exit, which also ends the listing. BOOST's bonus writes, `poke`, and settlement pages. |
| **ForgeEmissions** | `requestClaim` | Everything else |
| **Boost** | Capstone deposits and withdrawal requests | Claiming vested escrow, which only moves value the position already owns, and `refresh` |

**3. Settlement, in order, with no external call.**
1. Sync: lapses and Seal completion resolve first.
2. Log the seller and the current time.
3. Rewrite every active head at now, with age = `deedAge(capped age)` = capped age × 80 / 100 (floored, as canonical `accounting.ts` does).
   - The superseded heads move to history carrying the seller's Streak and bonus, so the seller's measures for every past interval stay exact.
4. Set the new state:
   - the buyer as owner;
   - the Streak to now;
   - the bonus to zero;
   - the wallet-bound terms cleared (§4 below);
   - no cooling plan;
   - the listing spent.

**What stays with the position:**
- lots and records;
- every Seal: an active Seal continues with its cohort and tags, and its escrow vests into the position's Capstone;
- unclaimed rewards, which are keyed by position, so the buyer claims rewards credited both before and after the sale;
- the Capstone;
- each lot's actual-participation clock. Ashfall still waits for the buyer's own 30-day Streak.

**Why the bonus becomes zero.** Pyre belongs to the seller, and the pool cannot separate Pyre from the Capstone part of the bonus. BOOST's next raise restores the Capstone part with the buyer's own Pyre. The market should call `Boost.refresh` in a try/catch after it settles. Until someone does, the position earns base Heat.

**[P] Why the cooling plan resets.**
- If the plan travelled, a seller could request the whole quota, cancel and then sell, so the buyer would inherit a lock on timed exits that is invisible from outside.
- If it resets, a seller could sell to themself to restore the quota. That costs 20% of capped age, the Deed fee and a 24-hour auction, so it is no cheaper than waiting.
- Boost's Capstone plan resets on the same rule.

**4. Phantom age is wallet-bound and never enters `Lot.age`.** This is a binding rule for the Kindling and First Flame PR.
- Two kinds of phantom age exist (spec §2):
  - First Flame's 15-day floor;
  - the Ignition head start.
- The position stores them as `founder` and `headStart`.
- The measures will add them through flags in each record's anchor word. `Record.streak` is a uint40 timestamp, so it has spare high bits.
- Settlement clears both after closing the seller's segments, so the buyer's segments never carry them.
- **Why not store phantom age in a lot's age:**
  - the 80% carry would sell it, which the spec forbids;
  - it could not be removed later: participation stops counting at 30 days, and the record has no spare bytes to mark it.

**5. The ownership log replaces the `ownedSince` that ADR 0010 planned.**
- Each sale appends `_owners[id][n] = (owner, until)`. Tenure n starts at the previous entry's `until`, or at `openedAt` for the first.
- `ForgeView.ownedSince` and `ownershipAt` read it.
- Keystone, in the Relics contract (not built), can prove from one entry that wallet W owned position `id` for a Seal's whole term, `[start, endedAt]`. This works for any past owner as well as the current one.
- So a seller who completes a Seal and sells before claiming its Keystone keeps the evidence. A single `ownedSince` field would have lost it at the sale.

**6. Boost recognizes a new owner by the pool's sale count, not by time.**
- Each Capstone account remembers the `transfers` count it last saw.
- When the count changes, the new owner gets an unused raise allowance and no withdrawal plan, even within the sale's own second.

## What the unbuilt DEEDS market must do (deploy blockers)

- **Before listing:** check that ForgeEmissions has no pending claim (`claimOf`) and that Boost has no unlapsed pending Capstone withdrawal (`accountOf(...).pending`). The pool can see neither.
- **The nonce:** keep the nonce that `list` returns and settle with exactly that nonce.
- **The auction:**
  - a 24-hour ascending auction with a reserve and no instant buyout;
  - anti-sniping of 5/5/30 minutes;
  - a 1% fee routed 50/50;
  - pull refunds and a buyer delivery claim.
  - The pool's settlement makes no external call, so a receiver callback in the market cannot reach custody.
- **After settling:** call `Boost.refresh(pool, id)` in a try/catch.
- **Market-only transfers:** the pool has no other path that writes the owner.

## Later hooks must respect the lock

Taps, source-lot additions (Casting, Stoke into LP) and Kindling's additions must each go through `_touchOwned` or check `listing`. No such hook may change a listed position's collateral.

## Budget (ADR 0010 asks every hook PR to record it)

| | Runtime bytes |
|---|---:|
| ForgePool before (ADR 0010) | 20,681 |
| ForgePool after | 22,400 (+1,719) |
| ↳ `settle` (incl. ownership log 161, plan reset 59, phantom terms 25) | 755 |
| ↳ `list` | 465 |
| ↳ `unlist` | 311 |
| ↳ emergency exit ending the listing | 63 |
| ↳ the lock in `_touchOwned` | 47 |
| ↳ the rest: the `DEEDS` immutable and the new fields | ≈ 78 |
| **Left under EIP-170** | **2,176** |

- ADR 0010 estimated 2–2.5 KB for all six hooks. Deeds alone used 1.7 KB, so that estimate was low.
- By ADR 0010's rule, the next lever comes before the next hook, in its own PR. Cold paths move into an external library that the pool calls by delegatecall, as it already does for `ForgeMeasures`: `seal()`, the bodies of `settle` and `list`, and the plan logic. Lowering optimizer runs, which saves about 500 bytes, is the fallback.

## Gas (isolated, optimizer 500 runs)

| Path | Gas |
|---|---:|
| `list`, 32 lots | 42,785 |
| `settle`, 32 lots (32 heads rewritten, one log entry) | 1,186,545 |
| `setOrdinaryBonus`, 32 lots, for comparison | 1,132,397 |

## Verification

- **Differential replays:** ten new ForgePool scenarios replay against the BigInt model, which mirrors `list`, `unlist`, `settle`, the lock and canonical `deedAge`.
  - Six are scripted: a full cycle; an exit ending a listing; relisting with stale nonces; a lapse resolved by the sync inside `list`; a Seal completing under its buyer; and the plan reset.
  - Four are seeded walks with 5 to 11 sales each.
  - After every step, the state hash includes the owner, listing, sale count, tenure start and the latest previous owner.
  - The earlier walks keep their exact action streams.
- **Invariants:**
  - a listed position is open, with no cooling pending;
  - the ownership log matches every sale;
  - emergency exit succeeds at every step, listed positions included;
  - Streak and bonus anchors never change inside an active segment, which also covers settlement.
  - ForgeViewTest decodes every Deed field at non-zero values.
- **Unit tests:**
  - access and preconditions;
  - the lock and both escape routes;
  - a 730-day lot carrying 292 days, with the closed segments keeping the seller's anchors;
  - phantom terms cleared;
  - rewards travelling to the buyer;
  - Boost's lock, and the buyer's fresh allowance and plan in the sale's own second.
  - Boost's invariant handler now sells positions, so its invariants also hold across owner changes.

## Consequences

- **The market can be built at any time.** Its address is a deployment input, and the pool's interface toward it is final.
- **Every later hook must respect the lock.** The Kindling PR must follow rule 4.
- **The headroom refactor comes next,** before Taps.
- **Not audited or deployed.**
