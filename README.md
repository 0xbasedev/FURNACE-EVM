# FURNACE-EVM

EVM workspace for **FURNACE Protocol**, a loyalty-staking protocol built on EMBER, ASH, liquidity and earned time. The canonical design is **v5.5.0**, kept unchanged in [`canonical/`](canonical/README.md). Revision history is in [`docs/REVISIONS.md`](docs/REVISIONS.md).

> **Status: early implementation.** It contains math libraries, the home-chain EMBER token, the Mantle issuance ledger, Forge custody, base epoch settlement, Seals, Ashfall, the two EMBER pairs and Flow. Nothing is audited or deployed, and nothing here is production-ready. v5.5 requires at least two independent audits before activation. Initial launch is Ethereum-only.

## Layout

| Path | What it is |
|---|---|
| `canonical/` | **Canonical v5.5 package, byte-for-byte as supplied**: the config, `accounting.ts` integer reference, validators, spec, decisions, contract map, deployment gates, and its own 75 tests. CI verifies its `SHA256SUMS.json`. |
| `contracts/src/generated/` | `FurnaceParams.sol` (constants **generated from the canonical config**; only mined registry addresses) and `ScheduleTable.sol` (exact emission factors), both from `pnpm gen`. |
| `contracts/src/libraries/HeatMath.sol` | RAY-scale Heat. `heatPrimitive`, `integrateHeat`, `squaredHeatPrimitive`, `integrateSquaredHeat` (Heat², the Ashfall weight), `cooledAge` and `deedAge` are **exact ports** of `canonical/accounting.ts`. |
| `contracts/src/libraries/EmissionMath.sol` | **Exact** half-life schedule (integer table, [ADR 0002](docs/adr/0002-exact-emission-schedule.md)); `allocateMint` (shared base + Ashfall headroom with tagged residue) and `accruedPoolBudget` are **exact ports**. |
| `contracts/src/Mantle.sol` | **Issuance ledger** (the only EMBER minter): reserves the seed, vesting and epoch budgets; burns are registered through it; one-epoch-lag Ashfall; the distributor burns Seal forfeits without Ashfall credit; no owner. See [ADR 0003](docs/adr/0003-mantle-ledger.md). |
| `contracts/src/EmberToken.sol` | Home-chain EMBER: immutable, zero tax, 21M local backstop, and the Mantle as its only minter. Nothing is pre-minted. |
| `contracts/src/forge/ForgePool.sol` | **Forge custody** (one pool): up to 32 lots per position, cooling plans with frozen slices, in-kind execution with proportional age haircuts, cancel and lapse that resume the frozen state exactly, emergency exit, exact per-position S/W measures, and a pool occupancy log. Every exit makes exactly one external call, the token transfer. Append-only per-lot checkpoint records, each carrying its position's Streak anchor and ordinary Heat bonus, give `epochMeasure` over any past interval. The **ordinary bonus** (Capstone + Pyre, ≤ 0.65) is set only by an immutable `BOOST` address and enters W, the sealed W and Ashfall segment by segment; a top-up dilutes it until Boost refreshes it. See [ADR 0004](docs/adr/0004-forge-custody.md) and [ADR 0008](docs/adr/0008-ordinary-bonus.md). |
| `contracts/src/forge/ForgeEmissions.sol` | **Base epoch settlement**: the Mantle's distributor and the index of the four pools. It splits each epoch's base by pool weight and admits it only for occupied time. Bounded, resumable measure pages (≤32 lots, ≤256 record segments, due lapses charged) feed escrow pages that set each sealed position's capped Conviction escrow. Credit pages then pay `⌊flat·S_i/S⌋ + ⌊heat·W_i/W⌋` with one mint per page. Claims are fee-free 24h snapshots. **Ashfall** is split by pool weight and paid by stake × Heat² to lots with 30 days of participation in positions with a 30-day Streak; what nobody is owed rolls back to the Mantle. See [ADR 0005](docs/adr/0005-epoch-settlement.md) and [ADR 0007](docs/adr/0007-ashfall-and-handoffs.md). |
| **Seals** (`seal`, `settleSeal`) | **Conviction tracks:** 30/90/180/365-day terms at +0.15/.25/.35/.50. The cohort is fixed at sealing. Pending cooling pauses a Seal and extends its term; an executed withdrawal or emergency exit forfeits it; completion is back-dated. Lots are tagged in their records, and escrow is `min(⌊bucket·C_i/C⌋, ⌊L·B_i/W⌋)`. Escrow stays locked until the Seal ends, then goes to a held Capstone ledger, or is split 50/25/25 into forfeit ledgers if forfeited. The burn lane is burned (no Ashfall credit); the Capstone, match reserve and Sealed-pot stream pull theirs from addresses fixed at deployment. See [ADR 0006](docs/adr/0006-seals.md) and [ADR 0007](docs/adr/0007-ashfall-and-handoffs.md). |
| **Deeds** (`list`, `unlist`, `settle`) | **The custody side of a Deed sale.** The immutable `DEEDS` market lists a quiet position for its owner, which locks the owner's deposits, cooling, Seals, Claims and Capstone mutations; emergency exit still works and ends the listing, and the owner can unlist without the market. One settlement, with no external call: the seller's segments close under its anchors, the buyer gets 80% of capped age, a new Streak, a zero bonus, a fresh cooling plan and no wallet-bound terms, and an ownership log records each tenure for Keystone. The auction itself is not built. See [ADR 0011](docs/adr/0011-deeds-hook.md). |
| **Taps** (`requestTap`) | **The Relic-gated withdrawal that keeps the Streak.** From a 90-day Streak an owner may take 10% of active principal every 90 days, from 365 days 25% every 90 days, and from 730 days 25% every 60 days. A Tap freezes the youngest lots first and executes with no age haircut and no Streak reset; it pays the normal fee and the cooling plan's timer, and still forfeits a running Seal. The quota is used at request, so a cancel does not give it back. See [ADR 0014](docs/adr/0014-taps.md). |
| **Source-lot additions** (`addToLot`) | **Where Casting and Stoke into LP will land.** Only the pool's immutable `COMPOUNDER` (LP pools only; the same address Flow names for the Compound waiver) may return internally earned LP to an active lot, at that lot's own age and participation: no fee charged or booked, no new slot, the Seal tag and the Streak kept, a bonus diluted as a deposit dilutes it. A closed or listed position, or an empty or wholly frozen slot, refuses, so the reward stays claimable. The compounder itself is not built. See [ADR 0017](docs/adr/0017-source-lot-additions.md). |
| `contracts/src/forge/Boost.sol` | **Capstone and the ordinary bonus**: every pool's `BOOST`, ForgeEmissions' `CAPSTONE` and a Protocol burn registrar in one contract. Owners keep EMBER in a position's Capstone (1% fees, burned) for up to +0.5 Heat against the custody's EMBER value; Pyre adds up to +0.15. Withdrawals run on Forge's cumulative timers and never read a price; only raising does. **Stoke** compounds a position's unclaimed rewards into its Capstone with no fee, timer or sale; owners may opt keepers in within the canonical tip, interval and size limits. The valuation source and the Pyre ledger are immutable interfaces, not built. See [ADR 0009](docs/adr/0009-capstone-boost.md) and [ADR 0013](docs/adr/0013-stoke-capstone.md). |
| `contracts/src/forge/ForgePoolBase.sol`, `ForgePoolAnnex.sol` | ForgePool's storage, configuration and internal logic (`ForgePoolBase`), shared with the annex each pool deploys and runs by DELEGATECALL for its cold paths: Seals, BOOST's bonus, Deed listing and settlement, and fee collection. Principal paths, exits and views stay in the pool. `pnpm check:layout` proves that both contracts have the same storage layout. See [ADR 0012](docs/adr/0012-pool-annex.md). |
| `contracts/src/forge/ForgeView.sol`, `ForgeLens.sol` | ForgePool's read API (positions, lots, records, tickets, slices, Seals, occupancy), decoded from its raw storage through `extsload`. `using ForgeView for ForgePool;` keeps `pool.positionOf(id)`; `ForgeLens` serves the same reads as external calls for frontends. The views left the pool to make room for its remaining hooks. See [ADR 0010](docs/adr/0010-pool-headroom.md). |
| `contracts/src/forge/ForgeMeasures.sol` | External library: exact slot and position measures (S, W, their sealed parts, and the Ashfall weight) read from the pool's records by DELEGATECALL. It keeps ForgePool under the EIP-170 size limit. |
| `contracts/src/pairs/EmberPair.sol` | **The EMBER pairs**, BlastPool (EMBER/USDC) and SmelterPool (EMBER/WETH): one full-range constant-product contract, deployed twice, that is its own receipt. Exact-in, pull-based swaps with no callbacks. Buys pay 25 bps and sells 35 bps, every part in ppm and in the quote asset: the LP's 20 bps stays in the reserves; burn, liquidity and Quote yield are booked by lane for the fee router to pull. Only the immutable Flow may scale the protocol share (Bedrock's 50% rebate, a Compound's waiver), never the LP fee. Kindling's slot makes the first deposit. The reserves are internal, so donations change nothing. `redeem` pays in kind and is never paused; only swaps are. A 30-minute TWAP comes from a cumulative price and 8 observations. Forge pools 0 and 1 stake the pairs' predicted addresses, so the pairs are an add-on that can deploy later. See [ADR 0015](docs/adr/0015-ember-pairs.md). |
| `contracts/src/flow/Flow.sol` | **Flow**, the swap and zap entrypoint: exact-in swaps at the caller's Relic rebate (Eternal 25%, Bedrock 50% of the protocol share, read from an immutable source and snapped down to a configured tier; a broken source means no rebate), single-sided zaps in and out with an exact closed-form split and dust refunded, and `zapAndStake`, which stakes the LP it just formed into Forge pool 0 or 1 with no deposit fee through the pools' Flow-only `openFor` / `depositFor`. Only the immutable compounder gets the Compound waiver. Deadlines and minimums on every route; Flow holds nothing between calls and has no admin. See [ADR 0016](docs/adr/0016-flow.md). |
| `contracts/test/` | Exact differential tests against BigInt vectors, fuzz properties, and invariants. |
| `scripts/` | Independent checks: canonical checksums, config hash, CREATE3, and `gen`. `forge-model.ts`, `settlement-model.ts` and `pair-model.ts` are the exact BigInt references, and `forge-scenarios.ts`, `settlement-scenarios.ts` and `pair-model.ts` produce the differential scenarios. |
| `apps/forge-sim/` | **Forge simulator** (Vite, React, GSAP): Heat, exit tiers and age haircuts, Seal projections and a day-by-day settlement run, computed by importing the exact models above (see *Simulator*). |
| `apps/forge-app/` | **Testnet dApp** (Vite, React, GSAP, viem) for LiteForge: zap and stake fee-free through Flow beside what a 1% deposit would keep, swaps with the fee shown by lane, positions with Heat and the exit preview, and test-token mints. Every quote imports the exact pair and Flow models. It reads `deployments/testnet-4441.json` and `abi/` at build time; with no manifest it runs on simulated reserves and sends nothing (see *dApp*). |
| `tools/solc`, `tools/forge.mjs` | The solc-js shim, and a forge launcher that propagates forge's exit status (see *Toolchain*). |
| `contracts/script/` | **Testnet deployment kit**: `DeployTestnet.s.sol` deploys and wires the built core, the EMBER pairs and Flow through CreateX's CREATE3, with deployer- and chain-bound salts, on testnets only; `DeployTestnetPairs` deploys the pairs later instead, at the addresses pools 0 and 1 already stake. Stand-ins for unbuilt modules are in `testnet/`. Rehearsed on a fork of LitVM's LiteForge testnet (chain 4441); see [`docs/testnet/litvm-liteforge.md`](docs/testnet/litvm-liteforge.md). Not a canonical deployment. |
| `abi/` | The ABIs a frontend or indexer needs, exported from the build by `pnpm abi`; `index.json` marks the testnet-only stand-ins. ForgePool's ABI includes the functions its annex runs. |
| `deployments/` | Testnet manifests, and `litvm-mainnet.gate.json`, the record the LitVM mainnet gate reads (`scripts/mainnet-gate.ts`; all of it unset today). There is no mainnet broadcast script; see [`docs/mainnet/litvm-readiness.md`](docs/mainnet/litvm-readiness.md). |
| `docs/` | ADRs, revision log, testnet guides (`docs/testnet/`), the LitVM mainnet readiness page (`docs/mainnet/`), and the original v5.3.1 sources (`docs/sources/`, historical). |

