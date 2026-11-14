// Kindling's arithmetic for the interface (docs/adr/0021-kindling.md), from the repo's exact model
// (scripts/kindling-model.ts) and the canonical config, so every figure the screen shows is the
// contract's own: the fee, the refusals, a cancellation's share of the base, the bounty, and a
// wallet's share of the opening LP.
import {
  FEE_BPS, CONTRIBUTOR_PCT, BOUNTY_BPS, SEED, POOL_FEE_PCT, DURATION, SETTLE_WINDOW,
  MIN_CONTRIBUTION, WALLET_CAP, MIN_RAISE, MAX_RAISE, DECIMALS,
} from '@model/kindling-model';
import { MINIMUM_LIQUIDITY } from '@model/pair-model';
import { isqrt } from '@canonical/accounting';

const BPS = 10_000n;

export enum Status { Live, Settled, Failed }
/** `Kindling.Venue`: why a settlement would refuse BlastPool or pool 0. */
export const VENUE_REASON = [
  null,
  'BlastPool is not deployed yet.',
  'BlastPool does not name this event, EMBER or USDC.',
  'BlastPool already has liquidity.',
  'Forge pool 0 does not take this event’s positions.',
] as const;

/** What the screen reads from the chain (or the demo builds), for one wallet. */
export interface KindlingState {
  decimals: number;
  status: Status;
  start: bigint; end: bigint; deadline: bigint;
  minContribution: bigint; walletCap: bigint; minRaise: bigint; maxRaise: bigint;
  accepted: bigint; totalNet: bigint; totalFees: bigint;
  closedAt: bigint; liquidity: bigint; contributorLp: bigint;
  me: { gross: bigint; net: bigint; fee: bigint; done: boolean };
  entitlement: bigint; refundable: bigint;
  /** `venueCheck()`; 0 is safe, -1 unreadable. */
  venue: number;
}

export type Phase = 'pending' | 'open' | 'settleable' | 'waiting' | 'short' | 'expired' | 'settled' | 'failed';

/** Where the event is at `now` (seconds), in the order the contract decides it. */
export function phaseOf(s: KindlingState, now: bigint): Phase {
  if (s.status === Status.Settled) return 'settled';
  if (s.status === Status.Failed) return 'failed';
  if (now < s.start) return 'pending';
  if (now < s.end) return 'open';
  if (now >= s.deadline) return 'expired';
  if (s.accepted < s.minRaise) return 'short';
  return s.venue === 0 ? 'settleable' : 'waiting';
}

/** Whether `fail()` would succeed now. */
export const canFail = (s: KindlingState, now: bigint) =>
  s.status === Status.Live && now >= s.end && (s.accepted < s.minRaise || now >= s.deadline);

export const feeOf = (gross: bigint) => (gross * FEE_BPS) / BPS;

export type Admission =
  | { ok: true; fee: bigint; net: bigint }
  | { ok: false; reason: string; fee: bigint; net: bigint };

/** `contribute(gross)`'s checks, in its order, said plainly. */
export function admit(s: KindlingState, gross: bigint, now: bigint): Admission {
  const fee = feeOf(gross), net = gross - fee;
  const no = (reason: string): Admission => ({ ok: false, reason, fee, net });
  if (s.status !== Status.Live || now < s.start || now >= s.end) return no(now < s.start ? 'Kindling has not opened yet.' : 'Kindling is closed to new contributions.');
  if (gross < s.minContribution) return no(`The smallest contribution is ${usd(s.minContribution, s.decimals)}.`);
  if (s.me.gross + gross > s.walletCap) return no(`That passes the ${usd(s.walletCap, s.decimals, 0)} wallet cap: at most ${usd(headroom(s), s.decimals)} more.`);
  if (s.accepted + gross > s.maxRaise) return no(`That passes the ${usd(s.maxRaise, s.decimals, 0)} maximum: at most ${usd(headroom(s), s.decimals)} more.`);
  return { ok: true, fee, net };
}

/** The most this wallet may still contribute. */
export const headroom = (s: KindlingState) => {
  const w = s.walletCap - s.me.gross, r = s.maxRaise - s.accepted;
  const h = w < r ? w : r;
  return h > 0n ? h : 0n;
};

