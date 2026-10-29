import { SettlementModel, Phase } from '@model/settlement-model';
import { Revert, SealStatus } from '@model/forge-model';
import { DAY } from './config';
import { heatAt } from './heat';

export type EventKind = 'seal' | 'withdraw' | 'cancel' | 'deposit' | 'emergency' | 'claim';
export interface SimEvent { day: number; kind: EventKind; value?: number } // seal: track; withdraw: %; deposit: units

export interface TimelineInput {
  pool: number;
  stake: string; // decimal base units (strings cross the worker boundary)
  othersStake: string;
  others: number; // how many other stakers share `othersStake`
  days: number;
  events: SimEvent[];
}

export interface TimelineDay {
  day: number;
  claimable: string; // unclaimed + pending claim
  claimed: string; // paid out to the wallet
  locked: string; // running Seal escrow
  capstone: string; // vested escrow held for the Capstone
  forfeited: string; // this position's escrow routed after a forfeit
  active: string; // principal still earning
  heat: number; // stake-weighted Heat of the active lots
  poolPaid: string; // everything the pool credited that day
}

export interface TimelineLog { day: number; kind: EventKind; ok: boolean; note: string }
export interface TimelineResult { days: TimelineDay[]; log: TimelineLog[] }

const S0 = 1_800_000_000n; // Mantle START for the simulation (any instant works)
const HOUR = 3_600n;
const YOU = 1; // the user's position id in the chosen pool

/** Run `fn` on a copy; keep it only if nothing reverts (EVM atomicity). */
function attempt(m: SettlementModel, fn: (x: SettlementModel) => string): { m: SettlementModel; ok: boolean; note: string } {
  const x = m.clone();
  try {
    return { m: x, ok: true, note: fn(x) };
  } catch (e) {
    if (e instanceof Revert) return { m, ok: false, note: e.message };
    throw e;
  }
}

/** The keeper's day: finalize, open, and page every pool until it is done. */
function settleDay(m: SettlementModel, now: bigint) {
  m.finalize(now);
  const e = m.openEpoch(now);
  for (let i = 0; i < 4; i++) {
    for (let guard = 0; guard < 1_000; guard++) {
      const ph = m.epoch(e, i).phase;
      if (ph === Phase.Done) break;
      m.advance(e, i, now);
    }
  }
  return e;
}

