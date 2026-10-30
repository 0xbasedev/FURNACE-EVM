// Exact BigInt reference of ForgeEmissions (docs/adr/0005-epoch-settlement.md,
// docs/adr/0006-seals.md, docs/adr/0007-ashfall-and-handoffs.md): four ForgeModel pools
// with per-epoch measures, the Mantle's base and Ashfall budgets per epoch (with its burn
// credits and Ashfall queue), admission by occupied time, measure, escrow and credit pages,
// Ashfall by Heat² weight, Seal escrow ledgers and their consumers, and 24h claim
// snapshots. Every budget, escrow and payout is cross-checked against canonical
// settleBaseEpoch with the Seal measures B and C; every Ashfall weight against the custody
// model's own accrual.
import cfg from '../canonical/furnace.config';
import { accruedPoolBudget, allocateMint, parseUnits, settleBaseEpoch } from '../canonical/accounting';
import { emissionPerDay } from './schedule';
import { ForgeModel, Revert, SEAL_TRACKS, SealStatus, sealEnd, WINDOW } from './forge-model';

export const EPOCH = BigInt(cfg.emissions.epochSeconds);
export const PAGE = BigInt(cfg.execution.settlement.maxLotsPerPage);
export const SEGMENTS_PER_PAGE = 256n; // [P] ForgeEmissions.SEGMENTS_PER_PAGE
export const LAPSE_UNITS = 64n; // [P] ForgeEmissions.LAPSE_UNITS
export const ASHFALL_SEGMENT_UNITS = 2n; // [P] ForgeEmissions.ASHFALL_SEGMENT_UNITS
export const CLAIM_SECONDS = BigInt(cfg.cooldowns.claim.seconds);
export const ALLOC = cfg.forge.pools.map((p) => BigInt(p.allocPoints));
export const ALLOC_TOTAL = ALLOC.reduce((a, b) => a + b, 0n);
export const POOL_IS_LP = cfg.forge.pools.map((p) => p.stakeKind === 'lp');
const BUCKET_PCT = BigInt(cfg.emissions.convictionBucketPct);
const FLAT_PCT = BigInt(cfg.emissions.split.flatPct);
const RAY = 10n ** 27n;
const FORFEIT = cfg.forge.convictionTracks.forfeitRouting;
const ASHFALL = cfg.emissions.ashfall;
const CAP = parseUnits(String(cfg.token.maxSupply), 18);
// The Mantle reserves the Kindling seed and unreleased Treasury vesting from day 0 (no
// seed mint or vesting release happens in these scenarios).
const FIXED_RESERVED = parseUnits(String(cfg.token.allocations.kindlingPool), 18) + parseUnits(String(cfg.token.allocations.treasury.amount), 18);

const need = (ok: boolean, why: string) => { if (!ok) throw new Revert(why); };
const mulDiv = (a: bigint, b: bigint, c: bigint) => a * b / c;

