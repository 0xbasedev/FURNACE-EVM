// Exact BigInt reference of ForgeEmissions (docs/adr/0005-epoch-settlement.md,
// docs/adr/0006-seals.md): four ForgeModel pools with per-epoch measures, the Mantle's
// base budget per epoch, admission by occupied time, measure, escrow and credit pages,
// Seal escrow ledgers, and 24h claim snapshots. Every budget, escrow and payout is
// cross-checked against canonical settleBaseEpoch with the Seal measures B and C.
import cfg from '../canonical/furnace.config';
import { accruedPoolBudget, settleBaseEpoch } from '../canonical/accounting';
import { emissionPerDay } from './schedule';
import { ForgeModel, Revert, SEAL_TRACKS, SealStatus, sealEnd, WINDOW } from './forge-model';

export const EPOCH = BigInt(cfg.emissions.epochSeconds);
export const PAGE = BigInt(cfg.execution.settlement.maxLotsPerPage);
export const SEGMENTS_PER_PAGE = 256n; // [P] ForgeEmissions.SEGMENTS_PER_PAGE
export const LAPSE_UNITS = 64n; // [P] ForgeEmissions.LAPSE_UNITS
export const CLAIM_SECONDS = BigInt(cfg.cooldowns.claim.seconds);
export const ALLOC = cfg.forge.pools.map((p) => BigInt(p.allocPoints));
export const ALLOC_TOTAL = ALLOC.reduce((a, b) => a + b, 0n);
export const POOL_IS_LP = cfg.forge.pools.map((p) => p.stakeKind === 'lp');
const BUCKET_PCT = BigInt(cfg.emissions.convictionBucketPct);
const FLAT_PCT = BigInt(cfg.emissions.split.flatPct);
const RAY = 10n ** 27n;
const FORFEIT = cfg.forge.convictionTracks.forfeitRouting;

const need = (ok: boolean, why: string) => { if (!ok) throw new Revert(why); };
const mulDiv = (a: bigint, b: bigint, c: bigint) => a * b / c;

export enum Phase { None, Measuring, Escrowing, Crediting, Done }
export interface PoolEpoch {
  phase: Phase; positions: number; cursor: number; credited: number; escrowed: number;
  target: bigint; admitted: bigint; bucket: bigint; flat: bigint; heat: bigint; escrow: bigint; paid: bigint;
  S: bigint; W: bigint; C: bigint;
  earners: number[]; sealed: number[];
}
export interface MantleEpoch { base: bigint; minted: bigint; released: bigint }
export interface Measure { s: bigint; w: bigint; b: bigint; c: bigint; escrow: bigint; seal: number }
export interface Progress { id: number; slot: number; seg: bigint; seal: number; s: bigint; w: bigint; ss: bigint; sw: bigint }
const freshProgress = (): Progress => ({ id: 0, slot: 0, seg: 0n, seal: 0, s: 0n, w: 0n, ss: 0n, sw: 0n });

export class SettlementModel {
  pools: ForgeModel[];
  mantle: MantleEpoch[] = []; // index = epoch; length = Mantle.nextEpoch
  nextOpen = 0;
  epochs = new Map<string, PoolEpoch>(); // `${e}:${i}`
  measures = new Map<string, Measure>(); // `${e}:${i}:${id}`
  progress = new Map<string, Progress>(); // `${e}:${i}`
  unclaimed = new Map<string, bigint>(); // `${i}:${id}`
  claims = new Map<string, { amount: bigint; maturesAt: bigint }>();
  sealEscrow = new Map<string, bigint>(); // `${i}:${id}:${k}`
  capstoneOwed = new Map<string, bigint>(); // `${i}:${id}`
  burnLane = 0n; matchReserve = 0n; sealedPot = [0n, 0n, 0n, 0n];
  emberHeld = 0n; // ForgeEmissions' EMBER balance
  emberOf = new Map<number, bigint>(); // user index → EMBER

  constructor(readonly start: bigint) {
    this.pools = POOL_IS_LP.map((lp) => new ForgeModel(lp, start, EPOCH));
  }

  clone(): SettlementModel {
    const c = Object.setPrototypeOf(structuredClone({ ...this, pools: [] }), SettlementModel.prototype) as SettlementModel;
    c.pools = this.pools.map((p) => p.clone());
    return c;
  }