## Commands

```sh
git submodule update --init   # lib/forge-std
pnpm install
pnpm check          # typecheck, canonical checksums, config hash, CREATE3, gen freshness, simulator and dApp tests + builds, forge exit gate, contract size gate, pool and annex storage layouts, forge tests, ABI freshness, the mainnet gate still blocked
pnpm canonical:test # the canonical package's own tests + economics gate (pinned TypeScript 5.8.3)
pnpm check:all      # both (CI runs both)
pnpm gen            # regenerate FurnaceParams.sol, ScheduleTable.sol, oracle vectors, Forge, settlement and pair scenarios
pnpm gas            # gas report: every call its own transaction (forge test --isolate)
pnpm check:layout   # ForgePool and its annex share one storage layout, at the slots ForgeView decodes
pnpm config:hash
pnpm sim:dev        # the Forge simulator on localhost (sim:test, sim:build for its checks and static build)
pnpm app:dev        # the LiteForge testnet dApp on localhost (app:test, app:build for its checks and static build)
pnpm abi            # export the ABIs a frontend needs to abi/ (abi:check fails on stale files; part of pnpm check)
pnpm testnet:dry-run --sender <address>   # rehearse the testnet deployment on a fork of LiteForge (chain 4441)
pnpm testnet:deploy --account <keystore> --sender <address>   # broadcast it (testnet keys only)
pnpm testnet:pairs:deploy --account <keystore> --sender <address>   # only after FURNACE_TESTNET_PAIRS=later: the EMBER pairs
pnpm mainnet:gate   # the LitVM mainnet readiness gate: every blocker, in order (exits 1 while blocked; mainnet:gate:check runs in pnpm check)
```

