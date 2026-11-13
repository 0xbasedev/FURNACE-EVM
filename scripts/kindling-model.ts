// Exact BigInt reference of Kindling, its GenesisFeeEscrow and the permanent LP sink
// (docs/adr/0021-kindling.md), written from the spec, the ADR and the canonical config,
// independently of the contracts. The Solidity test replays its scenarios on a real EmberPair
// (BlastPool), a mock Mantle and a mock Forge pool 0, and compares every output, every revert and a
// hash of the whole state (the event, the escrow, every wallet, the pair, the sink, the Treasury,
// the keeper and the pool) after every step. The canonical `KindlingEscrow` (accounting.ts) is run
// beside the model on its own vectors.
import cfg from '../canonical/furnace.config';
import { KindlingEscrow, parseUnits, isqrt } from '../canonical/accounting';
import { PairModel, Revert, MINIMUM_LIQUIDITY } from './pair-model';
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex } from '@noble/hashes/utils.js';

const need = (ok: boolean, why: string) => { if (!ok) throw new Revert(why); };

// ── the config's figures, read here independently of FurnaceParams ──
const kd = cfg.kindling, kx = cfg.execution.kindling;
export const DECIMALS = 6; // USDC
export const U = 10n ** BigInt(DECIMALS), E = 10n ** 18n;
export const DURATION = BigInt(kd.durationHours) * 3600n;
export const SETTLE_WINDOW = BigInt(kx.maxSettlementDelaySeconds);
export const MIN_CONTRIBUTION = 1n * U; // [P]
export const WALLET_CAP = BigInt(kd.maxPerWalletUsd) * U;
export const MIN_RAISE = BigInt(kd.minRaiseUsd) * U;
export const MAX_RAISE = BigInt(kd.maxRaiseUsd) * U;
export const FEE_BPS = BigInt(kd.depositFeePct) * 100n;
export const CONTRIBUTOR_PCT = BigInt(kd.lpSplit.depositorDeedsPct);
export const BOUNTY_BPS = BigInt(kd.closeBountyBps);
export const SEED = BigInt(cfg.token.allocations.kindlingPool) * E;
export const POOL_FEE_PCT = BigInt(cfg.forge.fees.depositPct);
export const MIN_STAKE_LP = parseUnits(cfg.forge.minStakeLp, 18);
const BPS = 10_000n;

/** The contributors the harness funds, each with FUNDING USDC. */
export const WALLETS = 8;
export const FUNDING = 40_000n * U;
export enum Status { Live, Settled, Failed }
export enum EscrowState { Open, Settled, Failed }

interface Wallet { gross: bigint; net: bigint; fee: bigint; done: boolean; usdc: bigint; staked: bigint; lp: bigint }

export class KindlingModel {
  now = 0n;
  readonly end: bigint; readonly deadline: bigint;
  status = Status.Live;
  readonly w: Wallet[] = Array.from({ length: WALLETS }, () => ({ gross: 0n, net: 0n, fee: 0n, done: false, usdc: FUNDING, staked: 0n, lp: 0n }));
  accepted = 0n; totalNet = 0n; totalFees = 0n;
  closedAt = 0n; liquidity = 0n; contributorLp = 0n; lpPaid = 0n; netMaterialized = 0n;
  /** The escrow's ledgers and its USDC balance (donations included). */
  escrow = { state: EscrowState.Open, principal: 0n, fees: 0n, released: false, usdc: 0n };
  /** Kindling's own balances (donations included). */
  kUsdc = 0n; kEmber = 0n; kLp = 0n;
  readonly pair = new PairModel(DECIMALS);
  /** The pair's token balances beyond its reserves (donations), and the dead address's LP. */
  pairUsdc = 0n; pairEmber = 0n; dead = 0n;
  sinkLp = 0n; treasury = 0n; keeper = 0n; seedMinted = false;
  /** The mock Forge pool 0: LP held, deposit fees booked, positions opened. */
  poolLp = 0n; poolFees = 0n; positions = 0n;

  constructor(readonly start: bigint) { this.end = start + DURATION; this.deadline = this.end + SETTLE_WINDOW; }
  setNow(t: bigint) { this.now = t; this.pair.now = t; }

