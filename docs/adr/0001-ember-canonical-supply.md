# ADR 0001: EMBER canonical supply, minting and bridging

**Status:** Proposed. `EmberToken` (home chain) is implemented. The OFT adapter, the satellite OFT and burn reconciliation are not built yet.
**Date:** 2026-10-04 · **Config:** v5.3.2

## Context

The spec says EMBER has one canonical supply on every chain, a live 21M ceiling, and a single headroom budget shared by base emission and Ashfall:

```
mint = min(target, 21M − totalSupply)
```

Review §8 flags the gap. With burn/mint OFTs on every chain, no single chain's `totalSupply` is the global supply, and tokens in flight are invisible. Headroom computed locally could therefore over-mint.

## Decision

1. **Ethereum is the only chain where EMBER is minted.** `EmberToken` on Ethereum is a plain ERC-20 (Permit, Burnable). It has no owner, no pause, no tax and no upgrade path.
2. **Bridging uses a LayerZero OFT adapter (lockbox) on Ethereum.** Satellites (BNB Chain, Base, Arbitrum, Solana) run burn/mint OFTs that only the adapter path can mint. Tokens that leave Ethereum are locked, not burned. Ethereum's `totalSupply()` therefore always counts satellite supply and in-flight tokens. Headroom computed from it can only be understated, never overstated.
3. **One minter: the emission controller hosted by the Forge** (`MINTER = FurnaceParams.FORGE`). It mints base emissions, Ashfall and the treasury vesting stream, all inside `EmissionMath.totalMintForEpoch`. Per-chain emission shares (45/20/15/10/10) are minted on Ethereum and bridged out.
4. **The Kindling seed (420,000) is minted once in the constructor** to the Kindling registry address. This keeps the constructor argument-free for CREATE3. No other allocation is pre-minted.
5. **Satellite burns do not reopen headroom until they are reconciled.** A satellite burn reduces real supply, but the matching tokens stay locked on Ethereum. A later burn-report message, authenticated by LayerZero DVNs, will burn the matching amount from the lockbox. Until then headroom is conservative.
6. **Only real `burn()` reduces supply.** A transfer to `0x…dEaD` leaves `totalSupply` unchanged and does not reopen headroom. This matches its 0% Ashfall recycle rate.

## Consequences

- **Good:** the live-supply ceiling is enforced in one contract (`_update` guard) on one chain, and no cross-chain ledger is needed for safety.
- **Good:** in-flight OFT transfers are counted automatically, which closes review §8's in-flight item for EMBER.
- **Cost:** emissions for satellite chains need a bridge hop. Burns on satellites (Vent burn lanes) only reopen headroom after reconciliation, so late-stage tail emissions lag satellite burns. This fails safe.
- **Config wording:** `deployment.evm.contracts.EmberToken.description` says "LayerZero OFT protocol token". On Ethereum it is the canonical ERC-20 plus an adapter, and the same CREATE3 address carries the OFT bytecode on satellites. The next config revision should clarify that description, and decide whether the adapter needs its own registry entry. CREATE3 addresses don't depend on bytecode, so the same address on every chain still holds.
- **Open:** the satellite OFT also needs an argument-free constructor plus an initialize step inside the CREATE3 deploy transaction (`initializeInDeployTx: true`), because LayerZero's OFT constructor takes `(endpoint, delegate)`. A treasury vesting contract is still to be written. The burn-report message format and its DVN requirements are still to be designed.

## Alternatives rejected

- **Burn/mint OFT on every chain plus a global supply ledger.** This needs authenticated supply reports from every chain and in-flight accounting before any mint is safe. It is more moving parts on the critical path for the cap.
- **Minting the per-chain emission share on each satellite.** This creates five mint sites, each needing a global headroom view, and the spec forbids per-chain economic supply.
