// pnpm gen — derives Solidity constants and differential test vectors from the
// canonical package (canonical/furnace.config.ts + canonical/accounting.ts).
// Contracts never hand-copy a protocol number.
//   contracts/src/generated/FurnaceParams.sol    constants + MINED registry addresses
//   contracts/test/fixtures/oracle-vectors.json  reference values
// Integer references (accounting.ts, BigInt) are matched EXACTLY by the Solidity
// ports; float display helpers (heatMultiplier, baseEmissionPerDay) within 1e-12.
// pnpm gen --check exits non-zero if either output is stale (CI gate).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import cfg, { CREATEX_FACTORY, heatMultiplier, baseEmissionPerDay } from '../canonical/furnace.config';
import {
  RAY, AGE_CAP, ray, parseUnits, heatPrimitive, integrateHeat, cooledAge, deedAge,
  allocateMint, accruedPoolBudget,
} from '../canonical/accounting';
import { canonicalize, keccakHex } from './canonical';
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex } from '@noble/hashes/utils.js';

const PARAMS = 'contracts/src/generated/FurnaceParams.sol';
const VECTORS = 'contracts/test/fixtures/oracle-vectors.json';
const DAY = 86_400n;

/** Exact decimal → fixed-point integer string (shortest round-trip, never toFixed noise). */
const fixed = (x: number | string, decimals: number) => {
  const s = typeof x === 'number' ? (/e/i.test(String(x)) ? x.toFixed(decimals) : String(x)) : x;
  return parseUnits(s, decimals).toString();
};
const wadF = (x: number) => fixed(x, 18);

function checksum(addr: string): string {
  const lower = addr.slice(2).toLowerCase();
  const h = bytesToHex(keccak_256(new TextEncoder().encode(lower)));
  return '0x' + [...lower].map((ch, i) => (parseInt(h[i], 16) >= 8 ? ch.toUpperCase() : ch)).join('');
}

const f = cfg.forge;
const milestones = f.relics.filter((r) => r.heatBump > 0).sort((a, b) => a.days - b.days);
if (RAY !== 10n ** 27n) throw new Error('settlement.multiplierScale must be 1e27');
if (f.heat.shape !== 'sqrt') throw new Error('generator supports sqrt Heat only');
if (cfg.emissions.base.shape !== 'halfLife') throw new Error('generator supports halfLife emissions only');
if (cfg.token.maxSupply !== cfg.emissions.supplyCeiling.hardCap) throw new Error('maxSupply ≠ hardCap');
if (cfg.token.decimals.evm !== 18) throw new Error('EMBER must have 18 EVM decimals');

// ── FurnaceParams.sol ────────────────────────────────────────────────────
const lines: string[] = [];
const c = (type: string, name: string, value: string | number | bigint, note = '') =>
  lines.push(`    ${type} internal constant ${name} = ${value};${note ? ' // ' + note : ''}`);
const section = (title: string) => lines.push('', `    // ── ${title} ──`);

c('bytes32', 'CONFIG_HASH', keccakHex(canonicalize(cfg)), `canonical/furnace.config.ts v${cfg.version}`);

section('EMBER supply (live-supply ceiling, not cumulative)');
c('string', 'EMBER_NAME', JSON.stringify(cfg.token.name));
c('string', 'EMBER_SYMBOL', JSON.stringify(cfg.token.symbol));
c('uint256', 'EMBER_MAX_SUPPLY', `${cfg.token.maxSupply}e18`);
c('uint256', 'EMBER_KINDLING_SEED', `${cfg.token.allocations.kindlingPool}e18`);
c('uint256', 'EMBER_TREASURY_ALLOCATION', `${cfg.token.allocations.treasury.amount}e18`);
c('uint256', 'EMBER_TREASURY_VESTING', `${cfg.token.allocations.treasury.vestingDays} days`);

section('Emissions and base-epoch settlement (spec v5.5 §settlement)');
c('uint256', 'EPOCH_SECONDS', cfg.emissions.epochSeconds);
c('uint256', 'EMISSION_START_PER_DAY', `${cfg.emissions.base.startPerDay}e18`);
c('uint256', 'EMISSION_FLOOR_PER_DAY', `${cfg.emissions.base.floorPerDay}e18`);
c('uint256', 'EMISSION_HALF_LIFE_DAYS', cfg.emissions.base.halfLifeDays);
c('uint256', 'CONVICTION_BUCKET_PCT', cfg.emissions.convictionBucketPct);
c('uint256', 'SPLIT_FLAT_PCT', cfg.emissions.split.flatPct);

