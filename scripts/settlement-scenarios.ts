// Differential scenarios for ForgeEmissions + four ForgePools + the Mantle. Each action
// runs through SettlementModel; the Solidity test replays it and compares a keccak of
// the settlement state (budgets, pages, measures, credits, claims, balances) per step.
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex } from '@noble/hashes/utils.js';
import { DAY, RAY } from '../canonical/accounting';
import { Revert, MIN_STAKE_LP, MAX_BONUS_UNITS } from './forge-model';
import { SettlementModel, Phase } from './settlement-model';

export const S0 = 1_800_000_000n; // Mantle START in the settlement tests
const E = 10n ** 18n;
const HOUR = 3_600n;

export enum K {
  Open, Deposit, Request, Execute, Cancel, Emergency, Poke, Finalize, OpenEpoch, Advance, RequestClaim, ExecuteClaim, Seal, SettleSeal,
  Burn, BurnForfeits, TakeCapstone, TakeMatchReserve, TakeSealedPot, Boost,
}
export interface Act { kind: K; time: bigint; pool: number; pos: number; arg: bigint }

/** Word layout mirrored by contracts/test/ForgeEmissions.t.sol::snapshot. */
function words(m: SettlementModel, positions: number, now: bigint): bigint[] {
  const out: bigint[] = [];
  for (const pool of m.pools) out.push(pool.active, pool.frozen, pool.occupiedAt(now), BigInt(pool.positions.length));
  out.push(BigInt(m.mantle.length), m.queued, m.accounted);
  for (const me of m.mantle) out.push(me.base, me.minted, me.released, me.ashfall, me.ashfallMinted, me.ashfallRolled);
  for (let e = 0; e <= m.epochAt(now); e++) out.push(m.credits.get(e) ?? 0n);
  out.push(BigInt(m.nextOpen), m.emberHeld);
  for (let e = 0; e < m.nextOpen; e++) for (let i = 0; i < 4; i++) {
    const pe = m.epoch(e, i);
    out.push(BigInt(pe.phase), BigInt(pe.positions), BigInt(pe.cursor), BigInt(pe.credited), BigInt(pe.escrowed), pe.target, pe.admitted,
      pe.bucket, pe.flat, pe.heat, pe.escrow, pe.paid, pe.S, pe.W, pe.C, BigInt(pe.earners.length), BigInt(pe.sealed.length),
      pe.ashfall, pe.ashfallPaid, pe.Q);
    const pr = m.progressOf(e, i);
    out.push(BigInt(pr.id), BigInt(pr.slot), pr.seg, BigInt(pr.seal), pr.s, pr.w, pr.ss, pr.sw, pr.q / RAY, pr.q % RAY);
    for (const id of pe.earners) {
      const x = m.measures.get(`${e}:${i}:${id}`)!;
      out.push(BigInt(id), x.s, x.w, x.b, x.c, x.escrow, BigInt(x.seal), x.q);
    }
  }
  for (let i = 0; i < 4; i++) for (let id = 1; id <= positions; id++) {
    const c = m.claims.get(`${i}:${id}`);
    const seals = m.pools[i].positions[id - 1]?.seals.length ?? 0;
    out.push(m.unclaimed.get(`${i}:${id}`) ?? 0n, c?.amount ?? 0n, c?.maturesAt ?? 0n, m.capstoneOwed.get(`${i}:${id}`) ?? 0n,
      BigInt(seals), BigInt(m.sealStatus(i, id, seals, now)));
    for (let k = 1; k <= seals; k++) out.push(m.sealEscrow.get(`${i}:${id}:${k}`) ?? 0n);
  }
  out.push(m.burnLane, m.matchReserve, ...m.sealedPot);
  for (let id = 1; id <= positions; id++) out.push(m.emberOf.get(id) ?? 0n);
  out.push(...m.consumerEmber, 0n); // the registrar burns all it receives
  return out;
}

const hashWords = (ws: bigint[]) => '0x' + bytesToHex(keccak_256(Uint8Array.from(ws.flatMap((w) => {
  if (w < 0n || w >= 1n << 256n) throw new Error('word out of range');
  return [...Array(32)].map((_, i) => Number((w >> BigInt(8 * (31 - i))) & 0xffn));
}))));

