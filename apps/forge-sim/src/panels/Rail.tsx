import { ALLOC_TOTAL, POOLS } from '../engine/config';
import { num } from './format';

export interface Assumptions {
  pool: number;
  stakeText: string;
  ageDays: number;
  othersText: string;
  othersAgeDays: number;
  othersSealedPct: number;
  launchDay: number;
}

export function Rail({ a, set }: { a: Assumptions; set: (patch: Partial<Assumptions>) => void }) {
  const pool = POOLS[a.pool];
  return (
    <aside className="rail" aria-label="Your position and assumptions">
      <div className="rail-card">
        <h3>Your position</h3>
        <div className="pool-pick" role="group" aria-label="Pool">
          {POOLS.map((p) => (
            <button key={p.id} type="button" aria-pressed={a.pool === p.index} onClick={() => set({ pool: p.index })}>
              <span className="pname">{p.name}</span>
              <span className="pmeta">{p.lp ? 'LP' : 'single'} · {num((Number(p.alloc) / Number(ALLOC_TOTAL)) * 100, 0)}% of base</span>
            </button>
          ))}
        </div>
        <div className="field">
          <label htmlFor="stake">Stake <span className="unit">{pool.unit}</span></label>
          <input id="stake" className="input" inputMode="decimal" value={a.stakeText} onChange={(e) => set({ stakeText: e.target.value })} />
        </div>
        <div className="field">
          <label htmlFor="age">Lot age <output htmlFor="age">{num(a.ageDays, 0)} days</output></label>
          <input id="age" type="range" min={0} max={730} value={Math.round(a.ageDays)} onChange={(e) => set({ ageDays: Number(e.target.value) })} />
        </div>
      </div>
      <div className="rail-card">
        <h3>Everyone else</h3>
        <p className="unit" style={{ margin: 0 }}>Illustrative defaults. Change them to stress the projections.</p>
        <div className="field">
          <label htmlFor="others">Their stake <span className="unit">{pool.unit}</span></label>
          <input id="others" className="input" inputMode="decimal" value={a.othersText} onChange={(e) => set({ othersText: e.target.value })} />
        </div>
        <div className="field">
          <label htmlFor="others-age">Their average age <output htmlFor="others-age">{a.othersAgeDays} days</output></label>
          <input id="others-age" type="range" min={0} max={730} value={a.othersAgeDays} onChange={(e) => set({ othersAgeDays: Number(e.target.value) })} />
        </div>
        <div className="field">
          <label htmlFor="others-sealed">Sealed by others <output htmlFor="others-sealed">{a.othersSealedPct}%</output></label>
          <input id="others-sealed" type="range" min={0} max={100} value={a.othersSealedPct} onChange={(e) => set({ othersSealedPct: Number(e.target.value) })} />
        </div>
        <div className="field">
          <label htmlFor="launch">Days since emissions began <output htmlFor="launch">{a.launchDay}</output></label>
          <input id="launch" type="range" min={0} max={1500} step={5} value={a.launchDay} onChange={(e) => set({ launchDay: Number(e.target.value) })} />
        </div>
      </div>
    </aside>
  );
}
