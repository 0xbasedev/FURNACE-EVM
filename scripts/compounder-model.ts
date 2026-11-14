// Exact BigInt reference of the Compounder (docs/adr/0026-casting.md): Casting and the idle
// auto-pair, written from the spec (§7, §13), the ADR and the canonical config, independently of
// the contract. It runs on the pair model (scripts/pair-model.ts) and the pool model
// (scripts/forge-model.ts), with a cast ledger and a Vent lane in the place of ForgeEmissions and
// the Vent. The Solidity test replays its scenarios on the real Compounder, two real EmberPairs
// and two real ForgePools, with mocks for the ledger and the lane, and compares every output,
// every revert and a hash of the whole state after every step.
import cfg from '../canonical/furnace.config';
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex } from '@noble/hashes/utils.js';
import { AGE_CAP } from '../canonical/accounting';
import { PairModel, FULL_SHARE, Revert as PairRevert } from './pair-model';
import { ForgeModel, Revert as ForgeRevert } from './forge-model';

export class Revert extends Error {}
const need = (ok: boolean, why: string) => { if (!ok) throw new Revert(why); };
const min = (a: bigint, b: bigint) => (a < b ? a : b);
const isRevert = (e: unknown) => e instanceof Revert || e instanceof PairRevert || e instanceof ForgeRevert;

// ── the spec's figures ──
export const EPOCH = BigInt(cfg.emissions.epochSeconds);
export const CAST_PCT = BigInt(cfg.forge.casting.lpSharePct);
export const RESERVATION_EPOCHS = BigInt(cfg.execution.matching.claimWindowEpochs);
export const IDLE_EPOCHS = BigInt(cfg.fees.liquidityLane.matchReserve!.idleEpochsBeforeAutoPair);
const lane = cfg.fees.burnLane;
export const TWAP = BigInt(lane.twapSeconds);
export const MAX_AGE = 2n * TWAP; // FurnaceParams.VENT_ORACLE_MAX_AGE [P]
export const BAND_BPS = BigInt(lane.avgPriceBandBps);
if (cfg.forge.casting.fallback !== 'liquidEmber' || cfg.execution.matching.expiry !== 'releaseQuoteOnlyKeepUserReward') {
  throw new Error('the model returns what is not cast to its owner');
}

export const T0 = 1_800_000_000n; // ForgeEmissions' START in the test world
export const E18 = 10n ** 18n, U6 = 10n ** 6n;
export const PAIRS = 2, WALLETS = 4, MAX_POSITIONS = 4, EPOCHS = 12;

/** Why a share returns liquid (Compounder.Release). */
export enum Release { Expired, Uncovered, Closed, NoLot, Dust }

export interface Budget { demand: bigint; need: bigint; budget: bigint; remaining: bigint; frozen: boolean; closed: boolean }
const emptyBudget = (): Budget => ({ demand: 0n, need: 0n, budget: 0n, remaining: 0n, frozen: false, closed: false });

export class CompounderModel {
  now = T0;
  pairs = [new PairModel(6), new PairModel(18)];
  pools = [new ForgeModel(true), new ForgeModel(true)];
  /** The LP the test contract holds from initializing each pair; it hands LP to wallets. */
  bankLp = [0n, 0n];
  // ── the cast ledger (ForgeEmissions' Cast shares, unclaimed rewards and match ledger) ──
  share = new Map<string, bigint>(); // `${e}:${i}:${id}`
  demand = new Map<string, bigint>(); // `${e}:${i}`
  done = new Set<string>();
  taken = new Set<string>();
  unclaimed = new Map<string, bigint>(); // `${i}:${id}`
  ledgerEmber = 0n; forfeits = 0n;
  // ── the Vent's liquidity lane ──
  lane = [0n, 0n];
  // ── the Compounder ──
  free = [0n, 0n]; reserved = [0n, 0n]; lastActive = [0n, 0n];
  seed = 0n;
  budgets = new Map<string, Budget>();
  heldEmber = 0n; heldQuote = [0n, 0n];
  sinkLp = [0n, 0n];
  /** How many shares returned liquid, by Release (statistics only, not contract state). */
  releases = [0, 0, 0, 0, 0];

  constructor() {
    // Each pair opens at 100,000 EMBER against 50,000 USDC and 25 WETH, by the test contract.
    this.pairs[0].now = this.now; this.bankLp[0] = this.pairs[0].add(100_000n * E18, 50_000n * U6)[2];
    this.pairs[1].now = this.now; this.bankLp[1] = this.pairs[1].add(100_000n * E18, 25n * E18)[2];
  }