  contribute(i: number, gross: bigint): bigint[] {
    need(this.now >= this.start && this.now < this.end, 'NotOpen');
    need(gross >= MIN_CONTRIBUTION, 'BelowMinimumContribution');
    const fee = (gross * FEE_BPS) / BPS, net = gross - fee, c = this.w[i];
    need(c.gross + gross <= WALLET_CAP, 'WalletCap');
    need(this.accepted + gross <= MAX_RAISE, 'RaiseCap');
    if (gross > c.usdc) throw new Error('scenario contributes more USDC than the wallet holds');
    c.gross += gross; c.net += net; c.fee += fee; c.usdc -= gross;
    this.accepted += gross; this.totalNet += net; this.totalFees += fee;
    this.escrow.usdc += gross; this.escrow.principal += net; this.escrow.fees += fee;
    return [net, fee, 0n];
  }

  cancel(i: number, amount: bigint): bigint[] {
    need(this.status === Status.Live, 'NotLive');
    const c = this.w[i];
    need(amount !== 0n && amount <= c.net, 'BadCancel');
    const grossOut = (c.gross * amount + c.net - 1n) / c.net; // rounded up
    c.gross -= grossOut; c.net -= amount; c.usdc += amount;
    this.accepted -= grossOut; this.totalNet -= amount;
    this.escrow.principal -= amount; this.escrow.usdc -= amount;
    return [grossOut, 0n, 0n];
  }

  settle(): bigint[] {
    need(this.status === Status.Live, 'NotLive');
    need(this.now >= this.end, 'TooEarly');
    need(this.now < this.deadline, 'SettlementExpired');
    const base = this.accepted;
    need(base >= MIN_RAISE, 'BelowMinimumRaise');
    this.status = Status.Settled; this.closedAt = this.now;
    this.seedMinted = true; this.kEmber += SEED;
    const quote = this.escrow.principal;
    this.escrow.state = EscrowState.Settled; this.escrow.principal = 0n; this.escrow.usdc -= quote; this.kUsdc += quote;
    if (quote !== this.totalNet) throw new Error('escrow principal diverged from totalNet');
    const [e, q, minted] = this.pair.add(SEED, quote);
    this.kEmber -= e; this.kUsdc -= q; this.dead += MINIMUM_LIQUIDITY;
    const kept = (minted * CONTRIBUTOR_PCT) / 100n;
    this.liquidity = minted; this.contributorLp = kept;
    this.kLp += kept; this.sinkLp += minted - kept;
    const bounty = (base * BOUNTY_BPS) / BPS;
    if (bounty > this.escrow.fees) throw new Error('bounty exceeds the fees');
    const toTreasury = this.escrow.fees - bounty;
    this.escrow.released = true; this.escrow.fees = 0n; this.escrow.usdc -= bounty + toTreasury;
    this.keeper += bounty; this.treasury += toTreasury;
    return [minted, 0n, 0n];
  }

  fail(): bigint[] {
    need(this.status === Status.Live, 'NotLive');
    need(this.now >= this.end, 'TooEarly');
    const below = this.accepted < MIN_RAISE;
    need(below || this.now >= this.deadline, 'StillSettleable');
    this.status = Status.Failed; this.escrow.state = EscrowState.Failed;
    return [below ? 0n : 1n, 0n, 0n];
  }

  refund(i: number): bigint[] {
    need(this.status === Status.Failed, 'NotFailed');
    const c = this.w[i];
    need(!c.done && c.net + c.fee !== 0n, 'NothingOwed');
    c.done = true;
    this.escrow.principal -= c.net; this.escrow.fees -= c.fee; this.escrow.usdc -= c.net + c.fee;
    c.usdc += c.net + c.fee;
    return [c.net + c.fee, 0n, 0n];
  }