section('Heat, RAY (1e27) scale; ages in seconds');
c('uint256', 'RAY', '1e27');
c('uint256', 'HEAT_START_RAY', ray(String(f.heat.startMultiplier)));
c('uint256', 'HEAT_RAMP_BONUS_RAY', ray(String(f.heat.rampBonus)));
c('uint256', 'HEAT_AGE_CAP', `${f.heat.rampDays} days`);
c('uint256', 'HEAT_CORE_CAP_RAY', ray(String(f.heat.startMultiplier)) + ray(String(f.heat.rampBonus)) + milestones.reduce((n, m) => n + ray(String(m.heatBump)), 0n));
c('uint256', 'MAX_ORDINARY_BONUS_RAY', ray('0.65'), 'Capstone 0.5 + Pyre 0.15');
c('uint256', 'MAX_LOTS_PER_POSITION', f.heat.maxLotsPerPosition);
c('uint256', 'MILESTONE_COUNT', milestones.length);
milestones.forEach((m, i) => {
  c('uint256', `MILESTONE_${i}_SECONDS`, `${m.days} days`, m.key);
  c('uint256', `MILESTONE_${i}_BUMP_RAY`, ray(String(m.heatBump)));
});
c('uint256', 'DEED_HEAT_CARRY_PCT', f.deeds.heatCarryPct);

section(`Deterministic deployment registry (CREATE3). PROVISIONAL while the deployer is ${cfg.deployment.evm.deployer}`);
lines.push('    //    Only MINED entries become constants; unmined modules are constructor/initializer inputs.');
c('address', 'CREATEX', CREATEX_FACTORY);
const unmined: string[] = [];
for (const [name, entry] of Object.entries<any>(cfg.deployment.evm.contracts)) {
  const constName = name.replace(/([a-z])([A-Z])/g, '$1_$2').toUpperCase();
  if (entry.address == null) { unmined.push(name); continue; }
  c('address', constName, checksum(entry.address));
}
lines.push(`    // unmined: ${unmined.join(', ')}`);

const params = `// SPDX-License-Identifier: MIT
// AUTO-GENERATED by \`pnpm gen\` from canonical/furnace.config.ts v${cfg.version}. DO NOT EDIT.
pragma solidity 0.8.28;

/// @notice Protocol constants derived from the canonical config. Contracts read
///         these instead of hard-coding numbers; \`pnpm gen --check\` fails CI if stale.
library FurnaceParams {
${lines.join('\n')}
}
`;

// ── Oracle vectors ───────────────────────────────────────────────────────
// Deterministic sample: edges around every milestone and the cap, plus a seeded spread.
let seed = 0x5eedn;
const rnd = (max: bigint) => { seed = (seed * 6364136223846793005n + 1442695040888963407n) & ((1n << 64n) - 1n); return seed % max; };
const edges = [0n, 1n, 59n, 3_600n, DAY, ...milestones.flatMap((m) => { const t = BigInt(m.days) * DAY; return [t - 1n, t, t + 1n]; }), AGE_CAP + DAY, 2n * AGE_CAP, 10n * AGE_CAP];
const ages = [...new Set([...edges, ...Array.from({ length: 24 }, () => rnd(AGE_CAP + 30n * DAY))])].sort((a, b) => (a < b ? -1 : 1));
const S = (xs: bigint[]) => xs.map(String);