  currentEpoch() { return this.now <= T0 ? 0n : (this.now - T0) / EPOCH; }
  expiresAt(e: number) { return T0 + (BigInt(e) + 1n + RESERVATION_EPOCHS) * EPOCH; }
  budget(e: number, i: number): Budget { return this.budgets.get(`${e}:${i}`) ?? emptyBudget(); }
  castOf(e: number, i: number, id: number) { return this.done.has(`${e}:${i}`) ? this.share.get(`${e}:${i}:${id}`) ?? 0n : 0n; }
  private pairAt(j: number) { need(j >= 0 && j < PAIRS, 'UnknownPool'); return this.pairs[j]; }
  private castPool(i: number) { need(i >= 0 && i < PAIRS, 'UnknownPool'); return i; }

  // ── the test world's own actions ──
  warp(dt: bigint) { this.now += dt; }
  checkpoint(j: number) { const p = this.pairs[j]; p.now = this.now; p.checkpoint(); }
  /** A trader swaps at the full fee: a buy pays quote, a sell pays EMBER. */
  swap(j: number, buy: boolean, amount: bigint) {
    const p = this.pairs[j]; p.now = this.now;
    return (buy ? p.buy(amount, FULL_SHARE) : p.sell(amount, FULL_SHARE))[0];
  }
  /** The bank hands a wallet LP, which opens a position with it (1% fee to the pool). */
  open(i: number, wallet: number, lp: bigint) {
    if (lp > this.bankLp[i]) throw new Error('scenario: the bank holds less LP');
    this.bankLp[i] -= lp;
    return BigInt(this.pools[i].open(lp, this.now, wallet + 1));
  }
  deposit(i: number, id: number, lp: bigint) {
    if (lp > this.bankLp[i]) throw new Error('scenario: the bank holds less LP');
    this.bankLp[i] -= lp;
    this.pools[i].deposit(id, lp, this.now);
    return 0n;
  }
  request(i: number, id: number, amount: bigint) { return BigInt(this.pools[i].request(id, amount, this.now)); }
  emergency(i: number, id: number) { return this.pools[i].emergency(id, this.now); }
  list(i: number, id: number) { return BigInt(this.pools[i].list(id, this.pools[i].positions[id - 1]?.owner ?? 0, this.now)); }
  unlist(i: number, id: number) { this.pools[i].unlist(id, 'deeds'); return 0n; }
  /** The ledger credits a Cast share to an open pool-epoch. */
  credit(e: number, i: number, id: number, amount: bigint) {
    need(!this.done.has(`${e}:${i}`), 'Settled');
    this.share.set(`${e}:${i}:${id}`, (this.share.get(`${e}:${i}:${id}`) ?? 0n) + amount);
    this.demand.set(`${e}:${i}`, (this.demand.get(`${e}:${i}`) ?? 0n) + amount);
    this.ledgerEmber += amount;
    return 0n;
  }
  /** The pool-epoch is done: its shares become castable. Only after the epoch ends. */
  settle(e: number, i: number) {
    need(this.now >= T0 + (BigInt(e) + 1n) * EPOCH, 'Early');
    this.done.add(`${e}:${i}`);
    return 0n;
  }
  forfeit(amount: bigint) { this.forfeits += amount; this.ledgerEmber += amount; return 0n; }
  fund(j: number, amount: bigint) { this.lane[j] += amount; return 0n; }

  // ── the ledger's consumer call (ForgeEmissions.takeCast) ──
  private takeCast(e: number, i: number, id: number, used: bigint) {
    const c = this.castOf(e, i, id);
    need(c !== 0n, 'NothingToCast');
    const key = `${e}:${i}:${id}`;
    need(!this.taken.has(key), 'AlreadyCast');
    need(used <= c, 'CastExceeded');
    this.taken.add(key);
    this.unclaimed.set(`${i}:${id}`, (this.unclaimed.get(`${i}:${id}`) ?? 0n) + c - used);
    this.ledgerEmber -= used; this.heldEmber += used;
  }

  // ── the Compounder ──
  private doRefill(j: number) {
    const amount = this.lane[j];
    if (amount === 0n) return 0n;
    this.lane[j] = 0n; this.heldQuote[j] += amount; this.free[j] += amount;
    return amount;
  }
  refill(j: number) { this.pairAt(j); return this.doRefill(j); }
  pullForfeits() {
    const amount = this.forfeits;
    this.forfeits = 0n; this.ledgerEmber -= amount; this.heldEmber += amount; this.seed += amount;
    return amount;
  }
  fundSeed(amount: bigint) { need(amount !== 0n, 'ZeroAmount'); this.heldEmber += amount; this.seed += amount; return 0n; }

