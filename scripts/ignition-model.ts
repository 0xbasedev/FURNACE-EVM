// Exact BigInt reference of Ignition, the genesis farm (docs/adr/0023-ignition.md), written from
// the spec, the ADR and the canonical config, independently of the contract. The Solidity test
// replays its scenarios on real ASH (AshToken + AshLedger), mock USDC/WETH/WBTC/LP and a mock
// Cold Storage pool, and compares every output, every revert and a hash of the whole state (the
// farm, every pool, every wallet, the Treasury, Cold Storage and the ASH supply) after every step.
// The canonical float `ignitionWeight` is checked beside the integer entry weight.
import cfg, { ignitionWeight } from '../canonical/furnace.config';
import { parseUnits } from '../canonical/accounting';
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex } from '@noble/hashes/utils.js';

export class Revert extends Error {}
const need = (ok: boolean, why: string) => { if (!ok) throw new Revert(why); };

// ── the config's figures, read here independently of FurnaceParams ──
const ig = cfg.ignition;
export const DURATION = BigInt(ig.durationHours) * 3600n;
export const EXIT_WINDOW = BigInt(ig.exitWindowHours) * 3600n;
export const FEE_BPS = BigInt(ig.depositFeePct) * 100n;
export const EARLY_BIRD_PPM = BigInt(ig.earlyBird.maxBonusPct) * 10_000n;
export const PPM = 1_000_000n;
export const TOTAL = parseUnits(ig.rewards.total, 18);
/** The accumulator's scale [P]: exact enough for 6-, 8- and 18-decimal stakes. */
export const PREC = 10n ** 24n;
/** The most lots a wallet holds in one pool [P]. */
export const MAX_LOTS = 16;
export const COLD_FEE_PCT = BigInt(cfg.forge.fees.depositPct);
const BPS = 10_000n;

/** Ignition's pools, in the config's order: USDC, WETH, WBTC and the WETH/USDC LP. */
export enum Asset { USDC, WETH, WBTC, LP }
export const ASSETS = 4;
export const WEIGHTS = ig.pools.map((p) => BigInt(p.weight));
export const DECIMALS = [6, 18, 8, 18];
if (ig.pools.map((p) => p.stakeToken).join() !== 'USDC,WETH,WBTC,WETH/USDC') throw new Error('Ignition pools out of order');

/** The wallets the harness funds, each with FUNDING[asset] of every asset. */
export const WALLETS = 6;
export const FUNDING = DECIMALS.map((d) => 10_000_000n * 10n ** BigInt(d));

/** The early-bird entry weight in ppm for a deposit at `t` (linear, floored) [P]. */
export const weightAt = (t: bigint, start: bigint) => {
  const end = start + DURATION;
  if (t >= end) return PPM;
  const c = t < start ? start : t;
  return PPM + (EARLY_BIRD_PPM * (end - c)) / DURATION;
};

interface Lot { amount: bigint; ppm: bigint }
interface Account { principal: bigint; weighted: bigint; accSnap: bigint; earned: bigint; lots: Lot[] }
interface Pool { enabled: boolean; budget: bigint; lastB: bigint; acc: bigint; unallocated: bigint; principal: bigint; weighted: bigint }
interface Wallet {
  acct: Account[]; optedOut: boolean; snapped: boolean; founder: boolean; usdcKept: bigint; claimed: bigint;
  bal: bigint[]; ash: bigint; cold: bigint; positions: bigint;
}

export class IgnitionModel {
  now = 0n;
  readonly end: bigint;
  readonly pools: Pool[];
  readonly w: Wallet[];
  finalized = false; burned = 0n; released = false; paid = 0n;
  /** Ignition's own balances, donations included; ASH included. */
  hold: bigint[] = [0n, 0n, 0n, 0n]; holdAsh = 0n;
  treasury: bigint[] = [0n, 0n, 0n, 0n];
  ashSupply = 0n;
  /** The mock Cold Storage: USDC held, fees booked, positions opened. */
  coldUsdc = 0n; coldFees = 0n; coldPositions = 0n;

