// Exact BigInt reference of the epoch splitters (docs/adr/0024-epoch-splitters.md): ForgeAsh, the
// stayers' share and Quote yield (one BookedSplitter each), and the Sealed-pot stream, written from
// the spec, the ADR and the canonical config, independently of the contracts. The Solidity test
// replays its scenarios on real Forge pools (for owners and listings), real ASH (its token and
// ledger) and a mock measures source standing in for ForgeEmissions' settled epochs, and compares
// every output, every revert and a hash of the whole state after every step.
import cfg from '../canonical/furnace.config';
import { vested, parseUnits } from '../canonical/accounting';
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex } from '@noble/hashes/utils.js';

export class Revert extends Error {}
const need = (ok: boolean, why: string) => { if (!ok) throw new Revert(why); };

// ── the config's figures ──
export const EPOCH = BigInt(cfg.emissions.epochSeconds);
export const FLAT_PCT = BigInt(cfg.emissions.split.flatPct);
export const BASE_POINTS = cfg.forge.pools.map((p) => BigInt(p.allocPoints));
export const BASE_TOTAL = BASE_POINTS.reduce((a, b) => a + b, 0n);
export const ASH_POINTS = cfg.forge.pools.map((p) => BigInt(p.ashAllocPoints));
export const ASH_TOTAL = ASH_POINTS.reduce((a, b) => a + b, 0n);
export const ASH_FORGE = parseUnits(cfg.shareToken.allocations.forge, 18);
export const ASH_VESTING = BigInt(cfg.shareToken.forgeTrickleDays) * 86_400n;
export const STREAM = 30n; // [P]

/** The splitters, the tokens and the world's size. */
export enum S { ForgeAsh, Stayers, QuoteYield, SealedPot }
export enum Kind { Stake, Ordinary, Ashfall, Conviction }
export const KIND = [Kind.Ordinary, Kind.Stake, Kind.Ashfall, Kind.Conviction];
export enum Tok { Ember, Usdc, Ash }
export const POOLS = 4, IDS = 3, WALLETS = 6, EPOCHS = 6;
/** Position `id` (1-based) of pool `i` belongs to this wallet. */
export const ownerOf = (i: number, id: number) => (i * IDS + id - 1) % WALLETS;

interface PoolEpoch { done: boolean; S: bigint; W: bigint; Q: bigint; C: bigint; m: { S: bigint; W: bigint; Q: bigint; C: bigint }[] }
const key = (e: number, i: number, t: number) => `${e}/${i}/${t}`;

class Splitter {
  assigned = new Map<string, bigint>(); paid = new Map<string, bigint>(); rolled = new Set<string>(); claimed = new Set<string>();
  liability = [0n, 0n, 0n]; balance = [0n, 0n, 0n];
  constructor(readonly kind: Kind) {}
  get(m: Map<string, bigint>, k: string) { return m.get(k) ?? 0n; }
  add(m: Map<string, bigint>, k: string, v: bigint) { m.set(k, this.get(m, k) + v); }
}

export class SplitterModel {
  now = 0n;
  readonly s = [new Splitter(Kind.Ordinary), new Splitter(Kind.Stake), new Splitter(Kind.Ashfall), new Splitter(Kind.Conviction)];
  readonly epochs: PoolEpoch[][] = Array.from({ length: EPOCHS }, () => Array.from({ length: POOLS }, () => ({
    done: false, S: 0n, W: 0n, Q: 0n, C: 0n, m: Array.from({ length: IDS + 1 }, () => ({ S: 0n, W: 0n, Q: 0n, C: 0n })),
  })));
  listed = Array.from({ length: POOLS }, () => Array.from({ length: IDS + 1 }, () => false));
  wallets = Array.from({ length: WALLETS }, () => [0n, 0n, 0n]);
  /** The ledger: ASH released to ForgeAsh so far; the mock Sealed pots. */
  released = 0n; ashSupply = 0n; pot = [0n, 0n, 0n, 0n];

  constructor(readonly start: bigint) {}

