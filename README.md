# FURNACE-EVM

EVM workspace for **FURNACE Protocol**, a loyalty-staking protocol built on EMBER, ASH, liquidity and earned time. The canonical design is **v5.5.0**, kept unchanged in [`canonical/`](canonical/README.md). Revision history is in [`docs/REVISIONS.md`](docs/REVISIONS.md).

> **Status: early implementation.** It contains math libraries and the home-chain EMBER token. Nothing is audited or deployed, and nothing here is production-ready. v5.5 requires at least two independent audits before activation. Initial launch is Ethereum-only.

## Layout

| Path | What it is |
|---|---|
| `canonical/` | **Canonical v5.5 package, byte-for-byte as supplied**: the config, `accounting.ts` integer reference, validators, spec, decisions, contract map, deployment gates, and its own 75 tests. CI verifies its `SHA256SUMS.json`. |
| `contracts/src/generated/FurnaceParams.sol` | Solidity constants **generated from the canonical config** (`pnpm gen`). Only mined registry addresses become constants. |
| `contracts/src/libraries/HeatMath.sol` | RAY-scale Heat. `heatPrimitive`, `integrateHeat`, `cooledAge` and `deedAge` are **exact ports** of `canonical/accounting.ts`. |
| `contracts/src/libraries/EmissionMath.sol` | Half-life schedule; `allocateMint` (shared base + Ashfall headroom with tagged residue) and `accruedPoolBudget` are **exact ports**. |
| `contracts/src/EmberToken.sol` | Home-chain EMBER: immutable, zero tax, 21M local backstop, and the Mantle as its only minter. Nothing is pre-minted. |
| `contracts/test/` | Exact differential tests against BigInt vectors, fuzz properties, and invariants. |
| `scripts/` | Independent checks: canonical checksums, config hash, CREATE3, and `gen`. |
| `tools/solc` | solc-js shim for forge (see *Toolchain*). |
| `docs/` | ADRs, revision log, and the original v5.3.1 sources (`docs/sources/`, historical). |

## Commands

```sh
git submodule update --init   # lib/forge-std
pnpm install
pnpm check          # typecheck, canonical checksums, config hash, CREATE3, gen freshness, forge tests
pnpm canonical:test # the canonical package's own tests + economics gate (pinned TypeScript 5.8.3)
pnpm check:all      # both (CI runs both)
pnpm gen            # regenerate FurnaceParams.sol + oracle vectors after a canonical revision
pnpm config:hash
```

## Verified (current head)

- **Canonical package:** all 54 files match `SHA256SUMS.json`, and they still match after the package's own build. Its 75 tests pass. The economics gate reports no diagnostics. Its deployment gate fails, by design, until real operators are supplied.
- **Config hash:** v5.5.0 is `0x24f38f4aa11919503354bb5f8263978c7b3edc29723760928cb1eecdbafbe5ae` (31,451 bytes). This repo reproduces it independently with noble Keccak and its own serializer, and it equals the package manifest.
- **CREATE3:** the 9 mined addresses re-derive from their salts; they are provisional because the deployer is still the placeholder. Seven modules are unmined by design: Mantle, BlastPool, SmelterPool, Flow, GenesisFeeEscrow, TreasuryVesting and Timelock.
- **Forge, 30/30:**
  - The integer ports equal `canonical/accounting.ts` **exactly** on generated vectors. A deliberate 1-wei rounding change fails the suite.
  - The Heat integral telescopes exactly under checkpoint subdivision (fuzzed).
  - Mint conservation holds: base + Ashfall + residue = available ≤ headroom.
  - Invariants: supply ≤ 21M, and balances sum to supply.

## Toolchain

Foundry's installer, GitHub releases and the solc binary host are blocked in the cloud dev environment, so both compilers come from npm:
- `@foundry-rs/forge` (pinned) provides `forge`.
- `tools/solc` wraps solc-js 0.8.28 (npm `solc`, pinned).

EVM target: `cancun`.

## Deploy blockers (v5.5 deployment gate; see `canonical/DEPLOYMENT.md`)

- The real Ethereum deployer. The current one is a placeholder, so every mined address and `FurnaceParams` are provisional. Seven modules still need salts.
- A 3-of-5 Treasury Safe with five real owners, plus the Safe's factory inputs, nonce and predicted address. Also the Timelock identity.
- The guardian and treasury identities for Ethereum, the external WETH/USDC receipt, and the start time.
- Built and audited custody, settlement, escrow and auction contracts.

## Next steps (v5.5 `CONTRACTS.md`)

1. **Mantle:** the global issuance ledger, reservations (Kindling seed, Treasury vesting), epoch authorization and the burn-credit registry, built on `EmissionMath.allocateMint`.
2. **Forge core:** 32 source lots, checkpointed time-integrated measures (`HeatMath.integrateHeat`), cooling plans, and bounded 32-lot settlement pages. Principal exits never wait on settlement.
3. **FeeRouter (Vent)** with the 0.5% per-call and per-window throughput limits, and **GenesisFeeEscrow** for Kindling.
4. The Heat² primitive (`squaredHeatPrimitive`) port for Ashfall.
