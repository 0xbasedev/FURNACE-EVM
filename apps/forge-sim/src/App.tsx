import { useEffect, useMemo, useRef, useState } from 'react';
import gsap from 'gsap';
import { POOLS } from './engine/config';
import type { SimEvent } from './engine/timeline';
import { toWei } from './engine/units';
import { reducedMotion, useEntrance } from './motion/motion';
import { DayBook } from './panels/DayBook';
import { ExitPlanner } from './panels/ExitPlanner';
import { HeatPanel } from './panels/HeatPanel';
import { Rail, type Assumptions } from './panels/Rail';
import { SealPanel } from './panels/SealPanel';
import { useSealProjection, useTimeline } from './useForgeWorker';

const START: Assumptions = {
  pool: 0,
  stakeText: '2,500',
  ageDays: 45,
  othersText: '400,000',
  othersAgeDays: 90,
  othersSealedPct: 20,
  launchDay: 30,
};
// An example plan, so the day book opens doing something: seal for 30 days, claim on day 20.
const EXAMPLE_EVENTS: SimEvent[] = [
  { day: 0, kind: 'seal', value: 0 },
  { day: 20, kind: 'claim' },
];

export function App() {
  const [a, setA] = useState(START);
  const set = (patch: Partial<Assumptions>) => setA((x) => ({ ...x, ...patch }));
  const [exitPct, setExitPct] = useState(10);
  const [planUsed, setPlanUsed] = useState(0);
  const [days, setDays] = useState(60);
  const [events, setEvents] = useState<SimEvent[]>(EXAMPLE_EVENTS);
  const [playing, setPlaying] = useState(false);
  const pool = POOLS[a.pool];
  const stake = toWei(a.stakeText);
  const others = toWei(a.othersText);

  useEntrance('.panel, .rail-card');

  // "Let it age": time runs at 60 days a second up to two years.
  const age = useRef({ v: a.ageDays });
  useEffect(() => {
    if (!playing) return;
    age.current.v = a.ageDays >= 730 ? 0 : a.ageDays;
    const tween = gsap.to(age.current, {
      v: 730,
      duration: reducedMotion() ? 0.01 : (730 - age.current.v) / 60,
      ease: 'none',
      onUpdate: () => set({ ageDays: Math.round(age.current.v) }),
      onComplete: () => setPlaying(false),
    });
    return () => { tween.kill(); };
  }, [playing]); // eslint-disable-line react-hooks/exhaustive-deps

  const sealInput = useMemo(() => (stake === 0n ? undefined : {
    pool: a.pool, stake: String(stake), ageDays: Math.round(a.ageDays), othersStake: String(others),
    othersAgeDays: a.othersAgeDays, othersSealedPct: a.othersSealedPct, launchDay: a.launchDay,
  }), [a.pool, stake, a.ageDays, others, a.othersAgeDays, a.othersSealedPct, a.launchDay]);
  const seal = useSealProjection(sealInput);

  const timelineInput = useMemo(() => (stake === 0n ? undefined : {
    pool: a.pool, stake: String(stake), othersStake: String(others), others: 3, days, events,
  }), [a.pool, stake, others, days, events]);
  const timeline = useTimeline(timelineInput);

  const sealTrack = events.find((e) => e.kind === 'seal')?.value;
  const pickSeal = (track: number) =>
    setEvents([{ day: 0, kind: 'seal' as const, value: track }, ...events.filter((e) => e.kind !== 'seal')].sort((x, y) => x.day - y.day));
  const emergency = () => {
    const day = Math.min(days - 1, 15);
    setEvents([...events.filter((e) => e.kind !== 'emergency'), { day, kind: 'emergency' as const }].sort((x, y) => x.day - y.day));
    document.getElementById('day-book')?.scrollIntoView({ behavior: reducedMotion() ? 'auto' : 'smooth', block: 'start' });
  };

  return (
    <div className="page">
      <header className="masthead">
        <div className="brand">
          <h1>Furnace <span>Forge Simulator</span></h1>
          <p>Stake, age, seal and leave, priced day by day with the exact math the FURNACE contracts are tested against.</p>
        </div>
        <div className="notice" role="note">
          <span aria-hidden="true">⚠</span>
          <span><strong>A simulator, not a product.</strong> The contracts it mirrors are unaudited and not deployed. Every number is a projection under the assumptions you set; none of it is an APR, an offer or a promise.</span>
        </div>
      </header>
      <div className="bench">
        <Rail a={a} set={set} />
        <main className="surface">
          <HeatPanel ageDays={a.ageDays} playing={playing} onPlay={() => setPlaying((p) => !p)} />
          <ExitPlanner pool={pool} stake={stake} ageDays={a.ageDays} pct={exitPct} setPct={setExitPct}
            planUsedPct={planUsed} setPlanUsedPct={setPlanUsed} sealed={sealTrack !== undefined} onEmergency={emergency} />
          <SealPanel pool={pool} projections={seal.result} busy={seal.busy} error={seal.error} selected={sealTrack} onPick={pickSeal} />
          <DayBook pool={pool} days={days} setDays={setDays} events={events} setEvents={setEvents}
            result={timeline.result} busy={timeline.busy} error={timeline.error} />
        </main>
      </div>
      <footer className="foot">
        <p>Sources: the canonical FURNACE v5.5 configuration and integer reference (<code>canonical/accounting.ts</code>), and this repository's settlement model, which the Solidity contracts match bit for bit in differential tests. Heat, tiers, haircuts, Seal escrow and settlement are computed, not estimated.</p>
        <p>Pool budgets assume the pool is occupied all day. The day book starts every staker fresh at emissions launch. Ashfall, Quote yield, Capstone Heat and Relic perks are not modelled yet.</p>
      </footer>
    </div>
  );
}