  /** One wallet's materialization; null when it has nothing owed. */
  private one(i: number): bigint | null {
    need(this.status === Status.Settled, 'NotSettled');
    const c = this.w[i];
    if (c.done || c.net === 0n) return null;
    const lp = (this.contributorLp * c.net) / this.totalNet;
    // The pool's `openKindling`: the standard deposit fee, the LP minimum.
    const fee = (lp * POOL_FEE_PCT) / 100n;
    need(lp - fee >= MIN_STAKE_LP, 'BelowMinimum');
    c.done = true;
    this.lpPaid += lp; this.netMaterialized += c.net;
    this.kLp -= lp; this.poolLp += lp; this.poolFees += fee; c.staked += lp - fee;
    const id = ++this.positions;
    if (this.netMaterialized === this.totalNet) {
      const rest = this.contributorLp - this.lpPaid;
      this.lpPaid = this.contributorLp;
      this.kLp -= rest; this.sinkLp += rest; this.swept += rest;
    }
    return id;
  }
  swept = 0n;

  materialize(i: number): bigint[] {
    const id = this.one(i);
    need(id !== null, 'NothingOwed');
    return [id!, 0n, 0n];
  }

  materializeMany(mask: bigint): bigint[] {
    let paid = 0n;
    for (let i = 0; i < WALLETS; i++) if ((mask >> BigInt(i)) & 1n) { if (this.one(i) !== null) paid++; }
    return [paid, 0n, 0n];
  }

  entitlementOf(i: number) {
    const c = this.w[i];
    if (this.status !== Status.Settled || c.done || this.totalNet === 0n) return 0n;
    return (this.contributorLp * c.net) / this.totalNet;
  }
  refundableOf(i: number) {
    const c = this.w[i];
    if (this.status === Status.Settled || c.done) return 0n;
    return c.net + c.fee;
  }

  /** The state the Solidity test hashes after every step, in this exact order. */
  words(): bigint[] {
    const x: bigint[] = [BigInt(this.status), this.accepted, this.totalNet, this.totalFees, this.closedAt,
      this.liquidity, this.contributorLp, this.lpPaid, this.netMaterialized];
    const s = this.escrow;
    x.push(BigInt(s.state), s.principal, s.fees, s.released ? 1n : 0n, s.usdc);
    for (let i = 0; i < WALLETS; i++) {
      const c = this.w[i];
      x.push(c.gross, c.net, c.fee, c.done ? 1n : 0n, c.usdc, c.staked, c.lp, this.entitlementOf(i), this.refundableOf(i));
    }
    x.push(this.kUsdc, this.kEmber, this.kLp);
    x.push(this.pair.rE, this.pair.rQ, this.pair.supply, this.dead, this.pairUsdc, this.pairEmber);
    x.push(this.sinkLp, this.treasury, this.keeper, this.seedMinted ? 1n : 0n);
    x.push(this.poolLp, this.poolFees, this.positions);
    return x;
  }
}

// ── scenarios ──
export enum K { Warp, Contribute, Cancel, Settle, Fail, Refund, Materialize, MaterializeMany, Donate }
/** Donation targets: USDC to the escrow, USDC to Kindling, EMBER to Kindling, USDC and EMBER to the pair. */
export enum Gift { EscrowUsdc, KindlingUsdc, KindlingEmber, PairUsdc, PairEmber }
/** One action: [kind, a, b]. */
export type Act = [K, bigint, bigint];
const act = (k: K, a: bigint | number = 0n, b: bigint | number = 0n): Act => [k, BigInt(a), BigInt(b)];

export interface Scenario { name: string; start: bigint; actions: Act[] }

const hashWords = (w: bigint[]) => '0x' + bytesToHex(keccak_256(Uint8Array.from(w.flatMap((x) => {
  const h = x.toString(16).padStart(64, '0');
  return Array.from({ length: 32 }, (_, i) => parseInt(h.slice(2 * i, 2 * i + 2), 16));
}))));

