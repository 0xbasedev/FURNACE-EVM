// Exact BigInt reference of EmberPair (docs/adr/0015-ember-pairs.md), written from the ADR and
// the canonical config, independently of the contract. The Solidity test replays its scenarios
// step by step and compares every output, every revert and the pair's state after each step.
import cfg from '../canonical/furnace.config';
import { parseUnits, isqrt } from '../canonical/accounting';

export class Revert extends Error {}
const need = (ok: boolean, why: string) => { if (!ok) throw new Revert(why); };
const ceilDiv = (a: bigint, b: bigint) => (a + b - 1n) / b;
const min = (a: bigint, b: bigint) => (a < b ? a : b);

/** bps (half-bps allowed) → ppm, exactly. */
const ppm = (bps: number) => parseUnits(String(bps), 2);
export const D = 1_000_000n;
const sw = cfg.fees.swap;
export const LP_PPM = ppm(sw.buy.lpBps);
export const BUY = { burn: ppm(sw.buy.burnBps), liquidity: ppm(sw.buy.liquidityBps), quoteYield: 0n };
export const SELL = { burn: ppm(sw.sell.burnBps), liquidity: ppm(sw.sell.liquidityBps), quoteYield: ppm(sw.sell.quoteYieldBps) };
export const MINIMUM_LIQUIDITY = 1000n;
export const FULL_SHARE = D;

export interface Fees { lp: bigint; burn: bigint; liquidity: bigint; quoteYield: bigint; total: bigint }

/** Every component rounds up; protocol parts scale by `share` (ppm of the protocol share charged). */
export function fees(g: bigint, side: typeof BUY, share: bigint): Fees {
  const lp = ceilDiv(g * LP_PPM, D);
  const part = (p: bigint) => ceilDiv(g * p * share, D * D);
  const burn = part(side.burn), liquidity = part(side.liquidity), quoteYield = part(side.quoteYield);
  return { lp, burn, liquidity, quoteYield, total: lp + burn + liquidity + quoteYield };
}

export class PairModel {
  rE = 0n; rQ = 0n; supply = 0n; lpBalance = 0n;
  burn = 0n; liquidity = 0n; quoteYield = 0n;
  readonly quoteScale: bigint;
  constructor(readonly quoteDecimals: number) { this.quoteScale = 10n ** BigInt(18 - quoteDecimals); }

  private book(f: Fees) { this.burn += f.burn; this.liquidity += f.liquidity; this.quoteYield += f.quoteYield; }

  buy(quoteIn: bigint, share: bigint): bigint[] {
    need(quoteIn > 0n, 'ZeroAmount');
    need(this.supply > 0n, 'NoLiquidity');
    const f = fees(quoteIn, BUY, share);
    need(f.total < quoteIn, 'TooSmall');
    const net = quoteIn - f.total;
    const out = (this.rE * net) / (this.rQ + net);
    need(out > 0n, 'ZeroOutput');
    this.rQ += net + f.lp;
    this.rE -= out;
    this.book(f);
    return [out, f.total, f.lp];
  }

  sell(emberIn: bigint, share: bigint): bigint[] {
    need(emberIn > 0n, 'ZeroAmount');
    need(this.supply > 0n, 'NoLiquidity');
    const gross = (this.rQ * emberIn) / (this.rE + emberIn);
    const f = fees(gross, SELL, share);
    need(f.total < gross, 'TooSmall');
    this.rE += emberIn;
    this.rQ = this.rQ - gross + f.lp;
    this.book(f);
    return [gross - f.total, f.total, f.lp];
  }