/** Day-by-day run of the contract-mirroring SettlementModel with the user's events. */
export function runTimeline(input: TimelineInput): TimelineResult {
  let m = new SettlementModel(S0);
  const pool = () => m.pools[input.pool];
  const log: TimelineLog[] = [];
  const out: TimelineDay[] = [];
  const stake = BigInt(input.stake);
  pool().open(stake, S0 + 1n);
  const others = Math.max(0, input.others);
  for (let k = 0; k < others; k++) pool().open(BigInt(input.othersStake) / BigInt(others) || 1n, S0 + 1n);
  let claimed = 0n, forfeited = 0n;
  const executes: { at: bigint; ticket: number }[] = [];

  for (let d = 0; d < input.days; d++) {
    const dayStart = S0 + BigInt(d) * DAY;
    // The day's actions in time order: the user's events from 02:00, and each matured
    // withdrawal executed at its maturity (inside its 24h window).
    type Act = { t: bigint; run: () => void };
    const acts: Act[] = [];
    const executeAt = (x: { at: bigint; ticket: number }) => () => {
      if (!executes.includes(x)) return; // cancelled earlier today
      const r = attempt(m, (s) => `received ${s.pools[input.pool].execute(YOU, x.ticket, x.at)}`);
      m = r.m;
      log.push({ day: Number((x.at - S0) / DAY), kind: 'withdraw', ok: r.ok, note: r.ok ? r.note : `execute: ${r.note}` });
      executes.splice(executes.indexOf(x), 1);
    };
    for (const x of executes) if (x.at < dayStart + DAY) acts.push({ t: x.at, run: executeAt(x) });
    input.events.filter((ev) => ev.day === d).forEach((ev, k) => acts.push({ t: dayStart + 2n * HOUR + BigInt(k + 1), run: () => {
      const t = dayStart + 2n * HOUR + BigInt(k + 1);
      const r = attempt(m, (s) => {
        const p = s.pools[input.pool];
        const pos = p.positions[YOU - 1];
        switch (ev.kind) {
          case 'seal': return `sealed on the ${['Ember', 'Forge', 'Kiln', 'Eternal'][ev.value ?? 0]} track (Seal ${p.seal(YOU, ev.value ?? 0, t)})`;
          case 'withdraw': {
            const active = pos.lots.reduce((n, l) => n + l.amount, 0n);
            const amount = (active * BigInt(Math.round((ev.value ?? 10) * 100))) / 10_000n;
            const id = p.request(YOU, amount, t);
            const ticket = pos.tickets.get(id)!;
            executes.push({ at: ticket.maturity, ticket: id });
            return `cooling ${ev.value}% for ${Number(ticket.maturity - t) / 3600}h`;
          }
          case 'cancel': {
            const id = pos.pending[pos.pending.length - 1];
            if (id === undefined) throw new Revert('NothingPending');
            p.cancel(YOU, id, t);
            const i = executes.findIndex((x) => x.ticket === id);
            if (i >= 0) executes.splice(i, 1);
            return `cancelled ticket ${id}`;
          }
          case 'deposit': {
            const amount = BigInt(Math.round((ev.value ?? 0) * 1e6)) * 10n ** 12n;
            p.deposit(YOU, amount, t);
            return `deposited a new lot`;
          }
          case 'emergency': return `left with ${p.emergency(YOU, t)} (8% fee)`;
          case 'claim': {
            s.requestClaim(input.pool, YOU, t);
            return 'claim requested (24h timer)';
          }
        }
      });
      m = r.m;
      log.push({ day: d, kind: ev.kind, ok: r.ok, note: r.note });
    } }));
    acts.sort((a, b) => (a.t < b.t ? -1 : a.t > b.t ? 1 : 0)).forEach((a) => a.run());
    // Requests made today that mature today (the 6h tier) execute after the events.
    for (const x of [...executes].sort((a, b) => (a.at < b.at ? -1 : 1))) if (x.at < dayStart + DAY) executeAt(x)();
    // A requested claim pays out once its 24h timer has run.
    const pend = m.claims.get(`${input.pool}:${YOU}`);
    if (pend && pend.maturesAt <= dayStart + DAY) {
      m.executeClaim(input.pool, YOU, pend.maturesAt);
      claimed += pend.amount;
    }
    // End of day: the keeper settles the epoch that just ended.
    const end = dayStart + DAY + 60n;
    const e = settleDay(m, end);
    // A Seal that ended has its locked escrow released (permissionless settleSeal).
    const pos = pool().positions[YOU - 1];
    pos.seals.forEach((_, k) => {
      const key = `${input.pool}:${YOU}:${k + 1}`;
      if ((m.sealEscrow.get(key) ?? 0n) === 0n) return;
      const status = m.sealStatus(input.pool, YOU, k + 1, end);
      if (status !== SealStatus.Completed && status !== SealStatus.Forfeited) return;
      if (status === SealStatus.Forfeited) forfeited += m.sealEscrow.get(key)!;
      m.settleSeal(input.pool, YOU, k + 1, end);
    });
    const locked = [...m.sealEscrow.entries()].filter(([k]) => k.startsWith(`${input.pool}:${YOU}:`)).reduce((n, [, v]) => n + v, 0n);
    const lots = pos.lots.filter((l) => l.amount > 0n);
    const active = lots.reduce((n, l) => n + l.amount, 0n);
    const heat = active === 0n ? 0 : lots.reduce((n, l) => n + heatAt(Number(l.age) / 86_400) * Number(l.amount), 0) / Number(active);
    out.push({
      day: d,
      claimable: String((m.unclaimed.get(`${input.pool}:${YOU}`) ?? 0n) + (m.claims.get(`${input.pool}:${YOU}`)?.amount ?? 0n)),
      claimed: String(claimed),
      locked: String(locked),
      capstone: String(m.capstoneOwed.get(`${input.pool}:${YOU}`) ?? 0n),
      forfeited: String(forfeited),
      active: String(active),
      heat,
      poolPaid: String(m.epoch(e, input.pool).paid),
    });
  }
  return { days: out, log };
}