/** Apply one action; the harness performs the same calls. Returns the outputs and the revert. */
export function apply(m: KindlingModel, [k, a, b]: Act): { out: bigint[]; why: string } {
  try {
    let out = [0n, 0n, 0n];
    switch (k) {
      case K.Warp: m.setNow(m.now + a); break;
      case K.Contribute: out = m.contribute(Number(a), b); break;
      case K.Cancel: out = m.cancel(Number(a), b); break;
      case K.Settle: out = m.settle(); break;
      case K.Fail: out = m.fail(); break;
      case K.Refund: out = m.refund(Number(a)); break;
      case K.Materialize: out = m.materialize(Number(a)); break;
      case K.MaterializeMany: out = m.materializeMany(a); break;
      case K.Donate:
        switch (Number(a) as Gift) {
          case Gift.EscrowUsdc: m.escrow.usdc += b; break;
          case Gift.KindlingUsdc: m.kUsdc += b; break;
          case Gift.KindlingEmber: m.kEmber += b; break;
          case Gift.PairUsdc: m.pairUsdc += b; break;
          case Gift.PairEmber: m.pairEmber += b; break;
        }
        break;
    }
    return { out, why: '' };
  } catch (e) {
    if (!(e instanceof Revert)) throw e;
    return { out: [0n, 0n, 0n], why: e.message };
  }
}

/** Ledger identities checked after every model step. */
function audit(m: KindlingModel, at: string) {
  const live = m.w.filter((c) => !c.done);
  const owed = m.escrow.principal + m.escrow.fees;
  if (m.escrow.usdc < owed) throw new Error(`${at}: the escrow holds less than it owes`);
  if (m.status === Status.Live && (m.escrow.principal !== m.totalNet || m.escrow.fees !== m.totalFees)) throw new Error(`${at}: ledgers diverged`);
  if (m.status === Status.Failed) {
    const p = live.reduce((n, c) => n + c.net, 0n), f = live.reduce((n, c) => n + c.fee, 0n);
    if (p !== m.escrow.principal || f !== m.escrow.fees) throw new Error(`${at}: refund backing diverged`);
  }
  if (m.status === Status.Settled && m.lpPaid > m.contributorLp) throw new Error(`${at}: contributor LP overpaid`);
  if (m.w.some((c) => c.gross < 0n || c.net < 0n)) throw new Error(`${at}: negative wallet`);
}

function run(s: Scenario) {
  const m = new KindlingModel(s.start);
  m.setNow(s.start - 3600n); // the harness deploys an hour before START
  const cols = { kind: [] as number[], a: [] as string[], b: [] as string[], why: [] as string[], out0: [] as string[], out1: [] as string[], hash: [] as string[] };
  const stats = { settled: 0, failedBelow: 0, failedTimeout: 0, refunds: 0, materialized: 0, sweeps: 0, reverts: {} as Record<string, number> };
  for (const [n, x] of s.actions.entries()) {
    const sweptBefore = m.swept;
    const r = apply(m, x);
    audit(m, `${s.name} step ${n}`);
    if (r.why !== '') stats.reverts[r.why] = (stats.reverts[r.why] ?? 0) + 1;
    else if (x[0] === K.Settle) stats.settled++;
    else if (x[0] === K.Fail) r.out[0] === 0n ? stats.failedBelow++ : stats.failedTimeout++;
    else if (x[0] === K.Refund) stats.refunds++;
    else if (x[0] === K.Materialize) stats.materialized++;
    else if (x[0] === K.MaterializeMany) stats.materialized += Number(r.out[0]);
    if (m.swept > sweptBefore) stats.sweeps++;
    cols.kind.push(x[0]); cols.a.push(String(x[1])); cols.b.push(String(x[2])); cols.why.push(r.why);
    cols.out0.push(String(r.out[0])); cols.out1.push(String(r.out[1]));
    cols.hash.push(hashWords(m.words()));
  }
  // Every unit of LP has one owner: the contributors' positions, the sink, or (before every wallet
  // is materialized) Kindling; plus the pair's burned minimum.
  if (m.status === Status.Settled && m.poolLp + m.sinkLp + m.kLp + m.dead !== m.pair.supply) throw new Error(`${s.name}: LP not conserved`);
  return { name: s.name, start: String(s.start), ...cols, stats };
}

const T0 = 1_800_000_000n;
const usd = (n: number | bigint) => BigInt(n) * U;
/** Contribute a total of `total` dollars across wallets 0.., `per` dollars each. */
const fill = (total: number, per: number): Act[] => {
  const out: Act[] = []; let left = total, i = 0;
  while (left > 0) { const g = Math.min(per, left); out.push(act(K.Contribute, i++, usd(g))); left -= g; }
  return out;
};
const toEnd = (): Act => act(K.Warp, DURATION + 3600n);

