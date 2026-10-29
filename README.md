# FURNACE-EVM

EVM workspace for **FURNACE Protocol**, a loyalty-staking protocol built on EMBER, ASH, liquidity and earned time. The canonical design is **v5.5.0**, kept unchanged in [`canonical/`](canonical/README.md). Revision history is in [`docs/REVISIONS.md`](docs/REVISIONS.md).

> **Status: early implementation.** It contains math libraries, the home-chain EMBER token, the Mantle issuance ledger, Forge custody, base epoch settlement and Seals. Nothing is audited or deployed, and nothing here is production-ready. v5.5 requires at least two independent audits before activation. Initial launch is Ethereum-only.

## Layout

| Path | What it is |
|---|---|
| `canonical/` | **Canonical v5.5 package, byte-for-byte as supplied**: the config, `accounting.ts` integer reference, validators, spec, decisions, contract map, deployment gates, and its own 75 tests. CI verifies its `SHA256SUMS.json`. |
| `contracts/src/generated/` | `FurnaceParams.sol` (constants **generated from the canonical config**; only mined registry addresses) and `ScheduleTable.sol` (exact emission factors), both from `pnpm gen`. |
| `contracts/src/libraries/HeatMath.sol` | RAY-scale Heat. `heatPrimitive`, `integrateHeat`, `cooledAge` and `deedAge` are **exact ports** of `canonical/accounting.ts`. |
| `contracts/src/libraries/EmissionMath.sol` | **Exact** half-life schedule (integer table, [ADR 0002](docs/adr/0002-exact-emission-schedule.md)); `allocateMint` (shared base + Ashfall headroom with tagged residue) and `accruedPoolBudget` are **exact ports**. |
| `contracts/src/Mantle.sol` | **Issuance ledger** (the only EMBER minter): reserves the seed, vesting and epoch budgets; burns are registered through it; one-epoch-lag Ashfall; no owner. See [ADR 0003](docs/adr/0003-mantle-ledger.md). |
| `contracts/src/EmberToken.sol` | Home-chain EMBER: immutable, zero tax, 21M local backstop, and the Mantle as its only minter. Nothing is pre-minted. |
| `contracts/src/forge/ForgePool.sol` | **Forge custody** (one pool): up to 32 lots per position, cooling plans with frozen slices, in-kind execution with proportional age haircuts, cancel and lapse that resume the frozen state exactly, emergency exit, exact per-position S/W measures, and a pool occupancy log. Every exit makes exactly one external call, the token transfer. Append-only per-lot checkpoint records give `epochMeasure` over any past interval. See [ADR 0004](docs/adr/0004-forge-custody.md). |
| `contracts/src/forge/ForgeEmissions.sol` | **Base epoch settlement**: the Mantle's distributor and the index of the four pools. It splits each epoch's base by pool weight and admits it only for occupied time. Bounded, resumable measure pages (≤32 lots, ≤256 record segments, due lapses charged) feed escrow pages that set each sealed position's capped Conviction escrow. Credit pages then pay `⌊flat·S_i/S⌋ + ⌊heat·W_i/W⌋` with one mint per page. Claims are fee-free 24h snapshots. See [ADR 0005](docs/adr/0005-epoch-settlement.md). |
| **Seals** (`seal`, `settleSeal`) | **Conviction tracks:** 30/90/180/365-day terms at +0.15/.25/.35/.50. The cohort is fixed at sealing. Pending cooling pauses a Seal and extends its term; an executed withdrawal or emergency exit forfeits it; completion is back-dated. Lots are tagged in their records, and escrow is `min(⌊bucket·C_i/C⌋, ⌊L·B_i/W⌋)`. Escrow stays locked until the Seal ends, then goes to a held Capstone ledger, or is split 50/25/25 into held forfeit ledgers if forfeited. See [ADR 0006](docs/adr/0006-seals.md). |
| `contracts/src/forge/ForgeMeasures.sol` | External library: exact slot and position measures (S, W, and their sealed parts) read from the pool's records by DELEGATECALL. It keeps ForgePool under the EIP-170 size limit. |
| `contracts/test/` | Exact differential tests against BigInt vectors, fuzz properties, and invariants. |
| `scripts/` | Independent checks: canonical checksums, config hash, CREATE3, and `gen`. `forge-model.ts` and `settlement-model.ts` are the exact BigInt references, and `forge-scenarios.ts` and `settlement-scenarios.ts` produce the differential scenarios. |
| `tools/solc`, `tools/forge.mjs` | The solc-js shim, and a forge launcher that propagates forge's exit status (see *Toolchain*). |
| `docs/` | ADRs, revision log, and the original v5.3.1 sources (`docs/sources/`, historical). |