function apply(m: SettlementModel, a: Act): { model: SettlementModel; reverted: boolean } {
  const x = m.clone();
  try {
    const pool = x.pools[a.pool];
    switch (a.kind) {
      case K.Open:
        if (a.pos !== pool.positions.length + 1) throw new Error('scenario: Open must create the next position id');
        pool.open(a.arg, a.time); break;
      case K.Deposit: pool.deposit(a.pos, a.arg, a.time); break;
      case K.Request: pool.request(a.pos, a.arg, a.time); break;
      case K.Execute: pool.execute(a.pos, Number(a.arg), a.time); break;
      case K.Cancel: pool.cancel(a.pos, Number(a.arg), a.time); break;
      case K.Emergency: pool.emergency(a.pos, a.time); break;
      case K.Poke: pool.poke(a.pos, a.time); break;
      case K.Finalize: x.finalize(a.time); break;
      case K.OpenEpoch: x.openEpoch(a.time); break;
      case K.Advance: x.advance(Number(a.arg), a.pool, a.time); break;
      case K.RequestClaim: x.requestClaim(a.pool, a.pos, a.time); break;
      case K.ExecuteClaim: x.executeClaim(a.pool, a.pos, a.time); break;
      case K.Seal: pool.seal(a.pos, Number(a.arg), a.time); break;
      case K.SettleSeal: x.settleSeal(a.pool, a.pos, Number(a.arg), a.time); break;
      case K.Burn: x.burnRegistered(a.pos, a.arg, a.time); break;
      case K.BurnForfeits: x.burnForfeits(); break;
      case K.TakeCapstone: x.takeCapstone(a.pool, a.pos); break;
      case K.TakeMatchReserve: x.takeMatchReserve(); break;
      case K.TakeSealedPot: x.takeSealedPot(a.pool); break;
      case K.Boost: pool.setBonus(a.pos, a.arg, a.time); break;
    }
    return { model: x, reverted: false };
  } catch (e) {
    if (e instanceof Revert) return { model: m, reverted: true };
    throw e;
  }
}

interface Scenario { name: string; positions: number; actions: Act[] }

function record(sc: Scenario) {
  let m = new SettlementModel(S0);
  const flat: string[] = [], hash: string[] = [], probe: string[] = [];
  let reverts = 0;
  sc.actions.forEach((a, i) => {
    if (i > 0 && a.time < sc.actions[i - 1].time) throw new Error(`${sc.name}: time runs backwards at step ${i}`);
    let r: ReturnType<typeof apply>;
    try { r = apply(m, a); } catch (e) { throw new Error(`${sc.name} step ${i} (${K[a.kind]})`, { cause: e }); }
    m = r.model;
    if (r.reverted) reverts++;
    flat.push(String(a.kind), String(a.time), String(a.pool), String(a.pos), String(a.arg), r.reverted ? '1' : '0');
    hash.push(hashWords(words(m, sc.positions, a.time)));
    probe.push(String(m.emberHeld), String(m.nextOpen), String(m.mantle.length));
  });
  const credited = [...m.epochs.values()].reduce((n, pe) => n + pe.paid, 0n);
  const ashfall = [...m.epochs.values()].reduce((n, pe) => n + pe.ashfallPaid, 0n);
  const rolled = m.mantle.reduce((n, me) => n + me.ashfallRolled, 0n);
  return {
    positions: sc.positions, steps: sc.actions.length, reverts, credited: String(credited), ashfall: String(ashfall), ashfallRolled: String(rolled),
    actions: flat, hash, probe,
  };
}

// ── scripted ──────────────────────────────────────────────────────────────
const at = (d: bigint, h = 0n, s = 0n) => S0 + d * DAY + h * HOUR + s;
const A = (kind: K, time: bigint, pool = 0, pos = 0, arg = 0n): Act => ({ kind, time, pool, pos, arg });
/** Finalize epoch e, open it, and advance every pool until it is done. */
function settle(time: bigint, e: number, pages = 3, pools = [0, 1, 2, 3]): Act[] {
  const out = [A(K.Finalize, time), A(K.OpenEpoch, time)];
  for (const i of pools) for (let k = 0; k < pages; k++) out.push(A(K.Advance, time, i, 0, BigInt(e)));
  return out;
}