  /** Reserves, supply and a fresh TWAP; with `band`, the spot within BAND_BPS of it. */
  private market(j: number, band: boolean): [bigint, bigint, bigint, bigint] {
    const p = this.pairAt(j); p.now = this.now;
    need(p.rE !== 0n && p.rQ !== 0n && p.supply !== 0n, 'NoOracle');
    let twap: bigint, elapsed: bigint;
    try { [twap, elapsed] = p.consult(TWAP); } catch (e) { if (isRevert(e)) throw new Revert('NoOracle'); throw e; }
    need(elapsed <= MAX_AGE && twap !== 0n, 'StaleOracle');
    if (band) {
      const spot = (p.rQ << 112n) / p.rE, gap = spot > twap ? spot - twap : twap - spot;
      need(gap * 10_000n <= twap * BAND_BPS, 'OutOfBand');
    }
    return [p.rE, p.rQ, p.supply, twap];
  }

  freeze(e: number, i: number) {
    const j = this.castPool(i);
    const b = this.budget(e, i);
    need(!b.frozen, 'AlreadyFrozen');
    need(this.now < this.expiresAt(e), 'Expired');
    need(this.done.has(`${e}:${i}`), 'NotSettled');
    const demand = this.demand.get(`${e}:${i}`) ?? 0n;
    let needQ = 0n, budget = 0n;
    if (demand !== 0n) {
      this.doRefill(j);
      const twap = this.market(j, false)[3];
      needQ = (demand * twap) >> 112n;
      budget = min(this.free[j], needQ);
      this.free[j] -= budget; this.reserved[j] += budget;
    }
    this.budgets.set(`${e}:${i}`, { demand, need: needQ, budget, remaining: budget, frozen: true, closed: false });
    return budget;
  }

  private close_(e: number, i: number) {
    const b = this.budget(e, i);
    if (!b.frozen || b.closed) return 0n;
    const returned = b.remaining;
    this.budgets.set(`${e}:${i}`, { ...b, remaining: 0n, closed: true });
    this.reserved[i] -= returned; this.free[i] += returned;
    return returned;
  }
  close(e: number, i: number) {
    this.castPool(i);
    need(this.now >= this.expiresAt(e), 'NotExpired');
    return this.close_(e, i);
  }

  private spend(e: number, i: number, q: bigint, used: bigint) {
    const b = this.budget(e, i);
    this.budgets.set(`${e}:${i}`, { ...b, remaining: b.remaining - q });
    this.reserved[i] -= q; this.free[i] += q - used;
  }
  /** The youngest active lot already open when epoch e ended. */
  private sourceLot(i: number, id: number, e: number): number {
    const p = this.pools[i].positions[id - 1];
    const since = this.now - (T0 + (BigInt(e) + 1n) * EPOCH);
    let best = -1, bestAge = -1n;
    p.lots.forEach((l, s) => {
      if (l.amount === 0n) return;
      const age = min(l.age, AGE_CAP); // the pool model's ages are at `now` after the poke
      if (age >= since && (best < 0 || age < bestAge)) { best = s; bestAge = age; }
    });
    return best;
  }

  cast(e: number, i: number, id: number) {
    this.castPool(i);
    const c = this.castOf(e, i, id);
    need(c !== 0n, 'NothingToCast');
    need(!this.taken.has(`${e}:${i}:${id}`), 'AlreadyCast');
    if (this.now >= this.expiresAt(e)) {
      this.close_(e, i);
      this.takeCast(e, i, id, 0n);
      this.releases[Release.Expired]++;
      return 0n;
    }
    const b = this.budget(e, i);
    need(b.frozen, 'NotFrozen');
    const q = b.budget * c / b.demand;
    const eCov = b.need === 0n ? 0n : c * b.budget / b.need;
    const release = (why: Release) => {
      if (q !== 0n) this.spend(e, i, q, 0n);
      this.takeCast(e, i, id, 0n);
      this.releases[why]++;
      return 0n;
    };
    if (eCov === 0n) return release(Release.Uncovered);
    const pos = this.pools[i].positions[id - 1];
    if (pos.closed) return release(Release.Closed);
    need(pos.listing % 2 === 0, 'Listed');
    this.pools[i].poke(id, this.now);
    const slot = this.sourceLot(i, id, e);
    if (slot < 0) return release(Release.NoLot);
    const [rE, rQ, supply] = this.market(i, true);
    const eUsed = eCov * rQ / rE > q ? q * rE / rQ : eCov;
    const qUsed = eUsed * rQ / rE;
    if (eUsed === 0n || qUsed === 0n || min(eUsed * supply / rE, qUsed * supply / rQ) === 0n) return release(Release.Dust);
    this.takeCast(e, i, id, eUsed);
    const pair = this.pairs[i]; pair.now = this.now;
    const [ein, qin, lp] = pair.add(eUsed, qUsed);
    if (ein !== eUsed || qin !== qUsed) throw new Error('model: the pair took other amounts');
    this.heldEmber -= eUsed; this.heldQuote[i] -= qUsed;
    this.pools[i].addToLot(id, slot, lp, this.now);
    this.spend(e, i, q, qUsed);
    this.lastActive[i] = this.currentEpoch();
    return lp;
  }