  epochAt(t: bigint) { return t <= this.start ? 0n : (t - this.start) / EPOCH; }
  V(t: bigint) { return t <= this.start ? 0n : vested(ASH_FORGE, t - this.start, ASH_VESTING); }
  slice(e: number) { const s0 = this.start + BigInt(e) * EPOCH; return this.V(s0 + EPOCH) - this.V(s0); }

  budget(x: number, e: number, i: number, t: number) {
    const sp = this.s[x];
    if (x === S.ForgeAsh) return t !== Tok.Ash ? 0n : (this.slice(e) * ASH_POINTS[i]) / ASH_TOTAL + sp.get(sp.assigned, key(e, i, t));
    return sp.get(sp.assigned, key(e, i, t));
  }
  total(kind: Kind, pe: PoolEpoch) { return kind === Kind.Ashfall ? pe.Q : kind === Kind.Conviction ? pe.C : pe.S; }
  amount(kind: Kind, pe: PoolEpoch, id: number, b: bigint) {
    const m = pe.m[id];
    if (b === 0n) return 0n;
    if (kind === Kind.Stake) return pe.S === 0n ? 0n : (b * m.S) / pe.S;
    if (kind === Kind.Ashfall) return pe.Q === 0n ? 0n : (b * m.Q) / pe.Q;
    if (kind === Kind.Conviction) return pe.C === 0n ? 0n : (b * m.C) / pe.C;
    if (pe.S === 0n) return 0n;
    const flat = (b * FLAT_PCT) / 100n;
    let out = (flat * m.S) / pe.S;
    if (pe.W !== 0n) out += ((b - flat) * m.W) / pe.W;
    return out;
  }
  settled(e: number, i: number) {
    need(i < POOLS, 'UnknownPool');
    const pe = this.epochs[e]?.[i];
    need(pe !== undefined && pe.done, 'NotSettled');
    return pe!;
  }
  assign(x: number, e: number, i: number, t: number, amt: bigint) {
    if (amt === 0n) return;
    const sp = this.s[x];
    sp.add(sp.assigned, key(e, i, t), amt); sp.liability[t] += amt;
  }

  /** The mock source settles epoch `e` of pool `i` with these position measures. */
  settle(e: number, i: number, m: { S: bigint; W: bigint; Q: bigint; C: bigint }[]) {
    const pe = this.epochs[e][i];
    pe.done = true;
    for (let id = 1; id <= IDS; id++) pe.m[id] = m[id - 1];
    pe.S = m.reduce((a, x) => a + x.S, 0n); pe.W = m.reduce((a, x) => a + x.W, 0n);
    pe.Q = m.reduce((a, x) => a + x.Q, 0n); pe.C = m.reduce((a, x) => a + x.C, 0n);
  }