  bounds(e: number): [bigint, bigint] {
    const s = this.start + BigInt(e) * EPOCH;
    return [s, s + EPOCH];
  }
  epoch(e: number, i: number): PoolEpoch { return this.epochs.get(`${e}:${i}`)!; }

  // ── Mantle ──────────────────────────────────────────────────────────────
  finalize(now: bigint) {
    const e = this.mantle.length;
    need(now >= this.bounds(e)[1], 'EpochNotOver');
    this.mantle.push({ base: emissionPerDay(BigInt(e)), minted: 0n, released: 0n });
  }
  private release(e: number, amount: bigint) {
    const m = this.mantle[e];
    if (amount > m.base - m.minted - m.released) throw new Error('model: release exceeds budget');
    m.released += amount;
  }
  private mint(e: number, amount: bigint) {
    const m = this.mantle[e];
    if (amount > m.base - m.minted - m.released) throw new Error('model: mint exceeds budget');
    m.minted += amount;
    this.emberHeld += amount;
  }

  // ── settlement ──────────────────────────────────────────────────────────
  openEpoch(now: bigint): number {
    const e = this.nextOpen;
    need(this.mantle.length > e, 'EpochNotFinalized');
    const base = this.mantle[e].base;
    const [s, end] = this.bounds(e);
    let released = base;
    this.pools.forEach((pool, i) => {
      const target = mulDiv(base, ALLOC[i], ALLOC_TOTAL);
      if (end > now) throw new Error('model: future occupancy');
      const occupied = pool.occupiedAt(end) - pool.occupiedAt(s);
      const admitted = accruedPoolBudget(target, occupied, EPOCH);
      released -= admitted;
      this.epochs.set(`${e}:${i}`, {
        phase: admitted === 0n ? Phase.Done : Phase.Measuring, positions: pool.positions.length, cursor: 0, credited: 0, escrowed: 0,
        target, admitted, bucket: 0n, flat: 0n, heat: 0n, escrow: 0n, paid: 0n, S: 0n, W: 0n, C: 0n, earners: [], sealed: [],
      });
    });
    this.nextOpen = e + 1;
    if (released !== 0n) this.release(e, released);
    return e;
  }

  advance(e: number, i: number, now: bigint) {
    const pe = this.epochs.get(`${e}:${i}`);
    need(pe !== undefined && (pe.phase === Phase.Measuring || pe.phase === Phase.Escrowing || pe.phase === Phase.Crediting), 'NothingToAdvance');
    if (pe!.phase === Phase.Measuring) this.measurePage(e, i, pe!, now);
    else if (pe!.phase === Phase.Escrowing) this.escrowPage(e, i, pe!);
    else this.creditPage(e, i, pe!, now);
  }

  progressOf(e: number, i: number): Progress { return this.progress.get(`${e}:${i}`) ?? freshProgress(); }

  /** Mirror of ForgeEmissions._measurePage: ≤32 slot visits and SEGMENTS_PER_PAGE record
   *  segments per page, resuming mid-position. Each finished position's record-based
   *  sum must equal the model's own epoch-split accrual. */
  private measurePage(e: number, i: number, pe: PoolEpoch, now: bigint) {
    const pool = this.pools[i];
    const [start, end] = this.bounds(e);
    const pr = this.progressOf(e, i);
    let budget = SEGMENTS_PER_PAGE, slots = 0n;
    while (budget !== 0n) {
      if (pr.id === 0) {
        if (pe.cursor === pe.positions || slots === PAGE) break;
        const q = pool.positions[pe.cursor];
        const cost = BigInt(q.pending.filter((t) => q.tickets.get(t)!.maturity + WINDOW <= now).length) * LAPSE_UNITS;
        if (cost <= budget) budget -= cost;
        else if (budget !== SEGMENTS_PER_PAGE) break;
        pool.poke(pe.cursor + 1, now);
        pr.id = pe.cursor + 1;
      }
      const p = pool.positions[pr.id - 1];
      let j = pr.slot;
      while (j < 32 && !p.heads.has(j)) j++;
      if (j === 32) { this.finishPosition(e, i, pe, pr); Object.assign(pr, freshProgress()); budget--; continue; }
      if (slots === PAGE) break;
      slots++;
      const r = pool.measureSlot(pr.id, j, start, end, pr.seg, budget);
      pr.s += r.s; pr.w += r.w; pr.ss += r.ss; pr.sw += r.sw; budget -= r.used;
      if (r.seal !== 0) pr.seal = r.seal;
      if (r.done) { pr.slot = j + 1; pr.seg = 0n; } else { pr.slot = j; pr.seg = r.next; }
    }
    this.progress.set(`${e}:${i}`, pr);
    if (pr.id === 0 && pe.cursor === pe.positions) this.budget(e, i, pe);
  }