  autoPair(j: number) {
    this.pairAt(j);
    const idleFrom = this.lastActive[j] + IDLE_EPOCHS;
    need(this.currentEpoch() >= idleFrom, 'NotIdle');
    this.doRefill(j);
    const [rE, rQ, supply] = this.market(j, true);
    let e = this.free[j] * rE / rQ;
    if (e > this.seed) e = this.seed;
    const q = e * rQ / rE;
    need(e !== 0n && q !== 0n && min(e * supply / rE, q * supply / rQ) !== 0n, 'NothingToPair');
    const pair = this.pairs[j]; pair.now = this.now;
    const [ein, qin, lp] = pair.add(e, q);
    if (ein !== e || qin !== q) throw new Error('model: the pair took other amounts');
    this.seed -= e; this.free[j] -= q; this.heldEmber -= e; this.heldQuote[j] -= q; this.sinkLp[j] += lp;
    return lp;
  }

  /** The whole state, in the order the Solidity test reads it. */
  words(): bigint[] {
    const w: bigint[] = [];
    for (let j = 0; j < PAIRS; j++) {
      const p = this.pairs[j];
      w.push(p.rE, p.rQ, p.supply, this.free[j], this.reserved[j], this.lastActive[j], this.lane[j], this.heldQuote[j], this.sinkLp[j], this.bankLp[j]);
    }
    w.push(this.seed, this.heldEmber, this.ledgerEmber, this.forfeits);
    for (let e = 0; e < EPOCHS; e++) for (let i = 0; i < PAIRS; i++) {
      const b = this.budget(e, i);
      w.push(this.demand.get(`${e}:${i}`) ?? 0n, this.done.has(`${e}:${i}`) ? 1n : 0n, b.need, b.budget, b.remaining, b.frozen ? 1n : 0n, b.closed ? 1n : 0n);
      for (let id = 1; id <= MAX_POSITIONS; id++) {
        w.push(this.share.get(`${e}:${i}:${id}`) ?? 0n, this.taken.has(`${e}:${i}:${id}`) ? 1n : 0n);
      }
    }
    for (let i = 0; i < PAIRS; i++) {
      const pool = this.pools[i];
      w.push(pool.active, pool.frozen, BigInt(pool.positions.length));
      for (let id = 1; id <= MAX_POSITIONS; id++) {
        const p = pool.positions[id - 1];
        w.push(this.unclaimed.get(`${i}:${id}`) ?? 0n);
        if (!p) { w.push(0n, 0n); continue; }
        w.push(p.closed ? 1n : 0n, BigInt(p.listing % 2));
        if (p.closed) continue; // an exited position's heads are history
        for (let s = 0; s < 32; s++) {
          const l = p.lots[s];
          w.push(l.amount, l.amount === 0n ? 0n : min(l.age + (this.now - p.last), AGE_CAP));
        }
      }
    }
    return w;
  }
}

// ── scenarios ──
export enum K {
  Warp, Checkpoint, Swap, Open, Deposit, Request, Emergency, List, Unlist, Credit, Settle, Forfeit, Fund,
  Refill, PullForfeits, FundSeed, Freeze, Cast, Close, AutoPair,
}
/** [kind, a, b, c, d]: the arguments as each kind reads them. */
export type Act = [K, bigint, bigint, bigint, bigint];
const act = (k: K, a = 0n, b = 0n, c = 0n, d = 0n): Act => [k, a, b, c, d];
const N = (x: bigint) => Number(x);

/** A reverting call changes nothing: the model restores its state, as the EVM does. */
export function apply(m: CompounderModel, [k, a, b, c, d]: Act): { out: bigint; why: string } {
  const saved = structuredClone({ ...m, pairs: [], pools: [] });
  const pairs = m.pairs.map((p) => structuredClone(p)), pools = m.pools.map((p) => p.clone());
  try {
    let out = 0n;
    switch (k) {
      case K.Warp: m.warp(a); break;
      case K.Checkpoint: m.checkpoint(N(a)); break;
      case K.Swap: out = m.swap(N(a), b === 1n, c); break;
      case K.Open: out = m.open(N(a), N(b), c); break;
      case K.Deposit: out = m.deposit(N(a), N(b), c); break;
      case K.Request: out = m.request(N(a), N(b), c); break;
      case K.Emergency: out = m.emergency(N(a), N(b)); break;
      case K.List: out = m.list(N(a), N(b)); break;
      case K.Unlist: out = m.unlist(N(a), N(b)); break;
      case K.Credit: out = m.credit(N(a), N(b), N(c), d); break;
      case K.Settle: out = m.settle(N(a), N(b)); break;
      case K.Forfeit: out = m.forfeit(a); break;
      case K.Fund: out = m.fund(N(a), b); break;
      case K.Refill: out = m.refill(N(a)); break;
      case K.PullForfeits: out = m.pullForfeits(); break;
      case K.FundSeed: out = m.fundSeed(a); break;
      case K.Freeze: out = m.freeze(N(a), N(b)); break;
      case K.Cast: out = m.cast(N(a), N(b), N(c)); break;
      case K.Close: out = m.close(N(a), N(b)); break;
      case K.AutoPair: out = m.autoPair(N(a)); break;
    }
    return { out, why: '' };
  } catch (e) {
    if (!isRevert(e)) throw e;
    Object.assign(m, saved);
    m.pairs = pairs.map((p) => Object.setPrototypeOf(p, PairModel.prototype) as PairModel);
    m.pools = pools;
    return { out: 0n, why: (e as Error).message };
  }
}

