// pnpm gen — derives Solidity constants and differential test vectors from the
// canonical package (canonical/furnace.config.ts + canonical/accounting.ts).
// Contracts never hand-copy a protocol number.
//   contracts/src/generated/FurnaceParams.sol    constants + MINED registry addresses
//   contracts/src/generated/ScheduleTable.sol    exact half-life factor table
//   contracts/test/fixtures/oracle-vectors.json  reference values
//   contracts/test/fixtures/forge-vectors.json   ForgePool scenarios (scripts/forge-scenarios.ts)
//   contracts/test/fixtures/settlement-vectors.json  settlement scenarios (scripts/settlement-scenarios.ts)
//   contracts/test/fixtures/pair-vectors.json    EmberPair scenarios (scripts/pair-model.ts)
//   contracts/test/fixtures/flow-vectors.json    Flow zap scenarios (scripts/flow-model.ts)
//   contracts/test/fixtures/vent-vectors.json    Vent scenarios (scripts/vent-model.ts)
//   contracts/test/fixtures/kindling-vectors.json Kindling scenarios (scripts/kindling-model.ts)
//   contracts/test/fixtures/ignition-vectors.json Ignition scenarios (scripts/ignition-model.ts)
// Integer references (accounting.ts, BigInt) are matched EXACTLY by the Solidity
// ports; the float display helper heatMultiplier within 1e-12.
// pnpm gen --check exits non-zero if either output is stale (CI gate).
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import cfg, { CREATEX_FACTORY, heatMultiplier, baseEmissionPerDay } from '../canonical/furnace.config';
import { emissionPerDay, factorTable, HALF_LIFE } from './schedule';
import {
  RAY, AGE_CAP, ray, parseUnits, heatPrimitive, integrateHeat, cooledAge, deedAge,
  allocateMint, accruedPoolBudget, vested, DAY as DAY_N, isqrt, squaredHeatPrimitive, integrateSquaredHeat,
} from '../canonical/accounting';
import { canonicalize, keccakHex } from './canonical';
import { forgeVectors } from './forge-scenarios';
import { settlementVectors } from './settlement-scenarios';
import { capstoneUnits, pyreUnits, checkAgainstCanonical, PYRE_TIERS, RATIO_FOR_MAX } from './boost-model';
import { pairVectors, LP_PPM, BUY, SELL, D as PPM_ONE } from './pair-model';
import { flowVectors } from './flow-model';
import { ventVectors } from './vent-model';
import { kindlingVectors } from './kindling-model';
import { ignitionVectors } from './ignition-model';
import { keccak_256 } from '@noble/hashes/sha3.js';
import { bytesToHex } from '@noble/hashes/utils.js';

const PARAMS = 'contracts/src/generated/FurnaceParams.sol';
const SCHEDULE = 'contracts/src/generated/ScheduleTable.sol';
const VECTORS = 'contracts/test/fixtures/oracle-vectors.json';
const FORGE_VECTORS = 'contracts/test/fixtures/forge-vectors.json';
const SETTLEMENT_VECTORS = 'contracts/test/fixtures/settlement-vectors.json';
const PAIR_VECTORS = 'contracts/test/fixtures/pair-vectors.json';
const FLOW_VECTORS = 'contracts/test/fixtures/flow-vectors.json';
const VENT_VECTORS = 'contracts/test/fixtures/vent-vectors.json';
const KINDLING_VECTORS = 'contracts/test/fixtures/kindling-vectors.json';
const IGNITION_VECTORS = 'contracts/test/fixtures/ignition-vectors.json';
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