export function kindlingScenarios(): Scenario[] {
  const sc: Scenario[] = [];
  // 1. The canonical KindlingEscrow vectors: 10,000 → 9,700 net + 300 fee; cancel 4,000 then fail → 6,000.
  sc.push({ name: 'canonical', start: T0, actions: [
    act(K.Warp, 3600), act(K.Contribute, 0, usd(10_000)), act(K.Cancel, 0, usd(4_000)),
    act(K.Contribute, 1, usd(20_000)), act(K.Cancel, 1, usd(19_400)), // wallet 1 cancels all its net
    toEnd(), act(K.Settle), act(K.Fail), act(K.Refund, 0), act(K.Refund, 1), act(K.Refund, 0), act(K.Refund, 2),
  ] });
  // 2. Success: six wallets, settle, every entitlement materialized one by one; then every refusal after.
  sc.push({ name: 'success', start: T0, actions: [
    act(K.Warp, 3600), ...fill(118_000, 25_000).slice(0, 4), act(K.Contribute, 4, usd(17_777)), act(K.Contribute, 5, usd(1)),
    act(K.Settle), act(K.Fail), toEnd(), act(K.Materialize, 0), act(K.Refund, 0), act(K.Settle),
    act(K.Materialize, 0), act(K.Materialize, 3), act(K.Materialize, 3), act(K.Materialize, 6), act(K.Materialize, 1),
    act(K.Materialize, 2), act(K.Materialize, 5), act(K.Materialize, 4), act(K.Settle), act(K.Fail), act(K.Cancel, 0, 1n),
    act(K.Contribute, 6, usd(10)), act(K.Refund, 2),
  ] });
  // 3. The deadline cuts off exactly; deposits before START are refused.
  sc.push({ name: 'cutoff', start: T0, actions: [
    act(K.Contribute, 0, usd(10)), act(K.Warp, 3599), act(K.Contribute, 0, usd(10)), act(K.Warp, 1), act(K.Contribute, 0, usd(25_000)),
    act(K.Warp, DURATION - 1n), act(K.Contribute, 1, usd(25_000)), act(K.Settle), act(K.Fail), act(K.Warp, 1),
    act(K.Contribute, 2, usd(25_000)), act(K.Fail), act(K.Refund, 0), act(K.Refund, 1), act(K.Refund, 2), act(K.Materialize, 0),
  ] });
  // 4. Caps and the minimum contribution: the wallet cap exactly, one unit over, top-ups after a
  //    cancellation, $1 and one unit under it.
  sc.push({ name: 'caps', start: T0, actions: [
    act(K.Warp, 3600), act(K.Contribute, 0, usd(1) - 1n), act(K.Contribute, 0, usd(1)), act(K.Contribute, 0, usd(24_999)),
    act(K.Contribute, 0, 1n), act(K.Contribute, 0, usd(1)), act(K.Cancel, 0, 0n), act(K.Cancel, 0, usd(24_250) + 1n),
    act(K.Cancel, 0, usd(1_000)), act(K.Contribute, 0, usd(1_031)), act(K.Contribute, 0, usd(1_030)), act(K.Contribute, 0, 1n),
    act(K.Cancel, 0, 333_333n), act(K.Cancel, 1, 1n), ...fill(100_000, 25_000).slice(1), act(K.Contribute, 4, usd(1_000)),
    toEnd(), act(K.Settle), act(K.MaterializeMany, 0xffn), act(K.MaterializeMany, 0xffn),
  ] });
  // 5. Cancellations after the deadline drop the raise below the minimum: settle refuses, fail
  //    (below minimum) opens refunds, and every retained fee is refunded.
  sc.push({ name: 'cancel-after-deadline', start: T0, actions: [
    act(K.Warp, 3600), ...fill(110_000, 25_000), toEnd(), act(K.Fail), act(K.Cancel, 4, usd(9_700)), act(K.Cancel, 0, usd(5_000)),
    act(K.Settle), act(K.Fail), act(K.Settle), act(K.Cancel, 1, 1n), act(K.Refund, 0), act(K.Refund, 4), act(K.Refund, 1),
    act(K.Refund, 2), act(K.Refund, 3), act(K.Refund, 7),
  ] });
  // 6. A funded event nobody settles: the retry window, then the timeout.
  sc.push({ name: 'timeout', start: T0, actions: [
    act(K.Warp, 3600), ...fill(125_000, 25_000), toEnd(), act(K.Warp, SETTLE_WINDOW - 3601n), act(K.Fail),
    act(K.Cancel, 2, usd(100)), act(K.Warp, 1), act(K.Settle), act(K.Fail), act(K.Fail), act(K.Refund, 2), act(K.Refund, 2),
    act(K.Refund, 0), act(K.Refund, 4), act(K.Materialize, 1),
  ] });
  // 7. Pages: materializeMany over mixed wallets (done, never contributed, fully cancelled), the
  //    remainder swept on the last one.
  sc.push({ name: 'pages', start: T0, actions: [
    act(K.Warp, 3600), act(K.Contribute, 0, usd(25_000)), act(K.Contribute, 1, usd(24_123)), act(K.Contribute, 2, 33_333_333n),
    act(K.Contribute, 3, usd(25_000)), act(K.Contribute, 4, usd(25_000)), act(K.Contribute, 5, usd(777)), act(K.Cancel, 5, usd(777) - usd(777) * 3n / 100n),
    act(K.Contribute, 6, usd(4_321)), act(K.MaterializeMany, 0xffn), toEnd(), act(K.Settle), act(K.MaterializeMany, 0b00100101n),
    act(K.MaterializeMany, 0b00100101n), act(K.MaterializeMany, 0b11011010n), act(K.MaterializeMany, 0xffn),
  ] });
  // 8. Donations everywhere before settlement change nothing that is owed; the pair's reserves
  //    ignore them, so the opening price is still the raise's.
  sc.push({ name: 'donations', start: T0, actions: [
    act(K.Warp, 3600), ...fill(100_000, 25_000), act(K.Donate, Gift.EscrowUsdc, usd(5_000)), act(K.Donate, Gift.KindlingUsdc, usd(700)),
    act(K.Donate, Gift.KindlingEmber, 12_345n * E), act(K.Donate, Gift.PairUsdc, usd(900)), act(K.Donate, Gift.PairEmber, 1_000n * E),
    toEnd(), act(K.Settle), act(K.MaterializeMany, 0x0fn),
  ] });
  // 9. The bounty's base: cancellations leave it, rounded up, before success.
  sc.push({ name: 'bounty-base', start: T0, actions: [
    act(K.Warp, 3600), ...fill(125_000, 25_000), act(K.Cancel, 0, 1n), act(K.Cancel, 1, 7n), act(K.Cancel, 2, usd(3_333) + 1n),
    act(K.Contribute, 0, usd(1)), toEnd(), act(K.Cancel, 3, usd(1)), act(K.Settle), act(K.Materialize, 4), act(K.Materialize, 0),
    act(K.MaterializeMany, 0xffn),
  ] });
  // 10–15. Seeded random walks around the window's edges.
  for (let seed = 0x6b00n; seed < 0x6b06n; seed++) {
    let x = seed;
    const rnd = (n: bigint) => { x = (x * 6364136223846793005n + 1442695040888963407n) % (1n << 64n); return (x >> 33n) % n; };
    const actions: Act[] = [act(K.Warp, 3600 - Number(rnd(2n)))];
    for (let i = 0; i < 40; i++) {
      const r = rnd(10n), who = rnd(BigInt(WALLETS));
      if (r < 5n) actions.push(act(K.Contribute, who, rnd(2n) === 0n ? usd(rnd(26_000n)) : rnd(30n * U)));
      else if (r < 6n) actions.push(act(K.Cancel, who, rnd(3n) === 0n ? usd(25_000) : usd(rnd(5_000n)) + rnd(U)));
      else if (r < 8n) actions.push(act(K.Warp, rnd(4n) * 3600n));
      else if (r < 9n) actions.push(act(K.Contribute, who, usd(25_000)));
      else actions.push(act(K.Donate, rnd(5n), rnd(100n) * U));
    }
    actions.push(toEnd());
    if (rnd(3n) === 0n) actions.push(act(K.Warp, SETTLE_WINDOW));
    actions.push(act(K.Settle), act(K.Fail));
    for (let i = 0; i < 12; i++) {
      const who = rnd(BigInt(WALLETS));
      actions.push(rnd(3n) === 0n ? act(K.MaterializeMany, rnd(256n)) : rnd(2n) === 0n ? act(K.Materialize, who) : act(K.Refund, who));
    }
    actions.push(act(K.MaterializeMany, 0xffn));
    sc.push({ name: `walk${seed - 0x6b00n}`, start: T0, actions });
  }
  return sc;
}