  constructor(readonly start: bigint, readonly lp: boolean) {
    this.end = start + DURATION;
    const enabled = [true, true, true, lp];
    const sum = WEIGHTS.reduce((a, x, i) => a + (enabled[i] ? x : 0n), 0n);
    this.pools = WEIGHTS.map((x, i) => ({
      enabled: enabled[i], budget: enabled[i] ? (TOTAL * x) / sum : 0n, lastB: 0n, acc: 0n, unallocated: 0n, principal: 0n, weighted: 0n,
    }));
    this.w = Array.from({ length: WALLETS }, () => ({
      acct: Array.from({ length: ASSETS }, () => ({ principal: 0n, weighted: 0n, accSnap: 0n, earned: 0n, lots: [] as Lot[] })),
      optedOut: false, snapped: false, founder: false, usdcKept: 0n, claimed: 0n,
      bal: enabled.map((on, i) => (on ? FUNDING[i] : 0n)), ash: 0n, cold: 0n, positions: 0n,
    }));
  }

  /** The pool's cumulative budget at `t`: floor(budget · elapsed / DURATION), never anticipatory. */
  cumulative(i: number, t: bigint) {
    const c = t < this.start ? this.start : t > this.end ? this.end : t;
    return (this.pools[i].budget * (c - this.start)) / DURATION;
  }

  private update(i: number) {
    const p = this.pools[i];
    const b = this.cumulative(i, this.now), delta = b - p.lastB;
    if (delta === 0n) return;
    if (p.weighted === 0n) p.unallocated += delta;
    else { p.acc += (delta * PREC) / p.weighted; this.dustBound += p.weighted / PREC + 1n; }
    p.lastB = b;
  }

  private touch(i: number, a: Account) {
    this.update(i);
    const p = this.pools[i];
    a.earned += (a.weighted * (p.acc - a.accSnap)) / PREC;
    a.accSnap = p.acc;
    this.dustBound += 1n;
  }
  /** What the accumulator's floors can strand, at most: one unit per touch, and weight/PREC + 1 per update. */
  dustBound = 0n;

  private snap(x: Wallet) {
    if (this.now < this.end || x.snapped) return;
    x.snapped = true;
    x.founder = x.acct.some((a) => a.principal !== 0n);
    x.usdcKept = x.acct[Asset.USDC].principal;
  }

  private live(asset: number) { need(asset < ASSETS && this.pools[asset].enabled, 'PoolDisabled'); }

  deposit(i: number, asset: number, gross: bigint, optOut: boolean): bigint[] {
    this.live(asset);
    need(this.now >= this.start && this.now < this.end, 'NotOpen');
    const fee = (gross * FEE_BPS) / BPS, net = gross - fee;
    need(fee !== 0n, 'BelowMinimum');
    const x = this.w[i], a = x.acct[asset], ppm = weightAt(this.now, this.start);
    const last = a.lots[a.lots.length - 1];
    need((last !== undefined && last.ppm === ppm) || a.lots.length < MAX_LOTS, 'TooManyLots');
    if (gross > x.bal[asset]) throw new Error('scenario deposits more than the wallet holds');
    this.touch(asset, a);
    x.bal[asset] -= gross; this.hold[asset] += net; this.treasury[asset] += fee;
    if (last !== undefined && last.ppm === ppm) last.amount += net; else a.lots.push({ amount: net, ppm });
    a.principal += net; a.weighted += net * ppm;
    const p = this.pools[asset];
    p.principal += net; p.weighted += net * ppm;
    if (asset === Asset.USDC && optOut) x.optedOut = true;
    return [net, ppm];
  }

  withdraw(i: number, asset: number, amount: bigint): bigint[] {
    this.live(asset);
    const x = this.w[i], a = x.acct[asset];
    need(amount !== 0n && amount <= a.principal, 'BadAmount');
    need(!(asset === Asset.USDC && !x.optedOut && this.now >= this.end + EXIT_WINDOW), 'MustStake');
    this.snap(x);
    this.touch(asset, a);
    const p = this.pools[asset];
    let left = amount, lots = 0n;
    while (left !== 0n) {
      const lot = a.lots[a.lots.length - 1];
      const take = lot.amount < left ? lot.amount : left;
      lot.amount -= take; left -= take;
      a.weighted -= take * lot.ppm; p.weighted -= take * lot.ppm;
      if (lot.amount === 0n) { a.lots.pop(); lots++; }
    }
    a.principal -= amount; p.principal -= amount;
    this.hold[asset] -= amount; x.bal[asset] += amount;
    return [amount, lots];
  }

