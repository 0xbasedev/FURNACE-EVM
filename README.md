# FURNACE-EVM

EVM workspace for **FURNACE Protocol v5.3.1**, an omnichain loyalty-staking protocol built on EMBER, ASH, liquidity and earned time.

> **Status: pre-implementation.** No contracts exist yet. Nothing here is audited, deployed, or production-ready. The spec says no audit has happened.

## Layout

| Path | What it is |
|---|---|
| `furnace.config.ts` | **Canonical v5.3.1 config**, unmodified from the supplied file. It holds the data, the `validateConfig()` validator, and pure helpers such as `epochAllocation`, `heatMultiplier`, `totalMintForEpoch`, `create3Address` and `contractAddress`. |
| `config/furnace.config.canonical.json` | The canonical JSON form of the default export. `pnpm check` fails if the two drift apart. |
| `test/furnace.review.test.ts` | The 66-check review suite, transcribed from `docs/sources/furnace.review.test.pdf`. See *Changes to the review suite* below. |
| `scripts/` | `config:hash` (spec §23 serialization), `check:config`, and `verify:create3` (an independent CREATE3 re-derivation). |
| `docs/sources/` | The supplied source documents, unmodified. |

```sh
pnpm install
pnpm check          # CI gate: hash + mirror, CREATE3, review suite (66/66)
pnpm check:config   # full validateConfig(); fails until deploy identities are set
pnpm config:hash
```

## Verified in this repo (pnpm check)

- `keccak256(canonical(furnace.config.ts))` = `0x9ecedb63d5d10951caaf506032a1cf6d14b9e2196f236e2d2a45c200870463f7` (27,108 chars / 27,158 bytes). This matches the spec header and the review response.
- All 9 CreateX CREATE3 addresses re-derive from their salts. Two separate implementations check this: the config's `create3Address` and `scripts/verify-create3.ts`. Both match the spec §23 table. The addresses are bound to the placeholder deployer.
- The review suite passes 66/66. All 28 reviewer mutations are rejected, all 9 positive controls fire, and the conviction oracle reproduces 30.686800.
- The baseline `validateConfig()` returns 19 errors, all of them deploy blockers (listed below).

## Changes to the review suite

The supplied suite needed a reviewer `hash-registry.json` that is not available. The CREATE3 section now checks against the address table published in spec §23 by default. Set `REGISTRY=path` to use a registry file instead. The suite also now exits non-zero on failure so it can gate CI. The checks themselves are unchanged.

## Not yet in the repo

- `pnpm mine:salts` and the deploy scripts referenced by the config. They were not supplied, and no replacements have been written.
- Any contracts (Foundry / Anchor).

## Deploy blockers (present in the config by design)

- `deployment.evm.deployer` is the placeholder `0x1111…1111`, so all 9 mined addresses are **provisional**.
- `deployment.evm.treasurySafe.saltNonce` is `null`.
- `treasury.addresses.*` and `security.guardian.*` are zero or empty on every chain.
- `treasury.controller.signers` is `[]`. `threshold: 2` has no signer count. Spec §27 recommends 3-of-5.
- `chains[*].lz.dvns` is `[]` on every chain, but `requiredDvnCount` is 2.
- `deployment.svm.upgradeAuthority` is `""`. The Solana keypairs under `keys/` are not in the repo (gitignored).

## Open decisions (recorded, not resolved)

1. **Emission split.** The config stores `split: {flatPct: 30, heatPct: 70}` and `convictionBucketPct: 10`. **`epochAllocation()` currently implements the spec §10 reading.** The 30/70 split applies to the 90% non-conviction budget (27/63/10), and unused conviction budget returns to the Heat pool only (27/73 when nobody is sealed). The review suite asserts this ("empty bucket → 31.75% / 68.25%"). The review response's Decision 1 recommends pro-rata return so that 30/70 holds in every epoch. That decision is still open. Adopting it would be an economic change to the config and the helper, and it would change the hash.
2. **Casting in Ember Vault.** The config sends both single-token pools to liquid EMBER (`casting.singleTokenFallback: "liquidEmber"`). Review Decision 2 recommends a per-pool rule: Ember Vault → source-lot EMBER, Cold Storage → liquid EMBER. Not yet adopted.
3. **Deed age wording.** §5 says "inherits 80% of age"; §25 says "80% haircut". The config has `heatCarryPct: 80`.
4. **Pyre self-rebate.** §8 says no rebate; §12 allows partial self-recapture (0.25·p).
5. **Green UI elements.** §11 says Withdraw Now is the only green element, but Claim Now is also green.
6. **`heatAgeAfterDeposit()`** returns a stake-weighted *blended* age. It is fine for display. It must not drive lot accounting, which is per-lot (`depositDilution: "perLot"`).
7. **Contract-layer items** from review §8: a global supply ledger that counts in-flight OFT, funded Kindling refunds, bounded accrual, and integer settlement with explicit residuals.

## Next steps

1. Resolve decisions 1–2 above before porting `epochAllocation`, Casting, or Forge reward accounting to contracts.
2. Set up Foundry for the core contracts: EmberToken/AshToken OFTs, Forge, FeeRouter, Deeds, Relics, Hearth, Ignition, Kindling. Write invariant tests per spec §27.8.
