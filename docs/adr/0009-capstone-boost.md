# ADR 0009: Capstone and the Boost contract

Status: accepted for this repository. Not audited, not deployed. Rules marked **[P]** are provisional readings of this repo, not canonical v5.5 rules.

## Context

- **Spec v5.5 §6:**
  - Capstone holds EMBER and earns no base emissions.
  - Its bonus is at most +0.5 ordinary Heat, reached at a held-value/LP-value ratio of 0.5.
  - Deposit and withdrawal fees are 1%, burned, and "the existing withdrawal timer applies".
  - Moving Capstone does not touch Streak or age.
  - Valuation must use "the pool's protected valuation checkpoint, not an arbitrary caller price".
- **Spec §8:** Pyre is an account-wide boost from registered burns, in three tiers of +0.05 each, capped at 0.15.
- **ADR 0008** gave ForgePool its bonus hook and set two requirements on the Boost contract:
  - the Capstone ratio's denominator is custody principal;
  - refreshes are rate-limited.
- **ForgeEmissions** already fixes a `CAPSTONE` address, which pulls vested Seal escrow (ADR 0007).
- **The Mantle** fixes its burn registrars at construction. Capstone fee burns are in the Protocol category, 50% recycled (ADR 0003).

## Decisions

**1. [P] One contract, three fixed roles.**
- `Boost` is every pool's `BOOST`, ForgeEmissions' `CAPSTONE` consumer, and a Protocol-category burn registrar. That means one mined address, and vested Seal escrow lands where the bonus is computed.
- Boost is deployed after the pools, the Mantle and ForgeEmissions, at the address each of them was given. Its constructor checks every wire and reverts `Miswired` otherwise:
  - ForgeEmissions' `CAPSTONE`;
  - every pool's `BOOST`;
  - its own registrar category in the Mantle.

**2. The Capstone ledger, per position `(pool, id)`.**
- **Deposit (owner, open position only).**
  - 1% is booked as a fee and the rest counts toward the bonus.
  - The bonus is then raised if the price sources answer. The deposit stands either way, and `BonusUnavailable` is emitted otherwise.
- **Escrow.** Anyone may move a position's vested Seal escrow (`takeCapstone`) into its Capstone, **with no fee** [P]: it was minted for that position. The bonus is then raised as for a deposit.
- **Withdrawal** (cooldown `sameAsWithdraw`) mirrors ForgePool's cooling plan:
  - a reference balance, frozen when the plan starts;
  - requests cumulative over the 72-hour horizon, against the same five tier timers;
  - quota consumed by a cancel or a lapse;
  - a 24-hour execution window, and a 1% fee.
  - **[P] One pending request at a time.** Splitting therefore buys nothing: three successive 10% requests wait 6, 12 and 24 hours.
  - A lapse returns the amount to the Capstone.
- **A closed position** keeps its Capstone withdrawable. Its bonus no longer matters.

**3. The formula.**
- **Capstone part:**
  - `capstoneUnits = ⌊50,000 · Capstone / ⌈value · 0.5⌉⌋`, capped at 50,000;
  - `value = ⌈custody · rate / RAY⌉`, the custody's EMBER value;
  - zero custody or a zero rate gives zero.
  - Both roundings err against the holder.
- **Pyre part:** 5,000 units per tier reached by the owner's cumulative registered burn (250, 1,250 and 6,250 EMBER), capped at 15,000.
- **Constants.** All of them are generated from the config (`CAPSTONE_*`, `PYRE_*`). `pnpm gen` fails if the Capstone or Pyre policy, or the tier count, changes.
- **Reference.** `scripts/boost-model.ts` is the BigInt reference. Generation checks it against the canonical float helpers `capstoneBonus` and `pyreBoost` to within one unit at realistic sizes. Floats cannot represent a wei edge, so the edges are exact-tested in Solidity instead.

**4. [P] The price sources are interfaces, not inventions.**
- Nothing in the canonical package defines the "protected valuation checkpoint" for Capstone. The protected TWAP it does define (30 minutes, 2% band) is Vent's.
- **Valuation.** Boost takes an immutable `IValuation.emberPerStake(pool)`: EMBER-wei per stake-token-wei, RAY-scaled, so a 6-decimal stake needs no other conversion.
- **Pyre.** Boost takes an immutable `IPyreLedger.pyreBurned(wallet)`. The Relics contract that records Pyre burns is not built.
- **The EMBER-staked pool** (`ember-single`) never reads the valuation, because its rate is exactly 1.
- **Overflow.** Custody stays below 2¹⁰⁶, so a rate below 2¹⁶⁰ cannot overflow the units. A larger rate counts as unavailable. (A realistic 6-decimal rate is about 1e39, which a 2¹²⁸ guard had wrongly rejected. The 6-decimal test caught it.)

**5. Only raising reads a price.**
- **A withdrawal request lowers the bonus with no price.** It scales the pool's *current* bonus by the remaining Capstone fraction.
  - Scaling the current bonus never raises it and never exceeds the true value.
  - Scaling Boost's own last value could raise it, because a top-up may have diluted the pool's bonus since (ADR 0008).
  - The Pyre part is scaled too, against the holder, until the next raise.
