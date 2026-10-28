// Differential scenarios for ForgeEmissions + four ForgePools + the Mantle. Each action
// runs through SettlementModel; the Solidity test replays it and compares a keccak of
// the settlement state (budgets, pages, measures, credits, claims, balances) per step.
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex } from '@noble/hashes/utils.js';
import { DAY } from '../canonical/accounting';
import { Revert, MIN_STAKE_LP } from './forge-model';
import { SettlementModel, Phase } from './settlement-model';

export const S0 = 1_800_000_000n; // Mantle START in the settlement tests
const E = 10n ** 18n;
const HOUR = 3_600n;

export enum K { Open, Deposit, Request, Execute, Cancel, Emergency, Poke, Finalize, OpenEpoch, Advance, RequestClaim, ExecuteClaim }
export interface Act { kind: K; time: bigint; pool: number; pos: number; arg: bigint }

/** Word layout mirrored by contracts/test/ForgeEmissions.t.sol::snapshot. */
function words(m: SettlementModel, positions: number, now: bigint): bigint[] {
  const out: bigint[] = [];
  for (const pool of m.pools) out.push(pool.active, pool.frozen, pool.occupiedAt(now), BigInt(pool.positions.length));
  out.push(BigInt(m.mantle.length));
  for (const me of m.mantle) out.push(me.base, me.minted, me.released);
  out.push(BigInt(m.nextOpen), m.emberHeld);
  for (let e = 0; e < m.nextOpen; e++) for (let i = 0; i < 4; i++) {
    const pe = m.epoch(e, i);
    out.push(BigInt(pe.phase), BigInt(pe.positions), BigInt(pe.cursor), BigInt(pe.credited), pe.target, pe.admitted,
      pe.flat, pe.heat, pe.paid, pe.S, pe.W, BigInt(pe.earners.length));
    for (const id of pe.earners) { const x = m.measures.get(`${e}:${i}:${id}`)!; out.push(BigInt(id), x.s, x.w); }
  }
  for (let i = 0; i < 4; i++) for (let id = 1; id <= positions; id++) {
    const c = m.claims.get(`${i}:${id}`);
    out.push(m.unclaimed.get(`${i}:${id}`) ?? 0n, c?.amount ?? 0n, c?.maturesAt ?? 0n);
  }
  for (let id = 1; id <= positions; id++) out.push(m.emberOf.get(id) ?? 0n);
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
  return { positions: sc.positions, steps: sc.actions.length, reverts, credited: String(credited), actions: flat, hash, probe };
}

// ── scripted ──────────────────────────────────────────────────────────────
const at = (d: bigint, h = 0n, s = 0n) => S0 + d * DAY + h * HOUR + s;
const A = (kind: K, time: bigint, pool = 0, pos = 0, arg = 0n): Act => ({ kind, time, pool, pos, arg });
/** Finalize epoch e, open it, and advance every pool until it is done. */
function settle(time: bigint, e: number, pages = 3): Act[] {
  const out = [A(K.Finalize, time), A(K.OpenEpoch, time)];
  for (let i = 0; i < 4; i++) for (let k = 0; k < pages; k++) out.push(A(K.Advance, time, i, 0, BigInt(e)));
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
      if (ph === Phase.Measuring || ph === Phase.Crediting) work = [e, j];
    }
    const owed = [...m.unclaimed.entries()].filter(([, v]) => v > 0n).map(([k]) => k.split(':').map(Number));
    const waiting = [...m.claims.keys()].map((k) => k.split(':').map(Number));
    if (roll < 10) a = A(K.Finalize, now);
    else if (roll < 18) a = A(K.OpenEpoch, now);
    else if (roll < 36 && work) a = A(K.Advance, now, work[1], 0, BigInt(work[0]));
    else if (roll < 39) a = A(K.Advance, now, i, 0, BigInt(m.nextOpen + 1)); // not open: reverts
    else if (roll < 45 && owed.length) { const [pi, id] = owed[Number(rnd(BigInt(owed.length)))]; a = A(K.RequestClaim, now, pi, id); }
    else if (roll < 51 && waiting.length) { const [pi, id] = waiting[Number(rnd(BigInt(waiting.length)))]; a = A(K.ExecuteClaim, now, pi, id); }
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
  return { start: String(S0), names: all.map((s) => s.name), phases: Object.keys(Phase).length / 2, scenarios };
}
