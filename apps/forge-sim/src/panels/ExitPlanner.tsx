import { CLAIM_HOURS, EXECUTION_WINDOW_HOURS, TIERS, type PoolInfo } from '../engine/config';
import { planExit } from '../engine/exit';
import { toFloat } from '../engine/units';
import { HoldButton, Num } from '../motion/motion';
import { hours, num } from './format';

export function ExitPlanner({ pool, stake, ageDays, pct, setPct, planUsedPct, setPlanUsedPct, sealed, onEmergency }: {
  pool: PoolInfo; stake: bigint; ageDays: number; pct: number; setPct: (n: number) => void;
  planUsedPct: number; setPlanUsedPct: (n: number) => void; sealed: boolean; onEmergency: () => void;
}) {
  const plan = planExit({ stake, ageDays, pct, planUsedPct });
  const over = plan.tierHours === undefined;
  const tierIndex = TIERS.findIndex((t) => plan.cumulativePct <= t.maxPct);
  const lostDays = ageDays - plan.ageAfterDays;
  const u = pool.unit;
  return (
    <section className="panel" aria-labelledby="exit-h">
      <header>
        <span className="eyebrow">The quench</span>
        <h2 id="exit-h">Leaving, priced</h2>
        <p className="lede">Exits are always in kind and never locked. Their timer follows how much your current 72-hour plan has asked for in total, so splitting a big exit into small ones does not make it faster.</p>
      </header>

      <div className="field">
        <label htmlFor="exit-pct">Withdraw <output htmlFor="exit-pct">{pct}% · {num(toFloat(plan.amount), 2)} {u}</output></label>
        <input id="exit-pct" type="range" min={1} max={100} value={pct} onChange={(e) => setPct(Number(e.target.value))} />
      </div>
      <div className="field">
        <label htmlFor="plan-used">Already requested in this plan <output htmlFor="plan-used">{planUsedPct}%</output></label>
        <input id="plan-used" type="range" min={0} max={90} step={5} value={planUsedPct} onChange={(e) => setPlanUsedPct(Number(e.target.value))} />
      </div>

      <div className="ladder" role="list" aria-label="Cooling tiers">
        {TIERS.map((t, i) => (
          <div key={t.maxPct} role="listitem" className={`rung${i === tierIndex ? ' on' : ''}${i < tierIndex ? ' past' : ''}`}>
            <span className="t">{hours(t.seconds / 3600)}</span>
            <span className="p">≤{t.maxPct}%</span>
          </div>
        ))}
      </div>

      {over ? (
        <div className="nudge bad"><span className="ico">!</span><span>This plan has already asked for {planUsedPct}%; {pct}% more exceeds 100% of its reference balance. Wait for the plan's 72-hour horizon to pass with nothing pending, then start a new one.</span></div>
      ) : (
        <div className="figures">
          <div className="figure"><span className="k">Timer</span><span className="v">{hours(plan.tierHours!)}</span><span className="s">then {EXECUTION_WINDOW_HOURS}h to execute</span></div>
          <div className="figure"><span className="k">You receive</span><span className="v"><Num value={toFloat(plan.net)} format={(n) => num(n, 2)} /></span><span className="s">{u}, after the 1% fee</span></div>
          <div className="figure"><span className="k">Age left on the rest</span><span className="v"><Num value={plan.ageAfterDays} format={(n) => num(n, 1)} />d</span><span className="s">from {num(ageDays, 1)}d</span></div>
          <div className="figure"><span className="k">Heat after</span><span className="v"><Num value={plan.heatAfter} format={(n) => num(n, 3)} />×</span><span className="s">from {num(plan.heatBefore, 3)}×</span></div>
        </div>
      )}

      {!over && lostDays > 0.05 && (
        <div className="age-shift" aria-label="Age haircut">
          <span className="label eyebrow">What the withdrawal costs in age</span>
          <div className="age-track">
            <span className="before" style={{ width: `${Math.min(100, (ageDays / 365) * 100)}%` }} />
            <span className="after" style={{ width: `${Math.min(100, (plan.ageAfterDays / 365) * 100)}%` }} />
          </div>
          <span className="lede">The remaining stake keeps {num(100 - pct, 0)}% of its age: <b>{num(lostDays, 1)} days</b> of Heat history are cut. Cancelling restores the frozen part exactly, but still uses up this plan's quota.</span>
        </div>
      )}
      {!over && pct <= 10 && (
        <div className="nudge"><span className="ico">i</span><span>Up to 10% leaves in {hours(TIERS[0].seconds / 3600)}. The frozen part stops earning until it leaves or you cancel.</span></div>
      )}
      {sealed && !over && (
        <div className="nudge warn"><span className="ico">!</span><span>Your position is <b>sealed</b>. Requesting pauses the Seal; <b>executing</b> any withdrawal before the term ends forfeits all of its escrow. Claim rewards instead: claims are fee-free after {CLAIM_HOURS}h.</span></div>
      )}

      <div className="danger-zone">
        <h3>Emergency exit</h3>
        <p className="lede">Leaves at once with everything, active and cooling, in kind. It always works, even if every other part of the protocol is down.</p>
        <div className="figures">
          <div className="figure"><span className="k">Fee</span><span className="v" style={{ color: 'var(--danger)' }}>8%</span><span className="s">{num(toFloat(plan.emergencyFee), 2)} {u}</span></div>
          <div className="figure"><span className="k">You receive</span><span className="v">{num(toFloat(plan.emergencyNet), 2)}</span><span className="s">{u}; pending Ashfall {sealed ? 'and Seal escrow ' : ''}forfeited</span></div>
        </div>
        <div className="row">
          <HoldButton label="Hold to simulate an emergency exit in the day book" onConfirm={onEmergency}>Hold to simulate it</HoldButton>
          <span className="unit">Adds it to the day book below so you can see what it costs.</span>
        </div>
      </div>
    </section>
  );
}