## Simulator

`apps/forge-sim` is a static, single-page simulator for one Forge position. It has no chain connection and adds no math of its own: it imports `canonical/accounting.ts` (Heat, `cooledAge`, `settleBaseEpoch`), `scripts/schedule.ts` (emissions) and `scripts/settlement-model.ts` (the contract mirror) through path aliases, and runs the BigInt work in a Web Worker.

- **Heat**: the canonical curve with Relic milestones, and a "let it age" playback.
- **Leaving, priced**: the cumulative-plan tier timer, the 1% fee, the exact age haircut, and emergency exit behind a press-and-hold.
- **Seals**: escrow per track from the canonical settlement formula under the assumptions you set, whether the cap or the candidate binds, and what leaving early forfeits.
- **Day book**: up to 120 daily settlements of `SettlementModel` with your events (seal, withdraw, cancel, deposit, claim, emergency exit). Actions the contract rules reject are shown as rejected.

The engine tests (`apps/forge-sim/test`) check each projection against direct calls to the models. Every figure is a projection for unaudited, undeployed contracts under the assumptions on screen; it is not an APR. Not modelled yet: Ashfall, Quote yield, Capstone Heat, Relic perks.

## dApp

`apps/forge-app` is the testnet interface: a static page, an injected wallet (EIP-1193) and viem, no backend. It refuses to send anything off chain 4441 and offers to switch or add LiteForge.

