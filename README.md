# FURNACE-EVM

EVM workspace for **FURNACE Protocol**, an omnichain loyalty-staking protocol built on EMBER, ASH, liquidity and earned time. The config is at **v5.3.2**; see [`docs/REVISIONS.md`](docs/REVISIONS.md).

> **Status: early implementation.** It contains math libraries and the home-chain EMBER token. Nothing is audited or deployed, and nothing here is production-ready. The spec says no audit has happened, and mainnet requires at least two independent audits.

## Layout

| Path | What it is |
|---|---|
| `furnace.config.ts` | **Canonical config.** It holds the data, `validateConfig()`, and the reference helpers (`epochAllocation`, `heatMultiplier`, `totalMintForEpoch`, `castForPool`, `create3Address`, …). |
| `config/furnace.config.canonical.json` | Canonical JSON mirror of the default export (`pnpm config:json`). |
| `contracts/src/generated/FurnaceParams.sol` | Solidity constants **generated from the config** (`pnpm gen`). Contracts never hand-copy a protocol number. |
| `contracts/src/libraries/HeatMath.sol` | lotHeat (√ ramp plus prorated milestone bumps), position Heat, cap-first cooling, Deed age carry. |
| `contracts/src/libraries/EmissionMath.sol` | Half-life curve with floor, and the shared base + Ashfall headroom budget. |
| `contracts/src/EmberToken.sol` | Home-chain EMBER: immutable, zero tax, enforces the 21M live ceiling, single minter. See [ADR 0001](docs/adr/0001-ember-canonical-supply.md). |
| `contracts/test/` | Differential tests against vectors from the TS oracle, fuzz properties, and invariants. |
| `test/` | Review suite (66 checks) and v5.3.2 decision tests (19 checks). |
| `scripts/` | `config:hash`, `check:config`, `verify:create3`, `gen`. |
| `tools/solc` | solc-js shim for forge (see *Toolchain*). |
| `docs/sources/` | The supplied source documents, unmodified (spec v5.3.1, review, instructions). |

## Commands

```sh
git submodule update --init   # lib/forge-std
pnpm install
pnpm check          # everything below; this is the CI gate
pnpm typecheck
pnpm config:hash    # keccak256 of the canonical config
pnpm test:review    # 66-check review suite
pnpm test:config    # v5.3.2 decision tests
pnpm gen            # regenerate FurnaceParams.sol + oracle vectors after any config change
pnpm test:sol       # forge test
pnpm check:config   # full validateConfig(): fails until deploy identities are set (by design)
```

## Verified (pnpm check, current head)

- Config v5.3.2 hash is `0xbaeb97a2a062763bc986f78e270812214d439bba2044fcdbdc99ad5c00b17270`, and the JSON mirror matches it. The v5.3.1 hash (`0x9ecedb63…63f7`) was reproduced exactly from the supplied file before the revision.
- All 9 CREATE3 addresses re-derive from their salts. They are provisional because they're bound to the placeholder deployer.
- Review suite: 66/66. Decision tests: 19/19.
- Forge: 26/26.
  - Solidity math matches the TS oracle to within 1e-12 relative at every vector.
  - Fuzzing checks that Heat is bounded and monotone with no cliffs, that the emission curve is monotone and floored, and that base + Ashfall never exceed headroom.
  - Invariants: `totalSupply ≤ 21M`, and balances sum to supply.
- The generated Solidity is fresh relative to the config.

## Toolchain

Foundry's installer, GitHub releases and the solc binary host are blocked in the cloud dev environment, so both compilers come from npm:
- `@foundry-rs/forge` (pinned) provides `forge`.
- `tools/solc` wraps solc-js 0.8.28 (npm `solc`, pinned).

Builds are therefore reproducible from `pnpm install` alone. EVM target: `cancun`.

## Deploy blockers (in the config by design)

- `deployment.evm.deployer` is the placeholder `0x1111…1111`, so every mined address, and `FurnaceParams`, is **provisional**. Set the real deployer, then run `pnpm mine:salts` and `pnpm gen`.
- `deployment.evm.treasurySafe.saltNonce` is `null`. `treasury.controller.signers` is `[]` (spec §27 recommends 3-of-5).
- `treasury.addresses.*` and `security.guardian.*` are unset on every chain. `chains[*].lz.dvns` is `[]`, but at least 2 are required.
- `deployment.svm.upgradeAuthority` is `""`. The Solana keypairs under `keys/` are gitignored.
- `pnpm mine:salts` and the deploy scripts referenced by the config were not supplied. They have not been written yet.

## Decisions

**Resolved in v5.3.2** (details in `docs/REVISIONS.md`):
1. The unused Conviction bucket returns **pro-rata**, so 30/70 holds in every epoch.
2. Casting is **per pool**: LP pools cast LP into the source lot; Ember Vault casts EMBER into the source lot; Cold Storage pays liquid EMBER.

**Proposed in ADR 0001** (EMBER supply): mint only on Ethereum; bridge through an OFT lockbox adapter; a single minter (the Forge emission controller); the Kindling seed minted in the constructor; satellite burns reopen headroom only after reconciliation.

**Still open:**
- **Deed age wording.** §5 says "inherits 80% of age"; §25 says "80% haircut". The implementation follows §5 (`deedHeatAge` = 80% of the capped age).
- **Pyre self-rebate.** §8 says no rebate; §12 allows partial self-recapture (0.25·p). The config follows §12.
- **Green UI elements.** §11 says Withdraw Now is the only green element, but Claim Now is also green.
- **`heatAgeAfterDeposit()`** returns a blended age. It is for display only; lot accounting is per-lot.
- **Review §8 contract items** still open: funded Kindling refunds, bounded accrual, and integer settlement with explicit residuals.

## Next steps

1. FeeRouter and the Vent: fee vault, 40/40/10/10 split, fail-closed burn lane (TWAP, price band, chunking, router allowlist).
2. Forge core: lots (max 32), Stoke with provenance, cooling timers (freeze/cancel/expiry), epoch accrual with `epochAllocation` in integer math.
3. The LayerZero layer from ADR 0001: the OFT adapter, the satellite OFT with CREATE3-compatible init, and burn reconciliation.
