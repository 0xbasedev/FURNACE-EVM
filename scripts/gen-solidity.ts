// pnpm gen — derives Solidity constants and differential test vectors from the
// canonical package (canonical/furnace.config.ts + canonical/accounting.ts).
// Contracts never hand-copy a protocol number.
//   contracts/src/generated/FurnaceParams.sol    constants + MINED registry addresses
//   contracts/src/generated/ScheduleTable.sol    exact half-life factor table
//   contracts/test/fixtures/oracle-vectors.json  reference values
//   contracts/test/fixtures/forge-vectors.json   ForgePool scenarios (scripts/forge-scenarios.ts)
//   contracts/test/fixtures/settlement-vectors.json  settlement scenarios (scripts/settlement-scenarios.ts)
// Integer references (accounting.ts, BigInt) are matched EXACTLY by the Solidity
// ports; the float display helper heatMultiplier within 1e-12.
// pnpm gen --check exits non-zero if either output is stale (CI gate).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import cfg, { CREATEX_FACTORY, heatMultiplier, baseEmissionPerDay } from '../canonical/furnace.config';
import { emissionPerDay, factorTable, HALF_LIFE } from './schedule';
import {
  RAY, AGE_CAP, ray, parseUnits, heatPrimitive, integrateHeat, cooledAge, deedAge,
  allocateMint, accruedPoolBudget, vested, DAY as DAY_N,
} from '../canonical/accounting';
import { canonicalize, keccakHex } from './canonical';
import { forgeVectors } from './forge-scenarios';
import { settlementVectors } from './settlement-scenarios';
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex } from '@noble/hashes/utils.js';

const PARAMS = 'contracts/src/generated/FurnaceParams.sol';
const SCHEDULE = 'contracts/src/generated/ScheduleTable.sol';
const VECTORS = 'contracts/test/fixtures/oracle-vectors.json';
const FORGE_VECTORS = 'contracts/test/fixtures/forge-vectors.json';
const SETTLEMENT_VECTORS = 'contracts/test/fixtures/settlement-vectors.json';
const DAY = 86_400n;

/** Exact decimal → fixed-point integer string (shortest round-trip, never toFixed noise). */
const fixed = (x: number | string, decimals: number) => {
  const s = typeof x === 'number' ? (/e/i.test(String(x)) ? x.toFixed(decimals) : String(x)) : x;
  return parseUnits(s, decimals).toString();
};

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
// The Mantle issues the full GLOBAL target; chain shares are routed out of the distributor's
// budget, never applied as a mint-side multiplier (an immutable Mantle must not under-issue
// if a later config lowers the home share). Guard the share table here instead.
const home = cfg.chains.find((ch) => ch.role === 'home' && ch.enabled);
if (!home || home.key !== cfg.emissions.controllerChain) throw new Error('home chain must be the enabled emissions controller');
const shareSum = cfg.chains.filter((ch) => ch.enabled).reduce((n, ch) => n + ch.fixedEmissionSharePct, 0);
if (shareSum !== 100) throw new Error(`enabled chain emission shares must sum to 100, got ${shareSum}`);

section('Ashfall (burn recycling, one-epoch lag)');
const ash = cfg.emissions.ashfall;
if (ash.lagEpochs !== 1) throw new Error('Mantle implements a one-epoch Ashfall lag');
c('uint256', 'ASHFALL_LAG_EPOCHS', ash.lagEpochs);
c('uint256', 'RECYCLE_PROTOCOL_BURN_PCT', ash.recycleRates.protocolBurns);
c('uint256', 'RECYCLE_PYRE_BURN_PCT', ash.recycleRates.pyreBurns);
c('uint256', 'RECYCLE_UNSOLICITED_PCT', ash.recycleRates.unsolicited, 'unregistered burns are never recognized');

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