  add(emberDesired: bigint, quoteDesired: bigint): bigint[] {
    need(emberDesired > 0n && quoteDesired > 0n, 'ZeroAmount');
    if (this.supply === 0n) {
      const l = isqrt(emberDesired * quoteDesired * this.quoteScale);
      need(l > MINIMUM_LIQUIDITY, 'LiquidityTooLow');
      this.rE = emberDesired; this.rQ = quoteDesired;
      this.supply = l; this.lpBalance += l - MINIMUM_LIQUIDITY;
      return [emberDesired, quoteDesired, l - MINIMUM_LIQUIDITY];
    }
    let e = emberDesired, q = (emberDesired * this.rQ) / this.rE;
    if (q > quoteDesired) { q = quoteDesired; e = (quoteDesired * this.rE) / this.rQ; }
    const l = min((e * this.supply) / this.rE, (q * this.supply) / this.rQ);
    need(l > 0n, 'ZeroLiquidity');
    this.rE += e; this.rQ += q; this.supply += l; this.lpBalance += l;
    return [e, q, l];
  }

  redeem(l: bigint): bigint[] {
    need(l > 0n, 'ZeroAmount');
    const e = (l * this.rE) / this.supply, q = (l * this.rQ) / this.supply;
    need(e > 0n || q > 0n, 'ZeroOutput');
    if (l > this.lpBalance) throw new Error('scenario redeems more than it holds');
    this.lpBalance -= l; this.supply -= l; this.rE -= e; this.rQ -= q;
    return [e, q, 0n];
  }

  collect(): bigint[] {
    const out = [this.burn, this.liquidity, this.quoteYield];
    this.burn = this.liquidity = this.quoteYield = 0n;
    return out;
  }

  /** k never decreases outside a redeem; checked on every model step. */
  get k() { return this.rE * this.rQ; }
}

export enum K { Add, Redeem, Buy, Sell, Collect }
export interface Step { kind: K; a: bigint; b: bigint; share: bigint }

function run(quoteDecimals: number, steps: Step[]) {
  const m = new PairModel(quoteDecimals);
  const cols = { kind: [] as number[], a: [] as string[], b: [] as string[], share: [] as string[], why: [] as string[], out0: [] as string[], out1: [] as string[], out2: [] as string[],
    rE: [] as string[], rQ: [] as string[], supply: [] as string[], lp: [] as string[], burn: [] as string[], liquidity: [] as string[], quoteYield: [] as string[] };
  for (const s of steps) {
    const k0 = m.k, redeem = s.kind === K.Redeem;
    let out = [0n, 0n, 0n], why = '';
    try {
      out = s.kind === K.Add ? m.add(s.a, s.b) : s.kind === K.Redeem ? m.redeem(s.a) : s.kind === K.Buy ? m.buy(s.a, s.share)
        : s.kind === K.Sell ? m.sell(s.a, s.share) : m.collect();
    } catch (e) { if (!(e instanceof Revert)) throw e; why = e.message; }
    if (!redeem && m.k < k0) throw new Error('model k decreased');
    cols.kind.push(s.kind); cols.a.push(String(s.a)); cols.b.push(String(s.b)); cols.share.push(String(s.share)); cols.why.push(why);
    cols.out0.push(String(out[0])); cols.out1.push(String(out[1])); cols.out2.push(String(out[2]));
    cols.rE.push(String(m.rE)); cols.rQ.push(String(m.rQ)); cols.supply.push(String(m.supply)); cols.lp.push(String(m.lpBalance));
    cols.burn.push(String(m.burn)); cols.liquidity.push(String(m.liquidity)); cols.quoteYield.push(String(m.quoteYield));
  }
  return { quoteDecimals, ...cols };
}