section('ASH: 70,000 cumulative economic issuance (spec v5.5 §1; ADR 0022)');
{
  const st = cfg.shareToken;
  const leaves = [st.allocations.launch.ignition, st.allocations.launch.kindling, st.allocations.forge].map((x) => parseUnits(x, 18));
  if (leaves.reduce((a, b) => a + b, 0n) !== parseUnits(st.maxSupply, 18)) throw new Error('shareToken allocations must sum exactly to maxSupply');
  if (st.decimals.evm !== 18) throw new Error('ASH is 18 decimals on EVM');
  if (!(Number.isInteger(st.forgeTrickleDays) && st.forgeTrickleDays > 0)) throw new Error('shareToken.forgeTrickleDays must be whole days');
  c('string', 'ASH_NAME', JSON.stringify(st.name));
  c('string', 'ASH_SYMBOL', JSON.stringify(st.symbol));
  c('uint256', 'ASH_MAX_SUPPLY', `${st.maxSupply}e18`, 'cumulative: nothing re-issues what is burned');
  c('uint256', 'ASH_IGNITION_ALLOCATION', `${st.allocations.launch.ignition}e18`);
  c('uint256', 'ASH_KINDLING_BONUS', `${st.allocations.launch.kindling}e18`, 'minted only if Kindling settles [P]');
  c('uint256', 'ASH_FORGE_ALLOCATION', `${st.allocations.forge}e18`);
  c('uint256', 'ASH_FORGE_VESTING', `${st.forgeTrickleDays} days`, 'V(t) = floor(alloc · min(elapsed, duration) / duration)');
}

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
// The ordinary bonus ceiling is Capstone's maximum plus Pyre's (canonical integrateHeat checks 0.65).
if (ray(String(f.capstone.maxBonus)) + ray(String(f.pyre.maxBoost)) !== ray('0.65')) throw new Error('Capstone + Pyre maximum must equal the 0.65 ordinary bonus ceiling');
c('uint256', 'MAX_ORDINARY_BONUS_RAY', ray('0.65'), 'Capstone 0.5 + Pyre 0.15');
// [P] ForgePool stores a position's ordinary bonus as uint16 units of 1e-5 (ADR 0008).
const BONUS_UNIT = 10n ** 22n;
if (ray('0.65') % BONUS_UNIT !== 0n || ray('0.65') / BONUS_UNIT > 65535n) throw new Error('ordinary bonus ceiling must be a whole number of uint16 units');
c('uint256', 'ORDINARY_BONUS_UNIT_RAY', BONUS_UNIT, '[P] 0.00001');
c('uint256', 'MAX_ORDINARY_BONUS_UNITS', ray('0.65') / BONUS_UNIT);
c('uint256', 'MAX_LOTS_PER_POSITION', f.heat.maxLotsPerPosition);
c('uint256', 'MILESTONE_COUNT', milestones.length);
milestones.forEach((m, i) => {
  c('uint256', `MILESTONE_${i}_SECONDS`, `${m.days} days`, m.key);
  c('uint256', `MILESTONE_${i}_BUMP_RAY`, ray(String(m.heatBump)));
});
// Heat² primitive roots at the milestones, as canonical squaredHeatPrimitive forms them:
// T3(x) = isqrt(x³·RAY²/R), T5(x) = isqrt(x⁵·RAY²/R). Only the live endpoint is computed on chain.
milestones.forEach((m, i) => {
  const x = BigInt(m.days) * DAY;
  c('uint256', `MILESTONE_${i}_T3`, isqrt(x ** 3n * RAY * RAY / AGE_CAP));
  c('uint256', `MILESTONE_${i}_T5`, isqrt(x ** 5n * RAY * RAY / AGE_CAP));
});
c('uint256', 'DEED_HEAT_CARRY_PCT', f.deeds.heatCarryPct);
// First Flame (spec v5.5 §2; ADR 0018): a founder position's financial Heat reads this much older.
// The owner's reading: an offset on the real age (v5.4's "accumulates from day 15"), not a max.
if (!cfg.ignition.founderBadge.enabled) throw new Error('First Flame is disabled: ForgePool applies it');
c('uint256', 'FIRST_FLAME_AGE', BigInt(cfg.ignition.founderBadge.phantomAgeBonusDays) * DAY_N,
  `First Flame: ${cfg.ignition.founderBadge.phantomAgeBonusDays} days added to a founder's financial Heat age (ADR 0018)`);

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
// Records store participation (saturating at this minimum) as uint24.
if (BigInt(cfg.execution.ashfall.minimumParticipationDays) * DAY >= 1n << 24n) throw new Error('Ashfall participation minimum must fit uint24 records');
c('uint256', 'ASHFALL_MIN_PARTICIPATION', `${cfg.execution.ashfall.minimumParticipationDays} days`, 'actual participation, stored saturating here');
// Ashfall eligibility (spec §8, §12): a lot's actual participation AND its position's active Streak
// must both reach their minimums; the Streak minimum is the `minRelic` Relic's days. Weight is stake × Heat².
const ashCfg = cfg.execution.ashfall;
const ashfallPolicy: [string, unknown, unknown][] = [
  ['execution.ashfall.lotEligibility', ashCfg.lotEligibility, 'actualParticipationAgeAndActiveStreak'],
  ['execution.ashfall.founderFloorCountsAsParticipation', ashCfg.founderFloorCountsAsParticipation, false],
  ['execution.ashfall.transportBurnCredit', ashCfg.transportBurnCredit, false],
  ['emissions.ashfall.enabled', ash.enabled, true],
  ['emissions.ashfall.distributionWeight', ash.distributionWeight, 'heatSquared'],
  ['emissions.ashfall.rolloverUndistributed', ash.rolloverUndistributed, true],
  ['forge.emergencyExit.forfeitsAshfall', f.emergencyExit.forfeitsAshfall, true],
];
for (const [path, got, want] of ashfallPolicy) if (got !== want) throw new Error(`Ashfall implements ${path} = ${String(want)}, config has ${String(got)}`);
const minRelic = f.relics.find((r) => r.key === ash.minRelic);
if (!minRelic) throw new Error(`Ashfall minRelic ${ash.minRelic} is not a Relic`);
c('uint256', 'ASHFALL_MIN_STREAK', `${minRelic.days} days`, `${minRelic.key}: the position's active Streak`);

section('Capstone and Pyre: the ordinary Heat bonus (spec v5.5 §6, §8; ADR 0009)');
// Boost implements exactly these policies; fail generation if the config selects another.
const capCfg = f.capstone, pyreCfg = f.pyre;
const boostPolicy: [string, unknown, unknown][] = [
  ['forge.capstone.enabled', capCfg.enabled, true],
  ['forge.capstone.earnsEmissions', capCfg.earnsEmissions, false],
  ['forge.capstone.cooldown', capCfg.cooldown, 'sameAsWithdraw'],
  ['forge.capstone.affectsStreak', capCfg.affectsStreak, false],
  ['forge.capstone.affectsHeatAge', capCfg.affectsHeatAge, false],
  ['forge.pyre.enabled', pyreCfg.enabled, true],
  ['forge.pyre.soulbound', pyreCfg.soulbound, true],
];
for (const [path, got, want] of boostPolicy) if (got !== want) throw new Error(`Boost implements ${path} = ${String(want)}, config has ${String(got)}`);
const units = (x: number) => {
  const r = ray(String(x));
  if (r % BONUS_UNIT !== 0n) throw new Error(`${x} is not a whole number of bonus units`);
  return r / BONUS_UNIT;
};
c('uint256', 'CAPSTONE_MAX_BONUS_UNITS', units(capCfg.maxBonus), `+${capCfg.maxBonus} at and above ratioForMax`);
c('uint256', 'CAPSTONE_RATIO_FOR_MAX_RAY', ray(String(capCfg.ratioForMax)), 'Capstone value ÷ stake value');
c('uint256', 'CAPSTONE_DEPOSIT_FEE_PCT', capCfg.depositFeePct, 'burned (Protocol category)');
c('uint256', 'CAPSTONE_WITHDRAW_FEE_PCT', capCfg.withdrawFeePct, 'burned (Protocol category)');
if (pyreCfg.tiers.length !== 3) throw new Error('Boost._pyreUnits unrolls exactly 3 Pyre tiers');
pyreCfg.tiers.forEach((t, i) => {
  if (i > 0 && !(parseUnits(t.burnEmber, 18) > parseUnits(pyreCfg.tiers[i - 1].burnEmber, 18))) throw new Error('Pyre tiers must ascend');
  c('uint256', `PYRE_TIER_${i}_BURN`, parseUnits(t.burnEmber, 18), `${t.key}: ${t.burnEmber} EMBER burned`);
  c('uint256', `PYRE_TIER_${i}_UNITS`, units(t.heatBoost));
});
c('uint256', 'PYRE_MAX_BOOST_UNITS', units(pyreCfg.maxBoost));
if (units(capCfg.maxBonus) + units(pyreCfg.maxBoost) !== ray('0.65') / BONUS_UNIT) throw new Error('Capstone + Pyre maxima must fill the ordinary bonus ceiling');

