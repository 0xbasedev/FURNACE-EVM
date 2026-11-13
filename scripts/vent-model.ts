// Exact BigInt reference of the Vent (docs/adr/0020-vent.md), written from the ADR and the
// canonical config, independently of the contract. The Solidity test replays its scenarios on two
// real EmberPairs, four mock fee pools and a mock Mantle, and compares every output, every revert
// and a hash of the whole state (the Vent's lanes, ledgers and balances, the pairs, the pools,
// what each recipient received, and the pairs' TWAP) after every step.
import cfg from '../canonical/furnace.config';
import { parseUnits } from '../canonical/accounting';
import { PairModel, Revert, FULL_SHARE } from './pair-model';
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex } from '@noble/hashes/utils.js';

const need = (ok: boolean, why: string) => { if (!ok) throw new Revert(why); };
const min = (a: bigint, b: bigint) => (a < b ? a : b);

// ── the config's figures, read here independently of FurnaceParams ──
const fl = cfg.fees, bl = fl.burnLane, ex = cfg.execution.vent;
const em = cfg.forge.emergencyExit.routing, deedSplit = cfg.forge.deeds.feeRouting;
export const STD = { liquidity: BigInt(fl.vent.liquidityPct), hearth: BigInt(fl.vent.hearthPct), treasury: BigInt(fl.vent.treasuryPct) };
export const EMER = { liquidity: BigInt(em.liquidityPct), stakers: BigInt(em.stakersPct) };
export const DEED = { liquidity: BigInt(deedSplit.liquidityPct) };
export const TWAP = BigInt(bl.twapSeconds);
export const BAND_BPS = BigInt(bl.avgPriceBandBps);
export const SLIPPAGE_BPS = BigInt(bl.slippageCapBps);
export const CHUNK_BPS = parseUnits(String(bl.maxChunkPctOfReserve), 2);
export const WINDOW = BigInt(ex.aggregateWindowSeconds);
export const WINDOW_MAX_BPS = BigInt(ex.aggregateMaxReserveBps);
export const ORACLE_MAX_AGE = 2n * TWAP; // [P]
export const MIN_BATCH_USD = BigInt(fl.feeVault.minBatchUsd);
export const MAX_WAIT = BigInt(fl.feeVault.maxWaitHours) * 3600n;
export const CREDIT_PCT = BigInt(cfg.emissions.ashfall.recycleRates.protocolBurns);
const BPS = 10_000n;

/** Tokens, by index: EMBER, each pair's quote, each pair's LP, and one the Vent does not know. */
export enum T { Ember, Q0, Q1, L0, L1, Unknown }
export const QUOTE_DECIMALS = [6, 18] as const; // BlastPool's USDC, SmelterPool's WETH
export enum Who { Hearth, Treasury, Stakers, QuoteYield }
export enum Deferral { None, Empty, NotEligible, Paused, NoOracle, Stale, Band, Window, Unsafe }
/** The mock pools' stake tokens: the two pairs' LP, EMBER, BlastPool's quote (as in the kit). */
export const POOL_TOKEN = [T.L0, T.L1, T.Ember, T.Q0] as const;

interface Lane { burnQuote: bigint; matchReserve: bigint; pendingSince: bigint; draining: boolean; windowId: bigint; windowBase: bigint; windowSpent: bigint }
const lane0 = (): Lane => ({ burnQuote: 0n, matchReserve: 0n, pendingSince: 0n, draining: false, windowId: 0n, windowBase: 0n, windowSpent: 0n });