## Commands

```sh
git submodule update --init   # lib/forge-std
pnpm install
pnpm check          # typecheck, canonical checksums, config hash, CREATE3, gen freshness, forge exit gate, contract size gate, forge tests
pnpm canonical:test # the canonical package's own tests + economics gate (pinned TypeScript 5.8.3)
pnpm check:all      # both (CI runs both)
pnpm gen            # regenerate FurnaceParams.sol, ScheduleTable.sol, oracle vectors, Forge + settlement scenarios
pnpm gas            # gas report: every call its own transaction (forge test --isolate)
pnpm config:hash
```

## Verified (current head)

- **Canonical package:** all 54 files match `SHA256SUMS.json`, and they still match after the package's own build. Its 75 tests pass. The economics gate reports no diagnostics. Its deployment gate fails, by design, until real operators are supplied.
- **Config hash:** v5.5.0 is `0x24f38f4aa11919503354bb5f8263978c7b3edc29723760928cb1eecdbafbe5ae` (31,451 bytes). This repo reproduces it independently with noble Keccak and its own serializer, and it equals the package manifest.
- **CREATE3:** the 9 mined addresses re-derive from their salts; they are provisional because the deployer is still the placeholder. Seven modules are unmined by design: Mantle, BlastPool, SmelterPool, Flow, GenesisFeeEscrow, TreasuryVesting and Timelock.
- **Forge tests, 141/141:**
  - The integer ports equal `canonical/accounting.ts` **exactly** on generated vectors. A deliberate 1-wei rounding change fails the suite.
  - The emission schedule is exact on every day from 0 to 1700 plus far-out days (ADR 0002). Day 365 is exactly 10,800 EMBER, and the floor is first reached on day 1,619.
  - The Heat integral telescopes exactly under checkpoint subdivision (fuzzed).
  - Mint conservation holds: base + Ashfall + residue = available ≤ headroom.
  - Invariants: supply ≤ 21M, and balances sum to supply.
  - Mantle invariants under random action sequences, starting about 50,000 EMBER below the ceiling: `accounted + reserved ≤ 21M`, exact Ashfall credit conservation, `epochReserved` equal to the outstanding budgets, `totalSupply ≤ accounted`, the seed is all-or-nothing, vesting never runs ahead of V(t), Ashfall is always backed by recognized credits, and base never exceeds the schedule.
  - **ForgePool differential:** 21 scenarios, Seals included. After every action, a keccak of the full contract state (every lot and its Seal tag, every slice and ticket, and the Seal state) must equal the BigInt model's, and reverts must match. The model accrues sealed measures independently of the records.
  - **ForgePool invariants:** custody backed, tokens conserved, pool totals equal to the positions, slot masks consistent, ages bounded, measures and occupancy monotone, and emergency exit succeeding for every open position at every step. A running Seal is paused exactly while cooling is pending, and only its cohort carries its tag.
  - **ForgePool mutations:** 9 planted bugs, each caught by the suite; see ADR 0004.
  - **Settlement differential:** 17 scenarios across four pools, the Mantle, Seals and claims.
    - Cases include:
      - a position touched after its epoch ended but before its page ran;
      - a lapse inside an epoch;
      - a keeper five epochs late;
      - record spam resuming across pages;
      - due lapses that split a page;
      - a cap-bound sealer and candidate-bound sealers;
      - vesting with late credits;
      - forfeits by execute and by emergency exit.
    - The full settlement state, page progress and every escrow ledger included, matches the model after every action.
    - Every budget, escrow and payout equals canonical `settleBaseEpoch` with the Seal measures B and C.
  - **Bounded pages:**
    - A page visits at most 32 lots and 256 record segments, charges 64 units per lapse its syncs resolve, and resumes where the last one stopped.
    - A record-spammed slot (1,200 records, costing the attacker about 179k gas each) settles in 5 pages of at most 5.3M gas each, where it used to take one 20.9M page.
    - 32 positions with 8 due lapses each settle in 32 pages of at most 1.5M gas.
    - These figures are isolated per transaction (`pnpm gas`).
  - **Settlement invariants** (`fail_on_revert`):
    - each settled epoch's base is minted or released to the wei;
    - payouts never exceed the admitted budget;
    - EMBER held equals unclaimed and pending rewards plus every Seal escrow and forfeit ledger, and supply equals what the Mantle minted;
    - exits never depend on settlement.
  - **Settlement and Seal mutations:** 28 planted bugs, each caught; see ADR 0005 and ADR 0006.
  - **CI gate:** `pnpm forge:gate` proves that a failing test fails the build. The upstream npm wrapper did not propagate forge's exit status.
  - **Size gate:** `pnpm forge:sizes` fails the build if any contract exceeds the EIP-170 runtime limit (24,576 bytes). ForgePool had been 806 bytes over. The measure path now lives in the external library `ForgeMeasures`, and optimizer runs are 500. With Seals, ForgePool is 23,534 bytes.