section('Forge custody: fees, cooling plans, emergency exit (spec v5.5 §4, §11)');
// ForgePool implements exactly these policies; fail generation if the config selects another.
const wd = cfg.cooldowns.withdraw;
const ex = cfg.execution.withdrawals;
const policy: [string, unknown, unknown][] = [
  ['cooldowns.withdraw.earnsWhileCooling', wd.earnsWhileCooling, false],
  ['cooldowns.withdraw.onCancelOrLapse', wd.onCancelOrLapse, 'resumeFrozen'],
  ['forge.cancelReturnsAsFreshLot', f.cancelReturnsAsFreshLot, false],
  ['forge.heat.withdrawCooling', f.heat.withdrawCooling, 'proportional'],
  ['forge.withdrawResetsStreak', f.withdrawResetsStreak, true],
  ['execution.withdrawals.aggregation', ex.aggregation, 'frozenReferenceCumulativeRequests'],
  ['execution.withdrawals.cancelConsumesPlanQuota', ex.cancelConsumesPlanQuota, true],
  ['execution.withdrawals.freeze', ex.freeze, 'requestedSlice'],
  ['execution.withdrawals.lapse', ex.lapse, 'resumeFrozen'],
  ['execution.withdrawals.exitAsset', ex.exitAsset, 'inKind'],
  ['execution.withdrawals.exitRequiresOracle', ex.exitRequiresOracle, false],
  ['forge.emergencyExit.enabled', f.emergencyExit.enabled, true],
];
for (const [path, got, want] of policy) if (got !== want) throw new Error(`ForgePool implements ${path} = ${String(want)}, config has ${String(got)}`);
wd.tiers.forEach((t, i) => {
  const prev = wd.tiers[i - 1];
  if (prev && !(t.maxWithdrawPct > prev.maxWithdrawPct && t.seconds > prev.seconds)) throw new Error('withdraw tiers must ascend');
});
if (wd.tiers[wd.tiers.length - 1].maxWithdrawPct !== 100) throw new Error('last withdraw tier must cover 100%');
if (wd.tiers.length !== 5) throw new Error('ForgePool._tier unrolls exactly 5 withdraw tiers');
if (ex.planHorizonSeconds < wd.tiers[wd.tiers.length - 1].seconds) throw new Error('plan horizon shorter than the longest tier');
c('uint256', 'FORGE_DEPOSIT_FEE_PCT', f.fees.depositPct);
c('uint256', 'FORGE_WITHDRAW_FEE_PCT', f.fees.withdrawPct);
c('uint256', 'EMERGENCY_EXIT_FEE_PCT', f.emergencyExit.feePct);
c('uint256', 'MIN_STAKE_LP', parseUnits(f.minStakeLp, 18), `${f.minStakeLp} LP`);
c('uint256', 'WITHDRAW_TIER_COUNT', wd.tiers.length);
wd.tiers.forEach((t, i) => {
  c('uint256', `WITHDRAW_TIER_${i}_MAX_PCT`, t.maxWithdrawPct);
  c('uint256', `WITHDRAW_TIER_${i}_SECONDS`, t.seconds);
});
c('uint256', 'WITHDRAW_EXECUTION_WINDOW', wd.executionWindowSeconds);
c('uint256', 'COOLING_PLAN_HORIZON', ex.planHorizonSeconds);
c('uint256', 'ASHFALL_MIN_PARTICIPATION', `${cfg.execution.ashfall.minimumParticipationDays} days`, 'actual participation, stored saturating here');