export class VentModel {
  now = 0n;
  readonly pairs = [new PairModel(QUOTE_DECIMALS[0]), new PairModel(QUOTE_DECIMALS[1])];
  readonly lanes = [lane0(), lane0()];
  /** owed[who][token], received[who][token], for EMBER and the two quotes. */
  readonly owed = [0, 1, 2, 3].map(() => [0n, 0n, 0n]);
  readonly received = [0, 1, 2, 3].map(() => [0n, 0n, 0n]);
  /** The Vent's balance of each token (T order), donations and unbooked LP dust included. */
  readonly bal = [0n, 0n, 0n, 0n, 0n, 0n];
  /** Each mock pool's fee ledgers [deposit, withdrawal, emergency]. */
  readonly pools = [0, 1, 2, 3].map(() => [0n, 0n, 0n]);
  readonly drawn = [0n, 0n];
  totalBurned = 0n; totalCredit = 0n;

  setNow(t: bigint) { this.now = t; for (const p of this.pairs) p.now = t; }

  // ── collection ──
  collectPool(i: number): bigint[] {
    need(i < 4, 'BadPool');
    const [dep, wd, emer] = this.pools[i];
    this.pools[i] = [0n, 0n, 0n];
    const tok = POOL_TOKEN[i];
    this.bal[tok] += dep + wd + emer;
    this.book(tok, dep + wd, emer, 0n);
    return [dep + wd, emer, 0n];
  }

  collectPair(j: number): bigint[] {
    need(j < 2, 'BadPair');
    const [burn, liquidity, quoteYield] = this.pairs[j].collect();
    const q = j === 0 ? T.Q0 : T.Q1;
    this.bal[q] += burn + liquidity + quoteYield;
    const l = this.lanes[j];
    this.addBurnQuote(l, burn);
    l.matchReserve += liquidity;
    this.owed[Who.QuoteYield][q] += quoteYield;
    return [burn, liquidity, quoteYield];
  }

  collectAll(): bigint[] {
    for (let i = 0; i < 4; i++) this.collectPool(i);
    for (let j = 0; j < 2; j++) this.collectPair(j);
    return [0n, 0n, 0n];
  }

  bookDeedFee(tok: T, amount: bigint, byDeeds: boolean): bigint[] {
    need(byDeeds, 'NotDeeds');
    need(amount > 0n, 'ZeroAmount');
    need(tok !== T.Unknown, 'UnknownAsset');
    this.bal[tok] += amount;
    this.book(tok, 0n, 0n, amount);
    return [0n, 0n, 0n];
  }

  private book(tok: T, standard: bigint, emergency: bigint, deed: bigint) {
    if (standard + emergency + deed === 0n) return;
    if (tok === T.Ember) return this.route(T.Ember, 0, standard, emergency, deed);
    if (tok === T.L0 || tok === T.L1) return this.unwind(tok === T.L0 ? 0 : 1, standard, emergency, deed);
    if (tok === T.Q0 || tok === T.Q1) return this.route(tok, tok === T.Q0 ? 0 : 1, standard, emergency, deed);
    throw new Revert('UnknownAsset');
  }

  /** One redeem; each side split by the kinds' LP weights, the rest to the emergency kind. */
  private unwind(j: number, standard: bigint, emergency: bigint, deed: bigint) {
    const p = this.pairs[j], total = standard + emergency + deed;
    if ((total * p.rE) / p.supply === 0n && (total * p.rQ) / p.supply === 0n) return; // dust stays unbooked
    const [e, q] = p.redeem(total);
    const lp = j === 0 ? T.L0 : T.L1, quote = j === 0 ? T.Q0 : T.Q1;
    this.bal[lp] -= total; this.bal[T.Ember] += e; this.bal[quote] += q;
    const share = (x: bigint): [bigint, bigint, bigint] => {
      const s = (x * standard) / total, d = (x * deed) / total;
      return [s, x - s - d, d];
    };
    this.route(T.Ember, 0, ...share(e));
    this.route(quote, j, ...share(q));
  }