/** The books balance after every step. */
function audit(m: CompounderModel, at: string) {
  for (let j = 0; j < PAIRS; j++) {
    if (m.heldQuote[j] !== m.free[j] + m.reserved[j]) throw new Error(`${at}: quote held is not free plus reserved`);
    let outstanding = 0n;
    for (const [key, b] of m.budgets) if (Number(key.split(':')[1]) === j) outstanding += b.remaining;
    if (outstanding !== m.reserved[j]) throw new Error(`${at}: reserved is not the outstanding budgets`);
  }
  if (m.heldEmber !== m.seed) throw new Error(`${at}: EMBER held is not the seed`);
  for (const [key, b] of m.budgets) {
    if (b.remaining > b.budget || b.budget > b.need) throw new Error(`${at}: budget ${key} out of order`);
  }
}

const hashWords = (w: bigint[]) => '0x' + bytesToHex(keccak_256(Uint8Array.from(w.flatMap((x) => {
  if (x < 0n || x >= 1n << 256n) throw new Error('word out of range');
  const h = x.toString(16).padStart(64, '0');
  return Array.from({ length: 32 }, (_, i) => parseInt(h.slice(2 * i, 2 * i + 2), 16));
}))));

export interface Scenario { name: string; actions: Act[] }
interface Stats { casts: number; partial: number; released: number; autoPairs: number; freezes: number; reverts: Record<string, number>; why: number[] }

export function run(s: Scenario) {
  const m = new CompounderModel();
  const cols = { kind: [] as number[], a: [] as string[], b: [] as string[], c: [] as string[], d: [] as string[], why: [] as string[], out: [] as string[], hash: [] as string[] };
  const stats: Stats = { casts: 0, partial: 0, released: 0, autoPairs: 0, freezes: 0, reverts: {}, why: [] };
  for (const [n, x] of s.actions.entries()) {
    const takenBefore = m.taken.size, unclaimedBefore = [...m.unclaimed.values()].reduce((t, v) => t + v, 0n);
    const r = apply(m, x);
    audit(m, `${s.name} step ${n}`);
    if (r.why !== '') stats.reverts[r.why] = (stats.reverts[r.why] ?? 0) + 1;
    else if (x[0] === K.Cast && m.taken.size > takenBefore) {
      const back = [...m.unclaimed.values()].reduce((t, v) => t + v, 0n) - unclaimedBefore;
      if (r.out === 0n) stats.released++;
      else { stats.casts++; if (back !== 0n) stats.partial++; }
    } else if (x[0] === K.AutoPair) stats.autoPairs++;
    else if (x[0] === K.Freeze) stats.freezes++;
    cols.kind.push(x[0]); cols.a.push(String(x[1])); cols.b.push(String(x[2])); cols.c.push(String(x[3])); cols.d.push(String(x[4]));
    cols.why.push(r.why); cols.out.push(String(r.out)); cols.hash.push(hashWords(m.words()));
  }
  stats.why = m.releases;
  return { name: s.name, ...cols, stats };
}

