// Exact BigInt reference of Flow's routes (docs/adr/0016-flow.md) on top of the pair model: the
// rebate tier, the single-sided zap split, the zap itself with its refunds, and the unzap. The
// Solidity test replays its scenarios against a real Flow and EmberPair, step by step.
import cfg from '../canonical/furnace.config';
import { isqrt } from '../canonical/accounting';
import { PairModel, Revert, LP_PPM, BUY, SELL, D } from './pair-model';

const need = (ok: boolean, why: string) => { if (!ok) throw new Revert(why); };
export const REBATE_TIERS = cfg.forge.relics.map((r) => r.perks.feeRebatePct ?? 0).filter((p) => p > 0).map(BigInt).sort((a, b) => (a < b ? -1 : 1));

/** The pair's protocol-share scale for a rebate source's percent: snapped down to a tier. */
export function rebateShare(pct: bigint): bigint {
  let tier = 0n;
  for (const t of REBATE_TIERS) if (pct >= t) tier = t;
  return D - tier * 10_000n;
}

/** Total fee and protocol part, in ppm, at `share`, as the split's proportional model uses them. */
function rates(buy: boolean, share: bigint) {
  const protocol = buy ? BUY.burn + BUY.liquidity : SELL.burn + SELL.liquidity + SELL.quoteYield;
  const pi = (protocol * share) / D;
  return { F: LP_PPM + pi, Pi: pi, L: LP_PPM };
}

/** The amount of a single-sided input `a` to swap (ADR 0016 §4), floor-rounded. */
export function split(m: PairModel, fromQuote: boolean, a: bigint, share: bigint): bigint {
  const { F, Pi, L } = rates(fromQuote, share);
  if (fromQuote) {
    const r = m.rQ;
    const inner = r * (2n * D - F) ** 2n + 4n * (D - Pi) * (D - F) * a;
    const root = isqrt(r * inner);
    return (2n * a * D * r) / (r * (2n * D - F) + root);
  }
  const r = m.rE;
  const B = r * (2n * D - F) - a * L;
  need(B > 0n, 'ZapTooLarge');
  const root = isqrt(B * B + 4n * (D - Pi) * D * a * r);
  return (2n * a * r * D) / (B + root);
}

/** A zap: swap the split, add what it can at the new ratio, refund the rest. */
export function zapIn(m: PairModel, fromQuote: boolean, a: bigint, share: bigint) {
  need(a > 0n, 'ZeroAmount');
  need(m.supply > 0n, 'NoLiquidity');
  const s = split(m, fromQuote, a, share);
  const [got] = fromQuote ? m.buy(s, share) : m.sell(s, share);
  const [eDesired, qDesired] = fromQuote ? [got, a - s] : [a - s, got];
  const [e, q, liquidity] = m.add(eDesired, qDesired);
  return { swapped: s, liquidity, refundEmber: eDesired - e, refundQuote: qDesired - q };
}

/** An unzap: redeem, then sell the other side into the asked-for token. */
export function zapOut(m: PairModel, liquidity: bigint, toQuote: boolean, share: bigint): bigint {
  const [e, q] = m.redeem(liquidity);
  if (toQuote) return q + (e > 0n ? m.sell(e, share)[0] : 0n);
  return e + (q > 0n ? m.buy(q, share)[0] : 0n);
}

export enum FK { Zap, ZapOut, Swap }
interface Step { kind: FK; fromQuote: boolean; a: bigint; share: bigint }

function run(quoteDecimals: number, seedEmber: bigint, seedQuote: bigint, steps: Step[]) {
  const m = new PairModel(quoteDecimals);
  m.add(seedEmber, seedQuote); // the initializer's first deposit
  const seeded = m.lpBalance;
  m.lpBalance = 0n; // the zapper starts with no receipts; the seed's are the initializer's
  const cols = { kind: [] as number[], fromQuote: [] as boolean[], a: [] as string[], share: [] as string[], why: [] as string[],
    out0: [] as string[], out1: [] as string[], out2: [] as string[], out3: [] as string[],
    rE: [] as string[], rQ: [] as string[], supply: [] as string[], held: [] as string[], fees: [] as string[] };
  for (const st of steps) {
    let out = [0n, 0n, 0n, 0n], why = '';
    const snap = { rE: m.rE, rQ: m.rQ, supply: m.supply, lp: m.lpBalance, b: m.burn, l: m.liquidity, y: m.quoteYield };
    try {
      if (st.kind === FK.Zap) {
        const z = zapIn(m, st.fromQuote, st.a, st.share);
        out = [z.swapped, z.liquidity, z.refundEmber, z.refundQuote];
      } else if (st.kind === FK.ZapOut) {
        out = [zapOut(m, st.a, st.fromQuote, st.share), 0n, 0n, 0n];
      } else {
        out = [(st.fromQuote ? m.buy(st.a, st.share) : m.sell(st.a, st.share))[0], 0n, 0n, 0n];
      }
    } catch (e) {
      if (!(e instanceof Revert)) throw e;
      why = e.message; // the whole call reverts: restore the model
      Object.assign(m, { rE: snap.rE, rQ: snap.rQ, supply: snap.supply, lpBalance: snap.lp, burn: snap.b, liquidity: snap.l, quoteYield: snap.y });
    }
    cols.kind.push(st.kind); cols.fromQuote.push(st.fromQuote); cols.a.push(String(st.a)); cols.share.push(String(st.share)); cols.why.push(why);
    cols.out0.push(String(out[0])); cols.out1.push(String(out[1])); cols.out2.push(String(out[2])); cols.out3.push(String(out[3]));
    cols.rE.push(String(m.rE)); cols.rQ.push(String(m.rQ)); cols.supply.push(String(m.supply)); cols.held.push(String(m.lpBalance));
    cols.fees.push(String(m.burn + m.liquidity + m.quoteYield));
  }
  return { quoteDecimals, seedEmber: String(seedEmber), seedQuote: String(seedQuote), seeded: String(seeded), ...cols };
}

