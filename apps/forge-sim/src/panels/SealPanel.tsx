import { useState } from 'react';
import { FORFEIT, TRACKS, type PoolInfo } from '../engine/config';
import { toFloat } from '../engine/units';
import { Num } from '../motion/motion';
import type { SealWire } from '../worker';
import { num } from './format';

export function SealPanel({ pool, projections, busy, error, selected, onPick }: {
  pool: PoolInfo; projections: SealWire[] | undefined; busy: boolean; error: string | undefined;
  selected: number | undefined; onPick: (track: number) => void;
}) {
  const [leaveDay, setLeaveDay] = useState(20);
  return (
    <section className="panel wide" aria-labelledby="seal-h">
      <header>
        <span className="eyebrow">The stamps</span>
        <h2 id="seal-h">Seals</h2>
        <p className="lede">A Seal commits your current lots for a term. In return you earn a share of the 10% Conviction bucket into escrow, capped at what your bonus would be worth as extra Heat. It is paid at term end into your Capstone. Principal is never locked: leaving early forfeits only the escrow.</p>
      </header>
      <div className="field">
        <label htmlFor="leave-day">If you left on day <output htmlFor="leave-day">{leaveDay}</output></label>
        <input id="leave-day" type="range" min={1} max={364} value={leaveDay} onChange={(e) => setLeaveDay(Number(e.target.value))} />
      </div>
      {error && <div className="nudge bad"><span className="ico">!</span><span>Projection failed: {error}</span></div>}
      <div className={`tracks${busy ? ' busy' : ''}`} aria-busy={busy}>
        {TRACKS.map((t) => {
          const p = projections?.[t.index];
          const escrow = p ? toFloat(BigInt(p.totalEscrow)) : 0;
          const gain = p ? toFloat(BigInt(p.gain)) : 0;
          const daysUntil = Math.min(leaveDay, t.days);
          const lost = p ? p.days.slice(0, daysUntil).reduce((n, d) => n + toFloat(BigInt(d.escrow)), 0) : 0;
          const leavesEarly = leaveDay < t.days;
          return (
            <article key={t.index} className="track" data-selected={selected === t.index}>
              <h3>{t.name} <small>{t.days}d · +{t.bonus}×</small></h3>
              <dl>
                <dt>Escrow over the term</dt><dd><Num value={escrow} format={(n) => num(n, 2)} /></dd>
                <dt>vs not sealing</dt><dd style={{ color: gain >= 0 ? 'var(--good)' : 'var(--danger)' }}>{gain >= 0 ? '+' : '−'}<Num value={Math.abs(gain)} format={(n) => num(n, 2)} /></dd>
                <dt>Paid at</dt><dd>day {t.days} + pauses</dd>
              </dl>
              {p && (
                <span className={`pill ${p.capDays > p.days.length / 2 ? 'cap' : 'cand'}`}>
                  {p.capDays > p.days.length / 2 ? 'capped by your bonus' : 'sharing the bucket'}
                </span>
              )}
              {leavesEarly ? (
                <div className="nudge bad"><span className="ico">!</span><span>Leaving on day {leaveDay} forfeits <b>{num(lost, 2)} EMBER</b>: {FORFEIT.burnPct}% to the burn lane, {FORFEIT.matchReservePct}% to the match reserve, {FORFEIT.sealedPotPct}% to the Sealed pot.</span></div>
              ) : (
                <div className="nudge"><span className="ico">✓</span><span>Done by day {leaveDay}: the escrow is yours, in Capstone.</span></div>
              )}
              <button type="button" className={`btn${selected === t.index ? ' primary' : ''}`} onClick={() => onPick(t.index)} aria-pressed={selected === t.index}>
                {selected === t.index ? 'Planned in the day book' : `Plan the ${t.name} Seal`}
              </button>
            </article>
          );
        })}
      </div>
      <p className="lede">Projection for {pool.name}, every day settled with the canonical settlement formula: your stake and age against the assumptions on the left. The figures are EMBER under those assumptions only; they are not an APR or a promise.</p>
    </section>
  );
}