// Stoke into the Capstone (spec §6, §210): the protocol Compound fee is zero, a Stoke without a
// matching reservation never sells, and keeper Stokes are opt-in per position. Boost implements
// exactly this; fail generation if the config selects anything else.
const auto = f.autoStoke;
const stokePolicy: [string, unknown, unknown][] = [
  ['forge.fees.compoundPct', f.fees.compoundPct, 0],
  ['forge.compound.lpMatch.fallback', f.compound.lpMatch.fallback, 'capstone'],
  ['forge.autoStoke.enabled', auto.enabled, true],
  ['forge.autoStoke.defaultOn', auto.defaultOn, false],
];
for (const [path, got, want] of stokePolicy) if (got !== want) throw new Error(`Boost implements ${path} = ${String(want)}, config has ${String(got)}`);
/** A percentage with at most two decimals, as exact basis points (no float arithmetic). */
const bps = (pct: number): bigint => {
  const m = /^(\d+)(?:\.(\d{1,2}))?$/.exec(String(pct));
  if (!m) throw new Error(`${pct}% is not a whole number of basis points`);
  return BigInt(m[1]) * 100n + BigInt((m[2] ?? '').padEnd(2, '0'));
};
const tipMin = bps(auto.tip.minPct), tipDefault = bps(auto.tip.defaultPct), tipMax = bps(auto.tip.maxPct);
if (!(0n < tipMin && tipMin <= tipDefault && tipDefault <= tipMax && tipMax < 10_000n)) throw new Error('autoStoke tips must satisfy 0 < min ≤ default ≤ max < 100%');
if (!(0 < auto.minInterval.minHours && auto.minInterval.minHours <= auto.minInterval.defaultHours)) throw new Error('autoStoke intervals must satisfy 0 < min ≤ default');
c('uint256', 'AUTO_STOKE_TIP_MIN_BPS', tipMin, `${auto.tip.minPct}% of a keeper Stoke`);
c('uint256', 'AUTO_STOKE_TIP_DEFAULT_BPS', tipDefault, `${auto.tip.defaultPct}% (the UI's default)`);
c('uint256', 'AUTO_STOKE_TIP_MAX_BPS', tipMax, `${auto.tip.maxPct}%`);
c('uint256', 'AUTO_STOKE_MIN_INTERVAL', BigInt(auto.minInterval.minHours) * 3600n, `${auto.minInterval.minHours}h between keeper Stokes`);
c('uint256', 'AUTO_STOKE_DEFAULT_INTERVAL', BigInt(auto.minInterval.defaultHours) * 3600n, `${auto.minInterval.defaultHours}h (the UI's default)`);
c('uint256', 'AUTO_STOKE_MIN_SIZE', parseUnits(auto.minSize, 18), `${auto.minSize} EMBER: [P] the floor of a position's keeper minimum`);

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

section('Taps: Relic-gated, Streak-preserving withdrawals (spec v5.5 §9)');
// A Tap draws the youngest lots first with no age haircut or Streak reset, pays the normal fee and
// timer, and forfeits a running Seal. The position's Streak picks the highest Relic tier with a Tap.
if (f.heat.tapDrawdownMode !== 'youngestFirst') throw new Error(`ForgePool draws Taps youngest-first, config has ${f.heat.tapDrawdownMode}`);
const tapTiers = f.relics.filter((r) => r.perks.tap).map((r) => ({ key: r.key, days: r.days, ...r.perks.tap! }));
if (tapTiers.length !== 3) throw new Error('ForgePool._chargeTap unrolls exactly 3 Tap tiers');
tapTiers.forEach((t, i) => {
  if (i > 0 && !(t.days > tapTiers[i - 1].days)) throw new Error('Tap tiers must ascend by Streak days');
  if (!(t.maxPct > 0 && t.maxPct <= 100 && Number.isInteger(t.maxPct))) throw new Error(`${t.key}: Tap share must be a whole percent in (0, 100]`);
  if (!(t.everyDays > 0 && Number.isInteger(t.everyDays))) throw new Error(`${t.key}: Tap interval must be whole days`);
});
// A Deed resets the Streak and keeps lastTapAt (ADR 0011, ADR 0014): safe only while the first tier's
// Streak outlasts every Tap interval, so a buyer can never Tap inside the seller's window.
if (tapTiers[0].days < Math.max(...tapTiers.map((t) => t.everyDays))) throw new Error('the first Tap tier must take at least as long as the longest Tap interval');
tapTiers.forEach((t, i) => {
  c('uint256', `TAP_TIER_${i}_STREAK`, BigInt(t.days) * DAY_N, `${t.key}: ${t.days} days of Streak`);
  c('uint256', `TAP_TIER_${i}_MAX_PCT`, t.maxPct, `of active principal [P]`);
  c('uint256', `TAP_TIER_${i}_EVERY`, BigInt(t.everyDays) * DAY_N, `one Tap per ${t.everyDays} days`);
});