const scripted: Scenario[] = [
  { name: 'steadyTwoStakers', positions: 2, actions: [
    A(K.Open, at(0n), 0, 1, 1000n * E),
    A(K.Open, at(0n, 6n), 0, 2, 500n * E),
    A(K.Open, at(0n, 12n), 2, 1, 300n * E),
    A(K.OpenEpoch, at(1n)), // not finalized yet
    ...settle(at(1n, 1n), 0),
    A(K.RequestClaim, at(1n, 2n), 0, 1),
    A(K.RequestClaim, at(1n, 2n), 0, 1), // pending
    A(K.ExecuteClaim, at(2n, 1n), 0, 1), // not matured (+23h)
    A(K.ExecuteClaim, at(2n, 2n), 0, 1),
    ...settle(at(2n, 3n), 1),
    A(K.RequestClaim, at(2n, 4n), 0, 2),
    A(K.ExecuteClaim, at(3n, 4n), 0, 2),
    A(K.RequestClaim, at(3n, 5n), 2, 1),
    A(K.ExecuteClaim, at(4n, 5n), 2, 1),
  ] },
  { name: 'touchedBeforePage', positions: 1, actions: [
    A(K.Open, at(0n), 0, 1, 1000n * E),
    // Epoch 0 is over but unsettled: these touches change the head and must not
    // change epoch 0's measure (they push its state into history).
    A(K.Deposit, at(1n, 1n), 0, 1, 400n * E),
    A(K.Request, at(1n, 2n), 0, 1, 300n * E),
    A(K.Cancel, at(1n, 2n), 0, 1, 1n), // same instant: overwrite in place
    A(K.Request, at(1n, 3n), 0, 1, 200n * E),
    ...settle(at(1n, 4n), 0),
    ...settle(at(2n, 1n), 1),
  ] },
  { name: 'lapseInsideEpoch', positions: 1, actions: [
    A(K.Open, at(0n), 0, 1, 1000n * E),
    A(K.Request, at(0n, 1n), 0, 1, 99n * E), // 10% → 6h; lapses at +31h, inside epoch 1
    ...settle(at(3n), 0), // the page's poke back-dates the lapse to its deadline
    ...settle(at(3n), 1),
    ...settle(at(3n), 2),
  ] },
  { name: 'partialOccupancy', positions: 2, actions: [
    A(K.Open, at(0n), 0, 1, 100n * E),
    A(K.Open, at(0n, 12n), 1, 1, 100n * E), // half an epoch in pool 1
    A(K.Emergency, at(0n, 18n), 0, 1), // pool 0 occupied 18h, then empty
    A(K.Open, at(0n, 20n), 0, 2, 50n * E), // a newcomer for the last 4h
    ...settle(at(1n), 0),
    A(K.RequestClaim, at(1n, 1n), 0, 1), // closed positions keep their rewards
    A(K.ExecuteClaim, at(2n, 1n), 0, 1),
    A(K.Advance, at(2n, 1n), 3, 0, 0n), // empty pool: nothing to advance
  ] },
  { name: 'latePages', positions: 3, actions: [
    A(K.Open, at(0n), 0, 1, 800n * E),
    A(K.Open, at(0n, 3n), 0, 2, 200n * E),
    A(K.Open, at(0n, 5n), 1, 1, 50n * E),
    A(K.Open, at(1n, 2n), 3, 1, 70n * 10n ** 6n),
    A(K.Deposit, at(1n, 7n), 0, 2, 100n * E),
    A(K.Request, at(2n), 0, 1, 79n * E),
    A(K.Execute, at(2n, 6n), 0, 1, 1n),
    A(K.Open, at(2n, 8n), 0, 3, 10n * E),
    A(K.Request, at(3n, 1n), 1, 1, 49n * E / 2n),
    A(K.Emergency, at(4n, 2n), 0, 2),
    // A keeper that was away for five days settles everything at once.
    ...settle(at(5n, 1n), 0), ...settle(at(5n, 1n), 1), ...settle(at(5n, 1n), 2), ...settle(at(5n, 1n), 3), ...settle(at(5n, 1n), 4),
    A(K.RequestClaim, at(5n, 2n), 0, 1), A(K.RequestClaim, at(5n, 2n), 0, 2), A(K.RequestClaim, at(5n, 2n), 0, 3),
    A(K.RequestClaim, at(5n, 2n), 1, 1), A(K.RequestClaim, at(5n, 2n), 3, 1),
    A(K.ExecuteClaim, at(6n, 2n), 0, 1), A(K.ExecuteClaim, at(6n, 2n), 0, 2), A(K.ExecuteClaim, at(6n, 2n), 1, 1),
  ] },
  { name: 'claimSnapshot', positions: 1, actions: [
    A(K.Open, at(0n), 2, 1, 100n * E),
    ...settle(at(1n), 0),
    A(K.RequestClaim, at(1n, 1n), 2, 1),
    ...settle(at(2n), 1), // credited after the snapshot: stays unclaimed
    A(K.ExecuteClaim, at(2n, 1n), 2, 1),
    A(K.RequestClaim, at(2n, 1n), 2, 1),
    A(K.ExecuteClaim, at(3n, 1n), 2, 1),
    A(K.RequestClaim, at(3n, 2n), 2, 1), // nothing left
  ] },
];
// ── Seals (ADR 0006) ─────────────────────────────────────────────────────
scripted.push(
  { name: 'sealCapBinds', positions: 2, actions: [
    // A small 30-day sealer beside a large unsealed staker: its escrow is capped at the
    // additive worth of +0.15 in the Heat budget, and the rest of the bucket returns.
    A(K.Open, at(0n), 0, 1, 100n * E),
    A(K.Open, at(0n), 0, 2, 900n * E),
    A(K.Seal, at(0n, 1n), 0, 1, 0n),
    ...settle(at(1n), 0, 4, [0]), // measure, escrow, credit
    A(K.SettleSeal, at(1n, 1n), 0, 1, 1n), // still running: SealNotEnded
    ...settle(at(2n), 1, 4, [0]),
    A(K.RequestClaim, at(2n, 1n), 0, 1), // only the ordinary part is claimable
    A(K.ExecuteClaim, at(3n, 1n), 0, 1),
  ] },
  { name: 'sealCandidateBinds', positions: 2, actions: [
    // Two sealers alone in a pool: each takes its C-share of the bucket, under its cap.
    A(K.Open, at(0n), 1, 1, 1000n * E),
    A(K.Open, at(0n), 1, 2, 400n * E),
    A(K.Seal, at(0n), 1, 1, 3n),
    A(K.Seal, at(0n), 1, 2, 1n),
    ...settle(at(1n), 0, 4, [1]),
  ] },
  { name: 'sealVestLate', positions: 1, actions: [
    A(K.Open, at(0n), 2, 1, 500n * E),
    A(K.Seal, at(0n, 2n), 2, 1, 0n), // 30 days: due day 30 + 2h
    ...settle(at(1n), 0, 4, [2]), // credited while running: locked in sealEscrow
    A(K.SettleSeal, at(30n, 3n), 2, 1, 1n), // completed by time: escrow → Capstone ledger
    A(K.SettleSeal, at(30n, 3n), 2, 1, 1n), // nothing left
    ...settle(at(30n, 4n), 1, 4, [2]), // a late credit after completion goes straight there
    A(K.Seal, at(30n, 5n), 2, 1, 1n), // SealGap
    A(K.Seal, at(31n, 2n), 2, 1, 1n),
    A(K.TakeCapstone, at(31n, 3n), 2, 1), // the Capstone pulls the vested escrow
    A(K.TakeCapstone, at(31n, 3n), 2, 1), // nothing left: pays 0
  ] },
  { name: 'sealForfeitRouted', positions: 2, actions: [
    A(K.Open, at(0n), 0, 1, 600n * E),
    A(K.Open, at(0n), 0, 2, 600n * E),
    A(K.Seal, at(0n), 0, 1, 2n),
    A(K.Seal, at(0n), 0, 2, 1n),
    ...settle(at(1n), 0, 4, [0]),
    A(K.Request, at(1n, 6n), 0, 1, 10n * E), // pauses position 1's Seal
    A(K.Execute, at(1n, 12n), 0, 1, 1n), // forfeits it
    A(K.SettleSeal, at(1n, 13n), 0, 1, 1n), // routed 50/25/25
    A(K.Emergency, at(1n, 18n), 0, 2), // forfeits position 2's Seal
    ...settle(at(2n), 1, 4, [0]), // late credits of forfeited Seals are routed directly
    A(K.SettleSeal, at(2n, 1n), 0, 2, 1n),
    // The ledgers' consumers: the burn lane burns (no Ashfall credit), the others pull.
    A(K.BurnForfeits, at(2n, 2n)),
    A(K.TakeMatchReserve, at(2n, 2n)),
    A(K.TakeSealedPot, at(2n, 2n), 0),
    A(K.TakeSealedPot, at(2n, 2n), 1), // empty pot: pays 0
    A(K.TakeSealedPot, at(2n, 2n), 7), // UnknownPool
    A(K.BurnForfeits, at(2n, 3n)), // nothing left
  ] },
  { name: 'sealPausedInEpoch', positions: 1, actions: [
    A(K.Open, at(0n), 3, 1, 5n * 10n ** 9n),
    A(K.Seal, at(0n), 3, 1, 1n),
    A(K.Request, at(0n, 4n), 3, 1, 10n ** 8n), // paused from 4h ...
    A(K.Cancel, at(0n, 10n), 3, 1, 1n), // ... to 10h: no sealed measure in between
    A(K.Request, at(0n, 20n), 3, 1, 10n ** 8n), // 6h tier; lapses at +30h (inside epoch 1)
    ...settle(at(3n), 0, 4, [3]),
    ...settle(at(3n), 1, 4, [3]),
    ...settle(at(3n), 2, 4, [3]),
  ] },
);
{ // Ashfall (ADR 0007). A burn in epoch 31 funds epoch 32's Ashfall, split by pool weight.
  // Weight = stake·Heat² while the lot's actual participation AND the position's Streak are
  // both ≥ 30 days. Pool 0: position 1 is eligible all day; position 2's Streak restarted on
  // day 2 (an executed withdrawal), so it qualifies from day 32 + 9h, then it leaves by
  // emergency exit before its credit and forfeits its share; position 3 (day 3) is too young
  // until epoch 33. Pool 2 pays its one eligible staker; pool 3's fresh staker is not
  // eligible, so its share rolls back; pool 1 is empty. Epoch 33 redistributes the queue.
  const acts: Act[] = [
    A(K.Open, at(0n), 0, 1, 1000n * E),
    A(K.Open, at(0n), 0, 2, 3000n * E),
    A(K.Open, at(0n), 2, 1, 500n * E),
    ...settle(at(1n, 1n), 0, 2, [0, 2]),
    A(K.RequestClaim, at(1n, 2n), 0, 1),
    A(K.ExecuteClaim, at(2n, 2n), 0, 1),
    A(K.Request, at(2n, 3n), 0, 2, 297n * E), // ≤10%: 6h
    A(K.Execute, at(2n, 9n), 0, 2, 1n), // resets position 2's Streak
    A(K.Open, at(3n), 0, 3, 200n * E),
    A(K.Burn, at(3n, 1n), 0, 1, 10n ** 30n), // more EMBER than it has: reverts
  ];
  for (let e = 1; e <= 30; e++) acts.push(...settle(at(31n), e, 2, [0, 2]));
  acts.push(
    A(K.Open, at(31n), 3, 1, 1000n * 10n ** 6n),
    A(K.Burn, at(31n, 2n), 0, 1, 100n * E), // credits[31] = 50 EMBER
    ...settle(at(32n, 1n), 31, 2, [0, 2, 3]), // epoch 31's Ashfall comes from epoch 30: none
    A(K.Emergency, at(33n, 0n, 1800n), 0, 2), // after epoch 32 ended, before its credit
    ...settle(at(33n, 1n), 32, 3, [0, 2, 3]),
    ...settle(at(34n, 1n), 33, 3, [0, 2, 3]), // the rolled Ashfall, to the stayers
    A(K.RequestClaim, at(34n, 2n), 0, 1),
    A(K.ExecuteClaim, at(35n, 2n), 0, 1),
    A(K.RequestClaim, at(34n, 2n + 24n), 0, 2), // emergency-exited: still claims its base rewards
  );
  scripted.push({ name: 'ashfallHeatSquared', positions: 3, actions: acts });
}
{ // Ordinary bonus (ADR 0008). Positions 1 and 2 stake the same; position 1 is boosted to the
  // 0.65 maximum from 6h into epoch 0, so its Heat share is larger. Position 3 is sealed and
  // boosted: its candidate C (sealed W × Seal bonus) carries the ordinary bonus too. A top-up
  // on day 1 halves position 1's bonus (custody doubles) until BOOST refreshes it on day 2.
  const acts: Act[] = [
    A(K.Open, at(0n), 0, 1, 1000n * E),
    A(K.Open, at(0n), 0, 2, 1000n * E),
    A(K.Open, at(0n), 0, 3, 1000n * E),
    A(K.Seal, at(0n), 0, 3, 3n),
    A(K.Boost, at(0n, 6n), 0, 1, MAX_BONUS_UNITS),
    A(K.Boost, at(0n, 6n), 0, 3, 30_000n),
    ...settle(at(1n, 1n), 0, 4, [0]),
    A(K.Deposit, at(1n, 2n), 0, 1, 1000n * E),
    A(K.Boost, at(1n, 3n), 0, 2, MAX_BONUS_UNITS + 1n), // above the ceiling
    A(K.Boost, at(2n, 1n), 0, 1, MAX_BONUS_UNITS),
    ...settle(at(2n, 1n), 1, 4, [0]),
    ...settle(at(3n, 1n), 2, 4, [0]),
    A(K.RequestClaim, at(3n, 2n), 0, 1),
    A(K.ExecuteClaim, at(4n, 2n), 0, 1),
  ];
  scripted.push({ name: 'boostedHeat', positions: 3, actions: acts });
}
{ // Due lapses cost page budget (LAPSE_UNITS each): three positions with two lapses due
  // when the page runs; the second cannot fit after the first, so it waits for page two.
  const acts: Act[] = [];
  for (let id = 1; id <= 3; id++) acts.push(A(K.Open, at(0n), 0, id, 100n * E));
  for (let id = 1; id <= 3; id++) acts.push(A(K.Request, at(0n, 1n), 0, id, 5n * E)); // 6h tier: lapses at +30h
  for (let id = 1; id <= 3; id++) acts.push(A(K.Request, at(0n, 2n), 0, id, 4n * E));
  acts.push(...settle(at(2n, 12n), 0, 5, [0]));
  scripted.push({ name: 'lapseBudget', positions: 3, actions: acts });
}
{ // Record spam: 1-wei request + cancel each second piles ~300 records into one slot,
  // more than one page's segment budget; the position resumes across pages.
  const acts: Act[] = [A(K.Open, at(0n), 0, 1, 100n * E), A(K.Open, at(0n), 0, 2, 50n * E), A(K.Deposit, at(0n, 1n), 0, 1, 100n * E)];
  for (let k = 0n; k < 300n; k++) {
    acts.push(A(K.Request, at(0n, 2n, k), 0, 1, 1n));
    acts.push(A(K.Cancel, at(0n, 2n, k), 0, 1, k + 1n));
  }
  acts.push(A(K.Finalize, at(1n)), A(K.OpenEpoch, at(1n)));
  for (let k = 0; k < 5; k++) acts.push(A(K.Advance, at(1n), 0, 0, 0n));
  acts.push(A(K.RequestClaim, at(1n, 1n), 0, 2), A(K.ExecuteClaim, at(2n, 1n), 0, 2));
  scripted.push({ name: 'recordSpam', positions: 2, actions: acts });
}
{ // Pages: 20 + 15 lots fill the first page; the third position needs a second one.
  const acts: Act[] = [A(K.Open, at(0n), 0, 1, E), A(K.Open, at(0n), 0, 2, E), A(K.Open, at(0n), 0, 3, E)];
  for (let i = 1; i < 20; i++) {
    acts.push(A(K.Deposit, at(0n, BigInt(i)), 0, 1, E));
    if (i < 15) acts.push(A(K.Deposit, at(0n, BigInt(i)), 0, 2, E));
  }
  acts.push(A(K.Finalize, at(1n)), A(K.OpenEpoch, at(1n)));
  for (let k = 0; k < 4; k++) acts.push(A(K.Advance, at(1n), 0, 0, 0n));
  scripted.push({ name: 'pagedLots', positions: 3, actions: acts });
}