  private fin() {
    if (this.finalized) return;
    need(this.now >= this.end, 'TooEarly');
    this.finalized = true;
    for (let i = 0; i < ASSETS; i++) this.update(i);
    if (!this.released) this.release();
    const allotted = this.pools.reduce((n, p) => n + p.budget, 0n);
    const burn = this.pools.reduce((n, p) => n + p.unallocated, 0n) + (TOTAL - allotted);
    this.burned = burn; this.holdAsh -= burn; this.ashSupply -= burn;
  }

  /** Anyone may call the ledger's permissionless release first; Ignition then finds the ASH there. */
  release(): bigint[] {
    need(!this.released, 'AlreadyReleased');
    this.released = true; this.holdAsh += TOTAL; this.ashSupply += TOTAL;
    return [TOTAL, 0n];
  }

  finalize(): bigint[] {
    need(!this.finalized, 'AlreadyFinalized');
    this.fin();
    return [this.burned, 0n];
  }

  private claimOne(i: number): bigint {
    const x = this.w[i];
    let amount = 0n;
    for (let k = 0; k < ASSETS; k++) {
      if (!this.pools[k].enabled) continue;
      const a = x.acct[k];
      this.touch(k, a);
      amount += a.earned; a.earned = 0n;
    }
    if (amount !== 0n) { x.claimed += amount; x.ash += amount; this.holdAsh -= amount; this.paid += amount; }
    return amount;
  }

  claim(i: number): bigint[] {
    this.fin();
    const amount = this.claimOne(i);
    need(amount !== 0n, 'NothingOwed');
    return [amount, 0n];
  }

  claimMany(mask: bigint): bigint[] {
    this.fin();
    let total = 0n;
    for (let i = 0; i < WALLETS; i++) if ((mask >> BigInt(i)) & 1n) total += this.claimOne(i);
    return [total, 0n];
  }

  private stakeOne(i: number): bigint[] | null {
    const x = this.w[i], a = x.acct[Asset.USDC];
    if (x.optedOut || a.principal === 0n) return null;
    this.snap(x);
    this.touch(Asset.USDC, a);
    const amount = a.principal, p = this.pools[Asset.USDC];
    p.principal -= amount; p.weighted -= a.weighted;
    a.principal = 0n; a.weighted = 0n; a.lots = [];
    this.hold[Asset.USDC] -= amount;
    // Cold Storage's `openIgnition`: the standard 1% deposit fee; a USDC pool's minimum is one unit.
    const fee = (amount * COLD_FEE_PCT) / 100n;
    this.coldUsdc += amount; this.coldFees += fee; x.cold += amount - fee;
    const id = ++this.coldPositions; x.positions++;
    return [id, amount];
  }

  stakeUsdc(i: number): bigint[] {
    need(this.now >= this.end + EXIT_WINDOW, 'TooEarly');
    const r = this.stakeOne(i);
    need(r !== null, 'NothingToStake');
    return r!;
  }

  stakeUsdcMany(mask: bigint): bigint[] {
    need(this.now >= this.end + EXIT_WINDOW, 'TooEarly');
    let n = 0n, total = 0n;
    for (let i = 0; i < WALLETS; i++) if ((mask >> BigInt(i)) & 1n) { const r = this.stakeOne(i); if (r) { n++; total += r[1]; } }
    return [n, total];
  }

  // ── views ──
  isFounder(i: number) {
    const x = this.w[i];
    if (this.now < this.end) return false;
    return x.snapped ? x.founder : x.acct.some((a) => a.principal !== 0n);
  }
  usdcKeptOf(i: number) {
    const x = this.w[i];
    if (this.now < this.end) return 0n;
    return x.snapped ? x.usdcKept : x.acct[Asset.USDC].principal;
  }
  pending(i: number) {
    let n = 0n;
    for (let k = 0; k < ASSETS; k++) {
      const p = this.pools[k], a = this.w[i].acct[k];
      if (!p.enabled) continue;
      const delta = this.cumulative(k, this.now) - p.lastB;
      const acc = p.weighted === 0n || delta === 0n ? p.acc : p.acc + (delta * PREC) / p.weighted;
      n += a.earned + (a.weighted * (acc - a.accSnap)) / PREC;
    }
    return n;
  }

