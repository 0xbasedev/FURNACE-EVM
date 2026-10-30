// Differential scenarios for ForgePool: action scripts run through the BigInt model
// (scripts/forge-model.ts). The Solidity test replays each action and compares a
// keccak of the full raw state, plus a few readable probes, after every step.
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex } from '@noble/hashes/utils.js';
import { DAY, RAY } from '../canonical/accounting';
import { ForgeModel, run, MAX_LOTS, MAX_PENDING, MIN_STAKE_LP, TIERS, WINDOW, HORIZON, SealStatus, MAX_BONUS_UNITS } from './forge-model';

export const T0 = 1_700_000_000n;
export const FUND = 10n ** 30n;
const E = 10n ** 18n;
const HOUR = 3_600n;

export enum Kind { Open, Deposit, Request, Execute, Cancel, Emergency, Poke, Collect, Seal, Boost }
export interface Action { kind: Kind; time: bigint; pos: number; arg: bigint }

interface Sim { model: ForgeModel; users: bigint[]; collector: bigint }

/** Word layout mirrored by contracts/test/ForgePool.t.sol::_snapshot. */
function words(s: Sim, positions: number, now: bigint): bigint[] {
  const m = s.model;
  const out: bigint[] = [];
  for (let id = 1; id <= positions; id++) {
    const p = m.positions[id - 1];
    if (!p) { out.push(...Array(26 + 5 * MAX_LOTS).fill(0n)); continue; }
    out.push(p.S, p.W, BigInt(p.lotCount), BigInt(p.reserved), BigInt(p.pending.length), p.paused, p.streakStart, p.last,
      p.closed ? 1n : 0n, p.ashfallForfeited ? 1n : 0n, p.plan?.start ?? 0n, p.plan?.reference ?? 0n, p.plan?.requested ?? 0n, BigInt(p.nextTicket - 1));
    const seal = p.seals[p.seals.length - 1];
    out.push(p.SS, p.SW, BigInt(p.seals.length), BigInt(seal?.track ?? 0), BigInt(seal?.status ?? SealStatus.None),
      seal?.start ?? 0n, seal?.pausedAt ?? 0n, seal?.pausedSeconds ?? 0n, seal?.endedAt ?? 0n, BigInt(seal?.cohort ?? 0));
    out.push(p.Q / RAY, p.bonus); // Ashfall weight, accrued independently; the contract's comes from records
    p.lots.forEach((l, j) => out.push(l.amount, l.age, l.part, BigInt(l.heldBy), BigInt(p.heads.get(j)?.seal ?? 0)));
    for (const tid of p.pending) {
      const t = p.tickets.get(tid)!;
      out.push(BigInt(tid), t.amount, t.maturity, 1n, t.poolApplied ? 1n : 0n);
      for (let j = 0; j < MAX_LOTS; j++) { const x = t.slices.get(j); out.push(x?.amount ?? 0n, x?.age ?? 0n, x?.part ?? 0n); }
    }
  }
  const queued = m.positions.reduce((n, p) => n + p.pending.filter((id) => !p.tickets.get(id)!.poolApplied).length, 0);
  out.push(m.active, m.frozen, m.occupiedAt(now), BigInt(m.occ.length), m.fees.deposit, m.fees.withdraw, m.fees.emergency,
    m.active + m.frozen + m.fees.deposit + m.fees.withdraw + m.fees.emergency, BigInt(queued), BigInt(m.positions.length), s.collector);
  for (let id = 1; id <= positions; id++) out.push(s.users[id - 1]);
  return out;
}

const hashWords = (ws: bigint[]) => '0x' + bytesToHex(keccak_256(Uint8Array.from(ws.flatMap((w) => {
  if (w < 0n || w >= 1n << 256n) throw new Error('word out of range');
  return [...Array(32)].map((_, i) => Number((w >> BigInt(8 * (31 - i))) & 0xffn));
}))));