// ── seeded random ─────────────────────────────────────────────────────────
function randomScenario(name: string, seed: bigint, steps: number): Scenario {
  let x = seed;
  const rnd = (n: bigint) => { x = (x * 6364136223846793005n + 1442695040888963407n) & ((1n << 64n) - 1n); return (x >> 11n) % n; };
  const positions = 3;
  const acts: Act[] = [];
  let m = new SettlementModel(S0);
  let now = S0;
  const gaps = [0n, 0n, 1n, HOUR, 3n * HOUR, 6n * HOUR, 12n * HOUR, DAY, 30n * HOUR, 2n * DAY];
  for (let s = 0; s < steps; s++) {
    now += gaps[Number(rnd(BigInt(gaps.length)))];
    const roll = Number(rnd(100n));
    const i = Number(rnd(4n));
    const pool = m.pools[i];
    const opened = pool.positions.length;
    const pos = opened === 0 ? 1 : Number(rnd(BigInt(Math.min(opened + 1, positions)))) + 1;
    let a: Act;
    // Settlement work the keeper would do next: the earliest pool-epoch not yet done.
    let work: [number, number] | undefined;
    for (let e = 0; e < m.nextOpen && !work; e++) for (let j = 0; j < 4 && !work; j++) {
      const ph = m.epoch(e, j).phase;
      if (ph === Phase.Measuring || ph === Phase.Escrowing || ph === Phase.Crediting) work = [e, j];
    }
    const locked = [...m.sealEscrow.entries()].filter(([, v]) => v > 0n).map(([k]) => k.split(':').map(Number));
    const owed = [...m.unclaimed.entries()].filter(([, v]) => v > 0n).map(([k]) => k.split(':').map(Number));
    const waiting = [...m.claims.keys()].map((k) => k.split(':').map(Number));
    if (roll < 10) a = A(K.Finalize, now);
    else if (roll < 18) a = A(K.OpenEpoch, now);
    else if (roll < 36 && work) a = A(K.Advance, now, work[1], 0, BigInt(work[0]));
    else if (roll < 39) a = A(K.Advance, now, i, 0, BigInt(m.nextOpen + 1)); // not open: reverts
    else if (roll < 45 && owed.length) { const [pi, id] = owed[Number(rnd(BigInt(owed.length)))]; a = A(K.RequestClaim, now, pi, id); }
    else if (roll < 51 && waiting.length) { const [pi, id] = waiting[Number(rnd(BigInt(waiting.length)))]; a = A(K.ExecuteClaim, now, pi, id); }
    else if (roll < 54 && locked.length) { const [pi, id, k] = locked[Number(rnd(BigInt(locked.length)))]; a = A(K.SettleSeal, now, pi, id, BigInt(k)); }
    else if (pos > opened) a = A(K.Open, now, i, opened + 1, (i === 3 ? 10n ** 6n : MIN_STAKE_LP * 2n) + rnd(500n * E));
    else {
      const p = pool.positions[pos - 1];
      const active = p.lots.reduce((n, l) => n + l.amount, 0n);
      const live = p.pending.map((id) => p.tickets.get(id)!);
      const r2 = Number(rnd(100n));
      if (r2 < 20) a = A(K.Deposit, now, i, pos, rnd(300n * E) + 1n);
      else if (r2 < 55) a = A(K.Request, now, i, pos, active === 0n ? 1n : rnd(active) + 1n);
      else if (r2 < 70 && live.length) {
        const t = live[Number(rnd(BigInt(live.length)))];
        if (t.maturity > now) now = t.maturity;
        a = A(K.Execute, now, i, pos, BigInt(t.id));
      } else if (r2 < 82 && live.length) a = A(K.Cancel, now, i, pos, BigInt(live[0].id));
      else if (r2 < 83) a = A(K.Emergency, now, i, pos);
      else if (r2 < 93) a = A(K.Seal, now, i, pos, rnd(4n));
      else if (r2 < 97) a = A(K.Boost, now, i, pos, rnd(MAX_BONUS_UNITS + 2n)); // the top value reverts
      else a = A(K.Poke, now, i, pos);
    }
    acts.push(a);
    m = apply(m, a).model;
  }
  return { name, positions, actions: acts };
}
const random = [randomScenario('random0', 0x5e771en, 160), randomScenario('random1', 0xc0ffeen, 160), randomScenario('random2', 0xf0e5n, 200)];

export function settlementVectors() {
  const all = [...scripted, ...random];
  const scenarios: Record<string, ReturnType<typeof record>> = {};
  for (const sc of all) scenarios[sc.name] = record(sc);
  const ash = scenarios.ashfallHeatSquared;
  if (BigInt(ash.ashfall) === 0n || BigInt(ash.ashfallRolled) === 0n) throw new Error('the Ashfall scenario must credit and roll Ashfall');
  return { start: String(S0), names: all.map((s) => s.name), phases: Object.keys(Phase).length / 2, scenarios };
}
