# ADR 0003: Mantle issuance ledger

**Status:** Accepted. The project owner confirmed the vesting-start and seed defaults on 2026-10-25; the other defaults below remain provisional.
**Date:** 2026-10-19 · **Config:** v5.5.0 · **Code:** `contracts/src/Mantle.sol`

## Context

v5.5 makes the home-chain Mantle the only economic mint authority. Its rules:
- It reserves Genesis, vesting, base and Ashfall budgets before minting.
- Burns reduce the ledger only after "unique authenticated recognition".
- Transport never creates headroom.
- `headroom = max(0, cap − globallyAccountedSupply − reservedEconomicIssuance)`.

The spec leaves several mechanics open. This ADR records how the Mantle resolves them.

## Decisions

**1. The ledger is the Mantle's own, not `totalSupply()`.**
`accounted` = everything the Mantle minted, minus burns it recognized. `reserved` covers:
- the Kindling seed until it is minted;
- unreleased Treasury vesting;
- finalized but unminted epoch budgets.

The invariant `accounted + reserved ≤ 21M` is fuzzed. `totalSupply ≤ accounted` holds while bridging is off.

**2. Recognition is the burn itself.**
- **How a burn is registered:** a registrar (Vent burn lane, Pyre, …) calls `burnRegistered(amount)`. The Mantle burns the registrar's own EMBER and records the category in the same call.
- **Fixed categories:** each registrar's category is set at construction (Protocol: 50% recycled; Pyre: 25%), so no burn can be counted twice or relabeled.
- **Raw burns don't count:** `burn()` calls and transfers to the dead address are never recognized. Their headroom stays stranded. That is conservative, and consistent with the 0% rate for unsolicited burns.

**3. Epoch budgets work on a pull model.**
- **Finalizing:** `finalizeEpoch()` is permissionless and finalizes one epoch per call, strictly in order, after the epoch ends. Catch-up is bounded per call.
- **Budget size:** it reserves the full **global** `baseEmissionPerDay(e)` (exact, ADR 0002) plus the authorized Ashfall.
- **Chain shares:** they are never applied as a multiplier on the mint side. The distributor routes satellite shares out of the budget as funded transfers. EMBER's `MANTLE` is immutable, so a mint-side multiplier would under-issue for good if a later config lowered the home share. `pnpm gen` instead checks that the enabled shares sum to 100. Both are scaled pro-rata by `allocateMint` when headroom is short. The floor-rounding residue is tagged per epoch and never minted.
- **Pulls:** the DISTRIBUTOR (the Forge's emission controller) pulls with `mintBase` and `mintAshfall`. Supply equals what was actually paid out.
- **Unpaid base:** `releaseBase` returns base the distributor will never pay (for example, empty-pool time) to headroom. It is never re-issued to anyone, and each later epoch is still capped by its own schedule target, so releasing creates no windfall.

**4. Ashfall timing and rollover.**
- **One-epoch lag:** credits are recorded against the epoch in which they were recognized and fund the next finalized epoch.
- **Cap shortfall:** credits that couldn't be granted because of the cap stay queued.
- **Rollover:** `rollAshfall` puts credits nobody was eligible for back in the queue, so they roll forward and never vanish.

**5. No owner, no upgrade path, no pause.** The token, distributor, Kindling, Treasury, start time and registrars are all immutable.

## Defaults

| Question | Default here | Alternative | Status |
|---|---|---|---|
| When does Treasury vesting start? | At the Mantle `START` (epoch 0) | At successful Kindling settlement | **Confirmed** by the project owner, 2026-10-25 |
| What happens to the seed reservation if Kindling fails? | Stays reserved forever; there is no release path | Kindling releases it on terminal failure | **Confirmed** by the project owner, 2026-10-25 |
| Who handles Ashfall rollover? | The Mantle queue, via `rollAshfall` from the Forge | The Forge keeps its own pot | Provisional |
| Is unpaid base kept reserved? | Released when the distributor calls `releaseBase` | Kept reserved forever | Provisional |
| Raw / unsolicited burns | Never recognized | A permissionless sync to `totalSupply` (rejected: it can't attribute a category, and becomes unsafe once transport exists) | Provisional |

## Consequences and limits

- **Deployment order:** EMBER and the Mantle reference each other's addresses, so the Mantle's CREATE3 salt must be mined before EMBER deploys. It is currently unmined.
- **Transport claims are not implemented.** Bridging must stay disabled until the Mantle counts outstanding transport claims in `accounted`.
- **Verification:**
  - Vesting matches canonical `vested()` exactly.
  - Daily releases sum to exactly 500,000.
  - The near-cap scenario scales base and Ashfall pro-rata and queues the Ashfall shortfall.
  - Mutation checks fail the suite when the shortfall queue or the Ashfall lag is removed, or when Ashfall budgets are left out of the reservation.
  - The invariant suite starts with about 50,000 EMBER of headroom, so the ceiling, pro-rata scaling and shortfall paths really are exercised. Two equalities are enforced: Ashfall credits are conserved exactly, and `epochReserved` matches the budgets still outstanding.