function apply(s: Sim, a: Action): { sim: Sim; reverted: boolean } {
  const u = [...s.users];
  const r = run(s.model, (m) => {
    switch (a.kind) {
      case Kind.Open: {
        if (a.pos !== m.positions.length + 1) throw new Error('scenario: Open must create the next position id');
        m.open(a.arg, a.time); u[a.pos - 1] -= a.arg; return;
      }
      case Kind.Deposit: m.deposit(a.pos, a.arg, a.time); u[a.pos - 1] -= a.arg; return;
      case Kind.Request: m.request(a.pos, a.arg, a.time); return;
      case Kind.Execute: u[a.pos - 1] += m.execute(a.pos, Number(a.arg), a.time); return;
      case Kind.Cancel: m.cancel(a.pos, Number(a.arg), a.time); return;
      case Kind.Emergency: u[a.pos - 1] += m.emergency(a.pos, a.time); return;
      case Kind.Poke: m.poke(a.pos, a.time); return;
      case Kind.Collect: return;
      case Kind.Seal: m.seal(a.pos, Number(a.arg), a.time); return;
      case Kind.Boost: m.setBonus(a.pos, a.arg, a.time); return;
    }
  });
  if (r.reverted) return { sim: s, reverted: true };
  let collector = s.collector;
  if (a.kind === Kind.Collect) {
    const f = r.model.fees;
    collector += f.deposit + f.withdraw + f.emergency;
    r.model.fees = { deposit: 0n, withdraw: 0n, emergency: 0n };
  }
  return { sim: { model: r.model, users: u, collector }, reverted: false };
}

interface Scenario { name: string; lp: boolean; positions: number; actions: Action[] }

function record(sc: Scenario) {
  let sim: Sim = { model: new ForgeModel(sc.lp), users: Array(sc.positions).fill(FUND), collector: 0n };
  const flat: string[] = [], hash: string[] = [], probe: string[] = [];
  let reverts = 0, boosted = 0;
  sc.actions.forEach((a, i) => { if (i > 0 && a.time < sc.actions[i - 1].time) throw new Error(`${sc.name}: time runs backwards at step ${i}`); });
  for (const [i, a] of sc.actions.entries()) {
    let r: ReturnType<typeof apply>;
    try { r = apply(sim, a); } catch (e) { throw new Error(`${sc.name} step ${i} (${Kind[a.kind]} pos ${a.pos} arg ${a.arg} t ${a.time})`, { cause: e }); }
    sim = r.sim;
    if (r.reverted) reverts++;
    if (sim.model.positions.some((p) => p.bonus > 0n && p.lots.some((l) => l.amount > 0n))) boosted++;
    flat.push(String(a.kind), String(a.time), String(a.pos), String(a.arg), r.reverted ? '1' : '0');
    hash.push(hashWords(words(sim, sc.positions, a.time)));
    const m = sim.model, p1 = m.positions[0];
    probe.push(...[p1?.S ?? 0n, p1?.W ?? 0n, m.active, m.frozen, m.occupiedAt(a.time), p1?.SS ?? 0n].map(String));
  }
  const ashfall = sim.model.positions.filter((p) => p.Q > 0n).length;
  return { lp: sc.lp, positions: sc.positions, steps: sc.actions.length, reverts, ashfall, boosted, actions: flat, hash, probe };
}

// ── scripted scenarios ───────────────────────────────────────────────────
const at = (d: bigint, h = 0n, s = 0n) => T0 + d * DAY + h * HOUR + s;
const A = (kind: Kind, time: bigint, pos: number, arg = 0n): Action => ({ kind, time, pos, arg });
const net = (x: bigint) => x - x / 100n;