  /** The state the Solidity test hashes after every step, in this exact order. */
  words(): bigint[] {
    const x: bigint[] = [this.finalized ? 1n : 0n, this.burned, this.paid];
    for (const p of this.pools) x.push(p.budget, p.lastB, p.acc, p.unallocated, p.principal, p.weighted);
    for (let i = 0; i < WALLETS; i++) {
      const c = this.w[i];
      x.push(c.optedOut ? 1n : 0n, c.snapped ? 1n : 0n, c.founder ? 1n : 0n, c.usdcKept, c.claimed);
      for (const a of c.acct) {
        x.push(a.principal, a.weighted, a.accSnap, a.earned, BigInt(a.lots.length));
        for (const l of a.lots) x.push(l.amount, l.ppm);
      }
      x.push(this.isFounder(i) ? 1n : 0n, this.usdcKeptOf(i), this.pending(i));
      x.push(...c.bal, c.ash, c.cold, c.positions);
    }
    x.push(...this.hold, this.holdAsh, ...this.treasury, this.ashSupply);
    x.push(this.coldUsdc, this.coldFees, this.coldPositions);
    return x;
  }
}

// ── scenarios ──
export enum K { Warp, Deposit, Withdraw, Finalize, Claim, ClaimMany, StakeUsdc, StakeUsdcMany, Release, Donate, WarpTo }
/** One action: [kind, a, b]. A deposit packs `a` = wallet | asset << 8 | optOut << 16; a withdraw `a` = wallet | asset << 8. */
export type Act = [K, bigint, bigint];
const act = (k: K, a: bigint | number = 0n, b: bigint | number = 0n): Act => [k, BigInt(a), BigInt(b)];
const dep = (i: number, asset: Asset, gross: bigint, optOut = false) => act(K.Deposit, i | (asset << 8) | (optOut ? 1 << 16 : 0), gross);
const wd = (i: number, asset: Asset, amount: bigint) => act(K.Withdraw, i | (asset << 8), amount);
const units = (asset: Asset, n: number | bigint) => BigInt(n) * 10n ** BigInt(DECIMALS[asset]);

export interface Scenario { name: string; start: bigint; lp: boolean; actions: Act[] }

const hashWords = (w: bigint[]) => '0x' + bytesToHex(keccak_256(Uint8Array.from(w.flatMap((x) => {
  const h = x.toString(16).padStart(64, '0');
  return Array.from({ length: 32 }, (_, i) => parseInt(h.slice(2 * i, 2 * i + 2), 16));
}))));

/** Apply one action; the harness performs the same calls. Returns the outputs and the revert. */
export function apply(m: IgnitionModel, [k, a, b]: Act): { out: bigint[]; why: string } {
  try {
    let out = [0n, 0n];
    const who = Number(a & 0xffn), asset = Number((a >> 8n) & 0xffn);
    switch (k) {
      case K.Warp: m.now += a; break;
      case K.Deposit: out = m.deposit(who, asset, b, ((a >> 16n) & 1n) === 1n); break;
      case K.Withdraw: out = m.withdraw(who, asset, b); break;
      case K.Finalize: out = m.finalize(); break;
      case K.Claim: out = m.claim(Number(a)); break;
      case K.ClaimMany: out = m.claimMany(a); break;
      case K.StakeUsdc: out = m.stakeUsdc(Number(a)); break;
      case K.StakeUsdcMany: out = m.stakeUsdcMany(a); break;
      case K.Release: out = m.release(); break;
      case K.Donate: m.hold[Number(a)] += b; break; // a token sent to Ignition: owed to nobody
      case K.WarpTo: m.now = a; break;
    }
    return { out, why: '' };
  } catch (e) {
    if (!(e instanceof Revert)) throw e;
    return { out: [0n, 0n], why: e.message };
  }
}