- **Zap & stake** (the default tab): one token in, through `Flow.zapAndStake`. It shows the LP staked fee-free beside what `deposit` would keep after its 1% fee, the exact split, the price impact and the dust returned. It can open a position or add to one picked under *Positions*.
- **Swap**: `Flow.swap` at the wallet's Relic rebate, with the fee broken into its LP, burn, liquidity and Quote yield lanes.
- **Positions**: each position in Forge pools 0 and 1, its Heat and a 10% exit preview from the simulator's engine.
- **Test tokens**: mints of tUSDC and tWETH, and the zkLTC faucet.

The nudges are interface policy, never on-chain rules:
- slippage defaults to 0.5%, with 1% and 3% (the cap) offered;
- price impact warns above 1% and blocks the button above 15%;
- a selling route says so before it is signed.

Each call carries a deadline and the minimum the chosen slippage allows; the contracts enforce only those. Approvals are for the exact amount a call spends, never unlimited. Its tests (`apps/forge-app/test`) check the quotes against the models, the calldata against the ABIs, and the approve-then-zap flow against a mock wallet. Not built into the interface yet: `zapOut` and the pools' exits (the contract routes exist; the Positions tab previews an exit but sends none). Rebates come from the testnet stand-in, not Relics.

## Verified (current head)