section('EMBER pairs: Flow swap fees in ppm, the oracle window (spec v5.5 §13, §14; ADR 0015)');
// Both pairs take every fee in the quote asset: a buy's from its input, a sell's from its output.
// The LP fee stays in the reserves; the protocol parts are booked per lane for the Vent to pull.
const swapCfg = cfg.fees.swap;
const swapPolicy: [string, unknown, unknown][] = [
  ['swap.amm', cfg.swap.amm, 'protocol-cpmm'],
  ['fees.swap.buy.treasuryBps', swapCfg.buy.treasuryBps, 0],
  ['fees.swap.sell.treasuryBps', swapCfg.sell.treasuryBps, 0],
  ['fees.quoteYield.enabled', cfg.fees.quoteYield.enabled, true],
  ['fees.quoteYield.asset', cfg.fees.quoteYield.asset, 'quoteAsset'],
  ['fees.liquidityLane.permanentMustBeFullRange', cfg.fees.liquidityLane.permanentMustBeFullRange, true],
  ['security.pausable.swaps', cfg.security.pausable.swaps, true],
  ['security.pausable.withdrawalsNever', cfg.security.pausable.withdrawalsNever, true],
];
for (const [path, got, want] of swapPolicy) if (got !== want) throw new Error(`EmberPair implements ${path} = ${String(want)}, config has ${String(got)}`);
if (swapCfg.buy.lpBps !== swapCfg.sell.lpBps) throw new Error('EmberPair charges one LP fee on both sides');
const ppmOf = (bps: number) => parseUnits(String(bps), 2);
const buyTotal = LP_PPM + BUY.burn + BUY.liquidity, sellTotal = LP_PPM + SELL.burn + SELL.liquidity + SELL.quoteYield;
if (buyTotal !== ppmOf(swapCfg.buy.totalBps)) throw new Error('buy-side swap fee parts must sum to buy.totalBps');
if (sellTotal !== ppmOf(swapCfg.sell.totalBps)) throw new Error('sell-side swap fee parts must sum to sell.totalBps');
const ceilingPpm = ppmOf(cfg.security.feeCeilings.swapBps);
if (buyTotal > ceilingPpm || sellTotal > ceilingPpm) throw new Error('a swap fee exceeds security.feeCeilings.swapBps');
if (PPM_ONE !== 1_000_000n) throw new Error('pair-model ppm scale must be 1e6');
const twap = cfg.fees.burnLane.twapSeconds;
if (!(Number.isInteger(twap) && twap > 0 && twap % 6 === 0)) throw new Error('the Vent TWAP must be whole seconds divisible by 6 (EmberPair observes every TWAP/6)');
c('uint256', 'PAIR_LP_FEE_PPM', LP_PPM, `${swapCfg.buy.lpBps} bps, both sides`);
c('uint256', 'PAIR_BUY_BURN_PPM', BUY.burn, `${swapCfg.buy.burnBps} bps`);
c('uint256', 'PAIR_BUY_LIQUIDITY_PPM', BUY.liquidity, `${swapCfg.buy.liquidityBps} bps`);
c('uint256', 'PAIR_SELL_BURN_PPM', SELL.burn, `${swapCfg.sell.burnBps} bps`);
c('uint256', 'PAIR_SELL_LIQUIDITY_PPM', SELL.liquidity, `${swapCfg.sell.liquidityBps} bps`);
c('uint256', 'PAIR_SELL_QUOTE_YIELD_PPM', SELL.quoteYield, `${swapCfg.sell.quoteYieldBps} bps, in the quote asset`);
c('uint256', 'PAIR_BUY_TOTAL_PPM', buyTotal, `${swapCfg.buy.totalBps} bps`);
c('uint256', 'PAIR_SELL_TOTAL_PPM', sellTotal, `${swapCfg.sell.totalBps} bps`);
c('uint256', 'PAIR_TWAP_SECONDS', twap, 'the Vent window; the pair observes every sixth of it');
c('address', 'BURN_ADDRESS', checksum(cfg.fees.burnAddress.evm), 'holds each pair\'s minimum liquidity');

section('Flow: Relic rebates of the protocol swap share, waivers (spec v5.5 §4, §14; ADR 0016)');
// Flow passes the pairs a protocol-share scale of 10^6 − tier·10^4 for the caller's Relic tier,
// 0 for the compounder's Compound, and stakes zap-formed LP without the deposit fee.
if (cfg.forge.fees.waiveDepositFeeFromFlow !== true) throw new Error('ForgePool implements forge.fees.waiveDepositFeeFromFlow = true');
if (cfg.fees.swap.waiveProtocolShareOnCompound !== true) throw new Error('Flow implements fees.swap.waiveProtocolShareOnCompound = true');
const rebateTiers = f.relics.filter((r) => (r.perks.feeRebatePct ?? 0) > 0).map((r) => ({ key: r.key, pct: r.perks.feeRebatePct! }));
if (rebateTiers.length !== 2) throw new Error('Flow._rebateShare unrolls exactly 2 rebate tiers');
rebateTiers.forEach((t, i) => {
  if (!(Number.isInteger(t.pct) && t.pct > 0 && t.pct <= 100)) throw new Error(`${t.key}: rebate must be a whole percent in (0, 100]`);
  if (i > 0 && !(t.pct > rebateTiers[i - 1].pct)) throw new Error('rebate tiers must ascend');
  c('uint256', `FLOW_REBATE_TIER_${i}_PCT`, t.pct, `${t.key}: % of the protocol swap share`);
});

