// Exact BigInt reference of the Hearth (docs/adr/0025-hearth.md): staked ASH earns the Vent's
// fee share through a global index per fee asset with checkpointed stake changes, written from the
// spec (§15), the ADR and the canonical config, independently of the contract. The Solidity test
// replays its scenarios on the real Hearth with mock EMBER, USDC (6 decimals), WETH and ASH, and
// compares every output, every revert and a hash of the whole state after every step.
import cfg from '../canonical/furnace.config';
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex } from '@noble/hashes/utils.js';

export class Revert extends Error {}
const need = (ok: boolean, why: string) => { if (!ok) throw new Revert(why); };

// ── the spec's figures ──
/** §15: "The 24h ASH exit cooldown is retained." */
export const COOLDOWN = 24n * 3600n;
export const PREC = 10n ** 36n;
if (cfg.execution.hearth.feeScope !== 'chainLocalFundedLiabilities') throw new Error('the model pays chain-local funded fees only');

/** The fee assets the test world binds (EMBER, USDC, WETH); index 3 is ASH, never a fee asset. */
export enum A { Ember, Usdc, Weth, Ash }
export const ASSETS = 3, WALLETS = 5;
export const ASH_EACH = 20_000n * 10n ** 18n;

interface Exit { amount: bigint; unlockAt: bigint }

export class HearthModel {
  now = 0n;
  totalStaked = 0n; totalExiting = 0n;
  stake = Array.from({ length: WALLETS }, () => 0n);
  exit: Exit[] = Array.from({ length: WALLETS }, () => ({ amount: 0n, unlockAt: 0n }));
  index = [0n, 0n, 0n]; liability = [0n, 0n, 0n]; treasuryOwed = [0n, 0n, 0n];
  paid = Array.from({ length: WALLETS }, () => [0n, 0n, 0n]);
  owed = Array.from({ length: WALLETS }, () => [0n, 0n, 0n]);
  /** Balances: the Hearth's of each asset and of ASH; each wallet's; the Treasury's. */
  held = [0n, 0n, 0n]; heldAsh = 0n;
  wallet = Array.from({ length: WALLETS }, () => [0n, 0n, 0n]);
  walletAsh = Array.from({ length: WALLETS }, () => ASH_EACH);
  treasury = [0n, 0n, 0n];

  private asset(a: number) { need(a >= 0 && a < ASSETS, 'UnknownAsset'); }
  unbooked(a: number) { return this.held[a] > this.liability[a] ? this.held[a] - this.liability[a] : 0n; }
  private bookIn(a: number, amt: bigint) {
    this.liability[a] += amt;
    if (this.totalStaked === 0n) this.treasuryOwed[a] += amt;
    else this.index[a] += (amt * PREC) / this.totalStaked;
  }
  private bookAll() { for (let a = 0; a < ASSETS; a++) { const u = this.unbooked(a); if (u !== 0n) this.bookIn(a, u); } }
  private settle(w: number) {
    for (let a = 0; a < ASSETS; a++) {
      const d = this.index[a] - this.paid[w][a];
      if (d === 0n) continue;
      if (this.stake[w] !== 0n) this.owed[w][a] += (this.stake[w] * d) / PREC;
      this.paid[w][a] = this.index[a];
    }
  }
  private pay(w: number, a: number) {
    const amt = this.owed[w][a];
    if (amt === 0n) return 0n;
    this.owed[w][a] = 0n; this.liability[a] -= amt; this.held[a] -= amt; this.wallet[w][a] += amt;
    return amt;
  }
  pending(w: number, a: number) { return this.owed[w][a] + (this.stake[w] * (this.index[a] - this.paid[w][a])) / PREC; }

