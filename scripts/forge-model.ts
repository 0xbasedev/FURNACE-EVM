// Exact BigInt reference of ForgePool custody (docs/adr/0004-forge-custody.md).
// One pool: positions of ≤32 lots, cooling plans with frozen slices, lazy lapses,
// in-kind exits, cumulative S/W measures and the pool occupancy log.
// Built on canonical/accounting.ts (integrateHeat, cooledAge). Rules marked [P] in
// ADR 0004 are this repo's provisional readings: matching this model proves the
// Solidity port is internally consistent, NOT that a [P] rule is canonical.
import cfg from '../canonical/furnace.config';
import { AGE_CAP, DAY, integrateHeat, cooledAge, parseUnits } from '../canonical/accounting';

export const MAX_LOTS = cfg.forge.heat.maxLotsPerPosition;
export const MAX_PENDING = 8; // [P] not in the canonical config
export const TIERS = cfg.cooldowns.withdraw.tiers.map((t) => ({ maxPct: BigInt(t.maxWithdrawPct), seconds: BigInt(t.seconds) }));
export const WINDOW = BigInt(cfg.cooldowns.withdraw.executionWindowSeconds);
export const HORIZON = BigInt(cfg.execution.withdrawals.planHorizonSeconds);
export const PART_CAP = BigInt(cfg.execution.ashfall.minimumParticipationDays) * DAY;
export const DEPOSIT_FEE_PCT = BigInt(cfg.forge.fees.depositPct);
export const WITHDRAW_FEE_PCT = BigInt(cfg.forge.fees.withdrawPct);
export const EMERGENCY_FEE_PCT = BigInt(cfg.forge.emergencyExit.feePct);
export const MIN_STAKE_LP = parseUnits(cfg.forge.minStakeLp, 18);

export class Revert extends Error {}
const need = (ok: boolean, why: string) => { if (!ok) throw new Revert(why); };
const min = (a: bigint, b: bigint) => (a < b ? a : b);

export interface Lot { amount: bigint; age: bigint; part: bigint; heldBy: number }
export interface Slice { amount: bigint; age: bigint; part: bigint }
export type Status = 'pending' | 'executed' | 'cancelled' | 'lapsed' | 'emergency';
export interface Ticket { id: number; amount: bigint; maturity: bigint; status: Status; poolApplied: boolean; slices: Map<number, Slice> }
export interface Position {
  id: number; lots: Lot[]; lotCount: number; reserved: number; last: bigint; streakStart: bigint;
  S: bigint; W: bigint; paused: bigint; closed: boolean; ashfallForfeited: boolean;
  plan: { start: bigint; reference: bigint; requested: bigint } | null;
  tickets: Map<number, Ticket>; pending: number[]; nextTicket: number;
  /** Settlement inputs: measures split at epoch boundaries, slots that ever held a lot. */
  epochS: Map<bigint, bigint>; epochW: Map<bigint, bigint>; historySlots: Set<number>;
  openedAt: bigint; closedAt: bigint;
  /** Mirror of ForgePool's checkpoint records: each slot's head and superseded heads. */
  heads: Map<number, Rec>; history: Map<number, Rec[]>;
}
export interface Rec { since: bigint; amount: bigint; age: bigint; part: bigint }
const UINT96_MAX = (1n << 96n) - 1n;
export interface Occ { time: bigint; cum: bigint; on: boolean }

const emptyLot = (): Lot => ({ amount: 0n, age: 0n, part: 0n, heldBy: 0 });
const deadline = (t: Ticket) => t.maturity + WINDOW;

export class ForgeModel {
  positions: Position[] = []; // index = id - 1
  active = 0n; frozen = 0n;
  occ: Occ[] = [];
  fees = { deposit: 0n, withdraw: 0n, emergency: 0n };
  /** `epochStart`/`epochSeconds` enable per-epoch measures (settlement); custody ignores them. */
  constructor(readonly lp: boolean, readonly epochStart?: bigint, readonly epochSeconds?: bigint) {}

  clone(): ForgeModel { return Object.setPrototypeOf(structuredClone({ ...this }), ForgeModel.prototype); }