section('The Vent: fee lanes, the protected buyback, its window (spec v5.5 §13; ADR 0020)');
// Liabilities are booked at receipt and converted later. The burn lane buys EMBER back in the
// fee's own pair under a TWAP band, a slippage floor, a per-call chunk and a cumulative window
// measured against the window's fixed starting reserve; a failed check defers, never reverts.
const fl = cfg.fees, bl = fl.burnLane, ventExec = cfg.execution.vent;
const ventPolicy: [string, unknown, unknown][] = [
  ['fees.burnLane.method', bl.method, 'unwindAndBuyback'],
  ['fees.burnLane.allowlistedRoutersOnly', bl.allowlistedRoutersOnly, true],
  ['fees.burnLane.deferIfUnsafe', bl.deferIfUnsafe, true],
  ['fees.feeVault.enabled', fl.feeVault.enabled, true],
  ['fees.liquidityLane.method', fl.liquidityLane.method, 'matchReserve'],
  ['fees.tokenFees.burnPct', fl.tokenFees.burnPct, 100],
  ['execution.vent.reserveReference', ventExec.reserveReference, 'fixedWindowStart'],
  ['execution.vent.atDeferralLimit', ventExec.atDeferralLimit, 'alertNeverWeakenGuards'],
  ['execution.vent.principalExitRequiresVent', ventExec.principalExitRequiresVent, false],
];
for (const [path, got, want] of ventPolicy) if (got !== want) throw new Error(`the Vent implements ${path} = ${String(want)}, config has ${String(got)}`);
const pctSplit = (name: string, parts: number[]) => {
  if (!parts.every((p) => Number.isInteger(p) && p >= 0) || parts.reduce((a, b) => a + b, 0) !== 100) throw new Error(`${name} must be whole percents summing to 100`);
};
const em = f.emergencyExit.routing, deedFee = f.deeds.feeRouting;
pctSplit('fees.vent', [fl.vent.burnPct, fl.vent.liquidityPct, fl.vent.hearthPct, fl.vent.treasuryPct]);
pctSplit('forge.emergencyExit.routing', [em.burnPct, em.liquidityPct, em.stakersPct]);
pctSplit('forge.deeds.feeRouting', [deedFee.burnPct, deedFee.liquidityPct]);
if (bl.twapSeconds !== twap) throw new Error('the Vent reads the pairs\' own TWAP window');
if (ventExec.aggregateWindowSeconds !== bl.twapSeconds) throw new Error('the Vent window is the TWAP window');
const chunkBps = parseUnits(String(bl.maxChunkPctOfReserve), 2);
if (!(chunkBps > 0n && chunkBps <= 100n)) throw new Error('fees.burnLane.maxChunkPctOfReserve must be in (0, 1]%');
if (!(bl.slippageCapBps > 0 && bl.slippageCapBps <= 100)) throw new Error('fees.burnLane.slippageCapBps must be in (0, 100]');
if (!(bl.avgPriceBandBps > 0 && bl.avgPriceBandBps <= 500)) throw new Error('fees.burnLane.avgPriceBandBps must be in (0, 500]');
if (!(ventExec.aggregateMaxReserveBps > 0 && BigInt(ventExec.aggregateMaxReserveBps) <= 100n)) throw new Error('execution.vent.aggregateMaxReserveBps must be in (0, 100]');
// A buy of at most the chunk moves the price by about twice the chunk; with the slippage floor
// that keeps every executed buyback far inside the price-impact cap, which is therefore implied.
if (!(2n * chunkBps + BigInt(bl.slippageCapBps) < BigInt(bl.maxPriceImpactBps))) throw new Error('the chunk and slippage floor must imply fees.burnLane.maxPriceImpactBps');
if (!(Number.isInteger(fl.feeVault.minBatchUsd) && fl.feeVault.minBatchUsd > 0)) throw new Error('fees.feeVault.minBatchUsd must be a whole number of dollars');
c('uint256', 'VENT_BURN_PCT', fl.vent.burnPct, 'standard Forge fees: burn lane');
c('uint256', 'VENT_LIQUIDITY_PCT', fl.vent.liquidityPct, 'match reserve: EMBER burned, quote held');
c('uint256', 'VENT_HEARTH_PCT', fl.vent.hearthPct, 'owed in kind to the Hearth');
c('uint256', 'VENT_TREASURY_PCT', fl.vent.treasuryPct, 'owed in kind to the Treasury');
c('uint256', 'EMERGENCY_BURN_PCT', em.burnPct, 'emergency-exit fees');
c('uint256', 'EMERGENCY_LIQUIDITY_PCT', em.liquidityPct);
c('uint256', 'EMERGENCY_STAKERS_PCT', em.stakersPct, 'owed in kind to the stakers\' distributor [P]');
c('uint256', 'DEED_FEE_BURN_PCT', deedFee.burnPct, 'Deed market fees');
c('uint256', 'DEED_FEE_LIQUIDITY_PCT', deedFee.liquidityPct);
c('uint256', 'VENT_BAND_BPS', bl.avgPriceBandBps, 'spot within this of the TWAP');
c('uint256', 'VENT_SLIPPAGE_BPS', bl.slippageCapBps, 'minimum out: the TWAP value less this, fees included');
c('uint256', 'VENT_CHUNK_BPS', chunkBps, `${bl.maxChunkPctOfReserve}% of the current quote reserve per call`);
c('uint256', 'VENT_PRICE_IMPACT_BPS', bl.maxPriceImpactBps, 'implied by the chunk and the slippage floor');
c('uint256', 'VENT_WINDOW_SECONDS', ventExec.aggregateWindowSeconds, 'aligned windows [P]');
c('uint256', 'VENT_WINDOW_MAX_BPS', ventExec.aggregateMaxReserveBps, 'of the window\'s fixed starting quote reserve');
c('uint256', 'VENT_ORACLE_MAX_AGE', 2 * bl.twapSeconds, 'a longer TWAP span is stale: defer [P]');
c('uint256', 'VENT_MIN_BATCH_USD', fl.feeVault.minBatchUsd, 'whole dollars, in a USD-stablecoin quote only [P]');
c('uint256', 'VENT_MAX_WAIT', BigInt(fl.feeVault.maxWaitHours) * 3600n, `${fl.feeVault.maxWaitHours} h`);
c('uint256', 'VENT_ALERT_AFTER', BigInt(bl.maxDeferralHours) * 3600n, `${bl.maxDeferralHours} h: an alert, never a weaker guard`);