  /** B and C are formed once per position-epoch from the unscaled sealed sums. */
  private finishPosition(e: number, i: number, pe: PoolEpoch, pr: Progress) {
    const p = this.pools[i].positions[pr.id - 1];
    const E = BigInt(e);
    if (pr.s !== (p.epochS.get(E) ?? 0n) || pr.w !== (p.epochW.get(E) ?? 0n)
      || pr.ss !== (p.epochSS.get(E) ?? 0n) || pr.sw !== (p.epochSW.get(E) ?? 0n)) {
      throw new Error(`model: records disagree with accrual (epoch ${e}, pool ${i}, position ${pr.id})`);
    }
    if (pr.s !== 0n) {
      const m: Measure = { s: pr.s, w: pr.w, b: 0n, c: 0n, escrow: 0n, seal: 0 };
      if (pr.ss !== 0n) {
        const bonus = SEAL_TRACKS[p.seals[pr.seal - 1].track].bonus;
        m.b = pr.ss * bonus; m.c = pr.sw * bonus / RAY; m.seal = pr.seal;
        pe.sealed.push(pr.id);
        pe.C += m.c;
      }
      this.measures.set(`${e}:${i}:${pr.id}`, m);
      pe.earners.push(pr.id);
      pe.S += pr.s; pe.W += pr.w;
    }
    pe.cursor++;
  }

  private budget(e: number, i: number, pe: PoolEpoch) {
    if (pe.S === 0n) { pe.phase = Phase.Done; this.release(e, pe.admitted); return; }
    pe.bucket = pe.admitted * BUCKET_PCT / 100n;
    pe.flat = (pe.admitted - pe.bucket) * FLAT_PCT / 100n;
    pe.heat = pe.admitted - pe.bucket - pe.flat; // L, before the unused bucket returns
    if (pe.C !== 0n) pe.phase = Phase.Escrowing;
    else this.finalHeat(e, i, pe);
  }

  private escrowPage(e: number, i: number, pe: PoolEpoch) {
    const end = Math.min(pe.sealed.length, pe.escrowed + Number(PAGE));
    for (; pe.escrowed < end; pe.escrowed++) {
      const m = this.measures.get(`${e}:${i}:${pe.sealed[pe.escrowed]}`)!;
      const candidate = mulDiv(pe.bucket, m.c, pe.C), cap = mulDiv(pe.heat, m.b, pe.W);
      m.escrow = candidate < cap ? candidate : cap;
      pe.escrow += m.escrow;
    }
    if (pe.escrowed === pe.sealed.length) this.finalHeat(e, i, pe);
  }

  private finalHeat(e: number, i: number, pe: PoolEpoch) {
    pe.heat += pe.bucket - pe.escrow;
    pe.phase = Phase.Crediting;
    // Cross-check the budget, every escrow and every payout against the canonical oracle.
    const oracle = settleBaseEpoch(pe.admitted, pe.earners.map((id) => {
      const m = this.measures.get(`${e}:${i}:${id}`)!;
      return { id: String(id), stakeSeconds: m.s, heatSeconds: m.w, sealSeconds: m.b, candidateSeconds: m.c };
    }));
    if (oracle.flatBudget !== pe.flat || oracle.heatBudget !== pe.heat || oracle.escrowPaid !== pe.escrow) {
      throw new Error('model: budget diverges from settleBaseEpoch');
    }
    pe.earners.forEach((id, k) => {
      const m = this.measures.get(`${e}:${i}:${id}`)!;
      if (oracle.payouts[k].ordinary !== this.payout(e, i, id) || oracle.payouts[k].escrow !== m.escrow) {
        throw new Error('model: payout diverges from settleBaseEpoch');
      }
    });
  }