/** The canonical `KindlingEscrow` on the same contributions as scenario 1, beside the model. */
function canonicalCrossCheck() {
  const ref = new KindlingEscrow();
  const d = ref.deposit('a', 10_000n * U);
  if (d.net !== 9_700n * U || d.fee !== 300n * U) throw new Error('canonical deposit vector');
  ref.cancel('a', 4_000n * U);
  ref.settle(false);
  if (ref.refund('a') !== 6_000n * U) throw new Error('canonical refund vector');
  const m = new KindlingModel(T0);
  m.setNow(T0);
  const [net, fee] = m.contribute(0, 10_000n * U);
  if (net !== d.net || fee !== d.fee) throw new Error('model deposit differs from canonical');
  m.cancel(0, 4_000n * U);
  m.setNow(m.end); m.fail();
  if (m.refund(0)[0] !== 6_000n * U) throw new Error('model refund differs from canonical');
  // Success: the canonical escrow releases every fee, cancelled contributions' included.
  const ok = new KindlingEscrow();
  for (const id of ['a', 'b', 'c', 'd', 'e']) ok.deposit(id, 25_000n * U);
  ok.cancel('b', 5_000n * U);
  const released = ok.settle(true);
  const s = new KindlingModel(T0);
  s.setNow(T0);
  for (let i = 0; i < 5; i++) s.contribute(i, 25_000n * U);
  s.cancel(1, 5_000n * U);
  s.setNow(s.end); s.settle();
  if (s.treasury + s.keeper !== released) throw new Error('model fee release differs from canonical');
  // The opening LP, from the spec's $100 example: 97 net, 90% of the LP to contributors.
  const lp = isqrt(SEED * (s.totalNet) * 10n ** 12n) - MINIMUM_LIQUIDITY;
  if (s.liquidity !== lp) throw new Error('opening LP differs from sqrt(seed · net)');
  return { canonicalRefund: String(6_000n * U), canonicalReleased: String(released) };
}

