import { segmentMeasures, settleBaseEpoch, type PositionMeasure } from '@canonical/accounting';
import { emissionPerDay } from '@model/schedule';
import { ALLOC_TOTAL, BUCKET_PCT, DAY, FLAT_PCT, FORFEIT, POOLS, TRACKS } from './config';

export interface SealAssumptions {
  pool: number;
  stake: bigint; // the user's stake
  ageDays: number; // the user's financial age when sealing
  othersStake: bigint; // everyone else in the pool
  othersAgeDays: number; // their average age
  othersSealedPct: number; // share of their stake sealed (on the Forge track)
  launchDay: number; // days since emissions started, for the daily base
}

export interface SealDay {
  day: number;
  budget: bigint; // the pool's admitted base for the day (full occupancy)
  ordinary: bigint; // the user's claimable reward while sealed
  escrow: bigint; // the user's escrow for the day
  unsealedOrdinary: bigint; // what the user would earn unsealed, same pool
  binding: 'cap' | 'candidate';
}

export interface SealProjection {
  track: number;
  days: SealDay[];
  totalOrdinary: bigint;
  totalEscrow: bigint;
  totalUnsealed: bigint;
  gain: bigint; // (ordinary + escrow) − unsealed over the term
  capDays: number; // days the per-position cap bound
}

const position = (id: string, stake: bigint, ageDays: number, bonusRay: bigint): PositionMeasure | undefined => {
  if (stake === 0n) return undefined;
  const age = BigInt(Math.round(ageDays * 86_400));
  return { id, ...segmentMeasures(stake, age, DAY, 0n, bonusRay) };
};

/** The pool's daily base at full occupancy, split by alloc points (ForgeEmissions.openEpoch). */
export function poolBudget(pool: number, day: number): bigint {
  return (emissionPerDay(BigInt(day)) * POOLS[pool].alloc) / ALLOC_TOTAL;
}

function settleDay(a: SealAssumptions, d: number, bonusRay: bigint) {
  const othersSealed = (a.othersStake * BigInt(Math.round(a.othersSealedPct * 100))) / 10_000n;
  const positions = [
    position('you', a.stake, a.ageDays + d, bonusRay),
    position('sealed', othersSealed, a.othersAgeDays + d, TRACKS[1].bonusRay),
    position('plain', a.othersStake - othersSealed, a.othersAgeDays + d, 0n),
  ].filter((p): p is PositionMeasure => p !== undefined);
  const budget = poolBudget(a.pool, a.launchDay + d);
  return { budget, positions, result: settleBaseEpoch(budget, positions) };
}

/** Day-by-day projection of one Seal track through the canonical settlement oracle. */
export function projectSeal(a: SealAssumptions, track: number): SealProjection {
  const t = TRACKS[track];
  const days: SealDay[] = [];
  let totalOrdinary = 0n, totalEscrow = 0n, totalUnsealed = 0n, capDays = 0;
  for (let d = 0; d < t.days; d++) {
    const sealed = settleDay(a, d, t.bonusRay);
    const plain = settleDay(a, d, 0n);
    const you = sealed.result.payouts.find((p) => p.id === 'you');
    const youPlain = plain.result.payouts.find((p) => p.id === 'you');
    if (!you || !youPlain) break;
    // Which side of min(candidate, cap) bound: recompute the cap from the oracle's inputs.
    const e = sealed.budget, bucket = (e * BUCKET_PCT) / 100n, flat = ((e - bucket) * FLAT_PCT) / 100n;
    const l = e - bucket - flat;
    const W = sealed.positions.reduce((n, p) => n + p.heatSeconds, 0n);
    const mine = sealed.positions.find((p) => p.id === 'you')!;
    const cap = W === 0n ? 0n : (l * mine.sealSeconds) / W;
    const binding = you.escrow === cap && you.escrow !== 0n ? 'cap' : 'candidate';
    if (binding === 'cap') capDays++;
    days.push({ day: d, budget: e, ordinary: you.ordinary, escrow: you.escrow, unsealedOrdinary: youPlain.ordinary, binding });
    totalOrdinary += you.ordinary;
    totalEscrow += you.escrow;
    totalUnsealed += youPlain.ordinary;
  }
  return { track, days, totalOrdinary, totalEscrow, totalUnsealed, gain: totalOrdinary + totalEscrow - totalUnsealed, capDays };
}

/** Escrow funded by day `day` of the term: what leaving then would forfeit, and where it goes. */
export function forfeitAt(p: SealProjection, day: number) {
  const lost = p.days.slice(0, Math.max(0, day)).reduce((n, d) => n + d.escrow, 0n);
  const burn = (lost * BigInt(FORFEIT.burnPct)) / 100n;
  const reserve = (lost * BigInt(FORFEIT.matchReservePct)) / 100n;
  return { lost, burn, reserve, pot: lost - burn - reserve };
}