const integ = Array.from({ length: 32 }, (_, i) => {
  const age = i < 4 ? [0n, AGE_CAP - DAY, AGE_CAP, 3n * AGE_CAP][i] : rnd(AGE_CAP + 60n * DAY);
  const active = i % 5 === 0 ? DAY : rnd(40n * DAY) + 1n;
  const bonus = i % 3 === 0 ? 0n : rnd(ray('0.65') + 1n);
  return { age, active, bonus, out: integrateHeat(age, active, bonus) };
});
const cools = Array.from({ length: 24 }, (_, i) => {
  const age = i === 0 ? 2n * AGE_CAP : rnd(AGE_CAP * 2n);
  const ref = rnd(10n ** 30n) + 1n;
  const withdrawn = i === 1 ? ref : i === 2 ? 0n : rnd(ref + 1n);
  return { age, ref, withdrawn, out: cooledAge(age, withdrawn, ref) };
});
const cap = parseUnits(cfg.token.maxSupply, 18);
const mints = [
  [cap - parseUnits('90', 18), 0n, parseUnits('100', 18), parseUnits('50', 18)],
  [parseUnits('420000', 18), 0n, parseUnits('21600', 18), 0n],
  [parseUnits('20990000', 18), parseUnits('4000', 18), parseUnits('21600', 18), parseUnits('5000', 18)],
  [cap, 0n, parseUnits('1000', 18), parseUnits('1000', 18)],
  [cap - 7n, 0n, 3n, 5n],
  [0n, 0n, 0n, 0n],
  ...Array.from({ length: 12 }, () => [rnd(cap + 1n), rnd(parseUnits('1000000', 18)), rnd(parseUnits('30000', 18)), rnd(parseUnits('30000', 18))]),
].map(([acc, res, b, a]) => ({ acc, res, b, a, out: allocateMint(cap, acc, res, b, a) }));
const budgets = Array.from({ length: 12 }, (_, i) => {
  const target = rnd(parseUnits('21600', 18)) + 1n;
  const occ = i === 0 ? 0n : i === 1 ? DAY : rnd(DAY + 1n);
  return { target, occ, out: accruedPoolBudget(target, occ, DAY) };
});
const emissionDays = [0, 1, 30, 182, 364, 365, 366, 730, 1095, 1617, 1618, 1619, 1700, 5000];
const heatDays = [0, 0.5, 1, 6.999, 7, 7.001, 15, 30, 60, 90, 135, 180, 250, 364.9, 365, 400, 730];

const vectors = {
  version: cfg.version,
  primitive: { ageSeconds: S(ages), ray: S(ages.map(heatPrimitive)) },
  integrate: { ageSeconds: S(integ.map((x) => x.age)), activeSeconds: S(integ.map((x) => x.active)), bonusRay: S(integ.map((x) => x.bonus)), ray: S(integ.map((x) => x.out)) },
  cool: { ageSeconds: S(cools.map((x) => x.age)), withdrawn: S(cools.map((x) => x.withdrawn)), reference: S(cools.map((x) => x.ref)), out: S(cools.map((x) => x.out)) },
  deed: { ageSeconds: S(ages), out: S(ages.map(deedAge)) },
  mint: {
    accounted: S(mints.map((m) => m.acc)), reserved: S(mints.map((m) => m.res)), base: S(mints.map((m) => m.b)), ashfall: S(mints.map((m) => m.a)),
    outBase: S(mints.map((m) => m.out.base)), outAshfall: S(mints.map((m) => m.out.ashfall)), outResidue: S(mints.map((m) => m.out.unmintedResidue)),
  },
  poolBudget: { target: S(budgets.map((x) => x.target)), occupied: S(budgets.map((x) => x.occ)), out: S(budgets.map((x) => x.out)) },
  // Float display helpers (no integer reference exists): compared within 1e-12 relative.
  lotHeat: { ageSeconds: heatDays.map((d) => String(Math.round(d * 86_400))), ray: heatDays.map((d) => fixed(heatMultiplier(Math.round(d * 86_400) / 86_400), 27)) },
  emission: { day: emissionDays.map(String), wad: emissionDays.map((d) => wadF(baseEmissionPerDay(d))) },
};
const vectorsJson = JSON.stringify(vectors, null, 2) + '\n';

// ── write or check ───────────────────────────────────────────────────────
const outputs: [string, string][] = [[PARAMS, params], [VECTORS, vectorsJson]];
if (process.argv.includes('--check')) {
  let stale = 0;
  for (const [p, body] of outputs) {
    let cur = '';
    try { cur = readFileSync(p, 'utf8'); } catch { /* missing */ }
    const ok = cur === body;
    if (!ok) stale++;
    console.log(`${ok ? '✓' : '✗'} ${p}${ok ? '' : ' is stale — run pnpm gen'}`);
  }
  process.exit(stale ? 1 : 0);
}
for (const [p, body] of outputs) { mkdirSync(dirname(p), { recursive: true }); writeFileSync(p, body); console.log(`wrote ${p}`); }
