# ADR 0024: The epoch splitters: ForgeAsh, the stayers' share, Quote yield and the Sealed pot

Status: accepted for this repository. Not audited, not deployed.

## Context

**Four slots the built core already names** have no contract behind them. Each pays funded value to Forge positions:
- **The ASH ledger's `FORGE`** (ADR 0022). The Forge's 28,000 ASH vests over 730 days as `V(t)`. The spec gives the pools' ASH weights, 500/200/300/0 (§4), and says nothing of how a pool shares its part.
- **The Vent's `STAKERS`** (ADR 0020). Emergency exits route 25% "to everyone who stayed" (§11). The Vent unwinds LP fees, so by the time this share is released it is EMBER and quote, with no record of which pool's exit paid it.
- **The Vent's `QUOTE_YIELD`.** The sell side's 5 bps in the pair's quote asset, paid "to stakers holding an ashfall-eligible relic, weighted by stake × Heat² like Ashfall" (config `quoteYield`; §12). The Ashfall eligibility rule (30 days of participation and an active Streak) applies.
- **ForgeEmissions' `SEALED_POT`** (ADR 0007). 25% of every forfeited Seal escrow, held per pool, which "streams … over its configured period to eligible ongoing Seals" (§12). The config gives no period.

**What exists.** ForgeEmissions already settles every pool epoch exactly, and keeps each position's measures in public storage:
- stake-seconds S and Heat-seconds W;
- the Ashfall weight Q (eligible stake × Heat², ADR 0007);
- the Conviction measure C of running Seals (ADR 0006).

It also keeps the pool's totals of each.

## Decision