section('Kindling: the genesis event, its escrow and the LP sink (spec v5.5 §3; ADR 0021)');
// One 24 h USDC raise. Contributions pay 3% into the GenesisFeeEscrow; success initializes
// BlastPool with the 420,000-EMBER seed and the net quote, 90% of the LP to contributors' positions
// and the rest to the permanent sink; failure refunds remaining principal plus every fee.
const kd = cfg.kindling, kx = cfg.execution.kindling;
const kindlingPolicy: [string, unknown, unknown][] = [
  ['kindling.enabled', kd.enabled, true],
  ['kindling.quoteToken', kd.quoteToken, 'USDC'],
  ['kindling.polPair', kd.polPair, 'EMBER/USDC'],
  ['kindling.priceMode', kd.priceMode, 'clearing'],
  ['kindling.atomicPoolInit', kd.atomicPoolInit, true],
  ['kindling.feeEscrowUntilClose', kd.feeEscrowUntilClose, true],
  ['kindling.feeDestination', kd.feeDestination, 'treasury'],
  ['fees.genesisDeposit.treasuryPct', cfg.fees.genesisDeposit.treasuryPct, 100],
  ['execution.kindling.feeCustody', kx.feeCustody, 'dedicatedImmutableEscrow'],
  ['execution.kindling.successRelease', kx.successRelease, 'afterAtomicPoolInitialization'],
  ['execution.kindling.failureRefundAsset', kx.failureRefundAsset, 'depositedQuote'],
  ['execution.kindling.cutoff', kx.cutoff, 'rejectNewDepositsAtDeadline'],
  ['execution.kindling.cancelUntilSettlement', kx.cancelUntilSettlement, 'netPrincipalNowFeeIfLaunchFails'],
  ['execution.kindling.closeBountyBasis', kx.closeBountyBasis, 'acceptedGrossQuote'],
  ['execution.kindling.treasuryFallback', kx.treasuryFallback, 'separateFundedEvent'],
];
for (const [path, got, want] of kindlingPolicy) if (got !== want) throw new Error(`Kindling implements ${path} = ${String(want)}, config has ${String(got)}`);
pctSplit('kindling.lpSplit', [kd.lpSplit.depositorDeedsPct, kd.lpSplit.burnPct]);
if (!(Number.isInteger(kd.durationHours) && kd.durationHours > 0)) throw new Error('kindling.durationHours must be whole hours');
if (!(Number.isInteger(kd.depositFeePct) && kd.depositFeePct > 0 && kd.depositFeePct <= cfg.security.feeCeilings.genesisPct)) throw new Error('kindling.depositFeePct must be a whole percent within the genesis ceiling');
if (!(kd.minRaiseUsd > 0 && kd.minRaiseUsd <= kd.maxRaiseUsd && kd.maxPerWalletUsd > 0 && kd.maxPerWalletUsd <= kd.maxRaiseUsd)) throw new Error('kindling raise limits are inconsistent');
for (const [k, v] of [['minRaiseUsd', kd.minRaiseUsd], ['maxRaiseUsd', kd.maxRaiseUsd], ['maxPerWalletUsd', kd.maxPerWalletUsd]] as const) if (!Number.isInteger(v)) throw new Error(`kindling.${k} must be whole dollars`);
if (!(Number.isInteger(kd.closeBountyBps) && kd.closeBountyBps > 0 && kd.closeBountyBps * 100 < kd.depositFeePct * 10_000)) throw new Error('the close bounty must be paid from the fee: closeBountyBps < depositFeePct');
if (BigInt(kd.seedEmberBpsOfMax) * BigInt(cfg.token.maxSupply) / 10_000n !== BigInt(cfg.token.allocations.kindlingPool)) throw new Error('kindling.seedEmberBpsOfMax must equal the kindlingPool allocation');
c('uint256', 'KINDLING_DURATION', BigInt(kd.durationHours) * 3600n, `${kd.durationHours} h; deposits stop exactly at the deadline`);
c('uint256', 'KINDLING_SETTLE_WINDOW', kx.maxSettlementDelaySeconds, 'after the deadline; unsettled by then, the event fails');
c('uint256', 'KINDLING_MIN_RAISE_USD', kd.minRaiseUsd, 'whole dollars of accepted gross, at settlement [P]');
c('uint256', 'KINDLING_MAX_RAISE_USD', kd.maxRaiseUsd, 'whole dollars of accepted gross, at admission [P]');
c('uint256', 'KINDLING_WALLET_CAP_USD', kd.maxPerWalletUsd, 'whole dollars of accepted gross per wallet, at admission [P]');
c('uint256', 'KINDLING_FEE_BPS', BigInt(kd.depositFeePct) * 100n, `${kd.depositFeePct}%, floored (accounting.ts KindlingEscrow)`);
c('uint256', 'KINDLING_CONTRIBUTOR_LP_PCT', kd.lpSplit.depositorDeedsPct, 'floored; the permanent sink takes the rest');
c('uint256', 'KINDLING_CLOSE_BOUNTY_BPS', kd.closeBountyBps, 'of accepted gross less cancellations, from the fees');
// The smallest contribution Kindling admits [P]. At $1 the fee's floor costs under a millionth of
// it, so splitting a deposit cannot dodge the fee, and every entitlement clears the pool minimum:
const KINDLING_MIN_CONTRIBUTION_USD = 1n;
c('uint256', 'KINDLING_MIN_CONTRIBUTION_USD', KINDLING_MIN_CONTRIBUTION_USD, 'whole dollars of gross per contribution [P]');
{
  // The worst case: the smallest net in the largest raise, the pair's LP value-scaled to 18 decimals
  // (EmberPair mints sqrt(ember · quote · 10^(18 − decimals))). Its 90% entitlement, less pool 0's
  // deposit fee, must clear MIN_STAKE_LP, so `materialize` never needs a dust path.
  const net = (usd: bigint) => usd * 10n ** 18n - usd * 10n ** 18n * BigInt(kd.depositFeePct) / 100n;
  const seed = BigInt(cfg.token.allocations.kindlingPool) * 10n ** 18n;
  const maxNet = net(BigInt(kd.maxRaiseUsd)), minNet = net(KINDLING_MIN_CONTRIBUTION_USD);
  const lp = isqrt(seed * maxNet) - 1000n;
  const entitlement = lp * BigInt(kd.lpSplit.depositorDeedsPct) / 100n * minNet / maxNet;
  const staked = entitlement - entitlement * BigInt(f.fees.depositPct) / 100n;
  if (staked < parseUnits(f.minStakeLp, 18)) throw new Error(`a $${KINDLING_MIN_CONTRIBUTION_USD} Kindling entitlement (${staked}) is below forge.minStakeLp`);
}

