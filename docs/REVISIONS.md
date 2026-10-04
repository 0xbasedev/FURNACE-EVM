# Config revisions

Every change to `furnace.config.ts` that alters its canonical hash gets a named revision. Record each one here and in `RECORDED` in `scripts/config-hash.ts`.

| Version | Hash (`pnpm config:hash`) | Chars / bytes | Source |
|---|---|---|---|
| 5.3.1 | `0x9ecedb63d5d10951caaf506032a1cf6d14b9e2196f236e2d2a45c200870463f7` | 27,108 / 27,158 | Spec PDF header and review response |
| 5.3.2 | `0xbaeb97a2a062763bc986f78e270812214d439bba2044fcdbdc99ad5c00b17270` | 27,456 / 27,510 | This repo |

## 5.3.2: resolves review Decisions 1 and 2

This is an **economic change**, not a cosmetic edit. Totals, caps, fees, timers and supply are unchanged. What changes is how emissions are routed inside an epoch.

**Decision 1: the unused Conviction bucket returns pro-rata.**
- The config field `forge.convictionTracks.bucketCap.unallocatedFlowsTo` changes from `heatPool` to `proRata`.
- In `epochAllocation()`, the unused part of the bucket now refills the flat and Heat pools in the 30/70 ratio. The 30/70 newcomer/loyalty split therefore holds in every epoch. Under v5.3.1 an epoch with no sealed positions split 27/73.
- Sealed escrow caps are unchanged: `cap = L·s·b/W`, with `L = 70% × 90% × E`.
- Who is affected: in epochs with little sealing, Heat-weighted positions get up to 3 percentage points less of the epoch, and flat (stake-weighted) positions get that share back.
- Supersedes spec §10 "27/73 with no seals". Spec §12's "30/70" now holds literally.

**Decision 2: Casting is per pool.**
- The config field `forge.casting.singleTokenFallback` is replaced by `forge.casting.singleTokenCast = { ember: 'sourceLot', other: 'liquidEmber' }`.
- LP pools are unchanged: cast LP goes into the source lot and is bounded by match-reserve coverage.
- **Ember Vault:** the 25% cast share joins the source lot as EMBER, at that lot's age. It needs no pairing and draws nothing from the match reserve, so "never paid liquid" holds in this pool.
- **Cold Storage:** liquid EMBER, as in v5.3.1.
- New helpers: `castDestination()` and `castForPool()`. New copy strings: `copy.warnings.castingNoteSingleEmber` and `copy.warnings.castingNoteSingleOther`.

**Tests**
- One review-suite assertion changes: the empty-bucket split is now 32.5%/67.5% (it was 31.75%/68.25%).
- `test/v5_3_2.test.ts` adds 19 checks.

**Spec follow-up.** The spec PDF still describes v5.3.1, including its hash in the header, §10 "27/73", and the §7 single-token casting rule. The next spec revision must update those sections.