  /** Floors for every share but the burn, which takes the remainder. */
  private route(tok: T, j: number, standard: bigint, emergency: bigint, deed: bigint) {
    const hearth = (standard * STD.hearth) / 100n, treasury = (standard * STD.treasury) / 100n, stakers = (emergency * EMER.stakers) / 100n;
    this.owed[Who.Hearth][tok] += hearth;
    this.owed[Who.Treasury][tok] += treasury;
    this.owed[Who.Stakers][tok] += stakers;
    const liquidity = (standard * STD.liquidity) / 100n + (emergency * EMER.liquidity) / 100n + (deed * DEED.liquidity) / 100n;
    const burn = standard + emergency + deed - hearth - treasury - stakers - liquidity;
    if (tok === T.Ember) this.burnEmber(burn + liquidity);
    else { const l = this.lanes[j]; this.addBurnQuote(l, burn); l.matchReserve += liquidity; }
  }

  private addBurnQuote(l: Lane, x: bigint) {
    if (x === 0n) return;
    if (l.burnQuote === 0n) l.pendingSince = this.now;
    l.burnQuote += x;
  }

  private burnEmber(x: bigint) {
    if (x === 0n) return;
    this.bal[T.Ember] -= x;
    this.totalBurned += x;
    this.totalCredit += (x * CREDIT_PCT) / 100n;
  }

  // ── the burn lane ──
  minBatch(j: number) { return j === 0 ? MIN_BATCH_USD * 10n ** BigInt(QUOTE_DECIMALS[0]) : 1n << 256n; }

  vent(j: number): bigint[] {
    need(j < 2, 'BadPair');
    const [reason, quoteIn, twap, minOut] = this.size(j);
    if (reason !== Deferral.None) return [BigInt(reason), 0n, 0n];
    const l = this.lanes[j], p = this.pairs[j];
    l.burnQuote -= quoteIn;
    l.windowSpent += quoteIn;
    if (l.burnQuote === 0n) { l.draining = false; l.pendingSince = 0n; } else l.draining = true;
    const [out] = p.buy(quoteIn, FULL_SHARE, minOut);
    this.bal[j === 0 ? T.Q0 : T.Q1] -= quoteIn;
    this.bal[T.Ember] += out;
    this.burnEmber(out);
    void twap;
    return [0n, quoteIn, out];
  }

  private size(j: number): [Deferral, bigint, bigint, bigint] {
    const l = this.lanes[j], p = this.pairs[j];
    const pending = l.burnQuote;
    if (pending === 0n) return [Deferral.Empty, 0n, 0n, 0n];
    if (!(l.draining || this.now >= l.pendingSince + MAX_WAIT || pending >= this.minBatch(j))) return [Deferral.NotEligible, 0n, 0n, 0n];
    if (p.paused) return [Deferral.Paused, 0n, 0n, 0n];
    if (p.rE === 0n || p.supply === 0n) return [Deferral.NoOracle, 0n, 0n, 0n];
    let twap: bigint, elapsed: bigint;
    try { [twap, elapsed] = p.consult(TWAP); } catch (e) { if (!(e instanceof Revert)) throw e; return [Deferral.NoOracle, 0n, 0n, 0n]; }
    if (elapsed > ORACLE_MAX_AGE || twap === 0n) return [Deferral.Stale, 0n, 0n, 0n];
    const spot = (p.rQ << 112n) / p.rE;
    const gap = spot > twap ? spot - twap : twap - spot;
    if (gap * BPS > twap * BAND_BPS) return [Deferral.Band, 0n, 0n, 0n];
    const id = this.now / WINDOW;
    if (l.windowId !== id || l.windowBase === 0n) { l.windowId = id; l.windowBase = p.rQ; l.windowSpent = 0n; }
    let allowance = (l.windowBase * WINDOW_MAX_BPS) / BPS;
    allowance = allowance > l.windowSpent ? allowance - l.windowSpent : 0n;
    const quoteIn = min(min(pending, (p.rQ * CHUNK_BPS) / BPS), allowance);
    if (quoteIn === 0n) return [Deferral.Window, 0n, 0n, 0n];
    const minOut = ((quoteIn << 112n) * (BPS - SLIPPAGE_BPS)) / (twap * BPS);
    try { if (p.previewBuy(quoteIn, FULL_SHARE).out < minOut) return [Deferral.Unsafe, 0n, 0n, 0n]; }
    catch (e) { if (!(e instanceof Revert)) throw e; return [Deferral.Unsafe, 0n, 0n, 0n]; }
    return [Deferral.None, quoteIn, twap, minOut];
  }