// ── the actions, by name ──
const H = 3600n, DAY = EPOCH;
const warp = (dt: bigint) => act(K.Warp, dt);
const ckpt = (j: number) => act(K.Checkpoint, BigInt(j));
const swap = (j: number, buy: boolean, amount: bigint) => act(K.Swap, BigInt(j), buy ? 1n : 0n, amount);
const open = (i: number, w: number, lp: bigint) => act(K.Open, BigInt(i), BigInt(w), lp);
const deposit = (i: number, id: number, lp: bigint) => act(K.Deposit, BigInt(i), BigInt(id), lp);
const request = (i: number, id: number, amount: bigint) => act(K.Request, BigInt(i), BigInt(id), amount);
const emergency = (i: number, id: number) => act(K.Emergency, BigInt(i), BigInt(id));
const list = (i: number, id: number) => act(K.List, BigInt(i), BigInt(id));
const unlist = (i: number, id: number) => act(K.Unlist, BigInt(i), BigInt(id));
const credit = (e: number, i: number, id: number, amount: bigint) => act(K.Credit, BigInt(e), BigInt(i), BigInt(id), amount);
const settle = (e: number, i: number) => act(K.Settle, BigInt(e), BigInt(i));
const forfeit = (amount: bigint) => act(K.Forfeit, amount);
const fund = (j: number, amount: bigint) => act(K.Fund, BigInt(j), amount);
const refill = (j: number) => act(K.Refill, BigInt(j));
const pullForfeits = () => act(K.PullForfeits);
const fundSeed = (amount: bigint) => act(K.FundSeed, amount);
const freeze = (e: number, i: number) => act(K.Freeze, BigInt(e), BigInt(i));
const cast = (e: number, i: number, id: number) => act(K.Cast, BigInt(e), BigInt(i), BigInt(id));
const close = (e: number, i: number) => act(K.Close, BigInt(e), BigInt(i));
const autoPair = (j: number) => act(K.AutoPair, BigInt(j));
/** Two checkpoints 30 minutes apart give both pairs a fresh TWAP at the second. */
const twap = (): Act[] => [ckpt(0), ckpt(1), warp(TWAP), ckpt(0), ckpt(1)];