  /** A fee asset (or ASH) arrives: the Vent's push, or a donation. */
  gift(a: number, amt: bigint) { if (a === A.Ash) this.heldAsh += amt; else this.held[a] += amt; }
  book(a: number) {
    this.asset(a);
    const amt = this.unbooked(a);
    need(amt !== 0n, 'NothingToBook');
    this.bookIn(a, amt);
    return amt;
  }
  claim(w: number, a: number) {
    this.asset(a);
    this.bookAll(); this.settle(w);
    const amt = this.pay(w, a);
    need(amt !== 0n, 'NothingOwed');
    return amt;
  }
  /** Returns the sum of the amounts, the replay's checksum (each asset's amount moves state). */
  claimAll(w: number) {
    this.bookAll(); this.settle(w);
    let sum = 0n;
    for (let a = 0; a < ASSETS; a++) sum += this.pay(w, a);
    return sum;
  }
  release(a: number) {
    this.asset(a);
    const amt = this.treasuryOwed[a];
    need(amt !== 0n, 'NothingOwed');
    this.treasuryOwed[a] = 0n; this.liability[a] -= amt; this.held[a] -= amt; this.treasury[a] += amt;
    return amt;
  }
  stakeIn(w: number, amt: bigint) {
    need(amt !== 0n, 'ZeroAmount');
    if (this.walletAsh[w] < amt) throw new Error('the walks never stake more than a wallet holds');
    this.bookAll(); this.settle(w);
    this.walletAsh[w] -= amt; this.heldAsh += amt; this.stake[w] += amt; this.totalStaked += amt;
    return 0n;
  }
  requestExit(w: number, amt: bigint) {
    need(amt !== 0n, 'ZeroAmount');
    need(amt <= this.stake[w], 'OverStake');
    this.bookAll(); this.settle(w);
    this.stake[w] -= amt; this.totalStaked -= amt; this.totalExiting += amt;
    this.exit[w] = { amount: this.exit[w].amount + amt, unlockAt: this.now + COOLDOWN };
    return this.now + COOLDOWN;
  }
  cancelExit(w: number) {
    const amt = this.exit[w].amount;
    need(amt !== 0n, 'NoExit');
    this.bookAll(); this.settle(w);
    this.exit[w] = { amount: 0n, unlockAt: 0n };
    this.totalExiting -= amt; this.stake[w] += amt; this.totalStaked += amt;
    return amt;
  }
  withdraw(w: number) {
    const e = this.exit[w];
    need(e.amount !== 0n, 'NoExit');
    need(this.now >= e.unlockAt, 'TooEarly');
    this.exit[w] = { amount: 0n, unlockAt: 0n };
    this.totalExiting -= e.amount; this.heldAsh -= e.amount; this.walletAsh[w] += e.amount;
    return e.amount;
  }

  /** The state the Solidity test hashes after every step, in this exact order. */
  words(): bigint[] {
    const x: bigint[] = [];
    for (let a = 0; a < ASSETS; a++) x.push(this.held[a], this.liability[a], this.index[a], this.treasuryOwed[a], this.treasury[a]);
    x.push(this.totalStaked, this.totalExiting, this.heldAsh);
    for (let w = 0; w < WALLETS; w++) {
      x.push(this.stake[w], this.exit[w].amount, this.exit[w].unlockAt, this.walletAsh[w]);
      for (let a = 0; a < ASSETS; a++) x.push(this.paid[w][a], this.owed[w][a], this.wallet[w][a]);
    }
    return x;
  }
}

// ── scenarios ──
export enum K { Warp, Gift, Book, Stake, Exit, Cancel, Withdraw, Claim, ClaimAll, Release }
/** One action: [kind, a, b]. Wallet actions take a = wallet; fee actions a = asset. */
export type Act = [K, bigint, bigint];
const act = (k: K, a: bigint | number = 0n, b: bigint | number = 0n): Act => [k, BigInt(a), BigInt(b)];
const gift = (a: A, amt: bigint) => act(K.Gift, a, amt);
const book = (a: A) => act(K.Book, a);
const stake = (w: number, amt: bigint) => act(K.Stake, w, amt);
const exit = (w: number, amt: bigint) => act(K.Exit, w, amt);
const cancel = (w: number) => act(K.Cancel, w);
const withdraw = (w: number) => act(K.Withdraw, w);
const claim = (w: number, a: A) => act(K.Claim, w, a);
const claimAll = (w: number) => act(K.ClaimAll, w);
const release = (a: A) => act(K.Release, a);
const warp = (dt: bigint) => act(K.Warp, dt);

export interface Scenario { name: string; actions: Act[] }

const hashWords = (w: bigint[]) => '0x' + bytesToHex(keccak_256(Uint8Array.from(w.flatMap((x) => {
  const h = x.toString(16).padStart(64, '0');
  return Array.from({ length: 32 }, (_, i) => parseInt(h.slice(2 * i, 2 * i + 2), 16));
}))));

/** A reverting call changes nothing: the model restores its state, as the EVM does. */
export function apply(m: HearthModel, [k, a, b]: Act): { out: bigint; why: string } {
  const saved = structuredClone({ ...m });
  try {
    let out = 0n;
    const n = Number(a);
    switch (k) {
      case K.Warp: m.now += a; break;
      case K.Gift: m.gift(n, b); break;
      case K.Book: out = m.book(n); break;
      case K.Stake: out = m.stakeIn(n, b); break;
      case K.Exit: out = m.requestExit(n, b); break;
      case K.Cancel: out = m.cancelExit(n); break;
      case K.Withdraw: out = m.withdraw(n); break;
      case K.Claim: out = m.claim(n, Number(b)); break;
      case K.ClaimAll: out = m.claimAll(n); break;
      case K.Release: out = m.release(n); break;
    }
    return { out, why: '' };
  } catch (e) {
    if (!(e instanceof Revert)) throw e;
    Object.assign(m, saved);
    return { out: 0n, why: e.message };
  }
}

