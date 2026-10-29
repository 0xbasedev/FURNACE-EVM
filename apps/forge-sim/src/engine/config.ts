// Everything the simulator shows comes from the canonical config and the repo's
// exact reference models: nothing here re-states a protocol number.
import cfg from '@canonical/furnace.config';
import { DAY, RAY, ray } from '@canonical/accounting';

export { cfg, DAY, RAY };
export const WAD = 10n ** 18n;

export interface PoolInfo { index: number; id: string; name: string; lp: boolean; alloc: bigint; unit: string }
export const POOLS: PoolInfo[] = cfg.forge.pools.map((p, index) => ({
  index,
  id: p.id,
  name: p.name,
  lp: p.stakeKind === 'lp',
  alloc: BigInt(p.allocPoints),
  unit: p.stakeKind === 'lp' ? 'LP' : p.id.split('-')[0].toUpperCase(),
}));
export const ALLOC_TOTAL = POOLS.reduce((n, p) => n + p.alloc, 0n);

export interface Relic { key: string; days: number; bump: number }
/** Heat milestones are the Relic ladder (7/30/90/180/365 days, +0.1× each). */
export const MILESTONES: Relic[] = cfg.forge.relics
  .filter((r) => r.heatBump > 0)
  .map((r) => ({ key: r.key, days: r.days, bump: r.heatBump }))
  .sort((a, b) => a.days - b.days);

export interface Track { index: number; name: string; days: number; bonus: number; bonusRay: bigint }
export const TRACKS: Track[] = cfg.forge.convictionTracks.tracks.map((t, index) => ({
  index,
  name: t.name,
  days: t.days,
  bonus: t.bonus,
  bonusRay: ray(String(t.bonus)),
}));

export const TIERS = cfg.cooldowns.withdraw.tiers.map((t) => ({ maxPct: t.maxWithdrawPct, seconds: t.seconds }));
export const WITHDRAW_FEE_PCT = BigInt(cfg.forge.fees.withdrawPct);
export const DEPOSIT_FEE_PCT = BigInt(cfg.forge.fees.depositPct);
export const EMERGENCY_FEE_PCT = BigInt(cfg.forge.emergencyExit.feePct);
export const EXECUTION_WINDOW_HOURS = cfg.cooldowns.withdraw.executionWindowSeconds / 3600;
export const CLAIM_HOURS = cfg.cooldowns.claim.seconds / 3600;
export const BUCKET_PCT = BigInt(cfg.emissions.convictionBucketPct);
export const FLAT_PCT = BigInt(cfg.emissions.split.flatPct);
export const FORFEIT = cfg.forge.convictionTracks.forfeitRouting;
export const HEAT_CAP_DAYS = cfg.forge.heat.rampDays;