section('Base epoch settlement: pools, pages, claims (spec v5.5 §4, §10, §11)');
const st = cfg.execution.settlement;
const settlementPolicy: [string, unknown, unknown][] = [
  ['execution.settlement.weightBasis', st.weightBasis, 'timeIntegratedPerLot'],
  ['execution.settlement.budgetAccrual', st.budgetAccrual, 'onlyWhilePoolHasActiveStake'],
  ['execution.settlement.aggregateAuthority', st.aggregateAuthority, 'onchainCheckpoints'],
  ['execution.settlement.exitsDependOnSettlement', st.exitsDependOnSettlement, false],
  ['cooldowns.claim.snapshotAtRequest', cfg.cooldowns.claim.snapshotAtRequest, true],
];
for (const [path, got, want] of settlementPolicy) if (got !== want) throw new Error(`ForgeEmissions implements ${path} = ${String(want)}, config has ${String(got)}`);
if (f.pools.length !== 4) throw new Error('ForgeEmissions binds exactly 4 pools');
const allocTotal = f.pools.reduce((n, pool) => n + pool.allocPoints, 0);
if (allocTotal === 0) throw new Error('pool alloc points must not all be zero');
c('uint256', 'SETTLEMENT_MAX_LOTS_PER_PAGE', st.maxLotsPerPage);
c('uint256', 'CLAIM_SECONDS', cfg.cooldowns.claim.seconds);
c('uint256', 'FORGE_POOL_COUNT', f.pools.length);
c('uint256', 'FORGE_ALLOC_POINTS_TOTAL', allocTotal);
f.pools.forEach((pool, i) => {
  c('uint256', `FORGE_POOL_${i}_ALLOC_POINTS`, pool.allocPoints, pool.id);
  c('bool', `FORGE_POOL_${i}_IS_LP`, String(pool.stakeKind === 'lp'));
});

section('Seals: Conviction tracks, escrow and forfeiture (spec v5.5 §10)');
const ct = f.convictionTracks;
const se = cfg.execution.seals;
const sealPolicy: [string, unknown, unknown][] = [
  ['forge.convictionTracks.enabled', ct.enabled, true],
  ['forge.convictionTracks.vestAtTermEnd', ct.vestAtTermEnd, true],
  ['forge.convictionTracks.bucketCap.enabled', ct.bucketCap.enabled, true],
  ['forge.convictionTracks.bucketCap.capToSealBonusOfHeatShare', ct.bucketCap.capToSealBonusOfHeatShare, true],
  ['forge.convictionTracks.bucketCap.unallocatedFlowsTo', ct.bucketCap.unallocatedFlowsTo, 'heatPool'],
  ['forge.convictionTracks.escrow.enabled', ct.escrow.enabled, true],
  ['forge.convictionTracks.escrow.payout', ct.escrow.payout, 'capstone'],
  ['execution.seals.membership', se.membership, 'sealedCohortsOnly'],
  ['execution.seals.topupsJoinExistingSeal', se.topupsJoinExistingSeal, false],
  ['execution.seals.pendingCooling', se.pendingCooling, 'pauseSealAccrualAndExtendEnd'],
  ['execution.seals.tapBeforeMaturity', se.tapBeforeMaturity, 'forfeitUnvestedBonus'],
];
for (const [path, got, want] of sealPolicy) if (got !== want) throw new Error(`Seals implement ${path} = ${String(want)}, config has ${String(got)}`);
if (ct.tracks.length !== 4) throw new Error('ForgePool._track unrolls exactly 4 Seal tracks');
ct.tracks.forEach((t, i) => {
  const prev = ct.tracks[i - 1];
  if (prev && !(t.days > prev.days && t.bonus > prev.bonus)) throw new Error('Seal tracks must ascend');
  if (ray(String(t.bonus)) > ray('0.5')) throw new Error('Seal bonus exceeds the canonical 0.5 ceiling');
});
const fr = ct.forfeitRouting;
if (fr.burnPct + fr.matchReservePct + fr.sealedPotPct !== 100) throw new Error('Seal forfeit routing must sum to 100');
c('uint256', 'SEAL_TRACK_COUNT', ct.tracks.length);
ct.tracks.forEach((t, i) => {
  c('uint256', `SEAL_TRACK_${i}_SECONDS`, `${t.days} days`, t.name);
  c('uint256', `SEAL_TRACK_${i}_BONUS_RAY`, ray(String(t.bonus)), `+${t.bonus}`);
});
c('uint256', 'SEAL_FORFEIT_BURN_PCT', fr.burnPct);
c('uint256', 'SEAL_FORFEIT_MATCH_RESERVE_PCT', fr.matchReservePct);
c('uint256', 'SEAL_FORFEIT_SEALED_POT_PCT', fr.sealedPotPct);

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