/** `cancel(amount)`: what comes back now, the fee that stays, and the gross that leaves the base. */
export function cancelPreview(s: KindlingState, amount: bigint) {
  const ok = s.status === Status.Live && amount > 0n && amount <= s.me.net;
  const grossOut = ok ? (s.me.gross * amount + s.me.net - 1n) / s.me.net : 0n;
  return { ok, back: ok ? amount : 0n, feeKept: s.me.fee, grossOut };
}

/** The close bounty a `settle` caller would earn now. */
export const bountyOf = (s: KindlingState) => (s.accepted * BOUNTY_BPS) / BPS;

/** The opening price set by the raise: quote units per whole EMBER (net raise ÷ the 420,000 seed). */
export const openingPrice = (totalNet: bigint) => (totalNet * 10n ** 18n) / SEED;

/**
 * A wallet's share of the opening LP if the event closed with `totalNet` and the wallet held `net`,
 * as the contracts compute it: `sqrt(seed · net · 10^(18 − decimals))` LP less the pair's minimum,
 * 90% of it floored for contributors, the wallet's floor of that, then its claim on each reserve.
 * `staked` is what pool 0 keeps after its 1% deposit fee.
 */
export function shareOf(totalNet: bigint, net: bigint, decimals: number) {
  if (totalNet === 0n || net === 0n) return { lp: 0n, staked: 0n, quoteSide: 0n, emberSide: 0n, emberAtOpen: 0n };
  const minted = isqrt(SEED * totalNet * 10n ** BigInt(18 - decimals)) - MINIMUM_LIQUIDITY;
  const contributorLp = (minted * CONTRIBUTOR_PCT) / 100n;
  const lp = (contributorLp * net) / totalNet;
  const supply = minted + MINIMUM_LIQUIDITY;
  const quoteSide = (lp * totalNet) / supply, emberSide = (lp * SEED) / supply;
  return { lp, staked: lp - (lp * POOL_FEE_PCT) / 100n, quoteSide, emberSide, emberAtOpen: (emberSide * totalNet) / SEED };
}

/** Progress toward the minimum and the maximum, in ppm. */
export const progressPpm = (s: KindlingState) => ({
  ofMin: s.minRaise === 0n ? 0n : (s.accepted * 1_000_000n) / s.minRaise,
  ofMax: s.maxRaise === 0n ? 0n : (s.accepted * 1_000_000n) / s.maxRaise,
});

/** Seconds as h:mm:ss (or d h when longer than a day). */
export function clock(seconds: bigint): string {
  const t = seconds > 0n ? Number(seconds) : 0;
  const d = Math.floor(t / 86400), h = Math.floor((t % 86400) / 3600), m = Math.floor((t % 3600) / 60), sec = t % 60;
  const p = (n: number) => String(n).padStart(2, '0');
  return d > 0 ? `${d}d ${p(h)}h ${p(m)}m` : `${p(h)}:${p(m)}:${p(sec)}`;
}

/** Dollars from USDC units (USDC valued at $1, ADR 0021 [P]). */
export function usd(v: bigint, decimals: number, digits = 2): string {
  const unit = 10n ** BigInt(decimals);
  const whole = v / unit, frac = v % unit;
  const f = digits === 0 ? '' : `.${(frac * 10n ** BigInt(digits) / unit).toString().padStart(digits, '0')}`;
  return `$${whole.toLocaleString('en-US')}${f}`;
}

/** A demo event on the model's own limits, for the screen before anything is deployed. */
export function demoState(now: bigint): KindlingState {
  const start = now - 9n * 3600n;
  const accepted = 68_420n * 10n ** BigInt(DECIMALS);
  return {
    decimals: DECIMALS, status: Status.Live,
    start, end: start + DURATION, deadline: start + DURATION + SETTLE_WINDOW,
    minContribution: MIN_CONTRIBUTION, walletCap: WALLET_CAP, minRaise: MIN_RAISE, maxRaise: MAX_RAISE,
    accepted, totalNet: accepted - feeOf(accepted), totalFees: feeOf(accepted),
    closedAt: 0n, liquidity: 0n, contributorLp: 0n,
    me: { gross: 0n, net: 0n, fee: 0n, done: false }, entitlement: 0n, refundable: 0n, venue: 0,
  };
}
