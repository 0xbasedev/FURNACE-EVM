// Integer reference for the base emission schedule (spec v5.5 §1: "a production
// fixed-point schedule evaluator must match its pinned test vectors").
// v5.5 ships only a float helper (baseEmissionPerDay), so this repo defines the
// integer evaluator and pins its vectors. See docs/adr/0002-exact-emission-schedule.md.
//
//   F[r] = floor(1e18 · 2^(−r/H))        r = 0..H−1 (H = halfLifeDays)
//          i.e. the largest x with x^H · 2^r ≤ 10^(18·H)   (exact, no floats)
//   q = ⌊day / H⌋, r = day mod H
//   curve(day) = ⌊START · F[r] / 1e18⌋ >> q   (nested floors commute: ⌊⌊x/a⌋/b⌋ = ⌊x/ab⌋,
//                                              so divide/shift order cannot change the result)
//   emission(day) = max(FLOOR, curve(day))
import cfg from '../canonical/furnace.config';

const WAD = 10n ** 18n;
export const HALF_LIFE = BigInt(cfg.emissions.base.halfLifeDays);
export const START = BigInt(cfg.emissions.base.startPerDay) * WAD;
export const FLOOR = BigInt(cfg.emissions.base.floorPerDay) * WAD;

function factor(r: bigint): bigint {
  // Largest x in [0, 1e18] with x^H · 2^r ≤ 10^(18H).
  const bound = 10n ** (18n * HALF_LIFE);
  const ok = (x: bigint) => x ** HALF_LIFE * (1n << r) <= bound;
  // Bracket the answer around the float estimate (widening until the bracket is proven),
  // then binary-search inside it: the same exact result in far fewer big powers.
  const est = BigInt(Math.floor(1e18 * 2 ** (-Number(r) / Number(HALF_LIFE))));
  let lo = 0n;
  let hi = WAD;
  for (let span = 1n << 12n; span < WAD; span <<= 8n) {
    const a = est > span ? est - span : 0n;
    const b = est + span < WAD ? est + span : WAD;
    if (ok(a) && (b === WAD || !ok(b))) { lo = a; hi = b; break; }
  }
  while (lo < hi) {
    const mid = (lo + hi + 1n) / 2n;
    if (ok(mid)) lo = mid;
    else hi = mid - 1n;
  }
  return lo;
}

let table: bigint[] | undefined;
export function factorTable(): bigint[] {
  table ??= Array.from({ length: Number(HALF_LIFE) }, (_, r) => factor(BigInt(r)));
  return table;
}

export function emissionPerDay(day: bigint): bigint {
  if (day < 0n) throw new RangeError('day must be ≥ 0');
  const q = day / HALF_LIFE;
  const r = day % HALF_LIFE;
  const curve = q >= 256n ? 0n : ((START * factorTable()[Number(r)]) / WAD) >> q;
  return curve > FLOOR ? curve : FLOOR;
}
