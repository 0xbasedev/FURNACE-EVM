// Exact BigInt reference of Boost's bonus formula (docs/adr/0009-capstone-boost.md): the
// Capstone part against a position's custody value, and the Pyre part from registered burns,
// in units of 1e-5 (ADR 0008). The canonical float helpers `capstoneBonus` and `pyreBoost`
// (canonical/furnace.config.ts) check it to unit precision; the integer roundings are [P].
import cfg, { capstoneBonus, pyreBoost } from '../canonical/furnace.config';
import { RAY, ray, parseUnits } from '../canonical/accounting';

export const BONUS_UNIT = 10n ** 22n;
const units = (x: number) => ray(String(x)) / BONUS_UNIT;
export const CAPSTONE_MAX_UNITS = units(cfg.forge.capstone.maxBonus);
export const RATIO_FOR_MAX = ray(String(cfg.forge.capstone.ratioForMax));
export const PYRE_TIERS = cfg.forge.pyre.tiers.map((t) => ({ burn: parseUnits(t.burnEmber, 18), units: units(t.heatBoost) }));
export const PYRE_MAX_UNITS = units(cfg.forge.pyre.maxBoost);

const ceilDiv = (a: bigint, b: bigint) => (a + b - 1n) / b;

/**
 * Capstone units: +maxBonus × min(ratio, ratioForMax) / ratioForMax, ratio = Capstone EMBER ÷
 * the custody's EMBER value (custody · rate / RAY, rate = EMBER-wei per stake-wei, RAY-scaled).
 * The value and the Capstone needed for the maximum round up, the units down: against the holder.
 */
export function capstoneUnits(capstone: bigint, custody: bigint, rate: bigint): bigint {
  const value = ceilDiv(custody * rate, RAY);
  if (capstone === 0n || value === 0n) return 0n;
  const forMax = ceilDiv(value * RATIO_FOR_MAX, RAY);
  return capstone >= forMax ? CAPSTONE_MAX_UNITS : (capstone * CAPSTONE_MAX_UNITS) / forMax;
}

/** Pyre units: every tier whose cumulative burn is reached, capped. */
export function pyreUnits(burned: bigint): bigint {
  const sum = PYRE_TIERS.reduce((n, t) => (burned >= t.burn ? n + t.units : n), 0n);
  return sum < PYRE_MAX_UNITS ? sum : PYRE_MAX_UNITS;
}

/** Checks both against the canonical float helpers; throws past one unit of difference. */
export function checkAgainstCanonical(capstone: bigint, custody: bigint, rate: bigint, burned: bigint) {
  const value = Number(custody * rate / RAY);
  const want = capstoneBonus(Number(capstone), value) * 1e5;
  const got = Number(capstoneUnits(capstone, custody, rate));
  if (value > 0 && Math.abs(got - want) > 1 + want * 1e-9) throw new Error(`capstoneUnits ${got} vs canonical ${want}`);
  const pw = pyreBoost(Number(burned / 10n ** 18n)) * 1e5, pg = Number(pyreUnits(burned)); // whole EMBER: exact as a float
  if (Math.abs(pg - pw) > 1e-6) throw new Error(`pyreUnits ${pg} vs canonical ${pw}`);
}
