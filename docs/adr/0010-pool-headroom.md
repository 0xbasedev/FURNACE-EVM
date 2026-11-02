# ADR 0010: ForgePool's views move out, to make room for its remaining hooks

Status: accepted for this repository. Not audited, not deployed.

## Context

- **ForgePool is immutable**, and it was 102 bytes under EIP-170 after ADR 0008 and ADR 0009.
- **An inventory of the canonical package** found that at least five features still need entry points inside the pool. A later contract cannot add them.

| Feature | Canonical source | What the pool must do |
|---|---|---|
| Deeds | Spec §5, `CONTRACTS.md` (Deeds), `DECISIONS.md` | A listing lock, and a settlement that changes the owner, carries 80% of capped age and resets the Streak, all exactly once |
| Taps | Spec §9 | A Relic-gated withdrawal that draws the youngest lots first, with no age haircut and no Streak reset, against a fixed quota; an active Seal is forfeited |
| Source-lot compounding / Casting | Spec §4, §6, §7; `DECISIONS.md` | Add principal to an existing lot at that lot's age, from an authorized caller |
| Kindling positions | Spec §2–§3 | Open contributor positions for the Kindling contract, on demand |
| First Flame | Spec §2 | A wallet-bound 15-day financial-Heat floor in the measures, which never transfers through a Deed |

- **The budget.** These need roughly 2–2.5 KB together. Lowering optimizer runs frees at most about 500 bytes (24,474 → 23,985 at 1 run).

## Decision

**1. Sixteen read-only views leave the pool.**
- The pool keeps one `extsload(bytes32[] slots)`, which returns raw storage words.
- `ForgeView`, an internal library, decodes the pool's storage layout and serves the same API: `positionOf`, `lotOf`, `lotAt`, `historyAt`, `historyLength`, `historyMaskOf`, `lotCount`, `custodyOf`, `sealOf`, `pendingTickets`, `ticketOf`, `sliceOf`, `dueLapses`, `occupancyLength`, `occupancyAt` and `lapseQueueLength`.
- With `using ForgeView for ForgePool;`, every call site reads `pool.positionOf(id)` as before.
- **What stays in the pool:**
  - views that compute over records or the lapse heap: `epochMeasure`, `measureSlot`, `occupiedSecondsAt`;
  - the public counters, `feesOwed` and the immutables.
- **Result.** ForgePool goes from 24,474 to **20,681 bytes, 3,895 under the limit**.

**2. The storage layout becomes an interface.**
- `ForgeView` hardcodes the slots (positions 9, lots 10, history 11, pending 12, tickets 13, slices 14, Seals 15, occupancy 6, lapse heap 7) and each packed field's offset.
- A deployed pool never changes its layout. A source change that moves a field must update `ForgeView`, and two suites catch a mismatch:
  - `ForgeViewTest` compares every decoded view, across random custody, cooling, Seal, bonus and emergency actions, with the pool's own storage, which a harness subclass returns through Solidity's accessors;
  - the differential replays hash their state through `ForgeView` after every step, so they must match the BigInt models.
- **Pre-refactor reference.** The harness keeps the pool's former `lotAt`, `custodyOf` and `dueLapses` logic as the reference for those derived views.

**3. Hot paths read only what they use.**
- `briefOf` returns the owner, closure and bonus from two words. `ownerOf`, `historyMaskOf` and `ashfallForfeitedOf` read one word each.
- `dueLapses` reads the pending word only when tickets are pending.
- `custodyOf` reads the used lots and the pending tickets, not all 32 slots.
- ForgeEmissions reads a position's history mask once per page rather than once per slot.

**4. `ForgeLens` serves frontends and indexers.** It is a stateless contract that wraps `ForgeView` in external calls. It holds no authority and can be redeployed at will.

**5. Exit paths are unchanged.** No exit gained a call: every exit still makes exactly one external call, the token transfer.

## Gas (`pnpm gas`: forge `--isolate`, optimizer 500 runs, solc-js 0.8.28)

Each figure is measured before (ADR 0009) and after this change.

| Path | Before | After |
|---|---:|---:|
| Measure page: 32 positions with 1 lot each | 4,004,342 | 4,128,846 |
| … with Ashfall | 5,564,421 | 5,688,925 |
| Measure page: 1 position with 32 lots | 845,471 | 816,798 |
| … with Ashfall | 1,785,259 | 1,756,586 |
| Credit page: 32 earners, base + Ashfall (two mints) | 1,392,666 | 1,065,655 |
| Heaviest page of 32 positions with 8 due lapses each | 1,520,060 | 1,544,958 |
| Record-spammed epoch, heaviest page | 5,411,891 | 5,420,501 |
| `requestClaim` | 65,724 | 55,153 |
| Capstone deposit, raising 32 lots | 1,267,271 | 1,306,066 |
| Capstone withdrawal execution | 65,554 | 57,976 |

- **Pages are within ±3%.**
  - The 32-position page costs about 3.5k more per position: `dueLapses` is now one `extsload` call instead of a view call.
  - Pages over many slots got cheaper, because the history mask is cached per page.
- **Credits and claims got cheaper**, because they read one word where the old views copied the whole position.

## Consequences

- **Integrators** read positions through `ForgeLens`, `ForgeView` or `eth_getStorageAt`. The pool's ABI no longer has the sixteen views.
- **The next PRs** add the inventory's hooks within the freed 3.9 KB, one per PR: Deeds first, then Taps, source-lot additions, Kindling positions and the First Flame floor. Each must leave room for the rest.
- **Not audited or deployed.**