  // ── releases, the match reserve ──
  release(who: Who, tok: T): bigint[] {
    const t = tok as number;
    const amount = t <= 2 ? this.owed[who][t] : 0n;
    if (amount === 0n) return [0n, 0n, 0n];
    this.owed[who][t] = 0n;
    this.bal[t] -= amount;
    this.received[who][t] += amount;
    return [amount, 0n, 0n];
  }

  draw(j: number, amount: bigint, byCompounder: boolean): bigint[] {
    need(byCompounder, 'NotCompounder');
    need(j < 2, 'BadPair');
    need(amount > 0n, 'ZeroAmount');
    const l = this.lanes[j];
    need(amount <= l.matchReserve, 'ExceedsReserve');
    l.matchReserve -= amount;
    this.bal[j === 0 ? T.Q0 : T.Q1] -= amount;
    this.drawn[j] += amount;
    return [0n, 0n, 0n];
  }

  /** The state the Solidity test hashes after every step, in this exact order. */
  words(): bigint[] {
    const w: bigint[] = [];
    for (let j = 0; j < 2; j++) {
      const l = this.lanes[j], p = this.pairs[j];
      w.push(l.burnQuote, l.matchReserve, l.pendingSince, l.draining ? 1n : 0n, l.windowId, l.windowBase, l.windowSpent);
      w.push(p.rE, p.rQ, p.supply, p.burn, p.liquidity, p.quoteYield, p.paused ? 1n : 0n);
      let c: [bigint, bigint] = [0n, 0n];
      try { c = p.consult(TWAP); } catch (e) { if (!(e instanceof Revert)) throw e; }
      w.push(c[0], c[1], this.drawn[j]);
    }
    for (const row of this.owed) w.push(...row);
    for (const row of this.received) w.push(...row);
    w.push(...this.bal.slice(0, 5));
    for (const row of this.pools) w.push(...row);
    w.push(this.totalBurned, this.totalCredit);
    return w;
  }
}

// ── scenarios ──
export enum K { Warp, Trade, PoolFee, CollectPool, CollectPair, CollectAll, Vent, Release, Draw, BookDeed, Donate, Pause, Checkpoint, AddLiquidity }
/** One action: [kind, a, b, c]. */
export type Act = [K, bigint, bigint, bigint];
const act = (k: K, a: bigint | number = 0n, b: bigint | number = 0n, c: bigint | number = 0n): Act => [k, BigInt(a), BigInt(b), BigInt(c)];

export interface Scenario { name: string; start: bigint; seed: [bigint, bigint, bigint, bigint]; actions: Act[] }

const hashWords = (w: bigint[]) => '0x' + bytesToHex(keccak_256(Uint8Array.from(w.flatMap((x) => {
  const h = x.toString(16).padStart(64, '0');
  return Array.from({ length: 32 }, (_, i) => parseInt(h.slice(2 * i, 2 * i + 2), 16));
}))));

