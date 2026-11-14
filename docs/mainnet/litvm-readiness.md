# LitVM mainnet: readiness

Status: **not ready.** Nothing is deployed and nothing is audited. LitVM mainnet has not published a chain id or RPC (LitVM's docs, checked November 2026). This page lists what stands between this repository and a LitVM mainnet deployment, in the order it must be cleared.

## The gate

`pnpm mainnet:gate` reads [`deployments/litvm-mainnet.gate.json`](../../deployments/litvm-mainnet.gate.json) and prints every blocker. It exits 1 while any remain.
- **Live checks.** With an RPC in the record, the gate queries the chain. It checks the chain id, CreateX's runtime hash, the Cancun opcodes, and that every module, token and the deployer have the code they should.
- **Rehearsal.** Run against LiteForge with a scratch record, the live checks pass: the chain id, CreateX's hash, and the PUSH0, TSTORE/TLOAD and MCOPY probes.
- **CI.** `pnpm mainnet:gate:check` runs offline in `pnpm check`. It fails if the record is malformed, or if the gate ever reports no blockers.
- **No mainnet broadcast script exists, by design.**
  - The testnet kit refuses every chain id outside its testnet list (4441 and 31337).
  - A mainnet deployment also needs the canonical deployment gate (`canonical/DEPLOYMENT.md`), which is Ethereum-only today.

**Fill the record only from verified sources.** The gate's live checks are not a substitute for those sources. Never put a key in it.

## Blockers, in order

1. **The chain.**
   - LitVM must publish the mainnet chain id, RPC and explorer.
   - Record them with their sources, then verify them with the gate's live run.
   - Re-check the Orbit facts that matter here: timestamps, the per-block gas limit (the largest deployment transaction is 12.48M), and the gas token.
2. **The canonical decision.** The canonical config's chains are Ethereum, BSC, Base, Arbitrum and Solana, and v5.5's launch gate is Ethereum-only.
   - Adding LitVM is the project owner's decision. It changes the config hash, and every generated constant follows.
   - Its quote asset needs the same decision. That is SmelterPool's pair asset: bridged WETH or wrapped zkLTC.
3. **The factory and the opcodes.**
   - CreateX must be at `0xba5E…ba5Ed` with the known runtime hash.
   - PUSH0, TSTORE/TLOAD and MCOPY must execute. The pools' and pairs' reentrancy guards use transient storage.
4. **The modules the testnet fills with an operator wallet or a stand-in.** Each must be a contract at a mined address:
   - Treasury (a 3-of-5 Safe with real owners) and the guardian;
   - the Deed market;
   - the protected valuation source, and Relics: its Pyre ledger and its fee-rebate perk;
   Flow ([ADR 0016](../adr/0016-flow.md)), the fee router, the Vent ([ADR 0020](../adr/0020-vent.md)), Kindling with its GenesisFeeEscrow and the permanent LP sink ([ADR 0021](../adr/0021-kindling.md)), ASH's ledger and Kindling bonus ([ADR 0022](../adr/0022-ash.md)), Ignition ([ADR 0023](../adr/0023-ignition.md)), the epoch splitters ([ADR 0024](../adr/0024-epoch-splitters.md): `ForgeAsh`, the stayers' share, Quote yield and the Sealed-pot stream), the Hearth ([ADR 0025](../adr/0025-hearth.md), at its mined address), and the Compounder ([ADR 0026](../adr/0026-casting.md): the compounder and the match reserve in one contract) are built and need only their mined addresses (AshToken's is mined). Ignition is every pool's `IGNITION` and `FOUNDERS` (the gate's `Ignition` and `Founders` slots hold its one address) and the ASH ledger's `IGNITION`; its WETH/USDC LP must be bound, and the LP must be verified, before it deploys. The Vent must also be registered with the Mantle as a Protocol burner. `ForgeAsh` must be the ASH ledger's `FORGE`, the two booked splitters the Vent's `STAKERS` and `QUOTE_YIELD`, and `SealedPotStream` ForgeEmissions' `SEALED_POT`; the ledger's vesting clock and ForgeEmissions' epoch clock must start together. The Hearth must be the Vent's `HEARTH`, with EMBER and each pair's quote asset as its fee assets. The Compounder must be the `COMPOUNDER` of LP pools 0 and 1, of Flow and of the Vent, and ForgeEmissions' `MATCH_RESERVE` (so the LP pools cast), with the permanent sink as its `SINK` and ForgeEmissions' epoch clock as its own; the Treasury's match-seed bucket funds its seed. Kindling must be the Mantle's `KINDLING`, BlastPool's initializer and pool 0's Kindling slot, with a `START` after Ignition's 24-hour free-exit window. The pairs they serve are built too ([ADR 0015](../adr/0015-ember-pairs.md)).
5. **The pairs' trust window** (ADR 0015). A CREATE3 address does not commit to code. The pairs must therefore deploy in the same broadcast as the core, or move to CreateX's CREATE2, which is a change to §23.
6. **The pools' immutable hooks: all built.** ForgePool cannot gain a hook without a migration, so every one ADR 0010 listed had to exist first. Built:
   - source-lot additions, the destination for Casting and Stoke into LP ([ADR 0017](../adr/0017-source-lot-additions.md));
   - Kindling positions and First Flame ([ADR 0018](../adr/0018-kindling-and-first-flame.md));
   - the head start ([ADR 0019](../adr/0019-head-start.md)).

   What remains is the modules that call them, in blocker 4, and the audits, in blocker 8.
7. **The deployer.** It must be a real key holder's EOA, not the canonical placeholder, and the record must name it. Every mined salt binds it.
8. **Audits.** The spec requires at least two independent audits before activation. Each must cover the exact commit to be deployed.

## What is ready

- **The testnet kit:**
  - the built core and the EMBER pairs, wired and tested offline against CreateX's real runtime;
  - rehearsed on a fork of LiteForge (52 transactions with the operator standing in for Kindling, 29 with the real Kindling; the largest 12.48M gas);
  - the real Kindling mode, end to end offline: raise, settlement on the real core, BlastPool's opening, the LP sink and pool 0 positions earning, or a failure that refunds;
  - the pairs deployable later, as an add-on.
  See [`docs/testnet/litvm-liteforge.md`](../testnet/litvm-liteforge.md).
- **The mainnet watch.** It reports the chain's facts once LitVM publishes them; that is blocker 1's input.
