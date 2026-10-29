import { useMemo, useRef, useState } from 'react';
import { HEAT_CAP_DAYS, MILESTONES } from '../engine/config';
import { heatAt, heatColorStop, heatCurve, nextMilestone } from '../engine/heat';
import { Num } from '../motion/motion';
import { heatColor, num } from './format';
import { placeLabels, textWidth, useWidth } from './useWidth';

const H = 240, L = 40, R = 16, T = 14, B = 30;
const MAX_DAY = 420;
const y = (h: number) => T + (1 - (h - 1) / 2.4) * (H - T - B); // 1.0x .. 3.4x: headroom for the Relic names

export function HeatPanel({ ageDays, playing, onPlay }: { ageDays: number; playing: boolean; onPlay: () => void }) {
  const wrap = useRef<HTMLDivElement>(null);
  const W = useWidth(wrap, 640);
  const x = (d: number) => L + (d / MAX_DAY) * (W - L - R);
  // A Relic name that would run off the right edge sits to the left of its line instead.
  const flip = (m: { days: number; key: string }) => x(m.days) + 4 + textWidth(m.key) > W;
  const curve = useMemo(() => heatCurve(MAX_DAY, 2), []);
  const heat = heatAt(ageDays);
  const reached = [...MILESTONES].reverse().find((m) => m.days <= ageDays);
  const next = nextMilestone(ageDays);
  const path = curve.map((p, i) => `${i ? 'L' : 'M'}${x(p.day).toFixed(1)},${y(p.heat).toFixed(1)}`).join('');
  const area = `${path}L${x(MAX_DAY)},${y(1)}L${x(0)},${y(1)}Z`;
  const [hover, setHover] = useState<number>();
  const svg = useRef<SVGSVGElement>(null);
  const onMove = (e: React.PointerEvent) => {
    const r = svg.current!.getBoundingClientRect();
    const px = ((e.clientX - r.left) / r.width) * W;
    setHover(Math.round(Math.min(MAX_DAY, Math.max(0, ((px - L) / (W - L - R)) * MAX_DAY))));
  };
  const hv = hover ?? undefined;
  return (
    <section className="panel" aria-labelledby="heat-h">
      <header>
        <span className="eyebrow">The fire</span>
        <h2 id="heat-h">Heat</h2>
        <p className="lede">Each lot's Heat grows with its age, from 1.0× to the 3.0× core cap at {HEAT_CAP_DAYS} days, with +0.1× at every Relic. Heat weights 63% of each day's rewards, plus whatever the 10% Seal bucket leaves unused (73% with no Seals).</p>
      </header>
      <div className="heat-readout">
        <span className="heat-big" style={{ color: heatColor(heatColorStop(heat)) }}>
          <Num value={heat} format={(n) => num(n, 3)} /><small>×</small>
        </span>
        <span className="heat-name">{reached ? reached.key : 'no Relic yet'}</span>
        <span className="value">age <Num value={ageDays} format={(n) => num(n, 0)} /> days</span>
        <button type="button" className="btn" onClick={onPlay} aria-pressed={playing}>{playing ? 'Pause time' : 'Let it age'}</button>
      </div>
      <div className="heat-bar" role="img" aria-label={`Heat ${num(heat, 2)} of 3.0`}>
        <span className="pin" style={{ left: `${heatColorStop(heat) * 100}%` }} />
      </div>
      <div className="chart-wrap" ref={wrap}>
        <svg ref={svg} className="chart" viewBox={`0 0 ${W} ${H}`} width={W} height={H} role="img" aria-label="Heat by lot age, 0 to 420 days"
          onPointerMove={onMove} onPointerLeave={() => setHover(undefined)}>
          <defs>
            <linearGradient id="heatStroke" x1={x(0)} x2={x(HEAT_CAP_DAYS)} gradientUnits="userSpaceOnUse">
              {[0, 0.2, 0.4, 0.6, 0.8, 1].map((t, i) => <stop key={t} offset={t} style={{ stopColor: `var(--heat-${i})` }} />)}
            </linearGradient>
          </defs>
          {[1, 1.5, 2, 2.5, 3].map((h) => (
            <g key={h}>
              <line className="grid" x1={L} x2={W - R} y1={y(h)} y2={y(h)} />
              <text x={L - 8} y={y(h) + 4} textAnchor="end">{h.toFixed(1)}×</text>
            </g>
          ))}
          {MILESTONES.map((m) => <line key={m.key} className="grid" x1={x(m.days)} x2={x(m.days)} y1={T} y2={H - B} />)}
          {placeLabels([...MILESTONES].reverse(), (m) => {
            const w = textWidth(`${m.days}d`);
            return [x(m.days) - w / 2, x(m.days) + w / 2];
          }, 1).map(({ item: m }) => (
            <text key={m.key} x={x(m.days)} y={H - B + 16} textAnchor="middle">{m.days}d</text>
          ))}
          {placeLabels(MILESTONES, (m) => {
            const w = textWidth(m.key);
            return flip(m) ? [x(m.days) - 4 - w, x(m.days) - 4] : [x(m.days) + 4, x(m.days) + 4 + w];
          }, 2).map(({ item: m, row }) => (
            <text key={m.key} x={flip(m) ? x(m.days) - 4 : x(m.days) + 4} y={T + 9 + row * 13} textAnchor={flip(m) ? 'end' : 'start'}>{m.key}</text>
          ))}
          <path d={area} style={{ fill: 'var(--glow)' }} />
          <path d={path} fill="none" stroke="url(#heatStroke)" strokeWidth="2.5" strokeLinejoin="round" strokeLinecap="round" />
          <circle cx={x(Math.min(ageDays, MAX_DAY))} cy={y(heat)} r="6" strokeWidth="2" style={{ fill: heatColor(heatColorStop(heat)), stroke: 'var(--surface)' }} />
          {hv !== undefined && (
            <g>
              <line x1={x(hv)} x2={x(hv)} y1={T} y2={H - B} strokeWidth="1" style={{ stroke: 'var(--ink-3)' }} />
              <circle cx={x(hv)} cy={y(heatAt(hv))} r="4" strokeWidth="2" style={{ fill: 'var(--ink)', stroke: 'var(--surface)' }} />
            </g>
          )}
        </svg>
        {hv !== undefined && (
          <div className="tip" style={{ left: `min(calc(${(x(hv) / W) * 100}% + 12px), calc(100% - 170px))`, top: 8 }}>
            <b>{num(heatAt(hv), 3)}×</b>
            <span>at {hv} days of age</span>
          </div>
        )}
      </div>
      {next ? (
        <div className="nudge"><span className="ico">↑</span><span>Next Relic, <b>{next.key}</b>, in <b>{num(next.inDays, 0)} days</b> (+{next.bump}× Heat). Staying is what makes Heat; nothing else raises it.</span></div>
      ) : (
        <div className="nudge"><span className="ico">✓</span><span>This lot has every Heat milestone. Its core Heat stays at <b>3.0×</b> as long as it is not cut by a withdrawal.</span></div>
      )}
    </section>
  );
}
