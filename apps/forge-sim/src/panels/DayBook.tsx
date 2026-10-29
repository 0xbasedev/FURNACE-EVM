import { useRef, useState } from 'react';
import { TRACKS, type PoolInfo } from '../engine/config';
import type { EventKind, SimEvent, TimelineResult } from '../engine/timeline';
import { toFloat } from '../engine/units';
import { compact, num } from './format';
import { useWidth } from './useWidth';

const SERIES = [
  { key: 'earned', label: 'Claimable and claimed', color: 'var(--s1)' },
  { key: 'locked', label: 'Locked in a Seal', color: 'var(--s2)' },
  { key: 'capstone', label: 'Vested to Capstone', color: 'var(--s3)' },
  { key: 'forfeited', label: 'Forfeited', color: 'var(--s4)' },
] as const;
type Key = (typeof SERIES)[number]['key'];

const KINDS: { kind: EventKind; label: string }[] = [
  { kind: 'seal', label: 'Seal' },
  { kind: 'withdraw', label: 'Withdraw %' },
  { kind: 'cancel', label: 'Cancel latest request' },
  { kind: 'deposit', label: 'Deposit' },
  { kind: 'claim', label: 'Claim rewards' },
  { kind: 'emergency', label: 'Emergency exit' },
];

export function describe(ev: SimEvent, unit: string): string {
  switch (ev.kind) {
    case 'seal': return `day ${ev.day} · Seal ${TRACKS[ev.value ?? 0].name}`;
    case 'withdraw': return `day ${ev.day} · withdraw ${ev.value}%`;
    case 'deposit': return `day ${ev.day} · deposit ${num(ev.value ?? 0, 0)} ${unit}`;
    case 'cancel': return `day ${ev.day} · cancel`;
    case 'claim': return `day ${ev.day} · claim`;
    case 'emergency': return `day ${ev.day} · emergency exit`;
  }
}

const H = 260, T = 14, B = 30;