/** Apply one action; the harness performs the same calls. Returns the outputs and the revert. */
export function apply(m: VentModel, [k, a, b, c]: Act): { out: bigint[]; why: string } {
  try {
    let out = [0n, 0n, 0n];
    switch (k) {
      case K.Warp: m.setNow(m.now + a); break;
      case K.Trade: out = [(b === 0n ? m.pairs[Number(a)].buy(c, FULL_SHARE) : m.pairs[Number(a)].sell(c, FULL_SHARE))[0], 0n, 0n]; break;
      case K.PoolFee: {
        // The mock pool books a fee of its stake token; LP comes out of the provider's holding.
        const tok = POOL_TOKEN[Number(a)];
        if (tok === T.L0 || tok === T.L1) { const p = m.pairs[tok === T.L0 ? 0 : 1]; if (c > p.lpBalance) throw new Error('scenario books more LP than exists'); }
        m.pools[Number(a)][Number(b)] += c;
        break;
      }
      case K.CollectPool: out = m.collectPool(Number(a)); break;
      case K.CollectPair: out = m.collectPair(Number(a)); break;
      case K.CollectAll: out = m.collectAll(); break;
      case K.Vent: out = m.vent(Number(a)); break;
      case K.Release: out = m.release(Number(a) as Who, Number(b) as T); break;
      case K.Draw: out = m.draw(Number(a), b, c === 0n); break;
      case K.BookDeed: out = m.bookDeedFee(Number(a) as T, b, c === 0n); break;
      case K.Donate: m.bal[Number(a)] += b; break;
      case K.Pause: m.pairs[Number(a)].paused = b !== 0n; break;
      case K.Checkpoint: out = m.pairs[Number(a)].checkpoint(); break;
      case K.AddLiquidity: out = m.pairs[Number(a)].add(b, c); break;
    }
    return { out, why: '' };
  } catch (e) {
    if (!(e instanceof Revert)) throw e;
    return { out: [0n, 0n, 0n], why: e.message };
  }
}

function run(s: Scenario) {
  const m = new VentModel();
  m.setNow(s.start);
  // Seed liquidity, as the harness's provider does at the scenario's start.
  m.pairs[0].add(s.seed[0], s.seed[1]);
  m.pairs[1].add(s.seed[2], s.seed[3]);
  const cols = { kind: [] as number[], a: [] as string[], b: [] as string[], c: [] as string[], why: [] as string[], out0: [] as string[], out1: [] as string[], out2: [] as string[], hash: [] as string[] };
  const stats = { vented: 0, deferred: [0, 0, 0, 0, 0, 0, 0, 0, 0], unwound: 0, reverts: 0 };
  for (const x of s.actions) {
    const before = m.pairs[0].supply + m.pairs[1].supply;
    const r = apply(m, x);
    if (x[0] === K.Vent && r.why === '') { if (r.out[0] === 0n) stats.vented++; else stats.deferred[Number(r.out[0])]++; }
    if (m.pairs[0].supply + m.pairs[1].supply < before && x[0] !== K.Trade) stats.unwound++;
    if (r.why !== '') stats.reverts++;
    cols.kind.push(x[0]); cols.a.push(String(x[1])); cols.b.push(String(x[2])); cols.c.push(String(x[3])); cols.why.push(r.why);
    cols.out0.push(String(r.out[0])); cols.out1.push(String(r.out[1])); cols.out2.push(String(r.out[2]));
    cols.hash.push(hashWords(m.words()));
  }
  return { name: s.name, start: String(s.start), seed: s.seed.map(String), ...cols, stats };
}

const E = 10n ** 18n, U = 10n ** 6n;
const START = 1_800_000_000n; // a realistic timestamp, inside a window
const SEED: [bigint, bigint, bigint, bigint] = [1_000_000n * E, 1_000_000n * U, 1_000_000n * E, 500n * E]; // $1 EMBER; 0.0005 WETH

/** Let the TWAP mature: checkpoints every observation period over more than the window. */
const mature = (): Act[] => Array.from({ length: 8 }, () => [act(K.Warp, 300), act(K.Checkpoint, 0), act(K.Checkpoint, 1)]).flat();