section('Ignition: the genesis farm, First Flame and the head start (spec v5.5 §2; ADR 0023)');
{
  const ig = cfg.ignition, pc = ig.principalAtClose;
  const ignitionPolicy: [string, unknown, unknown][] = [
    ['ignition.feeDestination', ig.feeDestination, 'treasury'],
    ['ignition.withdrawDuringWindow.enabled', ig.withdrawDuringWindow.enabled, true],
    ['ignition.withdrawDuringWindow.refundFee', ig.withdrawDuringWindow.refundFee, false],
    ['ignition.exitFeePct', ig.exitFeePct, 0],
    ['ignition.rewards.token', ig.rewards.token, 'ASH'],
    ['ignition.rewards.mode', ig.rewards.mode, 'per-second-pro-rata'],
    ['ignition.rewards.vesting', ig.rewards.vesting, 'none'],
    ['ignition.founderBadge.enabled', ig.founderBadge.enabled, true],
    ['ignition.heatHeadStart', ig.heatHeadStart, 'ignitionStart'],
    ['ignition.principalAtClose.usdc', pc.usdc, 'autoStakeColdStorage'],
    ['ignition.principalAtClose.usdcOptOutAtDeposit', pc.usdcOptOutAtDeposit, true],
    ['ignition.principalAtClose.otherAssets', pc.otherAssets, 'claimableFeeFree'],
    ['ignition.principalAtClose.headStartCappedToUsdKept', pc.headStartCappedToUsdKept, true],
    ['ignition.earlyBird.enabled', ig.earlyBird.enabled, true],
    ['ignition.earlyBird.shape', ig.earlyBird.shape, 'linear'],
    ['ignition.pools', ig.pools.map((p) => p.stakeToken).join(), 'USDC,WETH,WBTC,WETH/USDC'],
  ];
  for (const [path, got, want] of ignitionPolicy) if (got !== want) throw new Error(`Ignition implements ${path} = ${String(want)}, config has ${String(got)}`);
  if (ig.rewards.total !== cfg.shareToken.allocations.launch.ignition) throw new Error('ignition.rewards.total must equal the ASH Ignition leaf');
  if (!(Number.isInteger(ig.durationHours) && ig.durationHours >= ig.minDurationHours && ig.durationHours <= ig.maxDurationHours)) throw new Error('ignition.durationHours must be whole hours within its bounds');
  if (!(Number.isInteger(ig.depositFeePct) && ig.depositFeePct > 0 && ig.depositFeePct <= cfg.security.feeCeilings.genesisPct)) throw new Error('ignition.depositFeePct must be a whole percent within the genesis ceiling');
  if (!(Number.isInteger(ig.exitWindowHours) && ig.exitWindowHours > 0)) throw new Error('ignition.exitWindowHours must be whole hours');
  if (!(Number.isInteger(pc.headStartWindowDays) && pc.headStartWindowDays > 0)) throw new Error('ignition.principalAtClose.headStartWindowDays must be whole days');
  if (!(Number.isInteger(ig.earlyBird.maxBonusPct) && ig.earlyBird.maxBonusPct > 0 && ig.earlyBird.maxBonusPct < 100)) throw new Error('ignition.earlyBird.maxBonusPct must be a whole percent');
  for (const p of ig.pools) if (!(Number.isInteger(p.weight) && p.weight > 0)) throw new Error(`ignition pool ${p.id} weight must be a positive integer`);
  c('uint256', 'IGNITION_DURATION', BigInt(ig.durationHours) * 3600n, `${ig.durationHours} h; deposits and rewards stop exactly at END`);
  c('uint256', 'IGNITION_FEE_BPS', BigInt(ig.depositFeePct) * 100n, `${ig.depositFeePct}% of each deposit to the Treasury at once, never refunded; floored`);
  c('uint256', 'IGNITION_EXIT_WINDOW', BigInt(ig.exitWindowHours) * 3600n, 'after END: every asset may leave fee-free; then USDC auto-stakes');
  c('uint256', 'IGNITION_EARLY_BIRD_PPM', BigInt(ig.earlyBird.maxBonusPct) * 10_000n, `+${ig.earlyBird.maxBonusPct}% at START, linear to +0% at END`);
  c('uint256', 'IGNITION_WEIGHT_USDC', ig.pools[0].weight);
  c('uint256', 'IGNITION_WEIGHT_WETH', ig.pools[1].weight);
  c('uint256', 'IGNITION_WEIGHT_WBTC', ig.pools[2].weight);
  c('uint256', 'IGNITION_WEIGHT_LP', ig.pools[3].weight, 'an unbound LP pool gives its weight to the others [P]');
  c('uint256', 'IGNITION_HEAD_START_WINDOW', `${pc.headStartWindowDays} days`, "from Kindling's close");
  c('uint256', 'IGNITION_TWAP_SECONDS', twap, "BlastPool's TWAP values pool-0 LP for the head-start cap [P]");
  c('uint256', 'IGNITION_ORACLE_MAX_AGE', 2 * twap, 'a longer TWAP span is stale: refuse [P]');
}

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
const ashTotal = parseUnits(cfg.shareToken.allocations.forge, 18);
const ashDuration = BigInt(cfg.shareToken.forgeTrickleDays) * DAY_N;
// Fixed points (no draw from the shared generator, so no other fixture moves): edges, round days and odd seconds.
const ashElapsed = [0n, 1n, 59n, DAY_N, 7n * DAY_N, 30n * DAY_N, 365n * DAY_N, ashDuration / 3n, ashDuration / 2n, ashDuration - 1n, ashDuration,
  ashDuration + 1n, 10n * ashDuration, 12_345_678n, 33_333_333n, 61_234_567n];
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
// Boost's bonus formula (ADR 0009): 18- and 6-decimal stakes, EMBER-staked (rate 1), the edges
// around the maximum, zero custody and a zero rate; checked against canonical floats at real sizes.
const boostCases: { capstone: bigint; custody: bigint; rate: bigint }[] = [
  { capstone: 0n, custody: 10n ** 21n, rate: RAY },
  { capstone: 10n ** 18n, custody: 0n, rate: RAY },
  { capstone: 10n ** 18n, custody: 10n ** 21n, rate: 0n },
  { capstone: 10n ** 18n, custody: 1n, rate: 1n },
];
for (const [custody, rate] of [[10n ** 21n, RAY], [1000n * 10n ** 6n, 2n * 10n ** 12n * RAY], [37n * 10n ** 18n, 41n * RAY / 3n]] as [bigint, bigint][]) {
  const value = (custody * rate + RAY - 1n) / RAY;
  const forMax = (value * RATIO_FOR_MAX + RAY - 1n) / RAY;
  for (const capstone of [1n, forMax / 3n, forMax - 1n, forMax, forMax + 1n, 4n * forMax]) boostCases.push({ capstone, custody, rate });
}
for (let i = 0; i < 24; i++) {
  const six = i % 3 === 0;
  const custody = six ? rnd(10n ** 13n) + 1n : rnd(10n ** 27n) + 1n;
  const rate = six ? rnd(10n ** 40n) + 1n : rnd(10n ** 30n) + 1n;
  boostCases.push({ capstone: rnd((custody * rate) / RAY + 2n), custody, rate });
}
const pyreBurns = [0n, ...PYRE_TIERS.flatMap((t) => [t.burn - 1n, t.burn, t.burn + 1n]), 10n ** 30n];
for (const c of boostCases) if ((c.custody * c.rate) / RAY >= 10n ** 12n) checkAgainstCanonical(c.capstone, c.custody, c.rate, 0n);
// Floats cannot hold a wei below a threshold: compare whole-EMBER burns; the wei edges are exact-tested.
for (const b of [...pyreBurns.filter((x) => x % 10n ** 18n === 0n), ...PYRE_TIERS.flatMap((t) => [t.burn - 10n ** 18n, t.burn + 10n ** 18n])]) checkAgainstCanonical(0n, 0n, 0n, b);