  private claimOne(x: number, e: number, i: number, id: number, t: number): bigint {
    const pe = this.settled(e, i), sp = this.s[x];
    if (sp.claimed.has(`${key(e, i, t)}/${id}`) || sp.rolled.has(key(e, i, t))) return 0n;
    need(!this.listed[i][id], 'Listed');
    const amt = this.amount(sp.kind, pe, id, this.budget(x, e, i, t));
    if (amt === 0n) return 0n;
    sp.claimed.add(`${key(e, i, t)}/${id}`); sp.add(sp.paid, key(e, i, t), amt);
    if (x !== S.ForgeAsh) sp.liability[t] -= amt;
    if (x === S.ForgeAsh && sp.balance[Tok.Ash] < amt) this.releaseForge();
    sp.balance[t] -= amt; this.wallets[ownerOf(i, id)][t] += amt;
    return amt;
  }
  claim(x: number, e: number, i: number, id: number, t: number) {
    const amt = this.claimOne(x, e, i, id, t);
    need(amt !== 0n, 'NothingOwed');
    return [amt, 0n];
  }
  /** A page reverts whole: check every epoch it names, in order, before paying any (mask width 8). */
  claimMany(x: number, mask: bigint, i: number, id: number, t: number) {
    const sp = this.s[x];
    const epochs = Array.from({ length: 8 }, (_, e) => e).filter((e) => (mask >> BigInt(e)) & 1n);
    for (const e of epochs) {
      this.settled(e, i);
      if (sp.claimed.has(`${key(e, i, t)}/${id}`) || sp.rolled.has(key(e, i, t))) continue;
      need(!this.listed[i][id], 'Listed');
    }
    let total = 0n;
    for (const e of epochs) total += this.claimOne(x, e, i, id, t);
    return [total, 0n];
  }
  roll(x: number, e: number, i: number, t: number) {
    const pe = this.settled(e, i), sp = this.s[x];
    need(this.total(sp.kind, pe) === 0n, 'NotEmpty');
    need(!sp.rolled.has(key(e, i, t)), 'AlreadyRolled');
    sp.rolled.add(key(e, i, t));
    const amt = this.budget(x, e, i, t);
    sp.add(sp.assigned, key(e + 1, i, t), amt);
    return [amt, 0n];
  }
  /** A token arrives at a booked splitter (the Vent's push, or a donation). */
  gift(x: number, t: number, amt: bigint) { this.s[x].balance[t] += amt; }
  book(x: number, t: number) {
    const sp = this.s[x];
    const amt = sp.balance[t] - sp.liability[t];
    need(amt !== 0n, 'NothingToBook');
    const e = Number(this.epochAt(this.now));
    let rest = amt;
    for (let i = 1; i < POOLS; i++) { const share = (amt * BASE_POINTS[i]) / BASE_TOTAL; rest -= share; this.assign(x, e, i, t, share); }
    this.assign(x, e, 0, t, rest);
    return [amt, 0n];
  }
  pull(i: number) {
    need(i < POOLS, 'UnknownPool');
    const amt = this.pot[i];
    need(amt !== 0n, 'NothingToPull');
    this.pot[i] = 0n; this.s[S.SealedPot].balance[Tok.Ember] += amt;
    const e = Number(this.epochAt(this.now)), part = amt / STREAM;
    for (let k = 0; k < Number(STREAM) - 1; k++) this.assign(S.SealedPot, e + k, i, Tok.Ember, part);
    this.assign(S.SealedPot, e + Number(STREAM) - 1, i, Tok.Ember, amt - part * (STREAM - 1n));
    return [amt, 0n];
  }
  releaseForge() {
    const due = this.V(this.now) - this.released;
    this.released += due; this.ashSupply += due; this.s[S.ForgeAsh].balance[Tok.Ash] += due;
    return [due, 0n];
  }

  /** The state the Solidity test hashes after every step, in this exact order. */
  words(): bigint[] {
    const x: bigint[] = [];
    for (let k = 0; k < 4; k++) {
      const sp = this.s[k];
      x.push(...sp.liability, ...sp.balance);
      for (let e = 0; e < EPOCHS; e++) for (let i = 0; i < POOLS; i++) for (let t = 0; t < 3; t++) {
        x.push(this.budget(k, e, i, t), sp.get(sp.paid, key(e, i, t)), sp.rolled.has(key(e, i, t)) ? 1n : 0n);
      }
    }
    for (const w of this.wallets) x.push(...w);
    x.push(this.released, this.ashSupply, ...this.pot);
    return x;
  }
}

// ── scenarios ──
export enum K { Warp, Settle, Gift, Book, Claim, ClaimMany, Roll, Pot, Pull, List, Unlist, Release }
/** One action: [kind, a, b, c]. Claims pack a = splitter | token << 4 | pool << 8 | id << 12; b = epoch (or a mask). */
export type Act = [K, bigint, bigint, bigint];
const act = (k: K, a: bigint | number = 0n, b: bigint | number = 0n, c: bigint | number = 0n): Act => [k, BigInt(a), BigInt(b), BigInt(c)];
const pk = (x: S, t: Tok, i: number, id: number) => x | (t << 4) | (i << 8) | (id << 12);
const claim = (x: S, e: number, i: number, id: number, t: Tok) => act(K.Claim, pk(x, t, i, id), e);
const many = (x: S, mask: number, i: number, id: number, t: Tok) => act(K.ClaimMany, pk(x, t, i, id), mask);
const roll = (x: S, e: number, i: number, t: Tok) => act(K.Roll, pk(x, t, i, 0), e);
/** Settle epoch e of pool i with a measure seed: `c` packs the seed; the harness derives the same measures. */
const settle = (e: number, i: number, seed: number) => act(K.Settle, e, i, seed);