function audit(m: HearthModel, at: string) {
  for (let a = 0; a < ASSETS; a++) {
    if (m.held[a] < m.liability[a]) throw new Error(`${at}: owes more than it holds`);
    let promised = m.treasuryOwed[a];
    for (let w = 0; w < WALLETS; w++) promised += m.pending(w, a);
    if (promised > m.liability[a]) throw new Error(`${at}: promised more than was booked`);
  }
  const staked = m.stake.reduce((s, x) => s + x, 0n), exiting = m.exit.reduce((s, e) => s + e.amount, 0n);
  if (staked !== m.totalStaked || exiting !== m.totalExiting) throw new Error(`${at}: totals drifted`);
  if (m.heldAsh < staked + exiting) throw new Error(`${at}: ASH not backed`);
}

function run(s: Scenario) {
  const m = new HearthModel();
  m.now = T0;
  const cols = { kind: [] as number[], a: [] as string[], b: [] as string[], why: [] as string[], out: [] as string[], hash: [] as string[] };
  const stats = { claims: 0, books: 0, stakes: 0, withdrawals: 0, toTreasury: 0, reverts: {} as Record<string, number> };
  for (const [n, x] of s.actions.entries()) {
    const owedBefore = m.treasuryOwed.reduce((t, v) => t + v, 0n);
    const r = apply(m, x);
    audit(m, `${s.name} step ${n}`);
    if (m.treasuryOwed.reduce((t, v) => t + v, 0n) > owedBefore) stats.toTreasury++;
    if (r.why !== '') stats.reverts[r.why] = (stats.reverts[r.why] ?? 0) + 1;
    else if ((x[0] === K.Claim || x[0] === K.ClaimAll) && r.out !== 0n) stats.claims++;
    else if (x[0] === K.Book) stats.books++;
    else if (x[0] === K.Stake) stats.stakes++;
    else if (x[0] === K.Withdraw) stats.withdrawals++;
    cols.kind.push(x[0]); cols.a.push(String(x[1])); cols.b.push(String(x[2]));
    cols.why.push(r.why); cols.out.push(String(r.out)); cols.hash.push(hashWords(m.words()));
  }
  return { name: s.name, ...cols, stats };
}

export const T0 = 1_800_000_000n;
const E18 = 10n ** 18n, U = 10n ** 6n, H = 3600n;