const vectors = {
  version: cfg.version,
  primitive: { ageSeconds: S(ages), ray: S(ages.map(heatPrimitive)) },
  integrate: { ageSeconds: S(integ.map((x) => x.age)), activeSeconds: S(integ.map((x) => x.active)), bonusRay: S(integ.map((x) => x.bonus)), ray: S(integ.map((x) => x.out)) },
  // Heat² (Ashfall weight): the primitive at every sampled age, with and without an ordinary bonus.
  squaredPrimitive: { ageSeconds: S([...ages, ...ages]), bonusRay: S([...ages.map(() => 0n), ...ages.map((_, i) => (i % 2 ? ray('0.65') : rnd(ray('0.65') + 1n)))]), ray: [] as string[] },
  integrateSquared: { ageSeconds: S(integ.map((x) => x.age)), activeSeconds: S(integ.map((x) => x.active)), bonusRay: S(integ.map((x) => x.bonus)), ray: S(integ.map((x) => integrateSquaredHeat(x.age, x.active, x.bonus))) },
  cool: { ageSeconds: S(cools.map((x) => x.age)), withdrawn: S(cools.map((x) => x.withdrawn)), reference: S(cools.map((x) => x.ref)), out: S(cools.map((x) => x.out)) },
  deed: { ageSeconds: S(ages), out: S(ages.map(deedAge)) },
  mint: {
    accounted: S(mints.map((m) => m.acc)), reserved: S(mints.map((m) => m.res)), base: S(mints.map((m) => m.b)), ashfall: S(mints.map((m) => m.a)),
    outBase: S(mints.map((m) => m.out.base)), outAshfall: S(mints.map((m) => m.out.ashfall)), outResidue: S(mints.map((m) => m.out.unmintedResidue)),
  },
  vesting: { elapsed: S(vestElapsed), out: S(vestElapsed.map((t) => vested(vestTotal, t, vestDuration))) },
  // ASH's Forge allocation (spec v5.5 §1): the same canonical V(t), over 730 days.
  ashVesting: { elapsed: S(ashElapsed), out: S(ashElapsed.map((t) => vested(ashTotal, t, ashDuration))) },
  poolBudget: { target: S(budgets.map((x) => x.target)), occupied: S(budgets.map((x) => x.occ)), out: S(budgets.map((x) => x.out)) },
  // Float display helper (no integer reference exists): compared within 1e-12 relative.
  lotHeat: { ageSeconds: heatDays.map((d) => String(Math.round(d * 86_400))), ray: heatDays.map((d) => fixed(heatMultiplier(Math.round(d * 86_400) / 86_400), 27)) },
  capstoneUnits: { capstone: S(boostCases.map((c) => c.capstone)), custody: S(boostCases.map((c) => c.custody)), rate: S(boostCases.map((c) => c.rate)), out: S(boostCases.map((c) => capstoneUnits(c.capstone, c.custody, c.rate))) },
  pyreUnits: { burned: S(pyreBurns), out: S(pyreBurns.map(pyreUnits)) },
  // Exact integer schedule (scripts/schedule.ts): every day 0..1700 plus far-out days.
  emission: { day: emissionDays.map(String), wad: emissionDays.map((d) => emissionPerDay(BigInt(d)).toString()) },
};
vectors.squaredPrimitive.ray = vectors.squaredPrimitive.ageSeconds.map((a, i) => String(squaredHeatPrimitive(BigInt(a), BigInt(vectors.squaredPrimitive.bonusRay[i]))));
const vectorsJson = JSON.stringify(vectors, null, 2) + '\n';

// ── write or check ───────────────────────────────────────────────────────
const outputs: [string, string][] = [[PARAMS, params], [SCHEDULE, scheduleSol], [VECTORS, vectorsJson], [FORGE_VECTORS, JSON.stringify(forgeVectors(), null, 1) + '\n'], [SETTLEMENT_VECTORS, JSON.stringify(settlementVectors(), null, 1) + '\n'], [PAIR_VECTORS, JSON.stringify(pairVectors(), null, 1) + '\n'], [FLOW_VECTORS, JSON.stringify(flowVectors(), null, 1) + '\n'], [VENT_VECTORS, JSON.stringify(ventVectors(), null, 1) + '\n'], [KINDLING_VECTORS, JSON.stringify(kindlingVectors(), null, 1) + '\n'], [IGNITION_VECTORS, JSON.stringify(ignitionVectors(), null, 1) + '\n']];
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