/** Ledger identities checked after every model step. */
function audit(m: IgnitionModel, at: string) {
  for (let k = 0; k < ASSETS; k++) {
    const p = m.pools[k];
    const owed = m.w.reduce((n, x) => n + x.acct[k].principal, 0n);
    if (owed !== p.principal) throw new Error(`${at}: pool ${k} principal diverged`);
    if (m.w.reduce((n, x) => n + x.acct[k].weighted, 0n) !== p.weighted) throw new Error(`${at}: pool ${k} weight diverged`);
    if (m.hold[k] < owed) throw new Error(`${at}: Ignition holds less ${Asset[k]} than it owes`);
    for (const x of m.w) {
      const a = x.acct[k];
      if (a.lots.length > MAX_LOTS) throw new Error(`${at}: too many lots`);
      if (a.lots.reduce((n, l) => n + l.amount, 0n) !== a.principal) throw new Error(`${at}: lots diverged`);
      if (a.lots.reduce((n, l) => n + l.amount * l.ppm, 0n) !== a.weighted) throw new Error(`${at}: lot weights diverged`);
      for (let j = 1; j < a.lots.length; j++) if (a.lots[j].ppm >= a.lots[j - 1].ppm) throw new Error(`${at}: lots out of order`);
    }
    if (p.lastB > p.budget) throw new Error(`${at}: anticipated budget`);
  }
  // ASH: never more than 41,000; paid plus owed plus burned never exceeds what was released.
  const owed = m.w.reduce((n, _, i) => n + m.pending(i), 0n);
  if (m.released && m.paid + owed + m.burned > TOTAL) throw new Error(`${at}: ASH overcommitted`);
  if (m.ashSupply > TOTAL) throw new Error(`${at}: ASH past its Ignition leaf`);
}

function run(s: Scenario) {
  const m = new IgnitionModel(s.start, s.lp);
  m.now = s.start - 3600n; // the harness deploys an hour before START
  const cols = { kind: [] as number[], a: [] as string[], b: [] as string[], why: [] as string[], out0: [] as string[], out1: [] as string[], hash: [] as string[] };
  const stats = { deposits: 0, withdrawals: 0, claims: 0, stakes: 0, finalized: 0, burnedTotal: 0n, dust: '', reverts: {} as Record<string, number> };
  for (const [n, x] of s.actions.entries()) {
    const r = apply(m, x);
    audit(m, `${s.name} step ${n}`);
    if (r.why !== '') stats.reverts[r.why] = (stats.reverts[r.why] ?? 0) + 1;
    else if (x[0] === K.Deposit) stats.deposits++;
    else if (x[0] === K.Withdraw) stats.withdrawals++;
    else if (x[0] === K.Claim) stats.claims++;
    else if (x[0] === K.ClaimMany && r.out[0] !== 0n) stats.claims++;
    else if (x[0] === K.StakeUsdc) stats.stakes++;
    else if (x[0] === K.StakeUsdcMany) stats.stakes += Number(r.out[0]);
    cols.kind.push(x[0]); cols.a.push(String(x[1])); cols.b.push(String(x[2])); cols.why.push(r.why);
    cols.out0.push(String(r.out[0])); cols.out1.push(String(r.out[1]));
    cols.hash.push(hashWords(m.words()));
  }
  if (m.finalized) { stats.finalized = 1; stats.burnedTotal = m.burned; }
  // Once everyone has claimed, the ASH Ignition still holds is the accumulator's rounding dust only.
  if (m.finalized && m.w.every((_, i) => m.pending(i) === 0n)) {
    const dust = TOTAL - m.paid - m.burned;
    if (dust < 0n || dust > m.dustBound) throw new Error(`${s.name}: ASH dust ${dust} over its bound ${m.dustBound}`);
    stats.dust = String(dust);
  }
  return { name: s.name, start: String(s.start), lp: s.lp, ...cols, stats: { ...stats, burnedTotal: String(stats.burnedTotal) } };
}

const T0 = 1_800_000_000n;
const H = 3600n;
const end = (): Act => act(K.WarpTo, T0 + DURATION); // to END exactly
const toStart = (): Act => act(K.Warp, H);

