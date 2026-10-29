/// <reference lib="webworker" />
// Heavy BigInt work runs here so the page's motion never stutters. Requests carry
// decimal strings; replies carry decimal strings (BigInt does not cross postMessage
// in every browser we target).
import { emissionPerDay } from '@model/schedule';
import { projectSeal, type SealProjection } from './engine/seal';
import { runTimeline, type TimelineInput } from './engine/timeline';

export interface SealRequest {
  pool: number; stake: string; ageDays: number; othersStake: string; othersAgeDays: number;
  othersSealedPct: number; launchDay: number;
}
export type WorkerRequest =
  | { id: number; type: 'seal'; input: SealRequest }
  | { id: number; type: 'timeline'; input: TimelineInput };

export interface SealDayWire { day: number; ordinary: string; escrow: string; unsealed: string; binding: 'cap' | 'candidate' }
export interface SealWire {
  track: number; totalOrdinary: string; totalEscrow: string; totalUnsealed: string; gain: string; capDays: number;
  days: SealDayWire[];
}

const wireSeal = (p: SealProjection): SealWire => ({
  track: p.track,
  totalOrdinary: String(p.totalOrdinary),
  totalEscrow: String(p.totalEscrow),
  totalUnsealed: String(p.totalUnsealed),
  gain: String(p.gain),
  capDays: p.capDays,
  days: p.days.map((d) => ({ day: d.day, ordinary: String(d.ordinary), escrow: String(d.escrow), unsealed: String(d.unsealedOrdinary), binding: d.binding })),
});

emissionPerDay(0n); // build the exact schedule table once, before the first request

self.onmessage = (ev: MessageEvent<WorkerRequest>) => {
  const req = ev.data;
  try {
    if (req.type === 'seal') {
      const i = req.input;
      const a = { ...i, stake: BigInt(i.stake), othersStake: BigInt(i.othersStake) };
      const result = [0, 1, 2, 3].map((t) => wireSeal(projectSeal(a, t)));
      self.postMessage({ id: req.id, type: 'seal', result });
    } else {
      self.postMessage({ id: req.id, type: 'timeline', result: runTimeline(req.input) });
    }
  } catch (e) {
    self.postMessage({ id: req.id, type: 'error', error: e instanceof Error ? e.message : String(e) });
  }
};