/** The measures a seed gives position `id` of pool `i` in epoch `e`: deterministic, shared with the harness. */
export function measuresOf(e: number, i: number, seed: bigint) {
  const out: { S: bigint; W: bigint; Q: bigint; C: bigint }[] = [];
  for (let id = 1; id <= IDS; id++) {
    const h = BigInt('0x' + bytesToHex(keccak_256(Uint8Array.from([e, i, id, Number(seed & 0xffn), Number((seed >> 8n) & 0xffn)]))));
    // seed bit 16: an empty pool; bit 17: nobody sealed; bit 18: nobody Ashfall-eligible.
    const empty = ((seed >> 16n) & 1n) === 1n;
    const S_ = empty ? 0n : (h % 10n ** 24n) + 1n;
    const W_ = empty ? 0n : S_ + ((h >> 80n) % 10n ** 24n);
    const Q_ = empty || ((seed >> 18n) & 1n) === 1n ? 0n : (h >> 160n) % 10n ** 30n;
    const C_ = empty || ((seed >> 17n) & 1n) === 1n || id === 3 ? 0n : (h >> 120n) % 10n ** 22n;
    out.push({ S: S_, W: W_, Q: Q_, C: C_ });
  }
  return out;
}

export interface Scenario { name: string; start: bigint; actions: Act[] }

const hashWords = (w: bigint[]) => '0x' + bytesToHex(keccak_256(Uint8Array.from(w.flatMap((x) => {
  const h = x.toString(16).padStart(64, '0');
  return Array.from({ length: 32 }, (_, i) => parseInt(h.slice(2 * i, 2 * i + 2), 16));
}))));

export function apply(m: SplitterModel, [k, a, b, c]: Act): { out: bigint[]; why: string } {
  try {
    let out = [0n, 0n];
    const x = Number(a & 0xfn), t = Number((a >> 4n) & 0xfn), i = Number((a >> 8n) & 0xfn), id = Number((a >> 12n) & 0xfn);
    switch (k) {
      case K.Warp: m.now += a; break;
      case K.Settle: m.settle(Number(a), Number(b), measuresOf(Number(a), Number(b), c)); break;
      case K.Gift: m.gift(Number(a), Number(b), c); break;
      case K.Book: out = m.book(Number(a), Number(b)); break;
      case K.Claim: out = m.claim(x, Number(b), i, id, t); break;
      case K.ClaimMany: out = m.claimMany(x, b, i, id, t); break;
      case K.Roll: out = m.roll(x, Number(b), i, t); break;
      case K.Pot: m.pot[Number(a)] += b; break;
      case K.Pull: out = m.pull(Number(a)); break;
      case K.List: m.listed[Number(a)][Number(b)] = true; break;
      case K.Unlist: m.listed[Number(a)][Number(b)] = false; break;
      case K.Release: out = m.releaseForge(); break;
    }
    return { out, why: '' };
  } catch (e) {
    if (!(e instanceof Revert)) throw e;
    return { out: [0n, 0n], why: e.message };
  }
}

function audit(m: SplitterModel, at: string) {
  for (let k = 0; k < 4; k++) {
    const sp = m.s[k];
    for (let t = 0; t < 3; t++) {
      if (k !== S.ForgeAsh && sp.balance[t] < sp.liability[t]) throw new Error(`${at}: splitter ${k} owes more than it holds`);
      if (sp.balance[t] < 0n) throw new Error(`${at}: negative balance`);
    }
    for (let e = 0; e < EPOCHS; e++) for (let i = 0; i < POOLS; i++) for (let t = 0; t < 3; t++) {
      if (sp.get(sp.paid, key(e, i, t)) > m.budget(k, e, i, t)) throw new Error(`${at}: splitter ${k} paid past a budget`);
    }
  }
  if (m.released > ASH_FORGE || m.released > m.V(m.now)) throw new Error(`${at}: ASH released ahead of the curve`);
}