export function hearthScenarios(): Scenario[] {
  const sc: Scenario[] = [];
  // 1. A new staker cannot capture an old batch: its stake books the waiting fees to the old stake.
  sc.push({ name: 'old-batch', actions: [
    stake(0, 1000n * E18), gift(A.Ember, 50n * E18), gift(A.Usdc, 123_456_789n), stake(1, 9000n * E18),
    claim(1, A.Ember), claim(1, A.Usdc), claim(0, A.Ember), claim(0, A.Usdc), claim(0, A.Ember),
    gift(A.Ember, 10n * E18 + 1n), book(A.Ember), book(A.Ember), claim(1, A.Ember), claim(0, A.Ember), book(A.Weth),
  ] });
  // 2. A batch that arrives while nothing is staked is the Treasury's; releasing it is permissionless.
  sc.push({ name: 'treasury', actions: [
    release(A.Ember), gift(A.Ember, 7n * E18), gift(A.Weth, 3n), book(A.Ember), release(A.Ember), release(A.Ember),
    stake(2, 500n * E18), claim(2, A.Weth), release(A.Weth), gift(A.Ember, E18), claimAll(2), claim(2, A.Ember),
    exit(2, 500n * E18), gift(A.Usdc, 5n * U), book(A.Usdc), release(A.Usdc), warp(COOLDOWN), withdraw(2),
  ] });
  // 3. Exits: exiting ASH earns nothing; the cooldown restarts on a new request; cancels restake.
  sc.push({ name: 'exits', actions: [
    exit(0, 1n), exit(0, 0n), cancel(0), withdraw(0), stake(0, 0n), stake(0, 2000n * E18), stake(1, 2000n * E18),
    exit(0, 1500n * E18), exit(0, 600n * E18), gift(A.Weth, 4n * E18), book(A.Weth), warp(COOLDOWN - 1n), withdraw(0),
    exit(0, 100n * E18), warp(H), withdraw(0), warp(COOLDOWN), withdraw(0), withdraw(0), claim(0, A.Weth), claim(1, A.Weth),
    exit(1, 2000n * E18), gift(A.Weth, E18), cancel(1), gift(A.Weth, E18), claimAll(1), cancel(1), claim(0, A.Weth),
  ] });
  // 4. Six decimals beside eighteen: tiny batches over large stakes, dust, and claimAll.
  sc.push({ name: 'decimals', actions: [
    stake(0, 19_999n * E18), stake(1, 3n), stake(2, 7777n * E18 + 13n), gift(A.Usdc, 1n), book(A.Usdc), gift(A.Usdc, 999_999n),
    gift(A.Ember, 1n), claimAll(1), claimAll(0), claimAll(2), gift(A.Usdc, 10_000_000n * U), claimAll(1), claim(0, A.Usdc),
    exit(0, 19_999n * E18), gift(A.Usdc, 3n), claimAll(2), claimAll(0),
  ] });
  // 5. ASH is never a fee asset; ASH sent unasked changes no stake.
  sc.push({ name: 'not-an-asset', actions: [
    gift(A.Ash, 5n * E18), book(A.Ash), claim(0, A.Ash), release(A.Ash), stake(3, 10n * E18), gift(A.Ash, 1n),
    gift(A.Ember, 2n * E18), claimAll(3), exit(3, 10n * E18), warp(COOLDOWN), withdraw(3), claimAll(3),
  ] });
  // 6–9. Seeded walks.
  for (let seed = 0x2500n; seed < 0x2504n; seed++) {
    let x = seed;
    const rnd = (n: bigint) => { x = (x * 6364136223846793005n + 1442695040888963407n) % (1n << 64n); return (x >> 33n) % n; };
    const m = new HearthModel();
    m.now = T0;
    const actions: Act[] = [];
    for (let step = 0; step < 120; step++) {
      const r = rnd(11n), w = Number(rnd(BigInt(WALLETS))), a = Number(rnd(3n)) as A;
      let next: Act;
      if (r === 0n) next = warp(rnd(3n) === 0n ? COOLDOWN : rnd(COOLDOWN));
      else if (r === 1n || r === 2n) {
        const amt = a === A.Usdc ? rnd(10n ** 10n) + 1n : rnd(10n ** 20n) + 1n;
        next = gift(rnd(12n) === 0n ? A.Ash : a, amt);
      } else if (r === 3n) next = book(a);
      else if (r === 4n || r === 5n) {
        const want = rnd(3000n * E18) + 1n, have = m.walletAsh[w];
        next = stake(w, have === 0n ? 0n : want > have ? have : want);
      } else if (r === 6n) {
        const s = m.stake[w];
        next = exit(w, rnd(4n) === 0n || s === 0n ? rnd(100n * E18) + 1n : rnd(s) + 1n);
      } else if (r === 7n) next = rnd(2n) === 0n ? cancel(w) : withdraw(w);
      else if (r === 8n) next = claim(w, a);
      else if (r === 9n) next = claimAll(w);
      else next = release(a);
      apply(m, next);
      actions.push(next);
    }
    sc.push({ name: `walk${seed - 0x2500n}`, actions });
  }
  return sc;
}

export function hearthVectors() {
  const scenarios = hearthScenarios().map(run);
  const total = scenarios.reduce((t, s) => {
    for (const [k, v] of Object.entries(s.stats.reverts)) t.reverts[k] = (t.reverts[k] ?? 0) + v;
    return { ...t, claims: t.claims + s.stats.claims, books: t.books + s.stats.books, stakes: t.stakes + s.stats.stakes, withdrawals: t.withdrawals + s.stats.withdrawals, toTreasury: t.toTreasury + s.stats.toTreasury };
  }, { claims: 0, books: 0, stakes: 0, withdrawals: 0, toTreasury: 0, reverts: {} as Record<string, number> });
  if (total.claims < 25 || total.books < 6 || total.stakes < 15 || total.withdrawals < 4 || total.toTreasury < 2) throw new Error(`too few actions ${JSON.stringify(total)}`);
  for (const why of ['ZeroAmount', 'OverStake', 'NoExit', 'TooEarly', 'NothingToBook', 'NothingOwed', 'UnknownAsset']) {
    if (!total.reverts[why]) throw new Error(`no scenario reverts with ${why}`);
  }
  return { version: cfg.version, cooldown: String(COOLDOWN), prec: String(PREC), stats: total, scenarios };
}
