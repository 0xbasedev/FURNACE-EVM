// Quotes from the repo's exact BigInt models (scripts/pair-model.ts, scripts/flow-model.ts), so
// what the interface shows is what the contracts compute, to the wei.
import { PairModel, Revert, fees, BUY, SELL, D } from '@model/pair-model';
import { split, zapIn, zapOut, rebateShare } from '@model/flow-model';
import cfg from '@canonical/furnace.config';

export interface PairState { rE: bigint; rQ: bigint; supply: bigint; quoteDecimals: number }

function model(s: PairState): PairModel {
  const m = new PairModel(s.quoteDecimals);
  m.rE = s.rE;
  m.rQ = s.rQ;
  m.supply = s.supply;
  m.lpBalance = s.supply; // quotes never redeem beyond this
  return m;
}

export interface FeeLanes { lp: bigint; burn: bigint; liquidity: bigint; quoteYield: bigint; total: bigint }

export type Quote<T> = ({ ok: true } & T) | { ok: false; reason: string };

const failed = (e: unknown): { ok: false; reason: string } => {
  if (e instanceof Revert) return { ok: false, reason: e.message };
  throw e;
};

/** Price impact of the curve alone (fees excluded), in ppm: 1 − rIn / (rIn + amountIn). */
const curveImpactPpm = (reserveIn: bigint, amountIn: bigint) =>
  amountIn === 0n ? 0n : D - (reserveIn * D) / (reserveIn + amountIn);

export interface SwapQuote { out: bigint; fee: FeeLanes; impactPpm: bigint; share: bigint }

/** A swap at `share` ppm of the protocol share (10⁶ full; Flow passes the caller's tier). */
export function quoteSwap(s: PairState, buy: boolean, amountIn: bigint, share: bigint): Quote<SwapQuote> {
  try {
    const m = model(s);
    const base = buy ? amountIn : (m.rQ * amountIn) / (m.rE + amountIn);
    const [out] = buy ? m.buy(amountIn, share) : m.sell(amountIn, share);
    const f = fees(base, buy ? BUY : SELL, share);
    const impactPpm = buy ? curveImpactPpm(s.rQ, amountIn) : curveImpactPpm(s.rE, amountIn);
    return { ok: true, out, fee: f, impactPpm, share };
  } catch (e) {
    return failed(e);
  }
}

export interface ZapQuote {
  swapped: bigint;
  liquidity: bigint;
  refundEmber: bigint;
  refundQuote: bigint;
  /** What `deposit` would stake of the same LP after its 1% fee: the nudge's comparison. */
  depositNet: bigint;
  saved: bigint;
  impactPpm: bigint;
}

export const DEPOSIT_FEE_PCT = BigInt(cfg.forge.fees.depositPct);

/** A single-sided zap; staking it through Flow keeps every receipt, `deposit` keeps 99%. */
export function quoteZap(s: PairState, fromQuote: boolean, amountIn: bigint, share: bigint): Quote<ZapQuote> {
  try {
    const m = model(s);
    const swappedPart = split(m, fromQuote, amountIn, share);
    const z = zapIn(m, fromQuote, amountIn, share);
    const depositNet = z.liquidity - (z.liquidity * DEPOSIT_FEE_PCT) / 100n;
    const impactPpm = fromQuote ? curveImpactPpm(s.rQ, swappedPart) : curveImpactPpm(s.rE, swappedPart);
    return {
      ok: true,
      swapped: z.swapped,
      liquidity: z.liquidity,
      refundEmber: z.refundEmber,
      refundQuote: z.refundQuote,
      depositNet,
      saved: z.liquidity - depositNet,
      impactPpm,
    };
  } catch (e) {
    return failed(e);
  }
}

/** An unzap: redeem `liquidity` and sell the other side into one token. */
export function quoteZapOut(s: PairState, liquidity: bigint, toQuote: boolean, share: bigint): Quote<{ out: bigint }> {
  if (liquidity > s.supply) return { ok: false, reason: 'MoreThanSupply' };
  try {
    return { ok: true, out: zapOut(model(s), liquidity, toQuote, share) };
  } catch (e) {
    return failed(e);
  }
}

/** The protocol-share scale for a wallet's rebate percent, as Flow snaps it. */
export const shareForRebatePct = (pct: bigint): bigint => rebateShare(pct);

export const tierName = (share: bigint): string => {
  if (share === D) return 'No Relic rebate';
  const pct = Number((D - share) / 10_000n);
  const relic = cfg.forge.relics.find((r) => r.perks.feeRebatePct === pct);
  return `${relic ? relic.key[0].toUpperCase() + relic.key.slice(1) : 'Relic'} rebate: ${pct}% of the protocol share`;
};

/** Mid price, quote per EMBER, as a float for display only. */
export const midPrice = (s: PairState): number =>
  Number(s.rQ) / 10 ** s.quoteDecimals / (Number(s.rE) / 1e18);

/** Simulated reserves for the demo before anything is deployed (the smoke run's seed). */
export const DEMO: [PairState, PairState] = [
  { rE: 50_000n * 10n ** 18n, rQ: 50_000n * 10n ** 6n, supply: 50_000n * 10n ** 18n, quoteDecimals: 6 },
  { rE: 20_000n * 10n ** 18n, rQ: 10n * 10n ** 18n, supply: 447_213_595_499_957_939_281n, quoteDecimals: 18 },
];
