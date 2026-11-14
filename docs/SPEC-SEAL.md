# The spec seal: Furnace's fixed scope and finish line

Sealed 2026-11-14, at the owner's word: "Seal the specs now and finish it."

## 1. What is sealed

- **The spec is the canonical v5.5.0 package in `canonical/`, and nothing else.** No new feature, module or parameter enters this repository's scope.
  - It holds 54 files, each pinned by `canonical/SHA256SUMS.json` (sha256 `ea6e50170f7ca4fb3b05b951c9e6cc93642bb5f5657aa109ad1d5359176b2338`).
  - Its config hash is `0x24f38f4aa11919503354bb5f8263978c7b3edc29723760928cb1eecdbafbe5ae`, reproduced independently.
  - `pnpm check` verifies both on every run, and `canonical/` is never edited.
- **The scope is v5.5's contract table** (`canonical/CONTRACTS.md`), plus the module slots the built core already names in its constructors (the mainnet gate's 22). Nothing outside those two lists will be built.
- **Interpretation is sealed too.** Every gap the spec leaves was read as recommended and marked [P] in its ADR. All of them are listed in one generated register, [PROVISIONAL.md](PROVISIONAL.md). `pnpm check` fails if that register falls out of date with the ADRs.
  - The owner confirms or overrules each reading there. Until then, each one is a deploy blocker.
  - A later [P] can only narrow a gap the sealed spec leaves open. It can never add scope.

## 2. Built (at seal time)

| Spec module | Status |
|---|---|
| Mantle and the burn-credit registry | built (ADR 0003) |
| EmberToken | built |
| AshToken, with its issuance ledger and the Kindling bonus | built (ADR 0022) |
| Forge: custody, settlement, Seals, Ashfall, Capstone/Boost, Stoke, Taps, and the Deed, Kindling, First Flame and head-start hooks | built (ADR 0004–0014, 0017–0019) |
| GenesisFeeEscrow, Kindling and the permanent LP sink | built (ADR 0021) |
| Ignition | built (ADR 0023; PR #24) |
| ForgeAsh, the stayers' share, Quote yield and the Sealed-pot stream | built (ADR 0024; PR #25) |
| Hearth | built (ADR 0025; PR #26) |
| The match reserve and the compounder: Casting and the idle auto-pair | built (ADR 0026; step 4a) |
| BlastPool / SmelterPool | built (ADR 0015) |
| FeeRouter (the Vent) | built (ADR 0020) |
| Flow | built (ADR 0016) |

## 3. The finish line: what remains, in order

Each step is one PR, held to the same bar as every module so far:
- an ADR, with its [P] readings in the register;
- a BigInt model and an exact differential replay where there is arithmetic;
- unit and fuzz tests, and invariants;
- a mutation pass, with every survivor caught or explained;
- the testnet kit's real mode, with a LiteForge fork dry run;
- the ABIs, the gate's slots, and the docs;
- a clean `pnpm check` and green CI.

1. ~~**Ignition**~~ (done; PR #24, ADR 0023).
2. ~~**ForgeAsh and the Vent's distributors.**~~ (done; PR #25, ADR 0024: one abstract `EpochSplitter` paying ForgeEmissions' own settled measures, deployed four times.)
   - `ForgeAsh` streams the Forge's 28,000 ASH to Forge stakers by the pools' ASH weights (500/200/300/0).
   - `Stakers` gets emergency-exit fees, `QuoteYield` is the Heat²-weighted sell-side yield, and `SealedPot` streams Seal forfeits.
   - These are four slots with one shape: pull fixed inflows, distribute by a published weight.
3. ~~**Hearth**~~ (done; PR #26, ADR 0025): ASH staking with funded local fee-asset indexes, fed by the Vent's 10%.
4. **The match reserve and the compounder,** in two PRs:
   - ~~**4a, Casting and the idle auto-pair**~~ (done; ADR 0026). The Compounder fills the `Compounder` and `MatchReserve` slots: it draws the Vent's liquidity lane and ForgeEmissions' match ledger, casts a quarter of the LP pools' ordinary base into the source lot through `addToLot`, and pairs idle unreserved quote with seed EMBER into the permanent sink.
   - **4b, Stoke into LP.** The remainder of each epoch's budget as source-bound Stoke entitlements, an ordinary-base ledger beside `unclaimed`, and the owner's consented zap through Flow's waiver.
5. **The protected valuation source and Relics.**
   - The valuation source is the checkpointed EMBER-per-stake rate Boost reads.
   - Relics are wallet history and activity-derived perks: the Pyre ledger Boost reads, and the fee-rebate tiers Flow reads.
6. **Deeds**: the auction, settling through the pools' built Deed hook.
7. **TreasuryVesting and Timelock**: the cumulative exact allocation release, and delayed authorized periphery changes (never core, balances, fee liabilities or exits).
8. **Code complete (v1.0).**
   - The dApp's genesis screens: an Ignition tab beside Kindling.
   - An audit package: scope, the spec seal, the [P] register, threat model, invariants, mutation results and test evidence.
   - A deployment runbook, generated from the gate.
   - A `v1.0.0` tag on main, reading **code complete, not audited, not deployed**.

When step 8 lands, Furnace is finished in this repository. What is left after that is outside the code (§4).

## 4. Outside the code: what only the world or the owner can supply

The mainnet gate (`pnpm mainnet:gate`) lists these and stays blocked until each is real:

- **LitVM mainnet itself:**
  - its published chain id, RPC and explorer, and their sources;
  - CreateX and the Cancun opcodes verified on it.
- **Adding LitVM to the canonical config,** which changes the config hash. That is a deliberate re-seal, never a silent edit.
- **Identities and assets:**
  - the real deployer;
  - the 3-of-5 Treasury Safe with five real owners;
  - the guardian;
  - USDC's address and SmelterPool's quote (bridged WETH or wrapped zkLTC);
  - the bound WETH/USDC LP for Ignition.
- **The pairs' trust window:** same-broadcast deployment, or CreateX's CREATE2 (a §23 change).
- **The owner's confirmation** of each entry in [PROVISIONAL.md](PROVISIONAL.md).
- **Two independent audits,** which the spec requires before activation.

Nothing here is deployed, and nothing here is audited. No key is held by this repository or its tooling.