const scripted: Scenario[] = [
  { name: 'basicCycle', lp: true, positions: 1, actions: [
    A(Kind.Open, at(0n), 1, 1000n * E),
    A(Kind.Poke, at(10n), 1),
    A(Kind.Request, at(10n), 1, net(1000n * E) / 10n), // ≤10% → 6h
    A(Kind.Execute, at(10n, 5n), 1, 1n), // not matured
    A(Kind.Execute, at(10n, 6n), 1, 1n),
    A(Kind.Execute, at(10n, 7n), 1, 1n), // already executed
    A(Kind.Poke, at(40n), 1),
    A(Kind.Collect, at(40n), 0),
  ] },
  { name: 'cumulativeTiers', lp: true, positions: 1, actions: [
    A(Kind.Open, at(0n), 1, 1000n * E),
    A(Kind.Request, at(5n), 1, net(1000n * E) / 10n), // 10% → 6h
    A(Kind.Request, at(5n, 1n), 1, net(1000n * E) * 15n / 100n), // cum 25% → 12h
    A(Kind.Request, at(5n, 2n), 1, net(1000n * E) * 30n / 100n), // cum 55% → 48h
    A(Kind.Cancel, at(5n, 3n), 1, 2n), // quota stays consumed
    A(Kind.Request, at(5n, 4n), 1, net(1000n * E) / 2n), // cum 105% → PlanQuotaExceeded
    A(Kind.Request, at(5n, 4n), 1, net(1000n * E) * 45n / 100n), // cum 100% → 72h, but active < amount? (tests ExceedsActive vs quota)
    A(Kind.Execute, at(5n, 6n), 1, 1n),
    A(Kind.Execute, at(7n, 2n), 1, 3n),
    A(Kind.Poke, at(20n), 1),
    A(Kind.Request, at(20n), 1, 1n * E), // horizon passed, nothing pending → new plan
  ] },
  { name: 'overlapHaircut', lp: true, positions: 1, actions: [
    A(Kind.Open, at(0n), 1, 600n * E),
    A(Kind.Deposit, at(30n), 1, 400n * E),
    A(Kind.Request, at(60n), 1, 100n * E), // ticket 1 (A)
    A(Kind.Request, at(60n, 1n), 1, 200n * E), // ticket 2 (B), cum 30% → 24h
    A(Kind.Execute, at(61n, 2n), 1, 2n), // B executes: haircut lots AND A's slices
    A(Kind.Cancel, at(61n, 3n), 1, 1n), // A resumes at its haircut frozen age → new lots
    A(Kind.Poke, at(90n), 1),
  ] },
  { name: 'lapseLateTouch', lp: true, positions: 2, actions: [
    A(Kind.Open, at(0n), 1, 1000n * E),
    A(Kind.Open, at(0n, 1n), 2, 50n * E),
    A(Kind.Request, at(20n), 1, 300n * E), // 24h tier, lapses at +48h
    A(Kind.Poke, at(25n), 2), // other position touched: pool view only
    A(Kind.Poke, at(80n), 1), // late touch: resume back-dated to the deadline
    A(Kind.Execute, at(80n), 1, 1n), // lapsed → NotPending
  ] },
  { name: 'lapseIdlePool', lp: true, positions: 2, actions: [
    A(Kind.Open, at(0n), 1, 1000n * E),
    A(Kind.Request, at(10n), 1, net(1000n * E)), // 100% → pool idle
    A(Kind.Open, at(15n), 2, 10n * E), // pool processes the due lapse at its deadline first
    A(Kind.Emergency, at(15n, 1n), 2),
    A(Kind.Poke, at(30n), 1),
    A(Kind.Request, at(30n), 1, net(1000n * E)), // horizon passed → new plan, idle again
    A(Kind.Cancel, at(30n, 2n), 1, 2n),
    A(Kind.Request, at(31n), 1, net(1000n * E) / 4n), // plan quota: cancel consumed it → reverts
    A(Kind.Poke, at(40n), 1),
  ] },
  { name: 'cappedMerge', lp: true, positions: 1, actions: [
    A(Kind.Open, at(0n), 1, 1000n * E),
    A(Kind.Request, at(400n), 1, 400n * E), // capped lot split: one reserved slot
    A(Kind.Cancel, at(401n), 1, 1n), // equal capped state → merges back, slot released
    A(Kind.Deposit, at(402n), 1, 10n * E),
    A(Kind.Request, at(800n), 1, 200n * E),
    A(Kind.Cancel, at(800n, 1n), 1, 2n), // young lot differs → own slot; capped merges
    A(Kind.Poke, at(801n), 1),
  ] },
  { name: 'ashfallStreakReset', lp: true, positions: 2, actions: [
    // The Ashfall weight around a Streak reset (ADR 0007). Position 1 is eligible from day 30.
    // Its execute at day 40 + 6h resets the Streak: the records pushed then keep the old
    // anchor (eligible up to the reset), and the head written at the reset carries the new
    // one, so a record pushed at day 45 (within 30 days of the reset) is not eligible.
    // Eligibility returns at day 70 + 6h. Position 2 is the unreset control.
    A(Kind.Open, at(0n), 1, 1000n * E),
    A(Kind.Open, at(0n), 2, 1000n * E),
    A(Kind.Request, at(40n), 1, net(1000n * E) / 10n),
    A(Kind.Execute, at(40n, 6n), 1, 1n),
    A(Kind.Request, at(45n), 1, 10n * E),
    A(Kind.Cancel, at(45n, 1n), 1, 2n),
    A(Kind.Poke, at(75n), 1),
    A(Kind.Poke, at(75n), 2),
  ] },
  { name: 'emergencyWithPending', lp: false, positions: 3, actions: [
    A(Kind.Open, at(0n), 1, 777n * E),
    A(Kind.Open, at(1n), 2, 5n),
    A(Kind.Deposit, at(3n), 1, 123n * E),
    A(Kind.Request, at(9n), 1, 50n * E),
    A(Kind.Request, at(9n, 1n), 1, 100n * E),
    A(Kind.Emergency, at(9n, 2n), 1),
    A(Kind.Emergency, at(9n, 3n), 1), // closed
    A(Kind.Deposit, at(9n, 4n), 1, E), // closed
    A(Kind.Open, at(10n), 3, 1n), // single-asset pool: 1 wei nets 1 (the fee floors to 0)
    A(Kind.Collect, at(11n), 0),
  ] },
];
// ── Seals (ADR 0006) ─────────────────────────────────────────────────────
scripted.push(
  { name: 'sealPauseExtend', lp: true, positions: 1, actions: [
    A(Kind.Open, at(0n), 1, 1000n * E),
    A(Kind.Seal, at(1n), 1, 0n), // 30-day Ember track: the cohort is the one lot
    A(Kind.Deposit, at(2n), 1, 500n * E), // a top-up never joins
    A(Kind.Request, at(5n), 1, 100n * E), // pauses the Seal
    A(Kind.Seal, at(5n, 1n), 1, 1n), // CoolingPending
    A(Kind.Cancel, at(6n), 1, 1n), // resumes: the term extends by one day
    A(Kind.Poke, at(31n, 12n), 1), // not due yet (due on day 32)
    A(Kind.Seal, at(31n, 13n), 1, 2n), // SealActive
    A(Kind.Poke, at(33n), 1), // completed, back-dated to day 32
    A(Kind.Seal, at(33n), 1, 3n), // SealGap: needs one epoch after the end
    A(Kind.Seal, at(34n), 1, 3n), // a new 365-day Seal over both lots
    A(Kind.Poke, at(60n), 1),
  ] },
  { name: 'sealLapseUnpause', lp: true, positions: 1, actions: [
    A(Kind.Open, at(0n), 1, 1000n * E),
    A(Kind.Seal, at(0n), 1, 0n),
    A(Kind.Request, at(29n), 1, net(1000n * E)), // 100% → 72h, lapses at +96h (day 33)
    A(Kind.Poke, at(40n), 1), // lapse back-dated to day 33; due day 34; completed then
    A(Kind.Poke, at(41n), 1),
  ] },
  { name: 'sealForfeitExecute', lp: true, positions: 1, actions: [
    A(Kind.Open, at(0n), 1, 1000n * E),
    A(Kind.Seal, at(1n), 1, 1n),
    A(Kind.Deposit, at(3n), 1, 300n * E),
    A(Kind.Request, at(10n), 1, 50n * E),
    A(Kind.Execute, at(10n, 6n), 1, 1n), // forfeits the Seal
    A(Kind.Seal, at(10n, 7n), 1, 0n), // SealGap: one epoch after the forfeit
    A(Kind.Seal, at(11n, 6n), 1, 0n), // a fresh Seal over every lot, top-up included
    A(Kind.Poke, at(20n), 1),
  ] },
  { name: 'sealCohortJoin', lp: true, positions: 1, actions: [
    A(Kind.Open, at(0n), 1, 1000n * E),
    A(Kind.Deposit, at(0n, 1n), 1, 1000n * E),
    A(Kind.Seal, at(1n), 1, 2n), // cohort: slots 0 and 1
    A(Kind.Deposit, at(2n), 1, 1000n * E), // slot 2: not sealed
    A(Kind.Request, at(3n), 1, 300n * E), // pro-rata from all three: three reserved slots
    A(Kind.Request, at(3n, 1n), 1, 300n * E),
    A(Kind.Cancel, at(3n, 2n), 1, 1n), // slices → new slots: from 0 and 1 they join, from 2 not
    A(Kind.Poke, at(4n), 1),
    A(Kind.Cancel, at(4n, 1n), 1, 2n), // last ticket: the Seal resumes over the grown cohort
    A(Kind.Poke, at(10n), 1),
  ] },
  { name: 'sealEmergency', lp: false, positions: 2, actions: [
    A(Kind.Open, at(0n), 1, 1000n * E),
    A(Kind.Open, at(0n), 2, 10n * E),
    A(Kind.Seal, at(0n, 1n), 1, 3n),
    A(Kind.Seal, at(0n, 1n), 2, 4n), // UnknownTrack
    A(Kind.Request, at(5n), 1, 10n * E), // paused
    A(Kind.Emergency, at(6n), 1), // forfeited while paused
    A(Kind.Seal, at(40n), 1, 0n), // Closed
    A(Kind.Request, at(41n), 2, net(10n * E)),
    A(Kind.Execute, at(44n), 2, 1n), // position 2 is empty now
    A(Kind.Seal, at(44n, 1n), 2, 0n), // NothingToSeal
  ] },
);
// ── Ordinary bonus: Capstone + Pyre through BOOST (ADR 0008) ───────────────
scripted.push(
  { name: 'boostCycle', lp: true, positions: 2, actions: [
    // Position 1 is boosted through pending, lapsed, cancelled and executed tickets; position 2
    // is the unboosted control. Both reach Ashfall eligibility, and position 1 ends at the
    // maximum bonus past the age cap (canonical heatSeconds ≤ 3.65·stakeSeconds).
    A(Kind.Open, at(0n), 1, 1000n * E),
    A(Kind.Open, at(0n), 2, 1000n * E),
    A(Kind.Boost, at(1n), 1, 25_000n), // +0.25 from day 1
    A(Kind.Boost, at(1n), 3, 1n), // UnknownPosition
    A(Kind.Boost, at(2n), 1, MAX_BONUS_UNITS + 1n), // above the 0.65 ceiling
    A(Kind.Request, at(10n), 1, 99n * E), // ticket 1: its slice is frozen, not rewritten
    A(Kind.Boost, at(10n, 1n), 1, 40_000n), // a change with a ticket pending
    A(Kind.Boost, at(10n, 1n), 1, 40_000n), // unchanged: no rewrite
    A(Kind.Cancel, at(10n, 2n), 1, 1n), // the slice resumes under the new bonus
    A(Kind.Request, at(20n), 1, 99n * E), // ticket 2: lapses at day 21 + 6h
    A(Kind.Boost, at(40n), 1, 50_000n), // the sync resolves the lapse, back-dated, before the change
    A(Kind.Request, at(50n), 1, 99n * E), // ticket 3: matures at day 50 + 6h
    A(Kind.Boost, at(50n, 6n), 1, MAX_BONUS_UNITS), // the change and the Streak reset share an instant
    A(Kind.Execute, at(50n, 6n), 1, 3n),
    A(Kind.Poke, at(400n), 1),
    A(Kind.Poke, at(400n), 2),
    A(Kind.Emergency, at(401n), 1),
    A(Kind.Boost, at(402n), 1, 10_000n), // closed: keeps its bonus, no revert
    A(Kind.Poke, at(402n), 2),
  ] },
  { name: 'boostSealDeposit', lp: true, positions: 2, actions: [
    // The bonus inside a Seal's sealed W, and top-ups diluting it by custody before/after.
    A(Kind.Open, at(0n), 1, 1000n * E),
    A(Kind.Seal, at(0n, 1n), 1, 1n), // 90-day track
    A(Kind.Boost, at(5n), 1, 50_000n), // mid-Seal
    A(Kind.Deposit, at(10n), 1, 3000n * E), // custody ×4: the bonus quarters
    A(Kind.Deposit, at(10n), 1, 100n * E), // same instant: dilutes again, heads overwritten
    A(Kind.Request, at(20n), 1, 100n * E), // a pending slice still counts as custody
    A(Kind.Deposit, at(20n, 1n), 1, 500n * E),
    A(Kind.Boost, at(30n), 1, 0n),
    A(Kind.Deposit, at(31n), 1, 10n * E), // no bonus: no rewrite
    A(Kind.Poke, at(100n), 1), // the Seal completes, back-dated
    A(Kind.Open, at(100n), 2, 10n * E),
    A(Kind.Request, at(101n), 2, net(10n * E)), // 100%: position 2 empties
    A(Kind.Execute, at(104n), 2, 1n),
    A(Kind.Boost, at(104n, 1n), 2, 30_000n), // no active lot to rewrite
    A(Kind.Deposit, at(105n), 2, 10n * E), // custody was 0: the bonus drops to 0
    A(Kind.Poke, at(140n), 2),
  ] },
);
// Capacity edges: 16 young lots may split (16 + 16 = 32); 17 cannot, but 100% always can.
for (const n of [16, 17]) {
  const actions: Action[] = [A(Kind.Open, at(0n), 1, 100n * E)];
  for (let i = 1; i < n; i++) actions.push(A(Kind.Deposit, at(BigInt(i)), 1, 100n * E));
  const total = net(100n * E) * BigInt(n);
  actions.push(A(Kind.Request, at(40n), 1, total / 10n));
  actions.push(A(Kind.Request, at(40n, 1n), 1, total - total / 10n));
  actions.push(A(Kind.Request, at(40n, 2n), 1, total)); // quota exceeded unless the 10% reverted
  actions.push(A(Kind.Poke, at(45n), 1));
  scripted.push({ name: `capacity${n}`, lp: true, positions: 1, actions });
}
// Lot cap: 32 deposits fill the position; the 33rd reverts.
{
  const actions: Action[] = [A(Kind.Open, at(0n), 1, E)];
  for (let i = 1; i <= MAX_LOTS; i++) actions.push(A(Kind.Deposit, at(0n, BigInt(i)), 1, E));
  actions.push(A(Kind.Deposit, at(2n), 1, MIN_STAKE_LP)); // below minimum after fee
  scripted.push({ name: 'lotCap', lp: true, positions: 1, actions });
}