export function DayBook({ pool, days, setDays, events, setEvents, result, busy, error }: {
  pool: PoolInfo; days: number; setDays: (n: number) => void; events: SimEvent[]; setEvents: (e: SimEvent[]) => void;
  result: TimelineResult | undefined; busy: boolean; error: string | undefined;
}) {
  const [kind, setKind] = useState<EventKind>('withdraw');
  const [day, setDay] = useState(10);
  const [value, setValue] = useState(10);
  const [hover, setHover] = useState<number>();
  const svg = useRef<SVGSVGElement>(null);
  const wrap = useRef<HTMLDivElement>(null);
  const W = useWidth(wrap, 760);
  const narrow = W < 520;
  const L = narrow ? 44 : 56, R = narrow ? 92 : 120;

  const rows = (result?.days ?? []).map((d) => ({
    day: d.day,
    earned: toFloat(BigInt(d.claimable) + BigInt(d.claimed)),
    locked: toFloat(BigInt(d.locked)),
    capstone: toFloat(BigInt(d.capstone)),
    forfeited: toFloat(BigInt(d.forfeited)),
    claimed: toFloat(BigInt(d.claimed)),
    active: toFloat(BigInt(d.active)),
    heat: d.heat,
  }));
  const maxY = Math.max(1e-9, ...rows.flatMap((r) => SERIES.map((s) => r[s.key])));
  const niceMax = (() => { const p = 10 ** Math.floor(Math.log10(maxY)); return Math.ceil(maxY / p) * p; })();
  const n = Math.max(1, rows.length - 1);
  const x = (i: number) => L + (i / n) * (W - L - R);
  const y = (v: number) => T + (1 - v / niceMax) * (H - T - B);
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((f) => f * niceMax);
  const visible = SERIES.filter((s) => rows.some((r) => r[s.key] > 0));
  const last = rows[rows.length - 1];
  const endLabels: { key: Key; y: number }[] = [];
  if (last) for (const s of visible) {
    const yy = y(last[s.key]);
    if (endLabels.every((l) => Math.abs(l.y - yy) > 13)) endLabels.push({ key: s.key, y: yy });
  }

  const add = () => {
    const ev: SimEvent = { day: Math.min(days - 1, Math.max(0, day)), kind };
    if (kind === 'seal') ev.value = Math.min(3, Math.max(0, value));
    if (kind === 'withdraw') ev.value = Math.min(100, Math.max(1, value));
    if (kind === 'deposit') ev.value = Math.max(0, value);
    setEvents([...events, ev].sort((a, b) => a.day - b.day));
  };
  const onMove = (e: React.PointerEvent) => {
    if (!rows.length) return;
    const r = svg.current!.getBoundingClientRect();
    const px = ((e.clientX - r.left) / r.width) * W;
    setHover(Math.round(Math.min(n, Math.max(0, ((px - L) / (W - L - R)) * n))));
  };
  const h = hover !== undefined ? rows[hover] : undefined;
  const failed = (result?.log ?? []).filter((l) => !l.ok);

  return (
    <section className="panel wide" aria-labelledby="book-h" id="day-book">
      <header>
        <span className="eyebrow">The day book</span>
        <h2 id="book-h">Day by day, as settled</h2>
        <p className="lede">Your position in {pool.name} next to the stakers on the left, run through the same model the contracts are tested against: the cooldowns, the Seal, and every daily settlement page. Add what you would do and when.</p>
      </header>

      <div className="row">
        <span className="label eyebrow">Horizon</span>
        <div className="seg" role="group" aria-label="Days to simulate">
          {[30, 60, 90, 120].map((d) => (
            <button key={d} type="button" aria-pressed={days === d} onClick={() => setDays(d)}>{d} days</button>
          ))}
        </div>
      </div>

      <div className="events" aria-label="Planned events">
        {events.length === 0 && <span className="unit">No events: you simply stay.</span>}
        {events.map((ev, i) => {
          const bad = result?.log.some((l) => l.day === ev.day && l.kind === ev.kind && !l.ok);
          return (
            <span key={`${ev.day}-${ev.kind}-${i}`} className={`chip${bad ? ' bad' : ''}`}>
              {describe(ev, pool.unit)}
              <button type="button" aria-label={`Remove ${describe(ev, pool.unit)}`} onClick={() => setEvents(events.filter((_, k) => k !== i))}>×</button>
            </span>
          );
        })}
      </div>

      <div className="adder">
        <div className="field">
          <label htmlFor="ev-kind">Event</label>
          <select id="ev-kind" className="input" value={kind} onChange={(e) => setKind(e.target.value as EventKind)}>
            {KINDS.map((k) => <option key={k.kind} value={k.kind}>{k.label}</option>)}
          </select>
        </div>
        <div className="field">
          <label htmlFor="ev-day">Day</label>
          <input id="ev-day" className="input" type="number" min={0} max={days - 1} value={day} onChange={(e) => setDay(Number(e.target.value))} />
        </div>
        <div className="field">
          <label htmlFor="ev-value">{kind === 'seal' ? 'Track' : kind === 'withdraw' ? 'Percent' : kind === 'deposit' ? `Amount (${pool.unit})` : 'Value'}</label>
          {kind === 'seal' ? (
            <select id="ev-value" className="input" value={value} onChange={(e) => setValue(Number(e.target.value))}>
              {TRACKS.map((t) => <option key={t.index} value={t.index}>{t.name} ({t.days}d)</option>)}
            </select>
          ) : (
            <input id="ev-value" className="input" type="number" min={0} value={value} disabled={!['withdraw', 'deposit'].includes(kind)} onChange={(e) => setValue(Number(e.target.value))} />
          )}
        </div>
        <button type="button" className="btn primary" onClick={add}>Add event</button>
      </div>

      {error && <div className="nudge bad"><span className="ico">!</span><span>Simulation failed: {error}</span></div>}

      <div className="legend" aria-hidden="true">
        {SERIES.map((s) => <span key={s.key}><i style={{ background: s.color }} />{s.label}</span>)}
      </div>
      <div className={`chart-wrap${busy ? ' busy' : ''}`} ref={wrap}>
        <svg ref={svg} className="chart" viewBox={`0 0 ${W} ${H}`} width={W} height={H} role="img" aria-label={`Cumulative EMBER over ${days} days`}
          onPointerMove={onMove} onPointerLeave={() => setHover(undefined)}>
          {ticks.map((v) => (
            <g key={v}>
              <line className="grid" x1={L} x2={W - R} y1={y(v)} y2={y(v)} />
              <text x={L - 8} y={y(v) + 4} textAnchor="end">{compact(v)}</text>
            </g>
          ))}
          {rows.length > 1 && [0, Math.round(n / 2), n].map((i, k) => (
            <text key={k} x={x(i)} y={H - 8} textAnchor={k === 0 ? 'start' : k === 2 ? 'end' : 'middle'}>day {rows[i].day}</text>
          ))}
          {visible.map((s) => (
            <path key={s.key} fill="none" strokeWidth="2" strokeLinejoin="round" strokeLinecap="round" style={{ stroke: s.color }}
              d={rows.map((r, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(r[s.key]).toFixed(1)}`).join('')} />
          ))}
          {last && endLabels.map((l) => {
            const s = SERIES.find((q) => q.key === l.key)!;
            return (
              <g key={l.key}>
                <circle cx={x(n)} cy={l.y} r="4" strokeWidth="2" style={{ fill: s.color, stroke: 'var(--surface)' }} />
                <text x={x(n) + 10} y={l.y + 4} style={{ fill: 'var(--ink-2)' }}>{compact(last[l.key])} {l.key === 'earned' ? 'earned' : l.key}</text>
              </g>
            );
          })}
          {h && (
            <line x1={x(h.day)} x2={x(h.day)} y1={T} y2={H - B} strokeWidth="1" style={{ stroke: 'var(--ink-3)' }} />
          )}
        </svg>
        {h && (
          <div className="tip" style={{ left: `min(calc(${(x(h.day) / W) * 100}% + 12px), calc(100% - 200px))`, top: 8 }}>
            <span className="unit">end of day {h.day}</span>
            {SERIES.map((s) => (
              <span key={s.key} className="row"><span><i style={{ background: s.color }} />{s.label}</span><b>{num(h[s.key], 2)}</b></span>
            ))}
            <span className="row"><span>Heat</span><b>{num(h.heat, 3)}×</b></span>
          </div>
        )}
      </div>

      {failed.length > 0 && (
        <div className="log" aria-label="Rejected actions">
          {failed.map((l, i) => <span key={i} className="bad">day {l.day}: {l.kind} rejected by the contract rules ({l.note})</span>)}
        </div>
      )}

      <details>
        <summary className="eyebrow" style={{ cursor: 'pointer' }}>Ledger, every day</summary>
        <div className="table-wrap">
          <table>
            <thead><tr><th>Day</th><th>Active {pool.unit}</th><th>Heat</th><th>Earned</th><th>Claimed</th><th>Locked</th><th>Capstone</th><th>Forfeited</th></tr></thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.day}><td>{r.day}</td><td>{num(r.active, 2)}</td><td>{num(r.heat, 3)}</td><td>{num(r.earned, 2)}</td><td>{num(r.claimed, 2)}</td><td>{num(r.locked, 2)}</td><td>{num(r.capstone, 2)}</td><td>{num(r.forfeited, 2)}</td></tr>
              ))}
            </tbody>
          </table>
        </div>
      </details>
    </section>
  );
}