- **Execute and cancel make no price read and no pool call.**
- **Pool rejections never block a Capstone action.** Outside `refresh`, a pool that rejects the write (its record limit, ADR 0008) is reported (`BonusUnsynced`), not reverted.
- **Fees are only booked.** Anyone burns them through the Mantle with `burnFees`. So no Capstone exit depends on the valuation, the Pyre ledger, the pool's write, or the Mantle.

**6. [P] Refresh: lowering is open, raising is rationed.**
- `refresh(pool, id)` sets the bonus to its value now.
- Lowering is open to anyone at any time.
- Raising is open to the owner and, separately, to anyone else, each at most once per epoch. Neither side can use up the other's allowance.
- An unchanged value writes nothing.
- **Deposit and escrow raises are not rationed.** Each deposit costs a 1% burned fee, and escrow arrives only when a Seal vests.
- **Record growth from Boost is therefore bounded** by:
  - the valuation's cadence (lowering);
  - two raises per epoch;
  - fee-bearing deposits;
  - quota-bound withdrawals.

  That keeps ADR 0005's record-spam argument.

## Provisional defaults

| Topic | Default here | Why |
|---|---|---|
| Roles | One contract: BOOST, CAPSTONE, burn registrar | One mined address; escrow lands where the bonus is computed |
| Escrow into Capstone | No fee | Minted for the position |
| Pending Capstone withdrawals | One at a time | With the cumulative plan, splitting buys nothing |
| Valuation / Pyre sources | Immutable interfaces (RAY rate; cumulative burns) | Not defined canonically; not built |
| Raising | Once per epoch for the owner, once for anyone else | Bounds records without letting either side block the other |
| Lowering | Anyone, any time | A stale-high bonus is the only harmful staleness |

## Still required before any deployment

These are **not built**:
- **The valuation source.** The protected checkpoint behind `IValuation`, for the LP pools and `usdc-single`.
- **The Relics contract.** It records Pyre burns behind `IPyreLedger` and is the Mantle's Pyre-category registrar.
- **Deployment wiring.**
  - Boost's mined address goes into all four pools (`BOOST`), into ForgeEmissions (`CAPSTONE`) and into the Mantle's registrar list (Protocol).
- **Deed transfers** (ADR 0008).
  - The Capstone is keyed by position, so it follows a Deed once the pool can change owners.
  - Pyre does not transfer, so a sale needs a bonus refresh.
- **Stoke and compounding into Capstone** (spec §6, `DECISIONS.md`). Boost has no reward-claim path yet.

## Gas (`pnpm gas`: forge `--isolate`, optimizer 500 runs, solc-js 0.8.28)

| Path (32-lot position) | Gas |
|---|---:|
| Capstone deposit, raising the bonus | 1,267,271 |
| Capstone withdrawal request, lowering the bonus (no price) | 1,208,046 |
| Capstone withdrawal execution | 65,554 |
| `refresh`, raising the bonus | 1,190,307 |
| `burnFees` | 84,768 |

Raising or lowering a bonus costs about one record per active lot (ADR 0008). Execution touches no pool.

## Verification

- **Formula:** 46 Capstone vectors and 11 Pyre vectors, exactly equal to the BigInt reference. They cover:
  - 18- and 6-decimal stakes, and the EMBER pool;
  - one wei either side of the maximum;
  - zero custody and a zero rate;
  - every tier edge.
- **Unit tests (18).**
  - **Wiring and stakes:** the constructor's wire checks; EMBER-pool, 6-decimal and LP bonuses; Pyre.
  - **No price on withdrawals:** they request, cancel and execute while the valuation reverts, and a deposit stands while it is down.
  - **Limits:** an absurd rate counts as unavailable; splitting against the cumulative timer; lapse.
  - **Refresh:** separate raise allowances, with lowering open; dilution followed by a refresh.
  - **Ledgers and owners:** fees burned through the Mantle; escrow without fee; owner checks; a closed position's withdrawal.
- **Invariants:** random deposits, withdrawals, refreshes, top-ups, valuation moves and outages, and Pyre burns. They check that:
  - Capstone EMBER is fully backed (balance = Capstone + pending + booked fees);
  - a matured withdrawal inside its window always pays, and a cancel always succeeds, whatever the valuation does;
  - a withdrawal request never raises a bonus;
  - bonuses stay within the ceiling.

  A fixed-sequence probe shows the handler really reaches requests and executions.
- **Mutations:** 20 planted bugs in Boost, each run in its own worktree against every suite. **All 20 are caught.** They cover:
  - a withdrawal reading the valuation, or not lowering the bonus;
  - a non-cumulative or always-fresh plan;
  - unbooked deposit or withdrawal fees;
  - a shared raise allowance, no raise limit, or rationed lowering;
  - the EMBER pool reading the valuation;
  - the custody value rounded down;
  - a strict Pyre tier;
  - a lapse or a cancel not returned;
  - no owner check, or a deposit into a closed position;
  - execution before maturity;
  - no overflow guard, or one too tight for 6-decimal stakes;
  - a fee on escrow.

## Consequences and limits

- **Stale bonuses until someone refreshes:**
  - A price move leaves a bonus stale until a refresh. A stale-high bonus can be lowered by anyone at once.
  - A Capstone withdrawal also lowers the Pyre part until the next raise.
- **Trust in the sources.** A faulty valuation or Pyre ledger can mis-set bonuses within [0, 0.65]. That redistributes Heat and Ashfall rewards, never principal or Capstone EMBER. Both addresses are fixed at deployment.
- **Not audited or deployed.**