// ── ScheduleTable.sol (exact half-life factors, see scripts/schedule.ts) ──
const F = factorTable();
const scheduleSol = `// SPDX-License-Identifier: MIT
// AUTO-GENERATED by \`pnpm gen\` from scripts/schedule.ts. DO NOT EDIT.
pragma solidity 0.8.28;

/// @notice F[r] = floor(1e18 · 2^(−r/${HALF_LIFE})) for r = 0..${HALF_LIFE - 1n}, exact (integer ${HALF_LIFE}th root).
///         ${F.length} big-endian uint64 entries. See docs/adr/0002-exact-emission-schedule.md.
library ScheduleTable {
    uint256 internal constant LENGTH = ${F.length};
    bytes internal constant TABLE =
        hex"${F.map((x) => x.toString(16).padStart(16, '0')).join('')}";

    /// @dev r must be < LENGTH (callers pass day % LENGTH).
    function factor(uint256 r) internal pure returns (uint256 f) {
        bytes memory t = TABLE;
        assembly ("memory-safe") {
            f := shr(192, mload(add(add(t, 32), mul(r, 8))))
        }
    }
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
const vestTotal = parseUnits(cfg.token.allocations.treasury.amount, 18);
const vestDuration = BigInt(cfg.token.allocations.treasury.vestingDays) * DAY_N;
const vestElapsed = [0n, 1n, 59n, DAY_N, 7n * DAY_N, vestDuration / 2n, vestDuration - 1n, vestDuration, vestDuration + 1n, 10n * vestDuration,
  ...Array.from({ length: 16 }, () => rnd(vestDuration + DAY_N))];
const emissionDays = [...Array.from({ length: 1701 }, (_, d) => d), 2000, 5000, 9124, 9125, 100000, 1000000];
// Sanity: the exact schedule tracks v5.5's float helper to float precision.
for (const d of emissionDays) {
  const exact = Number(emissionPerDay(BigInt(d)));
  const float = baseEmissionPerDay(d) * 1e18;
  if (Math.abs(exact - float) / float > 1e-12) throw new Error(`schedule diverges from float oracle at day ${d}`);
}
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
  vesting: { elapsed: S(vestElapsed), out: S(vestElapsed.map((t) => vested(vestTotal, t, vestDuration))) },
  poolBudget: { target: S(budgets.map((x) => x.target)), occupied: S(budgets.map((x) => x.occ)), out: S(budgets.map((x) => x.out)) },
  // Float display helper (no integer reference exists): compared within 1e-12 relative.
  lotHeat: { ageSeconds: heatDays.map((d) => String(Math.round(d * 86_400))), ray: heatDays.map((d) => fixed(heatMultiplier(Math.round(d * 86_400) / 86_400), 27)) },
  // Exact integer schedule (scripts/schedule.ts): every day 0..1700 plus far-out days.
  emission: { day: emissionDays.map(String), wad: emissionDays.map((d) => emissionPerDay(BigInt(d)).toString()) },
};
const vectorsJson = JSON.stringify(vectors, null, 2) + '\n';

// ── write or check ───────────────────────────────────────────────────────
const outputs: [string, string][] = [[PARAMS, params], [SCHEDULE, scheduleSol], [VECTORS, vectorsJson], [FORGE_VECTORS, JSON.stringify(forgeVectors(), null, 1) + '\n'], [SETTLEMENT_VECTORS, JSON.stringify(settlementVectors(), null, 1) + '\n']];
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