  payout(e: number, i: number, id: number): bigint {
    const pe = this.epoch(e, i), m = this.measures.get(`${e}:${i}:${id}`)!;
    return mulDiv(pe.flat, m.s, pe.S) + mulDiv(pe.heat, m.w, pe.W);
  }

  private creditPage(e: number, i: number, pe: PoolEpoch, now: bigint) {
    const end = Math.min(pe.earners.length, pe.credited + Number(PAGE));
    let sum = 0n;
    const routed: [number, number, SealStatus, bigint][] = [];
    for (; pe.credited < end; pe.credited++) {
      const id = pe.earners[pe.credited];
      const amount = this.payout(e, i, id);
      const key = `${i}:${id}`;
      this.unclaimed.set(key, (this.unclaimed.get(key) ?? 0n) + amount);
      const m = this.measures.get(`${e}:${i}:${id}`)!;
      if (m.escrow !== 0n) {
        const status = this.sealStatus(i, id, m.seal, now);
        if (status === SealStatus.Active) this.add(this.sealEscrow, `${i}:${id}:${m.seal}`, m.escrow);
        else routed.push([id, m.seal, status, m.escrow]);
      }
      sum += amount + m.escrow;
    }
    pe.paid += sum;
    if (sum !== 0n) this.mint(e, sum);
    for (const [id, k, status, amount] of routed) this.releaseEscrow(i, id, k, status, amount);
    if (pe.credited === pe.earners.length) {
      pe.phase = Phase.Done;
      const residue = pe.admitted - pe.paid;
      if (residue !== 0n) this.release(e, residue);
    }
  }

  // ── Seals ───────────────────────────────────────────────────────────────
  private add(m: Map<string, bigint>, key: string, amount: bigint) { m.set(key, (m.get(key) ?? 0n) + amount); }
  /** ForgeEmissions.sealStatus: a running Seal past its due time reads Completed. */
  sealStatus(i: number, id: number, k: number, now: bigint): SealStatus {
    const s = this.pools[i].positions[id - 1]?.seals[k - 1];
    if (!s) return SealStatus.None;
    if (s.status === SealStatus.Active && s.pausedAt === 0n && sealEnd(s) <= now) return SealStatus.Completed;
    return s.status;
  }
  private releaseEscrow(i: number, id: number, k: number, status: SealStatus, amount: bigint) {
    if (status === SealStatus.Completed) { this.add(this.capstoneOwed, `${i}:${id}`, amount); return; }
    const burn = amount * BigInt(FORFEIT.burnPct) / 100n, reserve = amount * BigInt(FORFEIT.matchReservePct) / 100n;
    this.burnLane += burn; this.matchReserve += reserve; this.sealedPot[i] += amount - burn - reserve;
  }
  settleSeal(i: number, id: number, k: number, now: bigint) {
    need(i >= 0 && i < 4, 'UnknownPool');
    const status = this.sealStatus(i, id, k, now);
    need(status === SealStatus.Completed || status === SealStatus.Forfeited, 'SealNotEnded');
    const key = `${i}:${id}:${k}`, amount = this.sealEscrow.get(key) ?? 0n;
    need(amount !== 0n, 'NothingToSettle');
    this.sealEscrow.set(key, 0n);
    this.releaseEscrow(i, id, k, status, amount);
  }

  // ── claims ──────────────────────────────────────────────────────────────
  requestClaim(i: number, id: number, now: bigint) {
    need(this.pools[i].positions[id - 1] !== undefined, 'NotOwner');
    const key = `${i}:${id}`;
    need(!this.claims.has(key), 'ClaimPending');
    const amount = this.unclaimed.get(key) ?? 0n;
    need(amount !== 0n, 'NothingToClaim');
    this.unclaimed.set(key, 0n);
    this.claims.set(key, { amount, maturesAt: now + CLAIM_SECONDS });
  }
  executeClaim(i: number, id: number, now: bigint) {
    need(this.pools[i].positions[id - 1] !== undefined, 'NotOwner');
    const key = `${i}:${id}`;
    const c = this.claims.get(key);
    need(c !== undefined, 'NothingToClaim');
    need(now >= c!.maturesAt, 'ClaimNotMatured');
    this.claims.delete(key);
    this.emberHeld -= c!.amount;
    this.emberOf.set(id, (this.emberOf.get(id) ?? 0n) + c!.amount);
  }
}
