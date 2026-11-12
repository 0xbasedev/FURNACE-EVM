import cfg from '@canonical/furnace.config';

/** Interface policy (ADR 0016 §6): the chain checks only the minimum each call carries. */
export const DEFAULT_SLIPPAGE_BPS = cfg.swap.zap.defaultSlippageBps; // 50
export const MAX_SLIPPAGE_BPS = cfg.swap.zap.maxSlippageBps; // 300
export const IMPACT_WARN_PPM = 10_000n; // 1%
export const IMPACT_BLOCK_PPM = 150_000n; // 15%: beyond this, split the trade
export const STAKE_AFTER_ZAP = cfg.swap.zap.stakeAfterZap; // 'offer'

export type Level = 'ok' | 'warn' | 'confirm' | 'blocked';
export interface Assessment { level: Level; notes: string[] }

/** The nudge for a trade: what the interface says, and whether it lets it through. */
export function assess(o: { impactPpm: bigint; slippageBps: number; selling?: boolean }): Assessment {
  const notes: string[] = [];
  let level: Level = 'ok';
  const raise = (l: Level) => {
    const order: Level[] = ['ok', 'warn', 'confirm', 'blocked'];
    if (order.indexOf(l) > order.indexOf(level)) level = l;
  };
  if (o.slippageBps > MAX_SLIPPAGE_BPS) {
    notes.push(`Slippage above ${MAX_SLIPPAGE_BPS / 100}% is not offered.`);
    raise('blocked');
  } else if (o.slippageBps > DEFAULT_SLIPPAGE_BPS) {
    notes.push(`Slippage is above the ${DEFAULT_SLIPPAGE_BPS / 100}% default: a worse fill can go through.`);
    raise('confirm');
  }
  if (o.impactPpm > IMPACT_BLOCK_PPM) {
    notes.push('Price impact above 15%: split this into smaller trades.');
    raise('blocked');
  } else if (o.impactPpm > IMPACT_WARN_PPM) {
    notes.push(`Price impact ${(Number(o.impactPpm) / 1e4).toFixed(2)}%: the pool is thin for this size.`);
    raise('warn');
  }
  if (o.selling) {
    notes.push('This route sells. Leaving the pool ends what your LP earns here.');
    raise('confirm');
  }
  return { level, notes };
}

/** `amount` less `bps` of slippage, rounded down: the minimum a call accepts. */
export const withSlippage = (amount: bigint, bps: number): bigint => (amount * BigInt(10_000 - bps)) / 10_000n;
