# FURNACE-EVM

EVM workspace for **FURNACE Protocol v5.3.1**, an omnichain loyalty-staking protocol built on EMBER, ASH, liquidity and earned time.

> **Status: pre-implementation.** No contracts exist yet. Nothing here is audited, deployed, or production-ready. The spec says no audit has happened.

## What's in this commit

| Path | What it is |
|---|---|
| `docs/sources/*.pdf` | Supplied source documents, unmodified: the spec, the canonical config dump, the review test suite, and the review response. |
| `config/furnace.config.canonical.json` | The v5.3.1 config, rebuilt from `furnace.config.canonical.pdf`. It is **verified byte-exact**: it has 27,108 chars and 27,158 UTF-8 bytes, and its Keccak-256 equals the spec's published hash. |
| `scripts/config-hash.ts` | `pnpm config:hash`. It serializes per spec §23 (recursive key sort, array order kept, compact `JSON.stringify`, Keccak-256 over UTF-8). |
| `scripts/verify-create3.ts` | Recomputes all 9 CreateX CREATE3 addresses from their salts and checks the vanity prefixes. It is read-only and never writes config. |

```sh
pnpm install
pnpm check   # config:verify-hash + verify:create3
```

Verified hash: `0x9ecedb63d5d10951caaf506032a1cf6d14b9e2196f236e2d2a45c200870463f7`

## What this JSON is not

The JSON is the **data** of `furnace.config.ts`. It is not that file. The supplied sources do not include the TypeScript module or its helpers: `validateConfig`, `epochAllocation`, `totalMintForEpoch`, `heatMultiplier`, `deedHeatAge`, `contractAddress`, `namePresets`, and others. The review suite (`docs/sources/furnace.review.test.pdf`, 66 checks) imports those helpers. It also needs `hash-registry.json`, which was not supplied. **So the review suite has not been run here.** Its claimed 66/66 pass is unverified in this repo.

These helpers have not been rewritten here on purpose. A rewrite would be a new draft, not the canonical artifact.

## Deploy blockers (present in the config by design)

- `deployment.evm.deployer` is the placeholder `0x1111…1111`, so all 9 mined addresses are **provisional**.
- `deployment.evm.treasurySafe.saltNonce` is `null`.
- `treasury.addresses.*` and `security.guardian.*` are zero or empty on every chain.
- `treasury.controller.signers` is `[]`. `threshold: 2` has no signer count. Spec §27 recommends 3-of-5.
- `chains[*].lz.dvns` is `[]` on every chain, but `requiredDvnCount` is 2.
- `deployment.svm.upgradeAuthority` is `""`. The Solana keypairs under `keys/` are not in the repo (gitignored).

## Open decisions (recorded, not resolved)

1. **Emission split.** The config stores `split: {flatPct: 30, heatPct: 70}` and `convictionBucketPct: 10`. Spec §10 derives 27/63/10, and 27/73 when nobody is sealed. §12 says 30/70. The review response's Decision 1 (unused conviction returns pro-rata vs. Heat-pool-only) is still open.
2. **Casting in Ember Vault.** The config sends both single-token pools to liquid EMBER (`casting.singleTokenFallback: "liquidEmber"`). Review Decision 2 recommends a per-pool rule: Ember Vault → source-lot EMBER, Cold Storage → liquid EMBER. Not yet adopted.
3. **Deed age wording.** §5 says "inherits 80% of age"; §25 says "80% haircut". The config has `heatCarryPct: 80`.
4. **Pyre self-rebate.** §8 says no rebate; §12 allows partial self-recapture (0.25·p).
5. **Green UI elements.** §11 says Withdraw Now is the only green element, but Claim Now is also green.
6. **Contract-layer items** from review §8: a global supply ledger that counts in-flight OFT, funded Kindling refunds, bounded accrual, and integer settlement with explicit residuals.

## Next steps

1. Supply the real `furnace.config.ts` and `hash-registry.json`, then run `furnace.review.test.ts` as a CI gate.
2. Resolve decisions 1–2 above before writing `epochAllocation`, Casting, or Forge reward accounting.
3. Set up Foundry for the core contracts: EmberToken/AshToken OFTs, Forge, FeeRouter, Deeds, Relics, Hearth, Ignition, Kindling. Write invariant tests per spec §27.8.