/** The scripted edges plus seeded random walks, for a 6-decimal and an 18-decimal quote. */
export function pairVectors() {
  let seed = 0xb1a57n;
  const rnd = (max: bigint) => { seed = (seed * 6364136223846793005n + 1442695040888963407n) & ((1n << 64n) - 1n); return max === 0n ? 0n : seed % max; };
  const E = 10n ** 18n, U = 10n ** 6n;
  const st = (kind: K, a = 0n, b = 0n, share = FULL_SHARE): Step => ({ kind, a, b, share });
  const scenarios: ReturnType<typeof run>[] = [];

  // Edges: before initialization, the minimum, the rebate and waiver figures, tiny trades.
  scenarios.push(run(6, [
    st(K.Buy, U), st(K.Sell, E), st(K.Collect),
    st(K.Add, 1000n, 1n), // √(1000 · 1 · 10¹²) ≈ 3.2·10⁷ units: the quote's scaling at work
    st(K.Redeem, 1n), st(K.Add, 1n, 0n), st(K.Add, 1n, 1n),
  ]));
  scenarios.push(run(6, [st(K.Add, 1n, 1n)])); // √(1 · 1 · 10¹²) = 10⁶ units, above the minimum
  scenarios.push(run(18, [st(K.Add, 1000n, 1000n), st(K.Add, 1001n, 1001n)])); // √(10⁶) = 1000 is not above it; 1001 is
  scenarios.push(run(6, [
    st(K.Add, 1_000_000n * E, 1_000_000n * U),
    st(K.Buy, 1_000_000n), st(K.Sell, 10n ** 18n), // 1 USDC in at full fee; 1 EMBER out
    st(K.Buy, 1_000_000n, 0n, 500_000n), st(K.Sell, 10n ** 18n, 0n, 500_000n), // Bedrock: 22.5 / 27.5 bps
    st(K.Buy, 1_000_000n, 0n, 0n), st(K.Sell, 10n ** 18n, 0n, 0n), // the Compound waiver: 20 bps
    st(K.Buy, 1n), st(K.Buy, 2n), st(K.Buy, 3n), st(K.Buy, 4n), st(K.Buy, 400n), st(K.Buy, 401n),
    st(K.Sell, 1n), st(K.Sell, 10n ** 12n), st(K.Sell, 4n * 10n ** 12n),
    st(K.Collect), st(K.Collect),
    st(K.Add, E, 2n * U), st(K.Add, 3n * E, U), st(K.Add, 1n, U), st(K.Redeem, 10n ** 18n), st(K.Redeem, 1n),
  ]));

  // Random walks.
  for (const [decimals, steps] of [[6, 160], [18, 160], [6, 120], [18, 120]] as const) {
    const unit = 10n ** BigInt(decimals);
    const m = new PairModel(decimals); // a shadow to size redeems within the holder's balance
    const walk: Step[] = [st(K.Add, (rnd(10_000_000n) + 1_000n) * E, (rnd(10_000_000n) + 1_000n) * unit)];
    m.add(walk[0].a, walk[0].b);
    for (let i = 0; i < steps; i++) {
      const r = Number(rnd(100n));
      const share = [FULL_SHARE, FULL_SHARE, FULL_SHARE, 500_000n, 0n, rnd(D + 1n)][Number(rnd(6n))];
      const scale = [1n, 1000n, unit, 1000n * unit, 1_000_000n * unit][Number(rnd(5n))];
      let s: Step;
      if (r < 35) s = st(K.Buy, rnd(scale * 10n) + 1n, 0n, share);
      else if (r < 70) s = st(K.Sell, (rnd(scale * 10n) + 1n) * (10n ** BigInt(18 - decimals)), 0n, share);
      else if (r < 82) s = st(K.Add, rnd(1_000_000n * E) + 1n, rnd(1_000_000n * unit) + 1n);
      else if (r < 94) s = st(K.Redeem, m.lpBalance === 0n ? 1n : rnd(m.lpBalance / 3n + 1n) + 1n);
      else s = st(K.Collect);
      try {
        if (s.kind === K.Add) m.add(s.a, s.b); else if (s.kind === K.Redeem) m.redeem(s.a);
        else if (s.kind === K.Buy) m.buy(s.a, s.share); else if (s.kind === K.Sell) m.sell(s.a, s.share); else m.collect();
      } catch (e) { if (!(e instanceof Revert)) throw e; }
      walk.push(s);
    }
    scenarios.push(run(decimals, walk));
  }
  return { version: cfg.version, lpPpm: String(LP_PPM), scenarios };
}