// ── seeded random scenarios ──────────────────────────────────────────────
function randomScenario(name: string, seed: bigint, steps: number, lp: boolean): Scenario {
  let x = seed;
  const rnd = (n: bigint) => { x = (x * 6364136223846793005n + 1442695040888963407n) & ((1n << 64n) - 1n); return (x >> 11n) % n; };
  const positions = 3;
  const actions: Action[] = [];
  let sim: Sim = { model: new ForgeModel(lp), users: Array(positions).fill(FUND), collector: 0n };
  let now = T0;
  const gaps = [0n, 0n, 1n, 59n, HOUR, HOUR, 6n * HOUR - 1n, 6n * HOUR, 12n * HOUR, DAY, WINDOW + 1n, 3n * DAY, 7n * DAY, 30n * DAY, HORIZON, 200n * DAY];
  for (let i = 0; i < steps; i++) {
    now += gaps[Number(rnd(BigInt(gaps.length)))];
    const m = sim.model;
    const opened = m.positions.length;
    const pos = opened === 0 ? 1 : Number(rnd(BigInt(Math.min(opened + 1, positions)))) + 1;
    let a: Action;
    if (pos > opened) a = A(Kind.Open, now, opened + 1, rnd(1000n * E) + MIN_STAKE_LP * 2n);
    else {
      const p = m.positions[pos - 1];
      const active = p.lots.reduce((n, l) => n + l.amount, 0n);
      const live = p.pending.map((id) => p.tickets.get(id)!).filter((t) => t.maturity + WINDOW > now);
      const anyId = BigInt(p.nextTicket > 1 ? Number(rnd(BigInt(p.nextTicket - 1))) + 1 : 1);
      const roll = Number(rnd(100n));
      const pick = <T,>(xs: T[]) => xs[Number(rnd(BigInt(xs.length)))];
      if (live.length && roll < 35) { // execute a live ticket, jumping to its maturity (sometimes 1s early)
        const t = pick(live);
        if (t.maturity > now) now = t.maturity - (rnd(5n) === 0n ? 1n : 0n) + rnd(3n) * HOUR;
        a = A(Kind.Execute, now, pos, BigInt(t.id));
      } else if (live.length && roll < 55) a = A(Kind.Cancel, now, pos, BigInt(pick(live).id));
      else {
        const r2 = Number(rnd(100n));
        if (r2 < 12) a = A(Kind.Deposit, now, pos, rnd(500n * E) + 1n);
        else if (r2 < 72) a = A(Kind.Request, now, pos, active === 0n ? 1n : rnd(3n) === 0n ? active : rnd(active) + 1n);
        else if (r2 < 80) a = A(Kind.Seal, now, pos, rnd(5n)); // track 4 is unknown: reverts
        else if (r2 < 85) a = A(Kind.Execute, now, pos, anyId); // stale or wrong ids revert
        else if (r2 < 90) a = A(Kind.Cancel, now, pos, anyId);
        else if (r2 < 94) a = A(Kind.Collect, now, 0);
        else if (r2 < 95 && i > steps / 2) a = A(Kind.Emergency, now, pos);
        else if (r2 >= 95 && r2 < 99) a = A(Kind.Boost, now, pos, rnd(20n) === 0n ? MAX_BONUS_UNITS + 1n : rnd(MAX_BONUS_UNITS + 1n));
        else a = A(Kind.Poke, now, pos);
      }
    }
    actions.push(a);
    sim = apply(sim, a).sim;
  }
  return { name, lp, positions, actions };
}
const random = [
  randomScenario('random0', 0xf0e9n, 90, true),
  randomScenario('random1', 0xa5a1n, 90, true),
  randomScenario('random2', 0x7e57n, 90, false),
  randomScenario('random3', 0xc001n, 120, true),
  randomScenario('random4', 0x5eedn, 120, false),
  randomScenario('random5', 0xbeefn, 150, true),
];

export function forgeVectors() {
  const all = [...scripted, ...random];
  const scenarios: Record<string, ReturnType<typeof record>> = {};
  for (const sc of all) scenarios[sc.name] = record(sc);
  // The Ashfall weight comparison must not be vacuous: most scenarios reach both 30-day minimums.
  if (Object.values(scenarios).filter((x) => x.ashfall > 0).length < 12) throw new Error('too few scenarios with an Ashfall weight');
  // Nor the ordinary bonus: boosted active lots in the scripted Boost scenarios and most random ones.
  if (Object.values(scenarios).filter((x) => x.boosted > 0).length < 6) throw new Error('too few scenarios with a boosted lot');
  return {
    maxPendingTickets: MAX_PENDING, maxLots: MAX_LOTS, tiers: TIERS.map((t) => [String(t.maxPct), String(t.seconds)]),
    fund: String(FUND), names: all.map((s) => s.name), scenarios,
  };
}