export function compounderScenarios(): Scenario[] {
  const sc: Scenario[] = [];
  // 1. Full coverage: a funded reserve matches every share; the LP lands in the earning lot at its
  //    age, and nothing returns liquid but the rounding.
  sc.push({ name: 'covered', actions: [
    open(0, 0, 1000n * E18), open(0, 1, 400n * E18), open(1, 2, 300n * E18),
    credit(0, 0, 1, 40n * E18), credit(0, 0, 2, 10n * E18), credit(0, 1, 1, 7n * E18),
    freeze(0, 0), cast(0, 0, 1), // the epoch is not settled yet
    warp(DAY), settle(0, 0), settle(0, 1), freeze(0, 0), fund(0, 30_000n * U6), fund(1, 5n * E18),
    ...twap(), freeze(0, 0), freeze(0, 0), freeze(0, 1), cast(0, 0, 1), cast(0, 0, 1), cast(0, 0, 2), cast(0, 1, 1),
    cast(0, 0, 3), cast(0, 2, 1), refill(0), refill(2),
  ] });
  // 2. Partial coverage: the reserve covers part of the demand, pro-rata; the rest of each share
  //    returns liquid, and a dry pool-epoch returns everything.
  sc.push({ name: 'partial', actions: [
    open(0, 0, 2000n * E18), open(0, 1, 500n * E18), credit(0, 0, 1, 300n * E18), credit(0, 0, 2, 100n * E18),
    warp(DAY), settle(0, 0), fund(0, 40n * U6), ...twap(), freeze(0, 0), cast(0, 0, 2), cast(0, 0, 1),
    credit(1, 0, 1, 50n * E18), warp(DAY), settle(1, 0), ...twap(), freeze(1, 0), cast(1, 0, 1),
    // Dust: a covered share too small to pair a single quote wei returns liquid.
    credit(2, 0, 1, 5n * 10n ** 12n), credit(2, 0, 2, 10n ** 12n), warp(DAY), settle(2, 0), fund(0, 10n), ...twap(), freeze(2, 0),
    cast(2, 0, 2), cast(2, 0, 1),
  ] });
  // 3. The price moves after the freeze: a pump leaves quote over (back to unreserved), a dump
  //    leaves EMBER over (back to its owner); outside the band a cast waits, releasing nothing.
  sc.push({ name: 'drift', actions: [
    open(0, 0, 1000n * E18), open(0, 1, 1000n * E18), open(0, 2, 1000n * E18), open(0, 3, 1000n * E18),
    credit(0, 0, 1, 20n * E18), credit(0, 0, 2, 20n * E18), credit(0, 0, 3, 20n * E18), credit(0, 0, 4, 20n * E18),
    warp(DAY), settle(0, 0), fund(0, 1000n * U6), ...twap(), freeze(0, 0),
    swap(0, true, 400n * U6), cast(0, 0, 1), // +~1.6%: in band, EMBER is dearer, quote is left over
    swap(0, true, 600n * U6), cast(0, 0, 2), // past the band: waits
    swap(0, false, 1_900n * E18), ckpt(0), warp(TWAP), ckpt(0), cast(0, 0, 2), // back in band
    swap(0, false, 700n * E18), cast(0, 0, 3), // EMBER is cheaper: EMBER is left over
    warp(2n * H), cast(0, 0, 4), // the TWAP is stale: waits
    ...twap(), cast(0, 0, 4),
  ] });
  // 4. The source lot: the youngest active lot open when the epoch ended. A lot opened after it is
  //    not a source; a wholly cooling lot is skipped; with none left the share returns liquid.
  sc.push({ name: 'lots', actions: [
    open(0, 0, 500n * E18), warp(6n * H), deposit(0, 1, 300n * E18), warp(6n * H), deposit(0, 1, 200n * E18),
    open(0, 1, 400n * E18), credit(0, 0, 1, 12n * E18), credit(0, 0, 2, 9n * E18), credit(1, 0, 1, 5n * E18),
    warp(DAY), deposit(0, 1, 100n * E18), // after epoch 0 ended: not a source for it
    settle(0, 0), request(0, 2, 396n * E18), fund(0, 500n * U6), ...twap(), freeze(0, 0),
    cast(0, 0, 1), cast(0, 0, 2), // position 2's only lot is cooling: liquid
    warp(DAY), settle(1, 0), ...twap(), freeze(1, 0), cast(1, 0, 1), // now the day-1 deposit is a source
  ] });
  // 5. Closed, listed and expired: a closed position takes its share liquid; a listed one waits
  //    until it is unlisted; after the window every share returns liquid and the budget closes.
  sc.push({ name: 'expiry', actions: [
    open(0, 0, 500n * E18), open(0, 1, 500n * E18), open(0, 2, 500n * E18), open(0, 3, 500n * E18),
    credit(0, 0, 1, 10n * E18), credit(0, 0, 2, 10n * E18), credit(0, 0, 3, 10n * E18), credit(0, 0, 4, 10n * E18),
    warp(DAY), settle(0, 0), fund(0, 200n * U6), ...twap(), close(0, 0), freeze(0, 0),
    emergency(0, 2), cast(0, 0, 2), list(0, 3), cast(0, 0, 3), unlist(0, 3), cast(0, 0, 3),
    warp(RESERVATION_EPOCHS * DAY - 2n * TWAP - 1n), ...twap(), cast(0, 0, 4), // the last second of the window
    warp(1n), freeze(0, 0), close(0, 0), cast(0, 0, 1), close(0, 0), cast(0, 0, 1),
    credit(1, 0, 1, 3n * E18), warp(DAY), settle(1, 0), cast(1, 0, 1), // never frozen, expired: liquid
    warp(RESERVATION_EPOCHS * DAY), cast(1, 0, 1), freeze(1, 0),
  ] });
  // 6. The idle auto-pair: after seven epochs with no Cast, unreserved quote pairs with seed EMBER
  //    into the sink; a short seed pairs only what it covers; reserved quote is never touched.
  sc.push({ name: 'idle', actions: [
    open(0, 0, 500n * E18), credit(0, 0, 1, 10n * E18), forfeit(30n * E18), pullForfeits(), pullForfeits(),
    fundSeed(0n), fundSeed(20n * E18), fund(0, 2_000n * U6), fund(1, E18), ...twap(), autoPair(0),
    warp(DAY), settle(0, 0), ...twap(), freeze(0, 0), cast(0, 0, 1),
    warp(IDLE_EPOCHS * DAY), ...twap(), autoPair(0), // a Cast in epoch 1: not idle until epoch 8
    warp(DAY), ...twap(), autoPair(0), autoPair(0), autoPair(1), fundSeed(500n * E18), autoPair(1), autoPair(1),
    fund(0, 100n * U6), credit(8, 0, 1, 50n * E18), warp(DAY), settle(8, 0), ...twap(), freeze(8, 0),
    autoPair(0), fundSeed(300n * E18), autoPair(0), autoPair(0), cast(8, 0, 1), autoPair(0), autoPair(3),
  ] });
  // 7–10. Seeded walks over every action.
  for (let seed = 0x2600n; seed < 0x2604n; seed++) sc.push(walk(`walk${seed - 0x2600n}`, seed));
  return sc;
}

/** A seeded run of days: in each, the world moves (swaps, funding, deposits, cooling, listings,
 *  forfeits, seed), the ledger credits shares; after it ends, pool-epochs settle, budgets freeze
 *  (or not) and shares are cast, released or left to expire. */