export function ignitionScenarios(): Scenario[] {
  const sc: Scenario[] = [];
  // 1. Two wallets in one pool all event: the early one earns its +10% on top of pro rata; claims
  //    after close pay the whole USDC budget less rounding.
  sc.push({ name: 'early-bird', start: T0, lp: true, actions: [
    toStart(), dep(0, Asset.USDC, units(Asset.USDC, 10_000)), act(K.Warp, DURATION / 2n), dep(1, Asset.USDC, units(Asset.USDC, 10_000)),
    act(K.Claim, 0), act(K.Warp, DURATION / 2n), act(K.Claim, 0), act(K.Claim, 1), act(K.Claim, 1), act(K.Finalize),
  ] });
  // 2. Every pool, every asset's decimals, deposits across the window; the LP pool is bound.
  sc.push({ name: 'four-pools', start: T0, lp: true, actions: [
    dep(0, Asset.USDC, units(Asset.USDC, 1)), toStart(),
    dep(0, Asset.USDC, units(Asset.USDC, 50_000)), dep(1, Asset.WETH, units(Asset.WETH, 20)), dep(2, Asset.WBTC, units(Asset.WBTC, 1)),
    dep(3, Asset.LP, units(Asset.LP, 1_000)), act(K.Warp, 7n * H), dep(4, Asset.WETH, units(Asset.WETH, 3) + 7n), act(K.Warp, 30n * H),
    dep(5, Asset.WBTC, 123_456_789n), dep(1, Asset.USDC, 33_333_333n), act(K.Warp, DURATION - 37n * H - 1n), dep(2, Asset.LP, units(Asset.LP, 1)),
    act(K.Warp, 1), dep(2, Asset.LP, units(Asset.LP, 1)), act(K.Finalize), act(K.ClaimMany, 0x3fn), act(K.ClaimMany, 0x3fn), act(K.Claim, 3),
  ] });
  // 3. No LP pool: its weight is redistributed over the three bound pools; the LP asset refuses.
  sc.push({ name: 'no-lp', start: T0, lp: false, actions: [
    toStart(), dep(0, Asset.LP, units(Asset.LP, 1)), wd(0, Asset.LP, 1n), dep(0, Asset.USDC, units(Asset.USDC, 1_000)), dep(1, Asset.WETH, units(Asset.WETH, 1)),
    dep(2, Asset.WBTC, units(Asset.WBTC, 1)), act(K.Warp, DURATION), act(K.ClaimMany, 0x07n), act(K.Finalize),
  ] });
  // 4. Withdrawals youngest first: lots at falling weights, partial and whole withdrawals, a return
  //    deposit at a new weight; principal can leave at any time during the event.
  sc.push({ name: 'youngest-first', start: T0, lp: true, actions: [
    toStart(), dep(0, Asset.WETH, units(Asset.WETH, 10)), act(K.Warp, 10n * H), dep(0, Asset.WETH, units(Asset.WETH, 5)),
    act(K.Warp, 10n * H), dep(0, Asset.WETH, units(Asset.WETH, 1)), dep(1, Asset.WETH, units(Asset.WETH, 8)), wd(0, Asset.WETH, units(Asset.WETH, 2)),
    wd(0, Asset.WETH, 0n), wd(0, Asset.WETH, units(Asset.WETH, 100)), act(K.Warp, 5n * H), wd(0, Asset.WETH, units(Asset.WETH, 4) + 1n),
    dep(0, Asset.WETH, units(Asset.WETH, 1)), wd(1, Asset.WETH, units(Asset.WETH, 8) - units(Asset.WETH, 8) * 3n / 100n),
    act(K.Warp, 20n * H), wd(0, Asset.WETH, 1n), end(), wd(0, Asset.WETH, units(Asset.WETH, 1)), act(K.ClaimMany, 0x03n),
    act(K.Warp, EXIT_WINDOW), wd(0, Asset.WETH, units(Asset.WETH, 1)), act(K.Claim, 0),
  ] });
  // 5. An empty pool's time accrues to nobody and is burned at close; so is the pools' budget dust.
  sc.push({ name: 'empty-time', start: T0, lp: true, actions: [
    toStart(), act(K.Warp, 12n * H), dep(0, Asset.USDC, units(Asset.USDC, 100)), act(K.Warp, 12n * H), wd(0, Asset.USDC, units(Asset.USDC, 97)),
    act(K.Warp, 12n * H), dep(1, Asset.WBTC, units(Asset.WBTC, 2)), act(K.Finalize), act(K.Warp, DURATION), act(K.Finalize), act(K.Finalize),
    act(K.ClaimMany, 0x3fn), act(K.Claim, 0),
  ] });
  // 6. The cap of 16 lots: same-weight deposits merge, a 17th weight refuses, a withdrawal frees a lot.
  {
    const actions: Act[] = [toStart()];
    for (let j = 0; j < MAX_LOTS; j++) actions.push(dep(0, Asset.WBTC, 1_000n + BigInt(j)), act(K.Warp, 60));
    actions.push(dep(0, Asset.WBTC, 1_000n), dep(0, Asset.WBTC, 34n), dep(0, Asset.WBTC, 33n), act(K.Warp, 1), dep(0, Asset.WBTC, 1_000n),
      wd(0, Asset.WBTC, 985n), dep(0, Asset.WBTC, 5_000n), act(K.Warp, 600), dep(0, Asset.WBTC, 5_000n), dep(0, Asset.WBTC, 1n), end(),
      dep(0, Asset.WBTC, 1_000n), act(K.Claim, 0));
    sc.push({ name: 'lot-cap', start: T0, lp: true, actions });
  }
  // 7. The close: USDC auto-stakes into Cold Storage after the free-exit window unless opted out;
  //    during the window it may still leave; other assets are always claimable fee-free.
  sc.push({ name: 'close', start: T0, lp: true, actions: [
    toStart(), dep(0, Asset.USDC, units(Asset.USDC, 25_000)), dep(1, Asset.USDC, units(Asset.USDC, 5_000), true), dep(1, Asset.USDC, units(Asset.USDC, 1)),
    dep(2, Asset.USDC, units(Asset.USDC, 7_000)), dep(3, Asset.WETH, units(Asset.WETH, 2)), dep(4, Asset.USDC, units(Asset.USDC, 3)),
    act(K.StakeUsdc, 0), end(), act(K.StakeUsdc, 0), wd(2, Asset.USDC, units(Asset.USDC, 1_000)), act(K.Warp, EXIT_WINDOW - 1n),
    act(K.StakeUsdcMany, 0x3fn), wd(4, Asset.USDC, 1n), act(K.Warp, 1), wd(4, Asset.USDC, 1n), wd(1, Asset.USDC, units(Asset.USDC, 100)),
    act(K.StakeUsdc, 1), act(K.StakeUsdc, 3), act(K.StakeUsdc, 0), act(K.StakeUsdcMany, 0b011100n), act(K.StakeUsdc, 2),
    wd(3, Asset.WETH, units(Asset.WETH, 2) - units(Asset.WETH, 2) * 3n / 100n), wd(1, Asset.USDC, units(Asset.USDC, 4_750)),
    act(K.ClaimMany, 0x3fn), act(K.StakeUsdcMany, 0x3fn),
  ] });
  // 8. Founders: principal kept through close, read live until a wallet's first post-close action,
  //    then from its record; withdrawing everything before close forfeits it.
  sc.push({ name: 'founders', start: T0, lp: true, actions: [
    toStart(), dep(0, Asset.WETH, units(Asset.WETH, 1)), dep(1, Asset.USDC, units(Asset.USDC, 100)), dep(2, Asset.WBTC, units(Asset.WBTC, 1)),
    wd(2, Asset.WBTC, units(Asset.WBTC, 1) - units(Asset.WBTC, 1) * 3n / 100n), end(), wd(0, Asset.WETH, units(Asset.WETH, 1) - units(Asset.WETH, 1) * 3n / 100n),
    act(K.Warp, EXIT_WINDOW), act(K.StakeUsdc, 1), act(K.Finalize), act(K.ClaimMany, 0x07n),
  ] });
  // 9. The ledger's release is permissionless: someone calls it before close, Ignition finds the ASH.
  sc.push({ name: 'early-release', start: T0, lp: true, actions: [
    act(K.Release), toStart(), dep(0, Asset.USDC, units(Asset.USDC, 10)), act(K.Release), act(K.Donate, Asset.USDC, units(Asset.USDC, 5)),
    act(K.Donate, Asset.WETH, 77n), act(K.Warp, DURATION), act(K.Claim, 0), act(K.Release),
  ] });
  // 10–15. Seeded random walks over the window, the close and the claims.
  for (let seed = 0x1900n; seed < 0x1906n; seed++) {
    let x = seed;
    const rnd = (n: bigint) => { x = (x * 6364136223846793005n + 1442695040888963407n) % (1n << 64n); return (x >> 33n) % n; };
    const lp = rnd(3n) !== 0n;
    const actions: Act[] = [toStart()];
    const steps = 48;
    for (let i = 0; i < steps; i++) {
      const r = rnd(10n), who = Number(rnd(BigInt(WALLETS))), asset = Number(rnd(4n)) as Asset;
      const big = units(asset, rnd(5_000n) + 1n) / (asset === Asset.WBTC ? 1_000n : asset === Asset.WETH ? 100n : 1n);
      if (r < 5n) actions.push(dep(who, asset, rnd(4n) === 0n ? rnd(1_000n) + 1n : big, rnd(5n) === 0n));
      else if (r < 7n) actions.push(wd(who, asset, rnd(3n) === 0n ? big : rnd(10n ** BigInt(DECIMALS[asset]))));
      else actions.push(act(K.Warp, rnd(8n) * H + rnd(H)));
    }
    actions.push(end());
    for (let i = 0; i < 10; i++) {
      const r = rnd(6n), who = Number(rnd(BigInt(WALLETS)));
      if (r === 0n) actions.push(act(K.Warp, rnd(2n) * EXIT_WINDOW));
      else if (r === 1n) actions.push(act(K.StakeUsdcMany, rnd(64n)));
      else if (r === 2n) actions.push(wd(who, Number(rnd(4n)), rnd(10n ** 6n)));
      else if (r === 3n) actions.push(act(K.ClaimMany, rnd(64n)));
      else actions.push(act(K.Claim, who));
    }
    actions.push(act(K.Warp, EXIT_WINDOW), act(K.StakeUsdcMany, 0x3fn), act(K.ClaimMany, 0x3fn));
    sc.push({ name: `walk${seed - 0x1900n}`, start: T0, lp, actions });
  }
  return sc;
}

