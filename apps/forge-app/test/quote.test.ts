import { describe, expect, it } from 'vitest';
import { quoteSwap, quoteZap, quoteZapOut, shareForRebatePct, tierName, DEMO, type PairState } from '../src/quote';
import { assess, withSlippage, DEFAULT_SLIPPAGE_BPS, MAX_SLIPPAGE_BPS } from '../src/policy';

const E = 10n ** 18n, U = 10n ** 6n;
const big: PairState = { rE: 1_000_000n * E, rQ: 1_000_000n * U, supply: 1_000_000n * E, quoteDecimals: 6 };

describe('quotes are the contracts’ own math', () => {
  it('a 1 USDC buy pays 25 bps, by lane', () => {
    const q = quoteSwap(big, true, U, 1_000_000n);
    if (!q.ok) throw new Error(q.reason);
    expect(q.fee).toEqual({ lp: 2000n, burn: 250n, liquidity: 250n, quoteYield: 0n, total: 2500n });
  });
  it('Bedrock halves the protocol share, never the LP fee', () => {
    const q = quoteSwap(big, true, U, shareForRebatePct(50n));
    if (!q.ok) throw new Error(q.reason);
    expect(q.fee.total).toBe(2250n);
    expect(q.fee.lp).toBe(2000n);
    expect(tierName(q.share)).toMatch(/Bedrock rebate: 50%/);
  });
  it('a rebate snaps down to a tier', () => {
    expect(shareForRebatePct(0n)).toBe(1_000_000n);
    expect(shareForRebatePct(30n)).toBe(750_000n);
    expect(shareForRebatePct(99n)).toBe(500_000n);
  });
  it('a sell books Quote yield in the quote asset', () => {
    const q = quoteSwap(big, false, E, 1_000_000n);
    if (!q.ok) throw new Error(q.reason);
    expect(q.fee.quoteYield).toBeGreaterThan(0n);
    expect(q.fee.total).toBe(q.fee.lp + q.fee.burn + q.fee.liquidity + q.fee.quoteYield);
  });
  it('a too-small trade reports the contract’s revert', () => {
    expect(quoteSwap(big, true, 3n, 1_000_000n)).toEqual({ ok: false, reason: 'TooSmall' });
  });
  it('a zap stakes every receipt through Flow, and deposit would keep 99%', () => {
    const z = quoteZap(big, true, 1000n * U, 1_000_000n);
    if (!z.ok) throw new Error(z.reason);
    expect(z.liquidity).toBe(499_249_496_190_405_251_174n); // flow-vectors.json, scenario 0, step 0
    expect(z.refundQuote).toBe(3n);
    expect(z.saved).toBe(z.liquidity / 100n);
    expect(z.depositNet + z.saved).toBe(z.liquidity);
  });
  it('an unzap larger than the supply is refused, not thrown', () => {
    expect(quoteZapOut(DEMO[0], DEMO[0].supply + 1n, true, 1_000_000n)).toEqual({ ok: false, reason: 'MoreThanSupply' });
    expect(quoteZapOut(DEMO[0], 10n * E, true, 1_000_000n).ok).toBe(true);
  });
});

describe('nudges', () => {
  it('passes a normal trade', () => {
    expect(assess({ impactPpm: 100n, slippageBps: DEFAULT_SLIPPAGE_BPS }).level).toBe('ok');
  });
  it('warns on impact, asks above the default slippage, refuses above the cap', () => {
    expect(assess({ impactPpm: 20_000n, slippageBps: 50 }).level).toBe('warn');
    expect(assess({ impactPpm: 0n, slippageBps: 100 }).level).toBe('confirm');
    expect(assess({ impactPpm: 0n, slippageBps: MAX_SLIPPAGE_BPS + 1 }).level).toBe('blocked');
    expect(assess({ impactPpm: 200_000n, slippageBps: 50 }).level).toBe('blocked');
  });
  it('a selling route always asks', () => {
    const a = assess({ impactPpm: 0n, slippageBps: 50, selling: true });
    expect(a.level).toBe('confirm');
    expect(a.notes.join(' ')).toMatch(/sells/);
  });
  it('slippage rounds the minimum down', () => {
    expect(withSlippage(10_000n, 50)).toBe(9950n);
    expect(withSlippage(3n, 50)).toBe(2n);
  });
});