- **Canonical package:** all 54 files match `SHA256SUMS.json`, and they still match after the package's own build. Its 75 tests pass. The economics gate reports no diagnostics. Its deployment gate fails, by design, until real operators are supplied.
- **Config hash:** v5.5.0 is `0x24f38f4aa11919503354bb5f8263978c7b3edc29723760928cb1eecdbafbe5ae` (31,451 bytes). This repo reproduces it independently with noble Keccak and its own serializer, and it equals the package manifest.
- **CREATE3:** the 9 mined addresses re-derive from their salts; they are provisional because the deployer is still the placeholder. Seven modules are unmined by design: Mantle, BlastPool, SmelterPool, Flow, GenesisFeeEscrow, TreasuryVesting and Timelock.
- **Forge tests, 315/315:**
  - The integer ports equal `canonical/accounting.ts` **exactly** on generated vectors. A deliberate 1-wei rounding change fails the suite.
  - The emission schedule is exact on every day from 0 to 1700 plus far-out days (ADR 0002). Day 365 is exactly 10,800 EMBER, and the floor is first reached on day 1,619.
  - The Heat integral telescopes exactly under checkpoint subdivision (fuzzed). The Heat² primitive (`squaredHeatPrimitive`, the Ashfall weight) is exact as well, including its ~280-bit square root.
  - Mint conservation holds: base + Ashfall + residue = available ≤ headroom.
  - Invariants: supply ≤ 21M, and balances sum to supply.
  - Mantle invariants under random action sequences, starting about 50,000 EMBER below the ceiling: `accounted + reserved ≤ 21M`, exact Ashfall credit conservation, `epochReserved` equal to the outstanding budgets, `totalSupply ≤ accounted`, the seed is all-or-nothing, vesting never runs ahead of V(t), Ashfall is always backed by recognized credits, and base never exceeds the schedule.
  - **ForgePool differential:** 52 scenarios, Seals, a Streak reset, ordinary-bonus changes, 44 Deed sales, 48 Taps and 63 source-lot additions included. After every action, a keccak of the full contract state (every lot and its Seal tag, every slice and ticket with its Tap flag, the Seal state, the owner, listing and ownership log, the last Tap, and every wallet's balance) must equal the BigInt model's, and whether each call reverts must match. The model accrues sealed measures and the Ashfall weight, with the bonus, independently of the records; 35 of the 43 scenarios reach a nonzero Ashfall weight, and 16 run with boosted lots.
  - **ForgePool invariants:** custody backed, tokens conserved, pool totals equal to the positions, slot masks consistent, ages bounded, measures and occupancy monotone, and emergency exit succeeding for every open position at every step. A running Seal is paused exactly while cooling is pending, and only its cohort carries its tag. No Streak reset or bonus change falls inside an active record segment. A listed position is open with no cooling pending, and the ownership log holds exactly each sale. Executing a Tap leaves the Streak and every surviving lot's age as they were. A source-lot addition leaves its lot's age and participation, the slot count, the fees and the Streak as they were.
  - **ForgePool mutations:** 9 planted bugs, each caught by the suite; see ADR 0004.
  - **Settlement differential:** 20 scenarios across four pools, the Mantle, Seals, Ashfall, ordinary bonuses, claims and Stoke pulls.
    - Cases include:
      - a position touched after its epoch ended but before its page ran;
      - a lapse inside an epoch;
      - a keeper five epochs late;
      - record spam resuming across pages;
      - due lapses that split a page;
      - a cap-bound sealer and candidate-bound sealers;
      - vesting with late credits;
      - forfeits by execute and by emergency exit;
      - a burn funding the next epoch's Ashfall, paid by Heat² weight, with empty and ineligible pools and an emergency-exited position rolling their shares back;
      - the burn lane burned and the other ledgers pulled by their consumers;
      - a boosted and an unboosted position at equal stake, and a sealed, boosted one.
    - The full settlement state, page progress, every escrow ledger and the Mantle's Ashfall budgets, queue and credits included, matches the model after every action.
    - Every budget, escrow and payout equals canonical `settleBaseEpoch` with the Seal measures B and C.
  - **Bounded pages:**
    - A page visits at most 32 lots and 256 record segments, charges 64 units per lapse its syncs resolve, and resumes where the last one stopped.
    - A record-spammed slot (1,200 records, costing the attacker about 179k gas each) settles in 5 pages of at most 5.4M gas each, where it used to take one 20.9M page. With an Ashfall budget it settles in 10 pages of at most 3.4M.
    - 32 positions with 8 due lapses each settle in 32 pages of at most 1.5M gas.
    - These figures are isolated per transaction (`pnpm gas`).
  - **Settlement invariants** (`fail_on_revert`):
    - each settled epoch's base is minted or released to the wei;
    - payouts never exceed the admitted budget;
    - each settled epoch's Ashfall is credited or rolled back to the wei, and no pool pays more than its share;
    - EMBER held equals unclaimed and pending rewards plus every Seal escrow and forfeit ledger, and supply equals the Mantle's ledger (mints minus recognized burns);
    - exits never depend on settlement.
    - Runs start from 31 settled days, with random burns and consumer pulls, so Ashfall is live.
  - **Settlement and Seal mutations:** 28 planted bugs, each caught; see ADR 0005 and ADR 0006.
  - **Ashfall mutations:** 17 planted bugs (Heat², Streak anchors, eligibility, the Ashfall pass, the consumers), each caught; see ADR 0007.
  - **Boost mutations:** 21 planted bugs (withdrawals reading a price, the cumulative timer, fees, raise rationing, roundings, the overflow guard, ownership), each caught; see ADR 0009.
  - **Ordinary-bonus mutations:** 15 planted bugs (the authority, the ceiling, the rewrite order, the bonus in W, the sealed W and Ashfall, dilution, the record limit), each caught. The 17 Ashfall mutations were re-run on this code and are still caught; see ADR 0008.
  - **Deed mutations:** 34 planted bugs (the settlement order, nonce and parity, the carry and resets, the ownership log, the lock and its exits, the `list` preconditions, the new decoding offsets, the Claim and Capstone locks, Boost's ownership reset), each caught; see ADR 0011.
  - **Stoke mutations:** 22 planted bugs (the consumer, the Claim snapshot, the Stoke's lock, fee and rationing, the keeper's tip, interval, minimum, bounds and sale reset), each caught; see ADR 0013.
  - **Taps mutations:** 30 planted bugs (the haircut-free, Streak-keeping execution and the Seal forfeit, youngest-first and its ties, every tier edge, the window, the quota and its base, the plan, the cancel, the flag and its decoding), each caught; see ADR 0014.
  - **EMBER pairs** (ADR 0015):
    - **Differential:** 8 scenarios replay `pair-model.ts` step by step, 6- and 18-decimal quotes, random walks included. Every output, every revert and the pair's state (reserves, supply, the holder's receipts, the three fee ledgers) must equal the model's after each step.
    - **The spec's figures, exactly:** 25 and 35 bps at the full fee, 22.5 and 27.5 bps at Bedrock's rebate (2.5 bps of it Quote yield), 20 bps under the Compound waiver.
    - **Invariants:** balances equal the reserves plus booked fees plus donations; booked fees equal what the fee rule charges on every swap; k never falls outside a redeem; k / supply² never falls; receipts stay backed by the locked minimum; a redemption that pays never reverts, paused or not; a round trip never profits; the cumulative price never falls.
    - **Unit tests:** access, the initializer gate, decimals scaling, adds off the ratio, redeem while paused, fee-on-transfer refusal, donations, the oracle's windows and ring, collection by lane.
    - **Mutations:** 38 planted bugs (fee roundings and lanes, the rebate's scope, reserve accounting, access, pausing, initialization and the minimum, decimals scaling, add and redeem roundings, fee-on-transfer, the oracle's period, window, extrapolation and ring, and the kit's wiring), each caught. One, a ledger mix-up hidden by equal burn and liquidity rates, needed a new test; see ADR 0015.
  - **Flow** (ADR 0016):
    - **Differential:** 4 scenarios replay `flow-model.ts` (zaps from either side at every rebate tier, unzaps, rebated and Compound swaps, random walks on 6- and 18-decimal quotes). The returned amounts, the zapper's exact spends and refunds, the pair's state and its fees must equal the model's after each step, and Flow must hold nothing.
    - **Unit tests:** the tier snapping, a reverting, codeless or malformed rebate source (no rebate, no revert), Bedrock's half share, the compounder-only waiver, deadlines and minimums, zaps both ways on both pairs, `zapAndStake` opening and adding with no deposit fee booked (while a direct deposit still pays 1%), ownership, the listing lock and a closed position, the pools' Flow-only hooks, and only LP pools taking a Flow.
    - **Invariants:** Flow holds no token, receipt or allowance; every staked receipt is in custody whole; the pairs' booked fees equal the share rule on every swap leg; a zap returns at most dust.
    - **Mutations:** 35 planted bugs (the rebate's tiers, cap and source failures, the waiver, deadlines and minimums, the split's rates, share, LP term and root, refunds and allowances, the pool hook's fee, gating and ownership, Flow on a single-asset pool, the kit's wiring), each caught; see ADR 0016.
  - **Source-lot additions** (ADR 0017):
    - **Differential:** 9 new ForgePool scenarios (the lot's own age, refusals, cooling and lapse, Seals, Deeds and emergency, a single-asset pool, 32 lots, and three random walks with Deeds and Taps) replay exactly, state hash and measures after every step.
    - **Unit tests:** the compounder-only caller and a zero compounder, LP pools only, the lot's age and participation kept, measures only from the addition onward, the Seal tag, every refusal, a partly cooling lot, 32 lots, dilution equal to a deposit's, the amount width and the record limit.
    - **Invariants:** the pool handler and the decoding check both make additions; no successful addition moves its lot's age or participation, uses a slot, books a fee or touches the Streak.
    - **Mutations:** 24 planted bugs (the caller and its wiring, every refusal, the lot's age, participation, slot and Streak, active principal, fees, the pull, the dilution, the kit), each caught; see ADR 0017.
  - **Testnet kit:** the deployment runs offline against CreateX's real runtime, with the full wiring, salts bound to deployer, chain and version, refusal off the testnet list, and a first epoch settled with every pool earning, the two pairs' LP included. A second test shows the add-on: before the pairs exist, pools 0 and 1 refuse deposits and an epoch settles around them; after the pairs deploy at the predicted addresses, pool 0 takes LP and earns. Anyone but the deployer lands on another address. It is rehearsed live with `pnpm testnet:dry-run` on a fork of chain 4441.
  - **CI gate:** `pnpm forge:gate` proves that a failing test fails the build. The upstream npm wrapper did not propagate forge's exit status.
  - **Size gate:** `pnpm forge:sizes` fails the build if any contract exceeds the EIP-170 runtime limit (24,576 bytes). ForgePool had been 806 bytes over. The measure path now lives in the external library `ForgeMeasures`, and optimizer runs are 500. With Seals, the Streak anchors and the ordinary bonus, ForgePool reached 24,474 bytes (102 under); its two `mulDiv` calls had become plain arithmetic to fit the bonus hook (ADR 0008). Its sixteen views then moved into `ForgeView` behind one `extsload`, which left 20,681 bytes (ADR 0010). The Deed hook took it to 22,398 bytes (ADR 0011). Its cold paths then moved into an annex it delegatecalls, which left 19,825 bytes (ADR 0012). Taps take it to 20,973 bytes (3,603 under); the annex stays at 12,226 bytes (ADR 0014). EmberPair is 11,146 bytes (ADR 0015). Flow's fee-free stake takes ForgePool to 21,569 bytes (3,007 under), and Flow is 7,431 bytes (ADR 0016). Source-lot additions take ForgePool to **21,644 bytes (2,932 under)** and the annex to 13,988; the pool's initcode, which embeds the annex, is 37,091 of 49,152 (ADR 0017).

## Toolchain

Foundry's installer, GitHub releases and the solc binary host are blocked in the cloud dev environment, so both compilers come from npm:
- `@foundry-rs/forge` (pinned) provides the `forge` binary. Its npm `bin.mjs` (1.7.1) drops the exit status, so failing tests would exit 0. The scripts therefore run forge through `tools/forge.mjs`, which launches the same platform binary and forwards its status.
- `tools/solc` wraps solc-js 0.8.28 (npm `solc`, pinned). It hands solc the input on the wasm heap: solc-js's own `compile` copies it onto the wasm stack (4 bytes reserved per character), which overflowed ("memory access out of bounds") once a clean build compiled every test file at once (≈1.3 MB of input). Its output is byte-identical to `solc.compile`.

EVM target: `cancun`.

## Deploy blockers (v5.5 deployment gate; see `canonical/DEPLOYMENT.md`)

- The real Ethereum deployer. The current one is a placeholder, so every mined address and `FurnaceParams` are provisional. Seven modules still need salts.
- A 3-of-5 Treasury Safe with five real owners, plus the Safe's factory inputs, nonce and predicted address. Also the Timelock identity.
- The guardian and treasury identities for Ethereum, the external WETH/USDC receipt, and the start time.
- Mined addresses for the Capstone, match reserve and Sealed-pot stream: `ForgeEmissions` takes them as immutable constructor arguments (ADR 0007).
- A mined address for Boost: each `ForgePool` takes it as `BOOST`, `ForgeEmissions` as `CAPSTONE`, and the Mantle lists it as a Protocol-category burn registrar (ADR 0008, ADR 0009).
- The protected valuation source behind `IValuation` and the Relics contract behind `IPyreLedger` (ADR 0009).
- The Deed market at a mined address: each `ForgePool` takes it as `DEEDS`. It must check that no Claim or Capstone withdrawal is pending before listing, settle with the nonce `list` returned, run the canonical auction, and refresh the bonus after a sale (ADR 0011).
- The consumer of unclaimed rewards for Casting and Stoke into LP: today only Claim and the Capstone take them, and the Stoke's take-all reading is provisional until Casting is designed (ADR 0013).
- Each pool's annex, verified at deployment: its runtime hash, and immutables equal to its pool's (ADR 0012).
- The EMBER pairs' slots: Kindling as each pair's initializer, the Vent as its fee router, Flow (built; ADR 0016) at a mined address, and the guardian. Flow's own slots: the compounder (the Stoke-into-LP and Casting consumer, which LP pools 0 and 1 also name for `addToLot`; ADR 0017) and Relics' fee-rebate perk. Also a decision on the pairs' trust window: a CREATE3 address does not commit to code, so the pairs either deploy in the same broadcast as the core or move to CreateX's CREATE2, a change to §23 (ADR 0015). On LitVM, SmelterPool's quote asset (bridged WETH or wrapped zkLTC) is also undecided.
- Built and audited custody, settlement, escrow and auction contracts.

## Next steps (v5.5 `CONTRACTS.md`)

1. ~~Mantle~~ (done; ADR 0003). Its vesting-start and seed defaults were confirmed by the project owner. Transport claims stay unimplemented while bridging is disabled.
2. ~~Forge custody~~ (done; ADR 0004): lots, cooling plans, exits, checkpoint records and occupancy.
3. ~~Base epoch settlement~~ (done; ADR 0005): admission, pages, credits and claims. Without Seals the split is the canonical 27/73.
4. ~~Seals~~ (done; ADR 0006): cohorts, pause and extend, escrow, vesting and forfeiture.
5. ~~Ashfall and the Seal-ledger handoffs~~ (done; ADR 0007): the Heat² port, Streak anchors in the records, Ashfall pages, the uncredited forfeit burn, and pulls by the Capstone, match reserve and Sealed-pot stream.

   **Before any deployment,** these are still required (ADR 0007, ADR 0008):
   - the protected valuation source and the Relics (Pyre) ledger that Boost reads, and Boost's mined address (ADR 0009);
   - the pool's remaining hooks (ADR 0010, ADR 0011): Kindling positions, the First Flame floor and the head start (source-lot additions are built: ADR 0017). Each respects the listing lock, and phantom age never enters a lot's age;
   - the Deed market (ADR 0011);
   - the matching/match-reserve and Sealed-pot stream contracts, at mined addresses;
   - the emergency exit's stayers' share, which today goes to the fee collector.

   Next: the pool's remaining hooks (Kindling positions, the First Flame floor and the head start).
6. **FeeRouter (Vent)**, which pulls `ForgePool.feesOwed`, with the 0.5% per-call and per-window throughput limits, plus **GenesisFeeEscrow** for Kindling.
7. ~~The Heat² primitive (`squaredHeatPrimitive`) port and Ashfall distribution~~ (done; ADR 0007).
8. ~~The ordinary-bonus hook in ForgePool~~ (done; ADR 0008): `BOOST`, bonus-carrying records, dilution on top-ups, and a record limit for Boost rewrites.
9. ~~Capstone and Boost~~ (done; ADR 0009): the Capstone ledger, vested escrow, Forge-timed withdrawals that never read a price, and the Capstone + Pyre bonus.
10. ~~ForgePool headroom~~ (done; ADR 0010): the views move into `ForgeView` and `ForgeLens`, freeing 3.9 KB for the pool's remaining hooks.
11. ~~The Deed hook~~ (done; ADR 0011): the listing lock, one settlement, the ownership log, and the lock in ForgeEmissions and Boost.
12. ~~ForgePool's annex~~ (done; ADR 0012): the cold paths run in a delegatecalled annex built from the same source, freeing 2.6 KB; principal paths and exits stay in the pool.
13. ~~Stoke into the Capstone~~ (done; ADR 0013): fee-free compounding of unclaimed rewards, a rationed raise, and opt-in keepers.
14. ~~Taps~~ (done; ADR 0014): the Relic-gated, youngest-first withdrawal with no haircut and no Streak reset.
15. ~~The EMBER pairs~~ (done; ADR 0015): BlastPool and SmelterPool, with fees in ppm by lane, Flow-only rebates, a TWAP, and activation as an add-on. The Vent and Kindling, which they serve, are not built.
16. ~~Flow~~ (done; ADR 0016): rebated swaps, zaps in and out, the compounder's waiver, and the pools' fee-free same-route stake.
17. ~~Source-lot additions~~ (done; ADR 0017): the compounder's `addToLot`, which returns earned LP to an active lot at its own age with no fee and no new slot.