  // ── pool occupancy ─────────────────────────────────────────────────────
  occupiedAt(t: bigint): bigint {
    let i = this.occ.length - 1;
    while (i >= 0 && this.occ[i].time > t) i--;
    let base = i < 0 ? 0n : this.occ[i].cum + (this.occ[i].on ? t - this.occ[i].time : 0n);
    // At or after the last log entry, a due lapse not yet processed onchain has
    // already re-activated principal (deadline > last entry time by construction).
    if (i === this.occ.length - 1 && this.active === 0n && (i < 0 || !this.occ[i].on)) {
      const top = this.heapMin();
      if (top && deadline(top.t) <= t) base += t - deadline(top.t);
    }
    return base;
  }
  private setOn(t: bigint) {
    const last = this.occ[this.occ.length - 1];
    if (last?.on) return;
    this.occ.push({ time: t, cum: last ? last.cum : 0n, on: true });
  }
  private setOff(t: bigint) {
    const last = this.occ[this.occ.length - 1];
    if (!last?.on) return;
    this.occ.push({ time: t, cum: last.cum + (t - last.time), on: false });
  }
  /** Earliest pending ticket whose slices the pool still counts as frozen; ties by (position, ticket). */
  heapMin(): { p: Position; t: Ticket } | undefined {
    let best: { p: Position; t: Ticket } | undefined;
    for (const p of this.positions) for (const id of p.pending) {
      const t = p.tickets.get(id)!;
      if (t.poolApplied) continue;
      if (!best || deadline(t) < deadline(best.t) || (deadline(t) === deadline(best.t) && (p.id < best.p.id || (p.id === best.p.id && t.id < best.t.id)))) best = { p, t };
    }
    return best;
  }
  private applyLapse(e: { t: Ticket }) {
    e.t.poolApplied = true; this.active += e.t.amount; this.frozen -= e.t.amount;
  }
  private poolSync(now: bigint) {
    if (this.active !== 0n) return;
    const top = this.heapMin();
    if (top && deadline(top.t) <= now) { this.setOn(deadline(top.t)); this.applyLapse(top); }
  }
  private afterDecrease(now: bigint) {
    if (this.active !== 0n) return;
    const top = this.heapMin();
    if (top && deadline(top.t) <= now) this.applyLapse(top);
    else this.setOff(now);
  }
  private increaseActive(amount: bigint, now: bigint) {
    if (this.active === 0n) this.setOn(now);
    this.active += amount;
  }

  // ── position sync ──────────────────────────────────────────────────────
  epochOf(t: bigint): bigint {
    return (t - this.epochStart!) / this.epochSeconds!;
  }
  /** Accrue to `t`, split at epoch boundaries so each piece is credited to its epoch. */
  private accrue(p: Position, t: bigint) {
    const dt = t - p.last;
    if (dt === 0n) return;
    const epochs = this.epochSeconds !== undefined;
    for (let a = p.last; a < t;) {
      const b = !epochs ? t : a < this.epochStart! ? min(t, this.epochStart!) : min(t, this.epochStart! + (this.epochOf(a) + 1n) * this.epochSeconds!);
      const d = b - a;
      for (const lot of p.lots) {
        if (lot.amount === 0n) continue;
        const s = lot.amount * d, w = lot.amount * integrateHeat(lot.age, d, 0n);
        p.S += s; p.W += w;
        if (epochs && a >= this.epochStart!) {
          const e = this.epochOf(a);
          p.epochS.set(e, (p.epochS.get(e) ?? 0n) + s);
          p.epochW.set(e, (p.epochW.get(e) ?? 0n) + w);
        }
        lot.age = min(lot.age + d, AGE_CAP);
        lot.part = min(lot.part + d, PART_CAP);
      }
      a = b;
    }
    if (p.pending.length > 0) p.paused += dt;
    p.last = t;
  }
  private sync(p: Position, now: bigint) {
    for (;;) {
      let due: Ticket | undefined;
      for (const id of p.pending) {
        const t = p.tickets.get(id)!;
        if (deadline(t) <= now && (!due || deadline(t) < deadline(due) || (deadline(t) === deadline(due) && t.id < due.id))) due = t;
      }
      if (!due) break;
      this.accrue(p, deadline(due));
      this.resume(p, due, 'lapsed', now);
    }
    this.accrue(p, now);
  }
  private firstFree(p: Position): number {
    const j = p.lots.findIndex((l) => l.amount === 0n && l.heldBy === 0);
    if (j < 0) throw new Error('invariant: no free slot for a reserved resume');
    return j;
  }
  private dropPending(p: Position, t: Ticket, status: Status) {
    t.status = status;
    p.pending = p.pending.filter((id) => id !== t.id);
  }
  private resume(p: Position, t: Ticket, status: Status, now: bigint) {
    for (const [slot, s] of [...t.slices].sort((a, b) => a[0] - b[0])) {
      const lot = p.lots[slot];
      if (lot.heldBy === t.id) {
        Object.assign(lot, { amount: s.amount, age: s.age, part: s.part, heldBy: 0 });
        this.recordHead(p, slot);
      } else {
        if (lot.amount > 0n && lot.age === s.age && lot.part === s.part && lot.amount + s.amount <= UINT96_MAX) {
          lot.amount += s.amount;
          this.recordHead(p, slot);
        } else {
          const j = this.firstFree(p);
          p.lots[j] = { amount: s.amount, age: s.age, part: s.part, heldBy: 0 };
          p.historySlots.add(j); p.lotCount++;
          this.recordHead(p, j);
        }
        p.reserved--;
      }
    }
    this.dropPending(p, t, status);
    if (!t.poolApplied) {
      if (status === 'lapsed' && this.active === 0n) throw new Error('invariant: unapplied lapse with an idle pool');
      this.frozen -= t.amount;
      this.increaseActive(t.amount, now);
    }
  }
  private custody(p: Position): { active: bigint; frozen: bigint } {
    const active = p.lots.reduce((n, l) => n + l.amount, 0n);
    const frozen = p.pending.reduce((n, id) => n + p.tickets.get(id)!.amount, 0n);
    return { active, frozen };
  }
  private touch(id: number, now: bigint): Position {
    const p = this.positions[id - 1];
    need(p !== undefined, 'UnknownPosition');
    this.poolSync(now);
    this.sync(p, now);
    return p;
  }
  private addLot(p: Position, amount: bigint, now: bigint): bigint {
    const fee = amount * DEPOSIT_FEE_PCT / 100n;
    const net = amount - fee;
    need(this.lp ? net >= MIN_STAKE_LP : net > 0n, 'BelowMinimum');
    need(p.lotCount + p.reserved < MAX_LOTS, 'LotCapacity');
    const j = this.firstFree(p);
    p.lots[j] = { amount: net, age: 0n, part: 0n, heldBy: 0 };
    p.historySlots.add(j);
    this.recordHead(p, j);
    p.lotCount++;
    this.fees.deposit += fee;
    this.increaseActive(net, now);
    return net;
  }