**1. One abstract `EpochSplitter`, four deployments** (`contracts/src/yield/`). It has no admin, pause or upgrade.
- **Budgets.** Funds are assigned to an (epoch, pool, token) budget.
- **Payout.** Once ForgeEmissions has settled that pool's epoch (phase `Done`), each position measured in it may `claim` `floor(budget · its measure / the pool's total)`, once.
  - The claim is permissionless and paid to the position's owner.
  - `claimMany` takes a caller-sized list of epochs.
- **Rolls.** An epoch whose pool total is zero can pay nobody. The permissionless `roll` passes its budget to the next epoch, once.
- **Listings.** A listed position's share waits for the sale, as its base rewards do (ADR 0011).
- **Dust.** The floors' dust stays in the splitter. Nothing is redirected.
- **Measures.** They are ForgeEmissions' own, so no lot is re-measured and nothing new is accounted.

**2. `ForgeAsh`, the ledger's `FORGE`.**
- **The slice.** Each epoch is worth exactly `V(epoch end) − V(epoch start)` on the ledger's curve. The slices telescope to exactly 28,000, and nothing is ever rounded into a payment authority.
- **The split.** Each slice is split by the pools' ASH weights. Within a pool it is shared in the base's own shape, 30% by S and 70% by W (a provisional reading, §5).
- **Release.** ASH is released from the ledger when a claim needs it. A settled epoch has always ended, so its slice has always vested.

**3. `BookedSplitter`, deployed as the stayers' share and as Quote yield.**
- **Booking.** The Vent pushes what it owes. The permissionless `book(token)` assigns whatever the splitter holds beyond what it already owes to the epoch now running, split over the four pools by their base weights, 1000/400/400/200 (§5).
- **The stayers' share** pays by S (§5).
- **Quote yield** pays by Q, the Ashfall weight.
- **Donations.** A token sent unasked is booked the same way: it can only ever reach stakers.

**4. `SealedPotStream`, ForgeEmissions' `SEALED_POT`.** `pull(pool)` takes the pool's pot and streams it over the next 30 epochs (§5), in equal parts with the floor's remainder on the last. It goes to running Seals by C. It is never a new mint and never cast (§12).

**5. Provisional readings [P].** Each was taken as recommended, per the owner's standing rule. Each is a deploy blocker until confirmed, and listed in [PROVISIONAL.md](../PROVISIONAL.md).
- **[P] ForgeAsh shares a pool's slice as base rewards do,** 30% by stake-seconds and 70% by Heat. The spec gives only the pool weights.
- **[P] The stayers' share and Quote yield are split over the pools by the base weights.** The Vent's in-kind shares no longer say which pool paid them, so no per-pool attribution exists to honour.
- **[P] The stayers' share pays by stake-seconds,** "everyone who stayed", with no Heat or eligibility test.
- **[P] The Sealed pot streams over 30 epochs** (`SEALED_POT_STREAM_EPOCHS`), starting with the epoch of the pull. ADR 0007 left the period to the stream.
- **[P] Shares follow the position:** they are paid to its owner at claim time and wait while it is listed, as base rewards do.
- **[P] An epoch with a zero total rolls its whole budget to the next,** and only when someone rolls it.
- **[P] Unclaimed shares never expire.**

**6. The kit.**
- All four deploy at CREATE3 addresses, in every mode. The ASH ledger's `FORGE`, the Vent's `STAKERS` and `QUOTE_YIELD`, and ForgeEmissions' `SEALED_POT` name them.
- The wiring check also requires that the ledger's vesting clock and ForgeEmissions' epoch clock start together.
- The operator still stands in for the Hearth, the Treasury, the match reserve, the Deed market and the compounder.

## Size and gas

- **Size:** ForgeAsh is 7,474 runtime bytes, BookedSplitter 7,152 and SealedPotStream 7,185.
- **Gas** (isolated):
  - `book` (four pools): 155,243;
  - `pull` (a 30-epoch stream): 839,899;
  - a first ForgeAsh claim, which releases from the ledger: 268,423;
  - a later ForgeAsh claim: 161,460;
  - a stayers claim: 176,592.

## Verification

- **Model.** `scripts/splitter-model.ts` (BigInt) has 10 scenarios:
  - ForgeAsh's slices and weights, and rolls;
  - the stayers' bookings, Quote yield's eligibility, and the Sealed pot's stream;
  - listings;
  - four seeded walks.
  - **The replay.** `Splitters.t.sol` replays them one test each. It runs on real Forge pools (owners and listings), real ASH (token and ledger) and a mock measures source that settles epochs as ForgeEmissions would. After every step it checks each output, each revert selector and a hash of 912 state words, exactly.
  - **The model checks after every step** that no budget is overpaid, that booked splitters hold what they owe, and that the ledger never releases ahead of the curve.
- **Unit and fuzz tests:**
  - ForgeAsh's slices sum to exactly 28,000 over the vesting;
  - a claim releases exactly `V(now)` and pays the owner, not the caller;
  - a booking splits 1000/400/400/200 into the running epoch;
  - the stream is even, with the floor's remainder last;
  - zero inputs are refused;
  - shares never exceed their budget and fall short only by the floors (fuzzed).
- **Invariants** (`SplittersInvariant.t.sol`, 3, 128 runs × 64 calls; 94 claims and 117 rolls across the runs):
  - booked and streamed splitters always hold what they owe;
  - no budget is ever overpaid;
  - ForgeAsh never runs ahead of the curve, and ASH is minted only as it releases.
- **Kit.** The first-epoch test claims a real ForgeAsh share on the real core, paid to the owner and released to exactly `V(now)`. It also books a real Quote-yield release from the Vent.
  - **LiteForge fork dry runs, smoke on:**
    - 59 transactions and 101.8M gas by default;
    - 37 and 102.6M with the real Kindling;
    - 41 and 109.9M with Ignition.

## Consequences

- **Every fee and allocation the built core routes to stakers now has a contract that pays it.**
- **The mainnet gate's `ForgeAsh`, `Stakers`, `QuoteYield` and `SealedPot` slots are built,** so the blockers stay at 31.
- **What remains of the seal's finish line:**
  - the Hearth;
  - the match reserve and the compounder;
  - the valuation source and Relics;
  - the Deeds market;
  - TreasuryVesting and Timelock;
  - v1.0.