/** The integer entry weight against the canonical float `ignitionWeight`, at fixed points. */
function canonicalCrossCheck() {
  const points = [0n, 1n, 3_600n, DURATION / 3n, DURATION / 2n, DURATION - 3_600n, DURATION - 1n, DURATION];
  const ppm = points.map((e) => weightAt(T0 + e, T0));
  for (const [j, e] of points.entries()) {
    const float = ignitionWeight(Number(e) / 3600) * 1e6;
    if (Math.abs(Number(ppm[j]) - float) > 1) throw new Error(`entry weight diverges from canonical at ${e}`);
  }
  if (ppm[0] !== PPM + EARLY_BIRD_PPM || weightAt(T0 + DURATION, T0) !== PPM) throw new Error('entry weight edges');
  return { weightElapsed: points.map(String), weightPpm: ppm.map(String) };
}

export function ignitionVectors() {
  const cross = canonicalCrossCheck();
  const scenarios = ignitionScenarios().map(run);
  const total = scenarios.reduce((a, s) => {
    for (const [k, v] of Object.entries(s.stats.reverts)) a.reverts[k] = (a.reverts[k] ?? 0) + v;
    return { ...a, deposits: a.deposits + s.stats.deposits, withdrawals: a.withdrawals + s.stats.withdrawals, claims: a.claims + s.stats.claims,
      stakes: a.stakes + s.stats.stakes, finalized: a.finalized + s.stats.finalized };
  }, { deposits: 0, withdrawals: 0, claims: 0, stakes: 0, finalized: 0, reverts: {} as Record<string, number> });
  // Non-vacuity: every path and every refusal is exercised.
  if (total.deposits < 80 || total.withdrawals < 25 || total.claims < 25 || total.stakes < 8 || total.finalized < 12) throw new Error(`too few actions ${JSON.stringify(total)}`);
  for (const why of ['PoolDisabled', 'NotOpen', 'BelowMinimum', 'TooManyLots', 'BadAmount', 'MustStake', 'TooEarly', 'AlreadyFinalized',
    'NothingOwed', 'NothingToStake', 'AlreadyReleased']) {
    if (!total.reverts[why]) throw new Error(`no scenario reverts with ${why}`);
  }
  return { version: cfg.version, total: String(TOTAL), feeBps: String(FEE_BPS), duration: String(DURATION), ...cross, stats: total, scenarios };
}