export function ventScenarios(): Scenario[] {
  const sc: Scenario[] = [];
  // 1. Routing: every pool's standard and emergency fees, by asset; the pairs' own fees; releases.
  sc.push({ name: 'routing', start: START, seed: SEED, actions: [
    act(K.PoolFee, 0, 0, 1000n * E), act(K.PoolFee, 0, 1, 333n * E + 7n), act(K.PoolFee, 0, 2, 80n * E + 3n),
    act(K.PoolFee, 1, 0, 50n * E), act(K.PoolFee, 1, 2, 9n * E + 1n),
    act(K.PoolFee, 2, 0, 777n * E + 1n), act(K.PoolFee, 2, 2, 41n * E + 9n),
    act(K.PoolFee, 3, 1, 12_345n * U + 6n), act(K.PoolFee, 3, 2, 999n * U + 1n),
    act(K.CollectPool, 0), act(K.CollectPool, 1), act(K.CollectPool, 2), act(K.CollectPool, 3), act(K.CollectPool, 0), act(K.CollectPool, 4),
    act(K.Trade, 0, 0, 5000n * U), act(K.Trade, 0, 1, 3000n * E), act(K.Trade, 1, 0, E / 10n), act(K.Trade, 1, 1, 777n * E),
    act(K.CollectPair, 0), act(K.CollectPair, 1), act(K.CollectPair, 1), act(K.CollectPair, 2),
    ...[0, 1, 2, 3].flatMap((w) => [T.Ember, T.Q0, T.Q1, T.L0].map((t) => act(K.Release, w, t))),
    act(K.Release, Who.Hearth, T.Ember),
  ] });
  // 2. Dust: LP fees too small to redeem stay unbooked; tiny splits round to burn.
  sc.push({ name: 'dust', start: START, seed: SEED, actions: [
    act(K.PoolFee, 0, 0, 1n), act(K.CollectPool, 0), act(K.PoolFee, 0, 2, 3n), act(K.PoolFee, 0, 0, 2n), act(K.CollectPool, 0),
    act(K.PoolFee, 2, 0, 1n), act(K.PoolFee, 2, 2, 3n), act(K.CollectPool, 2), act(K.PoolFee, 3, 0, 9n), act(K.PoolFee, 3, 2, 1n), act(K.CollectPool, 3),
    act(K.PoolFee, 1, 0, 10n ** 12n), act(K.PoolFee, 1, 2, 10n ** 12n + 1n), act(K.CollectPool, 1),
    ...[0, 1, 2].flatMap((w) => [T.Ember, T.Q0, T.Q1].map((t) => act(K.Release, w, t))),
  ] });
  // 3. The burn lane's guards, each deferring in turn, then a buyback.
  sc.push({ name: 'guards', start: START, seed: SEED, actions: [
    act(K.Vent, 0), act(K.Vent, 2), // empty; a bad pair
    act(K.PoolFee, 3, 0, 1000n * U), act(K.CollectPool, 3), act(K.Vent, 0), // 400 USDC: below the $5,000 batch
    act(K.PoolFee, 3, 0, 20_000n * U), act(K.CollectPool, 3), act(K.Vent, 0), // now above it: no oracle yet
    act(K.Warp, 300), act(K.Checkpoint, 0), act(K.Vent, 0), // one observation, 300 s old: still not ready
    ...mature(), act(K.Pause, 0, 1), act(K.Vent, 0), act(K.Pause, 0, 0),
    act(K.Trade, 0, 0, 30_000n * U), act(K.Vent, 0), // spot ~6% above the TWAP: outside the band
    act(K.Trade, 0, 1, 29_000n * E), act(K.Warp, 1), act(K.Vent, 0), // back near the TWAP: a buyback
    act(K.Vent, 0), act(K.Vent, 0), // the window's allowance is spent
    act(K.Warp, 1800), act(K.Vent, 0), act(K.Warp, 1800), act(K.Vent, 0),
    act(K.Warp, 4000), act(K.Vent, 0), // the newest old-enough observation is now over 2× the window: stale
    act(K.Checkpoint, 0), act(K.Warp, 1800), act(K.Checkpoint, 0), act(K.Vent, 0),
  ] });
  // 4. The window: repeated calls, donations, and a reserve that grows inside the window.
  sc.push({ name: 'window', start: START + 1500n, seed: [10_000n * E, 10_000n * U, 10_000n * E, 5n * E], actions: [
    ...mature(), act(K.PoolFee, 3, 0, 40_000n * U), act(K.CollectPool, 3),
    act(K.Vent, 0), act(K.Vent, 0), act(K.Vent, 0), act(K.Donate, T.Q0, 50_000n * U), act(K.Vent, 0),
    act(K.AddLiquidity, 0, 10_000n * E, 10_000n * U), act(K.Vent, 0), // the base stays fixed; the chunk grows
    act(K.Warp, 300), act(K.Vent, 0), // a new window
    ...Array.from({ length: 12 }, () => [act(K.Warp, 600), act(K.Checkpoint, 0), act(K.Vent, 0)]).flat(),
  ] });
  // 5. The 24 h clock on SmelterPool (no USD threshold), draining, and the 72 h alert's deferrals.
  sc.push({ name: 'clock', start: START, seed: SEED, actions: [
    ...mature(), act(K.PoolFee, 1, 0, 2_000n * E), act(K.CollectPool, 1), act(K.Vent, 1),
    act(K.Warp, 86_399), act(K.Checkpoint, 1), act(K.Vent, 1), act(K.Warp, 1), act(K.Vent, 1), // ineligible; still stale; ...
    act(K.Warp, 300), act(K.Checkpoint, 1), act(K.Warp, 1500), act(K.Checkpoint, 1), act(K.Vent, 1),
    ...Array.from({ length: 10 }, () => [act(K.Warp, 1800), act(K.Checkpoint, 1), act(K.Vent, 1)]).flat(),
    act(K.Pause, 1, 1), act(K.Warp, 3 * 86_400), act(K.Vent, 1), act(K.Pause, 1, 0), act(K.Vent, 1),
  ] });
  // 6. Deed fees, the match reserve and its draws, gating.
  sc.push({ name: 'deedsAndDraws', start: START, seed: SEED, actions: [
    act(K.BookDeed, T.Q0, 100n * U, 1), act(K.BookDeed, T.Q0, 0n, 0), act(K.BookDeed, T.Unknown, 5n, 0),
    act(K.BookDeed, T.Q0, 1001n * U + 1n, 0), act(K.BookDeed, T.Ember, 77n * E + 1n, 0), act(K.BookDeed, T.L1, 3n * E, 0), act(K.BookDeed, T.Q1, 7n, 0),
    act(K.Draw, 0, 1n, 1), act(K.Draw, 0, 0n, 0), act(K.Draw, 2, 1n, 0), act(K.Draw, 0, 10n ** 30n, 0),
    act(K.Draw, 0, 400n * U, 0), act(K.Draw, 1, 1n, 0), act(K.Draw, 0, 100n * U + 1n, 0),
    act(K.PoolFee, 0, 2, 100n * E), act(K.CollectAll), act(K.CollectAll), act(K.Release, Who.Stakers, T.Q0), act(K.Release, Who.Stakers, T.Ember),
  ] });

  // Random walks: trades, fees, collections, vents, releases, draws, deeds, donations, pauses, time.
  for (const seed of [0x7e01n, 0x7e02n, 0x7e03n, 0x7e04n]) {
    let x = seed;
    const rnd = (n: bigint) => { x = (x * 6364136223846793005n + 1442695040888963407n) & ((1n << 64n) - 1n); return n === 0n ? 0n : (x >> 11n) % n; };
    const shadow = new VentModel();
    shadow.setNow(START);
    shadow.pairs[0].add(SEED[0], SEED[1]); shadow.pairs[1].add(SEED[2], SEED[3]);
    const actions: Act[] = [];
    const push = (a: Act) => { actions.push(a); apply(shadow, a); };
    mature().forEach(push);
    for (let i = 0; i < 240; i++) {
      const r = Number(rnd(100n)), j = Number(rnd(2n));
      const qUnit = j === 0 ? U : E / 2000n;
      if (r < 14) {
        push(act(K.Warp, [1n, 60n, 300n, 300n, 600n, 900n, 1800n, 3600n, 86_400n][Number(rnd(9n))]));
        if (rnd(10n) < 8n) { push(act(K.Checkpoint, 0)); push(act(K.Checkpoint, 1)); }
      } else if (r < 20) push(act(K.Checkpoint, j));
      else if (r < 34) push(act(K.Trade, j, rnd(2n), rnd(2n) === 0n ? (rnd(20_000n) + 1n) * qUnit : (rnd(20_000n) + 1n) * E));
      else if (r < 50) {
        const i2 = Number(rnd(4n)), kind = rnd(3n), tok = POOL_TOKEN[i2];
        const amt = tok === T.Q0 ? (rnd(30_000n) + 1n) * U : (rnd(300n) + 1n) * E + rnd(E);
        const lpLeft = tok === T.L0 ? shadow.pairs[0].lpBalance : tok === T.L1 ? shadow.pairs[1].lpBalance : amt;
        push(act(K.PoolFee, i2, kind, amt < lpLeft / 10n ? amt : 1n));
      } else if (r < 58) push(act(K.CollectPool, rnd(4n)));
      else if (r < 63) push(act(K.CollectPair, j));
      else if (r < 66) push(act(K.CollectAll));
      else if (r < 82) push(act(K.Vent, j));
      else if (r < 87) push(act(K.Release, rnd(4n), rnd(3n)));
      else if (r < 91) push(act(K.Draw, j, rnd(2n) === 0n ? shadow.lanes[j].matchReserve / (rnd(3n) + 1n) : rnd(1000n), rnd(5n) === 0n ? 1 : 0));
      else if (r < 94) push(act(K.BookDeed, [T.Ember, T.Q0, T.Q1][Number(rnd(3n))], (rnd(100n) + 1n) * (j === 0 ? U : E), rnd(6n) === 0n ? 1 : 0));
      else if (r < 96) push(act(K.Donate, [T.Ember, T.Q0, T.Q1][Number(rnd(3n))], rnd(1000n) * U));
      else if (r < 98) push(act(K.Pause, j, rnd(4n) === 0n ? 1 : 0));
      else push(act(K.AddLiquidity, j, (rnd(10_000n) + 1n) * E, (rnd(10_000n) + 1n) * qUnit));
    }
    sc.push({ name: `walk${seed - 0x7e00n}`, start: START, seed: SEED, actions });
  }
  return sc;
}

export function ventVectors() {
  const scenarios = ventScenarios().map(run);
  // Non-vacuity: the guards and the buybacks are all exercised.
  const total = scenarios.reduce((a, s) => ({ vented: a.vented + s.stats.vented, deferred: a.deferred.map((d, i) => d + s.stats.deferred[i]), unwound: a.unwound + s.stats.unwound }), { vented: 0, deferred: [0, 0, 0, 0, 0, 0, 0, 0, 0], unwound: 0 });
  if (total.vented < 20) throw new Error(`too few buybacks (${total.vented})`);
  for (const d of [Deferral.Empty, Deferral.NotEligible, Deferral.Paused, Deferral.NoOracle, Deferral.Stale, Deferral.Band, Deferral.Window, Deferral.Unsafe]) {
    if (total.deferred[d] === 0) throw new Error(`no scenario defers with ${Deferral[d]}`);
  }
  if (total.unwound < 5) throw new Error(`too few LP unwinds (${total.unwound})`);
  return { version: cfg.version, creditPct: String(CREDIT_PCT), stats: total, scenarios };
}
