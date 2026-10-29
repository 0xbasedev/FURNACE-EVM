import { cooledAge } from '@canonical/accounting';
import { DAY, EMERGENCY_FEE_PCT, TIERS, WITHDRAW_FEE_PCT } from './config';
import { heatAt } from './heat';

export interface ExitInput {
  stake: bigint; // the position's custody principal
  ageDays: number; // its financial age (one lot)
  pct: number; // this request, % of the plan's reference balance
  planUsedPct: number; // already requested in the current 72h plan (cancelled requests count)
}

export interface ExitPlan {
  amount: bigint;
  cumulativePct: number;
  tierHours: number | undefined; // undefined: the plan quota would be exceeded
  fee: bigint;
  net: bigint;
  ageAfterDays: number;
  heatBefore: number;
  heatAfter: number;
  emergencyFee: bigint;
  emergencyNet: bigint;
}

/** One normal withdrawal of a single-lot position, exactly as ForgePool prices it. */
export function planExit(i: ExitInput): ExitPlan {
  const cumulative = i.planUsedPct + i.pct;
  // Tier: the first one whose ceiling covers the plan's cumulative request (exact, no rounding).
  const tier = TIERS.find((t) => cumulative * 100 <= 100 * t.maxPct);
  const amount = (i.stake * BigInt(Math.round(i.pct * 100))) / 10_000n;
  const fee = (amount * WITHDRAW_FEE_PCT) / 100n;
  const ageSeconds = BigInt(Math.round(i.ageDays * 86_400));
  const after = i.stake === 0n || amount === 0n ? ageSeconds : cooledAge(ageSeconds, amount, i.stake);
  const ageAfterDays = Number(after) / Number(DAY);
  const emergencyFee = (i.stake * EMERGENCY_FEE_PCT) / 100n;
  return {
    amount,
    cumulativePct: cumulative,
    tierHours: tier && tier.seconds / 3600,
    fee,
    net: amount - fee,
    ageAfterDays,
    heatBefore: heatAt(i.ageDays),
    heatAfter: heatAt(ageAfterDays),
    emergencyFee,
    emergencyNet: i.stake - emergencyFee,
  };
}
