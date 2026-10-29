import { describe, expect, it } from 'vitest';
import { cooledAge, segmentMeasures, settleBaseEpoch } from '@canonical/accounting';
import { DAY, TIERS, TRACKS } from '../src/engine/config';
import { heatAt, nextMilestone } from '../src/engine/heat';
import { planExit } from '../src/engine/exit';
import { forfeitAt, poolBudget, projectSeal, type SealAssumptions } from '../src/engine/seal';
import { runTimeline } from '../src/engine/timeline';
import { fmt, toWei } from '../src/engine/units';

const E = 10n ** 18n;

describe('units', () => {
  it('parses and formats without float drift', () => {
    expect(toWei('1,234.5')).toBe(1234n * E + E / 2n);
    expect(fmt(1234n * E + E / 2n)).toBe('1,234.50');
    expect(fmt(toWei('0.000000000000000001'), 2)).toBe('0.00');
    expect(toWei('abc')).toBe(0n);
  });
});

describe('heat', () => {
  it('runs from 1.0x to the 3.0x core cap with the Relic ladder', () => {
    expect(heatAt(0)).toBeCloseTo(1, 12);
    expect(heatAt(365)).toBeCloseTo(3, 12);
    expect(heatAt(800)).toBeCloseTo(3, 12);
    expect(nextMilestone(10)?.key).toBe('flame');
    expect(nextMilestone(10)?.inDays).toBe(20);
  });
});

describe('exit planner', () => {
  it('prices every tier exactly as the cumulative plan does', () => {
    for (const [pct, used] of [[10, 0], [11, 0], [25, 0], [5, 20], [50, 0], [51, 0], [100, 0]] as const) {
      const p = planExit({ stake: 1000n * E, ageDays: 40, pct, planUsedPct: used });
      const want = TIERS.find((t) => pct + used <= t.maxPct)!.seconds / 3600;
      expect(p.tierHours).toBe(want);
    }
    expect(planExit({ stake: E, ageDays: 1, pct: 50, planUsedPct: 60 }).tierHours).toBeUndefined();
  });

  it('applies the canonical age haircut (a two-year lot at 50% lands at 182.5 days)', () => {
    const p = planExit({ stake: 1000n * E, ageDays: 730, pct: 50, planUsedPct: 0 });
    expect(p.ageAfterDays).toBeCloseTo(182.5, 9);
    const q = planExit({ stake: 777n * E, ageDays: 123.4, pct: 37, planUsedPct: 0 });
    expect(BigInt(Math.round(q.ageAfterDays * 86_400))).toBe(cooledAge(BigInt(Math.round(123.4 * 86_400)), q.amount, 777n * E));
    expect(q.fee).toBe(q.amount / 100n);
    expect(p.emergencyFee).toBe(80n * E);
  });
});

describe('seal projection', () => {
  const base: SealAssumptions = { pool: 0, stake: 100n * E, ageDays: 10, othersStake: 900n * E, othersAgeDays: 60, othersSealedPct: 0, launchDay: 0 };

  it('equals canonical settleBaseEpoch, day by day', () => {
    const p = projectSeal(base, 0);
    expect(p.days.length).toBe(TRACKS[0].days);
    for (const d of [0, 7, 29]) {
      const age = (x: number) => BigInt(Math.round(x * 86_400));
      const r = settleBaseEpoch(poolBudget(0, d), [
        { id: 'you', ...segmentMeasures(100n * E, age(10 + d), DAY, 0n, TRACKS[0].bonusRay) },
        { id: 'plain', ...segmentMeasures(900n * E, age(60 + d), DAY, 0n, 0n) },
      ]);
      expect(p.days[d].ordinary).toBe(r.payouts[0].ordinary);
      expect(p.days[d].escrow).toBe(r.payouts[0].escrow);
    }
    expect(p.capDays).toBe(30); // a small 30-day sealer is capped every day
    expect(p.totalEscrow).toBeGreaterThan(0n);
  });

  it('lets the candidate bind when sealers share the bucket', () => {
    const p = projectSeal({ ...base, stake: 1000n * E, othersStake: 400n * E, othersSealedPct: 100 }, 3);
    expect(p.capDays).toBeLessThan(p.days.length);
  });

  it('routes a forfeit 50/25/25 and never more than was funded', () => {
    const p = projectSeal(base, 1);
    const f = forfeitAt(p, 45);
    expect(f.burn + f.reserve + f.pot).toBe(f.lost);
    expect(f.lost).toBe(p.days.slice(0, 45).reduce((n, d) => n + d.escrow, 0n));
  });
});

describe('timeline (the contract-mirroring SettlementModel)', () => {
  it('pays a sole staker the pool budget, less floor dust', () => {
    const r = runTimeline({ pool: 2, stake: String(500n * E), othersStake: '0', others: 0, days: 3, events: [] });
    const paid = r.days.reduce((n, d) => n + BigInt(d.poolPaid), 0n);
    expect(BigInt(r.days[2].claimable)).toBe(paid);
    const full = poolBudget(2, 1) + poolBudget(2, 2);
    expect(paid).toBeGreaterThan(full); // day 0 is occupied for all but one second
  });

  it('vests a completed Ember Seal into the Capstone ledger', () => {
    const r = runTimeline({ pool: 0, stake: String(100n * E), othersStake: String(900n * E), others: 2, days: 34, events: [{ day: 0, kind: 'seal', value: 0 }] });
    expect(r.log[0]).toMatchObject({ kind: 'seal', ok: true });
    expect(BigInt(r.days[10].locked)).toBeGreaterThan(0n);
    expect(BigInt(r.days[33].capstone)).toBeGreaterThan(0n);
    expect(BigInt(r.days[33].locked)).toBe(0n);
  });

  it('forfeits on an executed withdrawal and rejects what the contract rejects', () => {
    const r = runTimeline({
      pool: 0, stake: String(100n * E), othersStake: String(900n * E), others: 2, days: 6,
      events: [
        { day: 0, kind: 'seal', value: 1 },
        { day: 2, kind: 'withdraw', value: 10 },
        { day: 2, kind: 'seal', value: 0 }, // CoolingPending
      ],
    });
    expect(r.log.find((l) => l.kind === 'seal' && !l.ok)?.note).toBe('CoolingPending');
    expect(BigInt(r.days[5].forfeited)).toBeGreaterThan(0n);
    expect(BigInt(r.days[5].locked)).toBe(0n);
  });
});