## Toolchain

Foundry's installer, GitHub releases and the solc binary host are blocked in the cloud dev environment, so both compilers come from npm:
- `@foundry-rs/forge` (pinned) provides the `forge` binary. Its npm `bin.mjs` (1.7.1) drops the exit status, so failing tests would exit 0. The scripts therefore run forge through `tools/forge.mjs`, which launches the same platform binary and forwards its status.
- `tools/solc` wraps solc-js 0.8.28 (npm `solc`, pinned).

EVM target: `cancun`.

## Deploy blockers (v5.5 deployment gate; see `canonical/DEPLOYMENT.md`)

- The real Ethereum deployer. The current one is a placeholder, so every mined address and `FurnaceParams` are provisional. Seven modules still need salts.
- A 3-of-5 Treasury Safe with five real owners, plus the Safe's factory inputs, nonce and predicted address. Also the Timelock identity.
- The guardian and treasury identities for Ethereum, the external WETH/USDC receipt, and the start time.
- Built and audited custody, settlement, escrow and auction contracts.

## Next steps (v5.5 `CONTRACTS.md`)

1. ~~Mantle~~ (done; ADR 0003). Its vesting-start and seed defaults were confirmed by the project owner. Transport claims stay unimplemented while bridging is disabled.
2. ~~Forge custody~~ (done; ADR 0004): lots, cooling plans, exits, checkpoint records and occupancy.
3. ~~Base epoch settlement~~ (done; ADR 0005): admission, pages, credits and claims. Without Seals the split is the canonical 27/73.
4. ~~Seals~~ (done; ADR 0006): cohorts, pause and extend, escrow, vesting and forfeiture. **Before any deployment, `ForgeEmissions` must also gain:**
   - the Capstone handoff;
   - the burn-lane, match-reserve and Sealed-pot consumers;
   - Ashfall.

   Next: Compound and Stoke.
5. **FeeRouter (Vent)**, which pulls `ForgePool.feesOwed`, with the 0.5% per-call and per-window throughput limits, plus **GenesisFeeEscrow** for Kindling.
6. The Heat² primitive (`squaredHeatPrimitive`) port and Ashfall distribution.