function run(s: Scenario) {
  const m = new SplitterModel(s.start);
  m.now = s.start - 3600n;
  const cols = { kind: [] as number[], a: [] as string[], b: [] as string[], c: [] as string[], why: [] as string[], out0: [] as string[], hash: [] as string[] };
  const stats = { claims: 0, rolls: 0, books: 0, pulls: 0, reverts: {} as Record<string, number> };
  for (const [n, x] of s.actions.entries()) {
    const r = apply(m, x);
    audit(m, `${s.name} step ${n}`);
    if (r.why !== '') stats.reverts[r.why] = (stats.reverts[r.why] ?? 0) + 1;
    else if (x[0] === K.Claim || (x[0] === K.ClaimMany && r.out[0] !== 0n)) stats.claims++;
    else if (x[0] === K.Roll) stats.rolls++;
    else if (x[0] === K.Book) stats.books++;
    else if (x[0] === K.Pull) stats.pulls++;
    cols.kind.push(x[0]); cols.a.push(String(x[1])); cols.b.push(String(x[2])); cols.c.push(String(x[3]));
    cols.why.push(r.why); cols.out0.push(String(r.out[0])); cols.hash.push(hashWords(m.words()));
  }
  return { name: s.name, start: String(s.start), ...cols, stats };
}

const T0 = 1_800_000_000n;
const D = EPOCH;
const U = 10n ** 6n, E18 = 10n ** 18n;
const all = (e: number, seed: number) => [0, 1, 2, 3].map((i) => settle(e, i, seed + i));

