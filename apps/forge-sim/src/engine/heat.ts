import { heatMultiplier } from '@canonical/furnace.config';
import { HEAT_CAP_DAYS, MILESTONES, type Relic } from './config';

/** Instantaneous ordinary Heat of a lot at `ageDays` (canonical helper, no Capstone or Pyre). */
export const heatAt = (ageDays: number): number => heatMultiplier(Math.max(0, ageDays));

export interface CurvePoint { day: number; heat: number }
export function heatCurve(maxDays = HEAT_CAP_DAYS + 35, step = 1): CurvePoint[] {
  const out: CurvePoint[] = [];
  for (let d = 0; d <= maxDays; d += step) out.push({ day: d, heat: heatAt(d) });
  return out;
}

export const HEAT_MIN = heatAt(0);
export const HEAT_CORE_MAX = heatAt(HEAT_CAP_DAYS);

/** The next Relic milestone ahead of `ageDays`, if any. */
export function nextMilestone(ageDays: number): (Relic & { inDays: number }) | undefined {
  const m = MILESTONES.find((r) => r.days > ageDays);
  return m && { ...m, inDays: m.days - ageDays };
}

/** Forge-colour temperature for a Heat value (blacksmith's colour chart, dull red to white). */
export function heatColorStop(heat: number): number {
  return Math.min(1, Math.max(0, (heat - HEAT_MIN) / (HEAT_CORE_MAX - HEAT_MIN)));
}