function walk(name: string, seed: bigint): Scenario {
  let x = seed;
  const rnd = (n: bigint) => { x = (x * 6364136223846793005n + 1442695040888963407n) % (1n << 64n); return (x >> 33n) % n; };
  const m = new CompounderModel();
  const actions: Act[] = [];
  const push = (a: Act) => { apply(m, a); actions.push(a); };
  for (let k = 0; k < 5; k++) push(open(k % 2, k % WALLETS, 200n * E18 + rnd(800n * E18)));
  for (let day = 0; day < 12; day++) {
    for (let k = Number(rnd(5n)) + 2; k > 0; k--) {
      const i = Number(rnd(2n)), pos = m.pools[i].positions.length, id = Number(rnd(BigInt(pos))) + 1, r = rnd(14n);
      if (r < 3n) push(swap(i, rnd(2n) === 0n, i === 0 ? rnd(400n * U6) + 1n : rnd(E18 / 5n) + 1n));
      else if (r < 5n) push(fund(i, i === 0 ? rnd(120n * U6) + 1n : rnd(E18 / 20n) + 1n));
      else if (r === 5n && pos < MAX_POSITIONS && m.bankLp[i] > 1000n * E18) push(open(i, Number(rnd(BigInt(WALLETS))), 100n * E18 + rnd(400n * E18)));
      else if (r === 5n || r === 6n) push(deposit(i, id, 10n * E18 + rnd(100n * E18)));
      else if (r === 7n) push(rnd(10n) === 0n ? emergency(i, id) : request(i, id, rnd(80n * E18) + 1n));
      else if (r === 8n) push(rnd(2n) === 0n ? list(i, id) : unlist(i, id));
      else if (r === 9n) push(rnd(2n) === 0n ? forfeit(rnd(20n * E18) + 1n) : pullForfeits());
      else if (r === 10n) push(fundSeed(rnd(40n * E18)));
      else if (r === 11n) push(autoPair(i));
      else push(warp(rnd(4n * H) + 1n));
    }
    for (let i = 0; i < PAIRS; i++) {
      if (rnd(4n) !== 0n) push(fund(i, i === 0 ? rnd(180n * U6) + 20n * U6 : rnd(E18 / 20n) + E18 / 200n));
      for (let id = 1; id <= m.pools[i].positions.length; id++) if (rnd(3n) !== 0n) push(credit(day, i, id, rnd(40n * E18) + 1n));
    }
    push(warp(T0 + BigInt(day + 1) * DAY + rnd(2n * H) - m.now));
    for (let i = 0; i < PAIRS; i++) if (rnd(6n) !== 0n) push(settle(day, i));
    for (const a of twap()) push(a);
    for (let i = 0; i < PAIRS; i++) if (rnd(5n) !== 0n) push(freeze(day, i));
    for (let i = 0; i < PAIRS; i++) for (let id = 1; id <= m.pools[i].positions.length; id++) {
      const r = rnd(10n);
      if (r < 6n) push(cast(day, i, id));
      else if (r === 6n) push(cast(Math.max(0, day - Number(rnd(9n))), i, id)); // an older epoch, maybe expired
      else if (r === 7n) { push(swap(i, rnd(2n) === 0n, i === 0 ? rnd(900n * U6) + 1n : rnd(E18 / 2n) + 1n)); push(cast(day, i, id)); }
    }
    if (rnd(3n) === 0n) push(close(Math.max(0, day - 8), Number(rnd(2n))));
  }
  return { name, actions };
}

export function compounderVectors() {
  const scenarios = compounderScenarios().map(run);
  const total = scenarios.reduce((t, s) => {
    for (const [k, v] of Object.entries(s.stats.reverts)) t.reverts[k] = (t.reverts[k] ?? 0) + v;
    return {
      ...t, casts: t.casts + s.stats.casts, partial: t.partial + s.stats.partial, released: t.released + s.stats.released, autoPairs: t.autoPairs + s.stats.autoPairs,
      freezes: t.freezes + s.stats.freezes, why: t.why.map((n, k) => n + s.stats.why[k]),
    };
  }, { casts: 0, partial: 0, released: 0, autoPairs: 0, freezes: 0, reverts: {} as Record<string, number>, why: [0, 0, 0, 0, 0] });
  if (total.casts < 40 || total.partial < 10 || total.released < 40 || total.autoPairs < 3 || total.freezes < 50) throw new Error(`too few actions ${JSON.stringify(total)}`);
  total.why.forEach((n, k) => { if (n === 0) throw new Error(`no share returns liquid as ${Release[k]}`); });
  for (const why of ['NotSettled', 'AlreadyFrozen', 'NotFrozen', 'Expired', 'NotExpired', 'NothingToCast', 'AlreadyCast', 'Listed', 'StaleOracle', 'OutOfBand', 'NotIdle', 'NothingToPair', 'UnknownPool', 'ZeroAmount']) {
    if (!total.reverts[why]) throw new Error(`no scenario reverts with ${why}`);
  }
  return {
    version: cfg.version, t0: String(T0), epoch: String(EPOCH), castPct: String(CAST_PCT), reservationEpochs: String(RESERVATION_EPOCHS),
    idleEpochs: String(IDLE_EPOCHS), stats: total, scenarios,
  };
}