export enum Phase { None, Measuring, Escrowing, Crediting, Done }
export interface PoolEpoch {
  phase: Phase; positions: number; cursor: number; credited: number; escrowed: number;
  target: bigint; admitted: bigint; bucket: bigint; flat: bigint; heat: bigint; escrow: bigint; paid: bigint;
  S: bigint; W: bigint; C: bigint;
  earners: number[]; sealed: number[];
  /** The pool's Ashfall share (lowered to what was paid once the rest rolls back), credited Ashfall, Q = ΣQ_i. */
  ashfall: bigint; ashfallPaid: bigint; Q: bigint;
}
export interface MantleEpoch { base: bigint; minted: bigint; released: bigint; ashfall: bigint; ashfallMinted: bigint; ashfallRolled: bigint }
export interface Measure { s: bigint; w: bigint; b: bigint; c: bigint; escrow: bigint; seal: number; q: bigint }
/** `q` is the exact (unrounded) Ashfall weight so far; the contract keeps it as q / RAY and q % RAY. */
export interface Progress { id: number; slot: number; seg: bigint; seal: number; s: bigint; w: bigint; ss: bigint; sw: bigint; q: bigint }
const freshProgress = (): Progress => ({ id: 0, slot: 0, seg: 0n, seal: 0, s: 0n, w: 0n, ss: 0n, sw: 0n, q: 0n });

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
  /** Mantle ledger: minted − recognized burns; burn credits per epoch; queued Ashfall. */
  accounted = 0n; credits = new Map<number, bigint>(); queued = 0n;
  /** EMBER pulled by the ledger consumers (Capstone, match reserve, Sealed-pot stream). */
  consumerEmber = [0n, 0n, 0n];

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
  epochAt(t: bigint): number { return t <= this.start ? 0 : Number((t - this.start) / EPOCH); }
  /** Mantle.finalizeEpoch: the global base target plus queued and lagged Ashfall credits,
   *  scaled by canonical allocateMint against the ledger's headroom. */
  finalize(now: bigint) {
    const e = this.mantle.length;
    need(now >= this.bounds(e)[1], 'EpochNotOver');
    const reserved = FIXED_RESERVED + this.mantle.reduce((n, m) => n + m.base + m.ashfall - m.minted - m.released - m.ashfallMinted - m.ashfallRolled, 0n);
    const target = this.queued + (e >= ASHFALL.lagEpochs ? this.credits.get(e - ASHFALL.lagEpochs) ?? 0n : 0n);
    const out = allocateMint(CAP, this.accounted, reserved, emissionPerDay(BigInt(e)), target);
    this.queued = target - out.ashfall;
    this.mantle.push({ base: out.base, minted: 0n, released: 0n, ashfall: out.ashfall, ashfallMinted: 0n, ashfallRolled: 0n });
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
    this.accounted += amount;
  }
  private mintAshfall(e: number, amount: bigint) {
    const m = this.mantle[e];
    if (amount > m.ashfall - m.ashfallMinted - m.ashfallRolled) throw new Error('model: Ashfall mint exceeds budget');
    m.ashfallMinted += amount;
    this.emberHeld += amount;
    this.accounted += amount;
  }
  private rollAshfall(e: number, amount: bigint) {
    const m = this.mantle[e];
    if (amount > m.ashfall - m.ashfallMinted - m.ashfallRolled) throw new Error('model: Ashfall roll exceeds budget');
    m.ashfallRolled += amount;
    this.queued += amount;
  }
  /** A user hands `amount` of its EMBER to the Protocol registrar, which burns it (Mantle.burnRegistered). */
  burnRegistered(user: number, amount: bigint, now: bigint) {
    const have = this.emberOf.get(user) ?? 0n;
    need(have >= amount, 'ERC20InsufficientBalance');
    this.emberOf.set(user, have - amount);
    this.accounted -= amount;
    const e = this.epochAt(now);
    this.credits.set(e, (this.credits.get(e) ?? 0n) + amount * BigInt(ASHFALL.recycleRates.protocolBurns) / 100n);
  }

  // ── settlement ──────────────────────────────────────────────────────────
  openEpoch(now: bigint): number {
    const e = this.nextOpen;
    need(this.mantle.length > e, 'EpochNotFinalized');
    const { base, ashfall } = this.mantle[e];
    const [s, end] = this.bounds(e);
    let released = base, rolled = ashfall;
    this.pools.forEach((pool, i) => {
      const target = mulDiv(base, ALLOC[i], ALLOC_TOTAL);
      if (end > now) throw new Error('model: future occupancy');
      const occupied = pool.occupiedAt(end) - pool.occupiedAt(s);
      const admitted = accruedPoolBudget(target, occupied, EPOCH);
      released -= admitted;
      const share = admitted === 0n ? 0n : mulDiv(ashfall, ALLOC[i], ALLOC_TOTAL);
      rolled -= share;
      this.epochs.set(`${e}:${i}`, {
        phase: admitted === 0n ? Phase.Done : Phase.Measuring, positions: pool.positions.length, cursor: 0, credited: 0, escrowed: 0,
        target, admitted, bucket: 0n, flat: 0n, heat: 0n, escrow: 0n, paid: 0n, S: 0n, W: 0n, C: 0n, earners: [], sealed: [],
        ashfall: share, ashfallPaid: 0n, Q: 0n,
      });
    });
    this.nextOpen = e + 1;
    if (released !== 0n) this.release(e, released);
    if (rolled !== 0n) this.rollAshfall(e, rolled);
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
    const unit = pe.ashfall !== 0n ? ASHFALL_SEGMENT_UNITS : 1n;
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
      if (slots === PAGE || budget < unit) break;
      slots++;
      const r = pool.measureSlot(pr.id, j, start, end, pr.seg, budget / unit, unit !== 1n);
      pr.s += r.s; pr.w += r.w; pr.ss += r.ss; pr.sw += r.sw; pr.q += r.q; budget -= r.used * unit;
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
      || pr.ss !== (p.epochSS.get(E) ?? 0n) || pr.sw !== (p.epochSW.get(E) ?? 0n)
      || (pe.ashfall !== 0n && pr.q !== (p.epochQ.get(E) ?? 0n))) {
      throw new Error(`model: records disagree with accrual (epoch ${e}, pool ${i}, position ${pr.id})`);
    }
    if (pr.s !== 0n) {
      const m: Measure = { s: pr.s, w: pr.w, b: 0n, c: 0n, escrow: 0n, seal: 0, q: pr.q / RAY };
      pe.Q += m.q;
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
    if (pe.Q === 0n) this.rollPool(e, pe);
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
    let sum = 0n, ashSum = 0n;
    const routed: [number, number, SealStatus, bigint][] = [];
    for (; pe.credited < end; pe.credited++) {
      const id = pe.earners[pe.credited];
      const m = this.measures.get(`${e}:${i}:${id}`)!;
      // Ashfall by Heat² weight, unless the position left by emergency exit before this credit.
      const ash = m.q !== 0n && !this.pools[i].positions[id - 1].ashfallForfeited ? mulDiv(pe.ashfall, m.q, pe.Q) : 0n;
      ashSum += ash;
      const amount = this.payout(e, i, id);
      const key = `${i}:${id}`;
      this.unclaimed.set(key, (this.unclaimed.get(key) ?? 0n) + amount + ash);
      if (m.escrow !== 0n) {
        const status = this.sealStatus(i, id, m.seal, now);
        if (status === SealStatus.Active) this.add(this.sealEscrow, `${i}:${id}:${m.seal}`, m.escrow);
        else routed.push([id, m.seal, status, m.escrow]);
      }
      sum += amount + m.escrow;
    }
    pe.paid += sum;
    pe.ashfallPaid += ashSum;
    if (sum !== 0n) this.mint(e, sum);
    if (ashSum !== 0n) this.mintAshfall(e, ashSum);
    for (const [id, k, status, amount] of routed) this.releaseEscrow(i, id, k, status, amount);
    if (pe.credited === pe.earners.length) {
      pe.phase = Phase.Done;
      const residue = pe.admitted - pe.paid;
      if (residue !== 0n) this.release(e, residue);
      this.rollPool(e, pe);
    }
  }
  /** The pool's uncredited Ashfall rolls back to the Mantle's queue. */
  private rollPool(e: number, pe: PoolEpoch) {
    const rest = pe.ashfall - pe.ashfallPaid;
    if (rest === 0n) return;
    pe.ashfall = pe.ashfallPaid;
    this.rollAshfall(e, rest);
  }

  // ── ledger consumers ────────────────────────────────────────────────────
  burnForfeits() {
    const amount = this.burnLane;
    this.burnLane = 0n;
    this.emberHeld -= amount;
    this.accounted -= amount; // recognized, uncredited
  }
  private hand(slot: number, amount: bigint) { this.emberHeld -= amount; this.consumerEmber[slot] += amount; }
  takeCapstone(i: number, id: number) {
    const key = `${i}:${id}`, amount = this.capstoneOwed.get(key) ?? 0n;
    this.capstoneOwed.set(key, 0n);
    this.hand(0, amount);
  }
  takeMatchReserve() { const amount = this.matchReserve; this.matchReserve = 0n; this.hand(1, amount); }
  takeSealedPot(i: number) {
    need(i >= 0 && i < 4, 'UnknownPool');
    const amount = this.sealedPot[i]; this.sealedPot[i] = 0n; this.hand(2, amount);
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