/** Scripted edges and seeded random walks, for a 6- and an 18-decimal quote. */
export function flowVectors() {
  let seed = 0xf10a7n;
  const rnd = (max: bigint) => { seed = (seed * 6364136223846793005n + 1442695040888963407n) & ((1n << 64n) - 1n); return max === 0n ? 0n : seed % max; };
  const E = 10n ** 18n, U = 10n ** 6n;
  const shares = REBATE_TIERS.map((t) => D - t * 10_000n);
  const st = (kind: FK, fromQuote: boolean, a: bigint, share = D): Step => ({ kind, fromQuote, a, share });
  const scenarios = [
    run(6, 1_000_000n * E, 1_000_000n * U, [
      st(FK.Zap, true, 1000n * U), st(FK.Zap, false, 1000n * E),
      st(FK.Zap, true, 1000n * U, shares[0]), st(FK.Zap, false, 1000n * E, shares[1]),
      st(FK.Zap, true, 250_000n * U), st(FK.Zap, false, 400_000n * E), // large against the reserves
      st(FK.Zap, true, 1n), st(FK.Zap, true, 10n), st(FK.Zap, false, 0n), // too small / zero
      st(FK.ZapOut, true, 10n ** 20n), st(FK.ZapOut, false, 10n ** 20n, shares[1]),
      st(FK.Swap, true, 5000n * U, shares[1]), st(FK.Swap, false, 5000n * E, 0n), // a Bedrock buy, a Compound sell
    ]),
    run(18, 20_000n * E, 10n * E, [
      st(FK.Zap, true, E / 10n), st(FK.Zap, false, 500n * E, shares[0]), st(FK.ZapOut, true, 10n ** 18n),
      st(FK.Zap, false, 10n ** 9n * E), // far beyond the reserves: ZapTooLarge
    ]),
  ];
  for (const [decimals, n] of [[6, 60], [18, 60]] as const) {
    const unit = 10n ** BigInt(decimals);
    const seedE = (rnd(5_000_000n) + 10_000n) * E, seedQ = (rnd(5_000_000n) + 10_000n) * unit;
    const shadow = new PairModel(decimals);
    shadow.add(seedE, seedQ); shadow.lpBalance = 0n;
    const steps: Step[] = [];
    for (let i = 0; i < n; i++) {
      const r = Number(rnd(10n));
      const share = [D, D, ...shares][Number(rnd(BigInt(shares.length + 2)))];
      const scale = [1n, 100n, 10_000n, 1_000_000n][Number(rnd(4n))];
      let s: Step;
      if (r < 6) s = r % 2 === 0 ? st(FK.Zap, true, (rnd(scale * 10n) + 1n) * unit, share) : st(FK.Zap, false, (rnd(scale * 10n) + 1n) * E, share);
      else if (r < 8 && shadow.lpBalance > 0n) s = st(FK.ZapOut, r === 6, rnd(shadow.lpBalance / 2n) + 1n, share);
      else s = st(FK.Swap, r % 2 === 0, r % 2 === 0 ? (rnd(scale) + 1n) * unit : (rnd(scale) + 1n) * E, [D, ...shares, 0n][Number(rnd(BigInt(shares.length + 2)))]);
      const snap = { rE: shadow.rE, rQ: shadow.rQ, supply: shadow.supply, lpBalance: shadow.lpBalance, burn: shadow.burn, liquidity: shadow.liquidity, quoteYield: shadow.quoteYield };
      try {
        if (s.kind === FK.Zap) zapIn(shadow, s.fromQuote, s.a, s.share);
        else if (s.kind === FK.ZapOut) zapOut(shadow, s.a, s.fromQuote, s.share);
        else if (s.fromQuote) shadow.buy(s.a, s.share); else shadow.sell(s.a, s.share);
      } catch (e) { if (!(e instanceof Revert)) throw e; Object.assign(shadow, snap); }
      steps.push(s);
    }
    scenarios.push(run(decimals, seedE, seedQ, steps));
  }
  return { version: cfg.version, rebateTiers: REBATE_TIERS.map(String), scenarios };
}
