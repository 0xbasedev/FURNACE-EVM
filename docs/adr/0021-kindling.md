# ADR 0021: Kindling, the GenesisFeeEscrow and the permanent LP sink

Status: accepted for this repository. Not audited, not deployed.

## Context

**What the spec requires** (v5.5 §3; `CONTRACTS.md` rows 11 and 13; DECISIONS A3; `DEPLOYMENT.md` line 39; the config's `kindling`, `execution.kindling` and `fees.genesisDeposit`):
- **The event.** It "opens after Ignition, lasts 24 hours, and accepts USDC on the home chain. Its seed is the single 420,000-EMBER allocation." It keeps "the $100,000 minimum, $5,000,000 maximum, $25,000 per-wallet admission cap, 3% fee". "Wallet caps are admission rules, not a claim to prevent one entity using many wallets."
- **Custody.** "Kindling fees are held by a dedicated immutable GenesisFeeEscrow whose success beneficiary is Treasury." Each event and asset has "a separate principal liability and fee liability". "There is no rescue, arbitrary approval, upgrade, or administrative withdrawal path for live refund backing."
- **Deposits and cancellations.**
  - "New deposits stop exactly at the deadline."
  - "Contributions can be cancelled until atomic successful settlement, including during a safe-settlement retry period. Cancellation returns net principal immediately; the fee remains escrowed."
  - "On failure, any fee previously retained on a cancelled contribution is refundable, and a remaining contribution receives its remaining principal plus its fee. No refund pays previously returned principal again."
- **Failure.** "Below minimum at the deadline, the event fails. A funded event that cannot safely settle becomes refundable no later than 72 hours after its deadline. A valid success transition and failure transition are mutually exclusive. Passing time is not evidence of successful pool initialization."
- **Success.** "Successful settlement performs pool initialization and LP custody atomically, then releases earned fees. The close bounty remains 5 bps of accepted gross quote, paid out of successful-event fee revenue … Cancelled contributions do not enlarge its base."
- **The LP.** "After accounting separately for the AMM's minimum liquidity, 90% of distributable LP is allocated pro-rata to contributor-owned auto-staked Deeds; 10% goes to an irretrievable LP sink. The two destinations cannot own the same unit. Entitlements are initialized in aggregate and materialized in bounded pages or on demand; finalization never loops over every contributor."
- **The worked example.** "A $100 gross contribution leaves $97 of net quote. A 90% contributor LP share corresponds approximately to $87.30 of quote-side reserves plus its token-side claim … The opening price is endogenous to net raised quote and the token seed."
- **The canonical reference.** `canonical/accounting.ts` `KindlingEscrow`: a 10,000 deposit is 9,700 net and 300 fee; cancelling 4,000 and then failing refunds 6,000; success releases every fee, cancelled contributions' included.

**What exists.**
- The Mantle's `mintKindlingSeed()` mints the 420,000-EMBER seed to its immutable `KINDLING`, once, and the reservation stays on failure (ADR 0003).
- BlastPool's first `addLiquidity` must come from its `INITIALIZER`. It mints `sqrt(ember · quote · 10^(18 − decimals))` LP and burns `MINIMUM_LIQUIDITY` (1,000) to the dead address (ADR 0015).
- Pool 0's `openKindling(owner, amount)` opens a contributor's position for `KINDLING` at the standard 1% fee (ADR 0018).
- On the testnet, the operator's wallet held all three slots.

## Decision

**1. Three immutable contracts in `contracts/src/kindling/`.** None has an admin, a pause or an upgrade.

**2. `GenesisFeeEscrow`: one event's custody of one asset.**
- **Immutables:** `QUOTE` (USDC), `EVENT` (that event's Kindling) and `TREASURY`.
- **Ledgers:** `principal` (net principal owed) and `fees`, kept apart. Only `EVENT` calls anything that changes them.
- **States:** `Open`, then `Settled` or `Failed`, once.
- **Principal leaves** only as a cancellation while `Open` (`returnPrincipal`), as the pool's quote on success (`fundLiquidity`, which also moves the state), or as a refund after `Failed`.
- **Fees leave** only after the pool is initialized (`releaseFees`, once: the bounty to its caller, the rest to the Treasury) or as refunds after `Failed`.
- **Every outflow is capped** by its own ledger (`ExceedsLiability`), so the Treasury can never take refund backing. A donation is nobody's liability and stays.

**3. `PermanentLiquidity`: the sink.** Its only function is a view (`held`). It has no CALL, CALLCODE, DELEGATECALL, CREATE, CREATE2, SELFDESTRUCT or even SSTORE in its runtime (a test scans the bytecode), and it refuses native currency. Kindling's 10% goes here, and so will the later idle auto-pairing's LP.

**4. `Kindling`: the event.**
- **Immutables:** `USDC`, `EMBER`, `MANTLE`, `PAIR` (BlastPool), `POOL` (Forge pool 0), `ESCROW`, `SINK` and `START`, with `END = START + 24 h` and `SETTLE_DEADLINE = END + 72 h`. The limits are the config's dollars times 10^decimals, read at construction.
- **The constructor** checks that the escrow names this event and this asset (`EscrowMismatch`) and reads USDC's decimals. It calls nothing else, so the Mantle, the pair and the pool can deploy later at their predicted addresses.
- **`contribute(gross)`** runs in `[START, END)` (`NotOpen`) and requires at least $1 (`BelowMinimumContribution`).
  - The fee is `gross · 300 / 10,000`, floored, as in `accounting.ts`.
  - A deposit is refused if it would take the wallet's accepted gross past $25,000 (`WalletCap`) or the event's past $5,000,000 (`RaiseCap`). It is never part-filled.
  - The gross is pulled from the wallet straight into the escrow and must arrive exactly (`NonStandardToken`), then booked.
- **`cancel(amount)`** returns up to the wallet's remaining net at once, until settlement and including after the deadline. The fee stays. The cancelled share of the wallet's accepted gross, `ceil(gross · amount / net)`, leaves the event's base.
- **`settle()`** is permissionless.
  - **Its window:** after `END` (`TooEarly`), before `SETTLE_DEADLINE` (`SettlementExpired`), with `accepted ≥ $100,000` (`BelowMinimumRaise`).
  - **Its venue check** (`venueCheck()`, also a view; `UnsafeVenue`):
    - BlastPool has code;
    - BlastPool names this event as its initializer, and EMBER and USDC as its tokens;
    - BlastPool has no LP and no reserves;
    - pool 0 exists, stakes BlastPool's LP and names this event as its `KINDLING`.
  - **Then, atomically:**
    1. the Mantle mints the seed, which must arrive as exactly 420,000 EMBER (`SeedMismatch`);
    2. the escrow pays the net principal, which must arrive exactly (`QuoteMismatch`);
    3. `PAIR.addLiquidity(seed, net, seed, net)` opens BlastPool at the raise's own price;
    4. of the `L` LP minted, `floor(0.9 · L)` stays for contributors and the rest goes to the sink;
    5. the escrow releases the fees: `floor(5 bps · accepted)` to the caller and the rest to the Treasury.
  - It records `closedAt`, which Ignition's 7-day head-start window will read (ADR 0019).
- **`fail()`** is permissionless once the event cannot settle: below the minimum after `END`, or unsettled at `SETTLE_DEADLINE`. Otherwise it reverts (`StillSettleable`). It returns its reason (`BelowMinimum` or `Timeout`).
- **`refund(wallet)`** is permissionless after failure and pays only the wallet: its remaining net plus every fee it paid, once (`NothingOwed`).
- **`materialize(wallet)` and `materializeMany(wallets)`** are permissionless after success.
  - Each wallet's entitlement is `floor(contributorLp · net / totalNet)`, sent through `POOL.openKindling(wallet, lp)`, so the position starts at age 0 and pays the 1% fee (ADR 0018).
  - A page skips wallets with nothing owed. Nothing loops over every contributor.
  - The materialization that places the last net principal sends the rounding remainder to the sink.
- **Views:** `venueCheck`, `entitlementOf` and `refundableOf`, for keepers and the interface.

**5. Provisional readings [P].** Each was taken as recommended (the owner's standing rule) and is a deploy blocker until the owner confirms it.
- **[P] The limits' basis.** The caps apply to the current accepted gross at admission. Success needs the accepted gross at settlement, after cancellations.
- **[P] Over-cap deposits are refused**, never part-filled.
- **[P] Top-ups are allowed** up to the wallet cap, into the same place: one position per wallet.
- **[P] A cancellation's share of the base** is `ceil(gross · amount / net)`. It is rounded up so that cancellations never enlarge the base. A full cancellation removes the wallet's gross exactly.
- **[P] A $1 minimum contribution** (`KINDLING_MIN_CONTRIBUTION_USD`, a contract constant, not a config field). At $1 the fee's floor costs under a millionth of the deposit, so splitting cannot dodge the fee. The generator proves that a $1 entitlement in a $5M raise, less pool 0's fee, clears `MIN_STAKE_LP`. So `materialize` needs no dust path, and the plan's liquid-LP fallback was not built.
- **[P] `START` is a constructor argument.** Scheduling it after Ignition's 24-hour free-exit window is the deployment's job.
- **[P] USDC is valued at $1.** It is the only asset. There is no WETH or WBTC swap at close.
- **[P] The bounty** goes to the `settle` caller, from the fees, and the Treasury receives the rest in the same transaction.
- **[P] Rounding.** Fees, the contributors' 90% and each entitlement are floored. The sink takes the 10% remainder and, at the last materialization, the entitlements' rounding remainder.
- **[P] Safe settlement** means the venue check above passes, the seed and quote arrive exactly, and the call is within 72 hours. Anything else waits, and ends in failure at the deadline.
- **[P] One sink** serves Kindling's 10% and the later idle auto-pairing.
- **Not built here:**
  - the 1,000-ASH bonus;
  - SmelterPool's initialization, a separately funded Treasury event;
  - the idle auto-pairing, which must be the Vent's `COMPOUNDER`, the only drawer of the match reserve;
  - a Kindling screen in the dApp.

**6. The testnet kit has two modes.**
- **By default the operator stands in** for Kindling, as before, so the smoke run can seed both pairs at once.
- **With `FURNACE_TESTNET_KINDLING=1`** the sink, the escrow and Kindling deploy at their CREATE3-predicted addresses (`FURNACE_TESTNET_KINDLING_START`, default the Mantle's `START`).
  - The Mantle's `KINDLING`, BlastPool's initializer and pool 0's Kindling slot name Kindling. SmelterPool's initializer stays the operator's, and the operator is the escrow's Treasury.
  - No EMBER exists until the event settles, so the smoke run only contributes the operator's wallet cap. The minimum needs at least four wallets.
  - `KindlingSettle` (in `DeployTestnet.s.sol`) settles or fails the event after its 24 hours, then claims the caller's entitlement or refund.
  - `DeployTestnetPairs` reads Kindling from the manifest, so BlastPool still names it when the pairs come later.

## Size and gas

- **Size.** Kindling is 10,772 runtime bytes (initcode 12,695), the escrow 2,978 and the sink 299. Nothing else changed size.
- **Gas** (`pnpm gas`, isolated, against the mock pool 0):
  - `contribute`: 125,537 for a first contribution, 91,326 for a top-up;
  - `cancel`: 71,268;
  - `settle` (seed, pool opening, LP split, fees): 544,918;
  - `materialize`: 219,455; `materializeMany` of 7 wallets: 542,534;
  - `fail`: 73,599; `refund`: 56,834.
- **On the real core** (`DeployTestnet.t.sol`): `settle` costs 559,052 and `materialize` into the real pool 0 costs 294,067.

## Verification

- **Model.** `scripts/kindling-model.ts` is an exact BigInt reference, written from the spec and the config independently of the contracts.
  - It runs beside the canonical `KindlingEscrow`: the 10,000 → 9,700 + 300 deposit, the cancel-4,000-then-fail refund of 6,000, and the success release of every fee.
  - It also checks that the opening LP is `sqrt(seed · net)` less the minimum.
  - After every step it audits its own ledgers: the escrow's backing, the refund backing, and that LP is conserved.
  - `pnpm gen` writes `contracts/test/fixtures/kindling-vectors.json`.
- **Differential.** `Kindling.t.sol` replays the model's 15 scenarios on a real EmberPair, a mock Mantle and a mock pool 0.
  - **The scenarios:**
    - the canonical vectors; a full success; the deadline cutoff; the caps and the minimum contribution;
    - cancellations after the deadline that sink the raise; the timeout; pages of materializations; donations everywhere; the bounty's base;
    - six seeded random walks.
  - **What is compared:** every output and every revert, plus a hash of 102 state words after every step: the event, the escrow, each wallet's place, balance, position, entitlement and refund, Kindling's balances, the pair's reserves, supply and donations, the sink, the Treasury, the keeper, the seed, and the pool.
  - **Coverage:** across the scenarios, 7 settle, 7 fail below the minimum and 1 on timeout. There are 25 refunds and 41 materializations, and every refusal the event has fires.
- **Unit tests** (17):
  - construction, the escrow's gates and ledger caps, a fee-on-transfer quote, a callback that tries to re-enter or fail the event, and USDC with 6 and 18 decimals;
  - the exact $5,000,000 maximum, with the smallest entitlement in it clearing the pool minimum, and one unit past either cap;
  - the exact minimum, which settles and cannot be failed;
  - every venue fault by name, after which the event still refunds in full at the deadline;
  - a wrong seed or a refusing Mantle, and a quote that starts taxing after the raise (USDC is upgradeable): each reverts the whole settlement;
  - the spec's $100 example, $87.30 of quote-side reserves and the same marked on the token side;
  - refunds paying the wallet, not the caller;
  - the sink's bytecode scan.
- **Invariants** (`KindlingInvariant.t.sol`, over random contributions, cancellations, time, endings, refunds, materializations and donations):
  - the escrow's balance is its liabilities plus donations, and equals the event's totals while live;
  - success and failure are exclusive, and the event, the escrow, `closedAt` and the seed agree;
  - no wallet is ever paid back more than it paid in, and a refund completes the return;
  - the Treasury receives nothing before success, then exactly the fees less the bounty;
  - every unit of LP has one owner.
  - `setUp` raises $85,000 through the handler so that runs reach both endings. A probe of 129 runs found 15 that settled (12 with materializations, 4 fully materialized, with the sweep) and 65 that failed.
- **Kit.**
  - `DeployTestnet.t.sol` covers the real mode end to end: the wiring, the smoke run's contribution, four more wallets, settlement on the real core, materialization, and the positions earning in pool 0's second epoch. Kindling's 24 hours are epoch 0, so its positions open as epoch 0 ends.
  - It also covers a failure with refunds, a cancelled contribution's fee included, after which BlastPool never opened and the seed stays reserved.
- **Rehearsal.** `pnpm testnet:dry-run` on a fork of LiteForge, with the smoke actions:
  - default mode: 52 transactions, 89.4M gas;
  - real Kindling mode: 29 transactions, 90.3M gas.
  - Each costs about 0.0018 zkLTC at 0.02 gwei, and the largest transaction is a ForgePool deployment at 12.48M.
- **`pnpm check`:** 396/396 Forge tests in a clean worktree.
- **Mutations:** 51 planted bugs, run in a separate worktree so the main tree never held one. **All 51 are caught**: 30 by the replay and 21 by unit tests, with no new test needed for any. The boundary, minimum and taxing-quote tests above were written before the pass, for the mutants that usually slip through. The 51 cover:
  - the window's edges, the $1 minimum, the fee's rounding, both caps (one unit slack and one unit strict), top-ups, the totals, the exact pull and the booking;
  - the cancellation's rounding, gate, zero amount and base;
  - settlement's timing, deadline, minimum and single use, the venue check, the seed and quote checks, the LP split, the sink transfer, and the bounty's base and recipient;
  - failure at the minimum, before the timeout and before the deadline;
  - refunds twice, unmarked or without the fee;
  - materialization twice, the entitlement's rounding, the sweep and its destination;
  - the venue's supply, stake-token and initializer checks, and both views;
  - the escrow's caller check, every ledger cap, its state moves, the single fee release and the refund's fee ledger.

## Consequences

- **The genesis event exists.** The Mantle's seed, BlastPool's opening deposit and pool 0's Kindling positions now have a contract that can use them, and the 10% sink is the same contract the idle auto-pairing will use.
- **Mainnet gate.** `Kindling` reads built and the gate gains `GenesisFeeEscrow` and `PermanentLiquidity` slots, for 28 blockers.
- **Still unbuilt:** Ignition (which schedules `START` and reads `closedAt`), the ASH bonus, SmelterPool's seeding event, the idle auto-pairing and a Kindling screen in the dApp. *Update:* all but SmelterPool's seeding event are built since: the idle auto-pairing is the Compounder's (ADR 0026), and its LP ends in this sink, which the kit now deploys in every mode.