  // ── checkpoint records (mirror of ForgePool._setHead / _slotMeasure) ─────
  /** Lot j changed at p.last: its old head moves to history unless it began then. */
  private recordHead(p: Position, j: number) {
    const lot = p.lots[j], t = p.last;
    const head = p.heads.get(j);
    if (head && head.since !== t) {
      if (!p.history.has(j)) p.history.set(j, []);
      p.history.get(j)!.push(head);
    }
    p.heads.set(j, { since: t, amount: lot.amount, age: lot.age, part: lot.part });
  }

  /** Resumable slot measure over [t0, t1], segment for segment as ForgePool.measureSlot. */
  measureSlot(id: number, j: number, t0: bigint, t1: bigint, from: bigint, maxSegs: bigint) {
    const p = this.positions[id - 1];
    if (t1 > p.last) throw new Error('model: measure before sync');
    if (p.closedAt !== 0n && p.closedAt < t1) t1 = p.closedAt;
    const out = { s: 0n, w: 0n, next: 0n, used: 0n, done: true };
    if (t1 <= t0) return out;
    const hist = p.history.get(j) ?? [], head = p.heads.get(j)!, n = hist.length;
    const seg = (k: number) => (k < n ? hist[k] : head);
    let i: number;
    if (from !== 0n) i = Number(from) - 1;
    else if (head.since <= t0) i = n;
    else {
      let lo = 0, hi = n;
      while (lo < hi) { const mid = (lo + hi) >> 1; if (hist[mid].since <= t0) lo = mid + 1; else hi = mid; }
      i = lo === 0 ? 0 : lo - 1;
    }
    for (; i <= n; i++) {
      if (out.used === maxSegs) return { ...out, next: BigInt(i + 1), done: false };
      const r = seg(i);
      if (r.since >= t1) break;
      out.used++;
      const end = i + 1 < n ? hist[i + 1].since : i + 1 === n ? head.since : 1n << 255n;
      if (end <= t0 || r.amount === 0n) continue;
      const a = r.since > t0 ? r.since : t0, b = end < t1 ? end : t1;
      const age = min(r.age + (a - r.since), AGE_CAP);
      out.s += r.amount * (b - a);
      out.w += r.amount * integrateHeat(age, b - a, 0n);
    }
    return out;
  }

