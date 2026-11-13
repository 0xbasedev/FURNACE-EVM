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
   - Re-check the Orbit facts that matter here: timestamps, the per-block gas limit (the largest deployment transaction is 11.99M), and the gas token.
2. **The canonical decision.** The canonical config's chains are Ethereum, BSC, Base, Arbitrum and Solana, and v5.5's launch gate is Ethereum-only.
   - Adding LitVM is the project owner's decision. It changes the config hash, and every generated constant follows.
   - Its quote asset needs the same decision. That is SmelterPool's pair asset: bridged WETH or wrapped zkLTC.
3. **The factory and the opcodes.**
   - CreateX must be at `0xba5E…ba5Ed` with the known runtime hash.
   - PUSH0, TSTORE/TLOAD and MCOPY must execute. The pools' and pairs' reentrancy guards use transient storage.
4. **The modules the testnet fills with an operator wallet or a stand-in.** Each must be a contract at a mined address:
   - Treasury (a 3-of-5 Safe with real owners) and the guardian;
   - Kindling (each pair's initializer and pool 0's `openKindling` caller) and the fee router (the Vent);
   - the compounder (Flow's waiver caller and the LP pools' `addToLot` caller) and the Deed market;
   - the match reserve and the Sealed-pot stream;
   - the protected valuation source, and Relics: its Pyre ledger and its fee-rebate perk;
   - Ignition's First Flame record, which every pool reads as `FOUNDERS` ([ADR 0018](../adr/0018-kindling-and-first-flame.md)).
   Flow itself is built ([ADR 0016](../adr/0016-flow.md)) and needs only its mined address; the pairs it routes are built too ([ADR 0015](../adr/0015-ember-pairs.md)).
5. **The pairs' trust window** (ADR 0015). A CREATE3 address does not commit to code. The pairs must therefore deploy in the same broadcast as the core, or move to CreateX's CREATE2, which is a change to §23.
6. **The pools' remaining hook: the head start.** It is needed before an immutable mainnet deployment, scoped to the principal present when it is granted so later deposits cannot reuse it. The pools cannot gain it later without a migration.
   - Built already: source-lot additions, the destination for Casting and Stoke into LP ([ADR 0017](../adr/0017-source-lot-additions.md)), and Kindling positions and First Flame ([ADR 0018](../adr/0018-kindling-and-first-flame.md)).
   - Their callers and the founder record are module slots in blocker 4.
7. **The deployer.** It must be a real key holder's EOA, not the canonical placeholder, and the record must name it. Every mined salt binds it.
8. **Audits.** The spec requires at least two independent audits before activation. Each must cover the exact commit to be deployed.

## What is ready

- **The testnet kit:**
  - the built core and the EMBER pairs, wired and tested offline against CreateX's real runtime;
  - rehearsed on a fork of LiteForge (48 transactions, the largest 11.99M gas);
  - the pairs deployable later, as an add-on.
  See [`docs/testnet/litvm-liteforge.md`](../testnet/litvm-liteforge.md).
- **The mainnet watch.** It reports the chain's facts once LitVM publishes them; that is blocker 1's input.