export function splitterScenarios(): Scenario[] {
  const sc: Scenario[] = [];
  // 1. ForgeAsh: each epoch's exact slice, by the ASH weights and the base shape; pool 3 earns none.
  sc.push({ name: 'forge-ash', start: T0, actions: [
    claim(S.ForgeAsh, 0, 0, 1, Tok.Ash), act(K.Warp, 3600 + Number(D)), ...all(0, 10),
    claim(S.ForgeAsh, 0, 0, 1, Tok.Ash), claim(S.ForgeAsh, 0, 0, 1, Tok.Ash), claim(S.ForgeAsh, 0, 1, 2, Tok.Ash), claim(S.ForgeAsh, 0, 2, 3, Tok.Ash),
    claim(S.ForgeAsh, 0, 3, 1, Tok.Ash), claim(S.ForgeAsh, 0, 0, 1, Tok.Usdc), act(K.Warp, D * 2n), ...all(1, 20), ...all(2, 30),
    many(S.ForgeAsh, 0b111, 0, 2, Tok.Ash), many(S.ForgeAsh, 0b111, 0, 2, Tok.Ash), many(S.ForgeAsh, 0b110, 2, 1, Tok.Ash), act(K.Release),
    claim(S.ForgeAsh, 2, 1, 1, Tok.Ash), claim(S.ForgeAsh, 3, 0, 1, Tok.Ash),
  ] });
  // 2. An empty pool's epoch rolls to the next; a roll is once, and only for an empty epoch.
  sc.push({ name: 'rolls', start: T0, actions: [
    act(K.Warp, 3600 + Number(D)), settle(0, 0, 1 << 16), settle(0, 1, 5), roll(S.ForgeAsh, 0, 1, Tok.Ash), roll(S.ForgeAsh, 0, 0, Tok.Ash),
    roll(S.ForgeAsh, 0, 0, Tok.Ash), claim(S.ForgeAsh, 0, 0, 1, Tok.Ash), roll(S.ForgeAsh, 1, 0, Tok.Ash), act(K.Warp, D), settle(1, 0, 7),
    claim(S.ForgeAsh, 1, 0, 1, Tok.Ash), claim(S.ForgeAsh, 1, 0, 2, Tok.Ash), claim(S.ForgeAsh, 1, 0, 3, Tok.Ash), roll(S.ForgeAsh, 1, 0, Tok.Ash),
  ] });
  // 3. The stayers' share: booked into the running epoch by the base weights, paid by stake.
  sc.push({ name: 'stayers', start: T0, actions: [
    act(K.Book, S.Stayers, Tok.Ember), act(K.Gift, S.Stayers, Tok.Ember, 1000n * E18 + 7n), act(K.Book, S.Stayers, Tok.Ember),
    act(K.Book, S.Stayers, Tok.Ember), act(K.Warp, 3600), act(K.Gift, S.Stayers, Tok.Usdc, 333_333_333n), act(K.Book, S.Stayers, Tok.Usdc),
    claim(S.Stayers, 0, 0, 1, Tok.Ember), act(K.Warp, D), act(K.Gift, S.Stayers, Tok.Ember, 5n), act(K.Book, S.Stayers, Tok.Ember),
    ...all(0, 40), claim(S.Stayers, 0, 0, 1, Tok.Ember), claim(S.Stayers, 0, 1, 1, Tok.Ember), claim(S.Stayers, 0, 3, 3, Tok.Usdc),
    claim(S.Stayers, 0, 2, 2, Tok.Usdc), claim(S.Stayers, 1, 0, 1, Tok.Ember), act(K.Warp, D), settle(1, 0, 1 << 16), roll(S.Stayers, 1, 0, Tok.Ember),
    act(K.Warp, D), settle(2, 0, 50), many(S.Stayers, 0b110, 0, 3, Tok.Ember),
  ] });
  // 4. Quote yield: only Ashfall-eligible weight earns; an epoch nobody is eligible in rolls.
  sc.push({ name: 'quote-yield', start: T0, actions: [
    act(K.Warp, 3600), act(K.Gift, S.QuoteYield, Tok.Usdc, 12_345_678n), act(K.Book, S.QuoteYield, Tok.Usdc), act(K.Warp, D),
    settle(0, 0, 60), settle(0, 1, 61 | (1 << 18)), settle(0, 2, 62), settle(0, 3, 63), claim(S.QuoteYield, 0, 1, 1, Tok.Usdc),
    roll(S.QuoteYield, 0, 1, Tok.Usdc), roll(S.QuoteYield, 0, 0, Tok.Usdc), many(S.QuoteYield, 0b1, 0, 1, Tok.Usdc), claim(S.QuoteYield, 0, 0, 2, Tok.Usdc),
    claim(S.QuoteYield, 0, 2, 3, Tok.Usdc), claim(S.QuoteYield, 0, 3, 1, Tok.Usdc), act(K.Gift, S.QuoteYield, Tok.Usdc, 1n), act(K.Book, S.QuoteYield, Tok.Usdc),
  ] });
  // 5. The Sealed pot: a pull streams over 30 epochs to running Seals; nothing to pull refuses.
  sc.push({ name: 'sealed-pot', start: T0, actions: [
    act(K.Pull, 0), act(K.Pot, 0, 3000n * E18 + 29n), act(K.Warp, 3600 + Number(D)), act(K.Pull, 0), act(K.Pull, 0), act(K.Pot, 2, 7n),
    act(K.Pull, 2), ...all(0, 70), ...all(1, 80), act(K.Warp, D * 6n), ...all(2, 90), ...all(3, 100), claim(S.SealedPot, 0, 0, 1, Tok.Ember),
    claim(S.SealedPot, 1, 0, 1, Tok.Ember), claim(S.SealedPot, 1, 0, 3, Tok.Ember), many(S.SealedPot, 0b1110, 0, 2, Tok.Ember),
    claim(S.SealedPot, 1, 2, 1, Tok.Ember), settle(4, 0, 110 | (1 << 17)), roll(S.SealedPot, 4, 0, Tok.Ember), settle(5, 0, 120),
    claim(S.SealedPot, 5, 0, 1, Tok.Ember),
  ] });
  // 6. A listed position's share waits for the sale; a claim is permissionless but pays the owner.
  sc.push({ name: 'listed', start: T0, actions: [
    act(K.Warp, 3600), act(K.Gift, S.Stayers, Tok.Ember, 100n * E18), act(K.Book, S.Stayers, Tok.Ember), act(K.Warp, D), ...all(0, 130),
    act(K.List, 0, 1), claim(S.Stayers, 0, 0, 1, Tok.Ember), claim(S.ForgeAsh, 0, 0, 1, Tok.Ash), many(S.Stayers, 0b1, 0, 1, Tok.Ember),
    act(K.Unlist, 0, 1), claim(S.Stayers, 0, 0, 1, Tok.Ember), claim(S.ForgeAsh, 0, 0, 1, Tok.Ash),
  ] });
  // 7–10. Seeded walks: every splitter, settlements, bookings, pulls, claims and rolls.
  for (let seed = 0x2400n; seed < 0x2404n; seed++) {
    let x = seed;
    const rnd = (n: bigint) => { x = (x * 6364136223846793005n + 1442695040888963407n) % (1n << 64n); return (x >> 33n) % n; };
    const actions: Act[] = [act(K.Warp, 3600)];
    const settledUpTo = [-1, -1, -1, -1];
    for (let step = 0; step < 110; step++) {
      const r = rnd(12n), i = Number(rnd(4n)), id = Number(rnd(3n)) + 1, sp = Number(rnd(4n)) as S;
      const t = sp === S.ForgeAsh ? Tok.Ash : sp === S.SealedPot ? Tok.Ember : (Number(rnd(2n)) as Tok);
      // Claims and rolls mostly name a settled epoch of their pool, now and then any epoch.
      const e = settledUpTo[i] >= 0 && rnd(5n) !== 0n ? Number(rnd(BigInt(settledUpTo[i] + 1))) : Number(rnd(BigInt(EPOCHS - 1)));
      if (r === 0n) actions.push(act(K.Warp, rnd(2n) * D + rnd(D)));
      else if (r === 1n || r === 10n) {
        const epochNow = settledUpTo[i] + 1;
        if (epochNow < EPOCHS - 1) { settledUpTo[i] = epochNow; actions.push(settle(epochNow, i, Number(rnd(1n << 19n)))); }
      } else if (r === 2n) actions.push(act(K.Gift, rnd(2n) + 1n, rnd(2n), rnd(10n ** 21n) + 1n));
      else if (r === 3n) actions.push(act(K.Book, rnd(2n) + 1n, rnd(2n)));
      else if (r === 4n) actions.push(act(K.Pot, i, rnd(10n ** 20n)));
      else if (r === 5n) actions.push(act(K.Pull, i));
      else if (r === 6n) actions.push(roll(sp, e, i, t));
      else if (r === 7n) actions.push(act(rnd(2n) === 0n ? K.List : K.Unlist, i, id));
      else if (r === 8n) actions.push(many(sp, Number(rnd(256n)), i, id, t));
      else actions.push(claim(sp, e, i, id, t));
    }
    sc.push({ name: `walk${seed - 0x2400n}`, start: T0, actions });
  }
  return sc;
}

export function splitterVectors() {
  const scenarios = splitterScenarios().map(run);
  const total = scenarios.reduce((a, s) => {
    for (const [k, v] of Object.entries(s.stats.reverts)) a.reverts[k] = (a.reverts[k] ?? 0) + v;
    return { ...a, claims: a.claims + s.stats.claims, rolls: a.rolls + s.stats.rolls, books: a.books + s.stats.books, pulls: a.pulls + s.stats.pulls };
  }, { claims: 0, rolls: 0, books: 0, pulls: 0, reverts: {} as Record<string, number> });
  if (total.claims < 25 || total.rolls < 4 || total.books < 6 || total.pulls < 3) throw new Error(`too few actions ${JSON.stringify(total)}`);
  for (const why of ['NotSettled', 'NotEmpty', 'AlreadyRolled', 'Listed', 'NothingOwed', 'NothingToBook', 'NothingToPull']) {
    if (!total.reverts[why]) throw new Error(`no scenario reverts with ${why}`);
  }
  return { version: cfg.version, epoch: String(EPOCH), stream: String(STREAM), stats: total, scenarios };
}