export function kindlingVectors() {
  const cross = canonicalCrossCheck();
  const scenarios = kindlingScenarios().map(run);
  const total = scenarios.reduce((a, s) => {
    for (const [k, v] of Object.entries(s.stats.reverts)) a.reverts[k] = (a.reverts[k] ?? 0) + v;
    return { ...a, settled: a.settled + s.stats.settled, failedBelow: a.failedBelow + s.stats.failedBelow, failedTimeout: a.failedTimeout + s.stats.failedTimeout,
      refunds: a.refunds + s.stats.refunds, materialized: a.materialized + s.stats.materialized, sweeps: a.sweeps + s.stats.sweeps };
  }, { settled: 0, failedBelow: 0, failedTimeout: 0, refunds: 0, materialized: 0, sweeps: 0, reverts: {} as Record<string, number> });
  // Non-vacuity: both endings, both failure reasons, the sweep and every refusal are exercised.
  if (total.settled < 5 || total.failedBelow < 2 || total.failedTimeout < 1) throw new Error(`too few endings ${JSON.stringify(total)}`);
  if (total.refunds < 10 || total.materialized < 20 || total.sweeps < 4) throw new Error(`too few payouts ${JSON.stringify(total)}`);
  for (const why of ['NotOpen', 'BelowMinimumContribution', 'WalletCap', 'NotLive', 'BadCancel', 'TooEarly', 'SettlementExpired',
    'BelowMinimumRaise', 'StillSettleable', 'NotFailed', 'NotSettled', 'NothingOwed']) {
    if (!total.reverts[why]) throw new Error(`no scenario reverts with ${why}`);
  }
  return { version: cfg.version, seed: String(SEED), feeBps: String(FEE_BPS), ...cross, stats: total, scenarios };
}