  // ── actions (each reverts atomically via run()) ────────────────────────
  open(amount: bigint, now: bigint): number {
    this.poolSync(now);
    const p: Position = {
      id: this.positions.length + 1, lots: Array.from({ length: MAX_LOTS }, emptyLot), lotCount: 0, reserved: 0,
      last: now, streakStart: now, S: 0n, W: 0n, paused: 0n, closed: false, ashfallForfeited: false,
      plan: null, tickets: new Map(), pending: [], nextTicket: 1,
      epochS: new Map(), epochW: new Map(), historySlots: new Set(), openedAt: now, closedAt: 0n,
      heads: new Map(), history: new Map(),
    };
    this.positions.push(p);
    this.addLot(p, amount, now);
    return p.id;
  }
  deposit(id: number, amount: bigint, now: bigint) {
    const p = this.touch(id, now);
    need(!p.closed, 'Closed');
    this.addLot(p, amount, now);
  }
  request(id: number, r: bigint, now: bigint): number {
    const p = this.touch(id, now);
    need(!p.closed, 'Closed');
    need(r > 0n, 'ZeroAmount');
    const { active } = this.custody(p);
    need(r <= active, 'ExceedsActive');
    if (!p.plan || (now >= p.plan.start + HORIZON && p.pending.length === 0)) p.plan = { start: now, reference: active, requested: 0n };
    const after = p.plan.requested + r;
    need(after <= p.plan.reference, 'PlanQuotaExceeded');
    need(p.pending.length < MAX_PENDING, 'TooManyPendingTickets');
    const tier = TIERS.find((t) => after * 100n <= p.plan!.reference * t.maxPct)!;
    // Pro-rata over active lots in slot order; floor dust goes to the first lots with room.
    const take = p.lots.map((l) => l.amount * r / active);
    let dust = r - take.reduce((n, x) => n + x, 0n);
    for (let j = 0; j < MAX_LOTS && dust > 0n; j++) {
      const add = min(dust, p.lots[j].amount - take[j]);
      take[j] += add; dust -= add;
    }
    const split = take.filter((x, j) => x > 0n && x < p.lots[j].amount).length;
    need(p.lotCount + p.reserved + split <= MAX_LOTS, 'LotCapacity');
    p.reserved += split;
    const t: Ticket = { id: p.nextTicket++, amount: r, maturity: now + tier.seconds, status: 'pending', poolApplied: false, slices: new Map() };
    take.forEach((x, j) => {
      if (x === 0n) return;
      const lot = p.lots[j];
      t.slices.set(j, { amount: x, age: lot.age, part: lot.part });
      lot.amount -= x;
      if (lot.amount === 0n) lot.heldBy = t.id;
      this.recordHead(p, j);
    });
    p.plan.requested = after;
    p.tickets.set(t.id, t);
    p.pending.push(t.id);
    this.active -= r; this.frozen += r;
    this.afterDecrease(now);
    return t.id;
  }
  execute(id: number, ticketId: number, now: bigint): bigint {
    const p = this.touch(id, now);
    const t = p.tickets.get(ticketId);
    need(t !== undefined && t.status === 'pending', 'NotPending');
    need(now >= t!.maturity, 'NotMatured');
    const { active, frozen } = this.custody(p);
    const balance = active + frozen;
    const w = t!.amount;
    for (const slot of t!.slices.keys()) {
      const lot = p.lots[slot];
      if (lot.heldBy === t!.id) { lot.heldBy = 0; p.lotCount--; } else p.reserved--;
    }
    this.dropPending(p, t!, 'executed');
    p.lots.forEach((lot, j) => {
      if (lot.amount === 0n) return;
      lot.age = cooledAge(lot.age, w, balance);
      this.recordHead(p, j);
    });
    for (const pid of p.pending) for (const s of p.tickets.get(pid)!.slices.values()) s.age = cooledAge(s.age, w, balance);
    p.streakStart = now;
    const fee = w * WITHDRAW_FEE_PCT / 100n;
    this.fees.withdraw += fee;
    this.frozen -= w;
    return w - fee;
  }
  cancel(id: number, ticketId: number, now: bigint) {
    const p = this.touch(id, now);
    const t = p.tickets.get(ticketId);
    need(t !== undefined && t.status === 'pending', 'NotPending');
    this.resume(p, t!, 'cancelled', now);
  }
  emergency(id: number, now: bigint): bigint {
    const p = this.touch(id, now);
    need(!p.closed, 'Closed');
    const { active, frozen } = this.custody(p);
    const total = active + frozen;
    need(total > 0n, 'NothingToExit');
    for (const pid of [...p.pending]) this.dropPending(p, p.tickets.get(pid)!, 'emergency');
    p.lots = Array.from({ length: MAX_LOTS }, emptyLot);
    p.lotCount = 0; p.reserved = 0; p.closed = true; p.ashfallForfeited = true; p.closedAt = now;
    const fee = total * EMERGENCY_FEE_PCT / 100n;
    this.fees.emergency += fee;
    this.frozen -= frozen;
    this.active -= active;
    this.afterDecrease(now);
    return total - fee;
  }
  poke(id: number, now: bigint) { this.touch(id, now); }
}

/** Run `fn` on a copy; commit only if it does not revert (EVM atomicity). */
export function run<T>(m: ForgeModel, fn: (x: ForgeModel) => T): { model: ForgeModel; reverted: boolean; out?: T } {
  const x = m.clone();
  try { return { model: x, reverted: false, out: fn(x) }; }
  catch (e) { if (e instanceof Revert) return { model: m, reverted: true }; throw e; }
}
