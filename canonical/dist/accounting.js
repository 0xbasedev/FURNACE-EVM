/**
 * Integer reference accounting for the selected v5.5 design.
 * Complete-cohort functions are test oracles, NOT production all-user loops.
 * No function authenticates a bridge receipt, oracle price, or asset transfer.
 */
import { furnaceConfig as config } from './furnace.config.js';
export const RAY = BigInt(config.execution.settlement.multiplierScale);
export const DAY = 86400n;
const BPS = 10000n;
export function nonnegative(...values) {
    if (values.some(v => typeof v !== 'bigint' || v < 0n))
        throw new Error('Expected nonnegative bigint');
}
export function parseUnits(amount, decimals) {
    if (!Number.isInteger(decimals) || decimals < 0 || decimals > 27 || !/^\d+(\.\d+)?$/.test(amount))
        throw new Error('Invalid decimal amount');
    const [whole, frac = ''] = amount.split('.');
    if (frac.length > decimals)
        throw new Error('Excess decimal precision');
    return BigInt(whole) * 10n ** BigInt(decimals) + BigInt(frac.padEnd(decimals, '0') || '0');
}
export const ray = (amount) => parseUnits(amount, 27);
export function isqrt(n) {
    nonnegative(n);
    if (n < 2n)
        return n;
    let x = 1n << BigInt((n.toString(2).length + 1) >> 1), y = (x + n / x) >> 1n;
    while (y < x) {
        x = y;
        y = (x + n / x) >> 1n;
    }
    return x;
}
export const AGE_CAP = BigInt(config.forge.heat.rampDays) * DAY;
const BUMP_POINTS = config.forge.relics.filter(x => x.heatBump > 0).map(x => ({ at: BigInt(x.days) * DAY, increment: ray(String(x.heatBump)) }));
const CORE_CAP = ray(String(config.forge.heat.startMultiplier)) + ray(String(config.forge.heat.rampBonus)) + BUMP_POINTS.reduce((n, x) => n + x.increment, 0n);
/** Canonical antiderivative, rounded ONCE at each evaluation; units RAY-seconds. */
export function heatPrimitive(ageSeconds) {
    nonnegative(ageSeconds);
    const a = ageSeconds > AGE_CAP ? AGE_CAP : ageSeconds;
    // Integral of 1.5 sqrt(a/R) is a^(3/2)/sqrt(R).
    const sqrtPrimitive = isqrt(a * a * a * RAY * RAY / AGE_CAP);
    let result = a * ray(String(config.forge.heat.startMultiplier))
        + sqrtPrimitive * (2n * ray(String(config.forge.heat.rampBonus))) / (3n * RAY);
    let left = 0n, bump = 0n;
    for (const point of BUMP_POINTS) {
        const duration = (a < point.at ? a : point.at) - left;
        if (duration > 0n)
            result += duration * bump + point.increment * duration * duration / (2n * (point.at - left));
        if (a <= point.at)
            break;
        left = point.at;
        bump += point.increment;
    }
    if (ageSeconds > AGE_CAP)
        result += (ageSeconds - AGE_CAP) * CORE_CAP;
    return result;
}
export function integrateHeat(ageSeconds, activeSeconds, ordinaryBonusRay = 0n) {
    nonnegative(ageSeconds, activeSeconds, ordinaryBonusRay);
    if (ordinaryBonusRay > ray('0.65'))
        throw new Error('Ordinary bonus exceeds Capstone + Pyre ceiling');
    const start = ageSeconds > AGE_CAP ? AGE_CAP : ageSeconds;
    return heatPrimitive(start + activeSeconds) - heatPrimitive(start) + ordinaryBonusRay * activeSeconds;
}
export function cooledAge(ageSeconds, withdrawn, referenceStake) {
    nonnegative(ageSeconds, withdrawn, referenceStake);
    if (referenceStake === 0n || withdrawn > referenceStake)
        throw new Error('Invalid withdrawal fraction');
    return (ageSeconds > AGE_CAP ? AGE_CAP : ageSeconds) * (referenceStake - withdrawn) / referenceStake;
}
export function deedAge(ageSeconds) { nonnegative(ageSeconds); return (ageSeconds > AGE_CAP ? AGE_CAP : ageSeconds) * 80n / 100n; }
export function vested(total, elapsedSeconds, durationSeconds) {
    nonnegative(total, elapsedSeconds, durationSeconds);
    if (durationSeconds === 0n)
        throw new Error('Zero vesting duration');
    return total * (elapsedSeconds < durationSeconds ? elapsedSeconds : durationSeconds) / durationSeconds;
}
export function segmentMeasures(stake, ageSeconds, activeSeconds, ordinaryBonus = 0n, sealBonus = 0n) {
    nonnegative(stake, ageSeconds, activeSeconds, ordinaryBonus, sealBonus);
    if (sealBonus > ray('0.5'))
        throw new Error('Seal bonus exceeds ceiling');
    const weighted = stake * integrateHeat(ageSeconds, activeSeconds, ordinaryBonus);
    return { stakeSeconds: stake * activeSeconds, heatSeconds: weighted, sealSeconds: stake * activeSeconds * sealBonus, candidateSeconds: weighted * sealBonus / RAY };
}
export function sumMeasures(parts) {
    const result = { stakeSeconds: 0n, heatSeconds: 0n, sealSeconds: 0n, candidateSeconds: 0n };
    for (const p of parts)
        for (const k of Object.keys(result)) {
            nonnegative(p[k]);
            result[k] += p[k];
        }
    return result;
}
/** Fixed-budget reference over complete, authenticated position measures. */
export function settleBaseEpoch(budget, positions) {
    nonnegative(budget);
    if (new Set(positions.map(x => x.id)).size !== positions.length)
        throw new Error('Duplicate position');
    for (const p of positions) {
        nonnegative(p.stakeSeconds, p.heatSeconds, p.sealSeconds, p.candidateSeconds);
        if (!p.id || p.heatSeconds < p.stakeSeconds * RAY || p.heatSeconds > p.stakeSeconds * ray('3.65') + 1n)
            throw new Error('Inconsistent stake/Heat measure');
        if (p.sealSeconds > p.stakeSeconds * ray('0.5') || p.candidateSeconds > p.heatSeconds / 2n + 1n || (p.sealSeconds === 0n) !== (p.candidateSeconds === 0n))
            throw new Error('Inconsistent Seal measure');
    }
    const total = sumMeasures(positions);
    if (total.stakeSeconds === 0n)
        return { payouts: positions.map(p => ({ id: p.id, ordinary: 0n, escrow: 0n })), flatBudget: 0n, heatBudget: 0n, escrowPaid: 0n, residue: budget };
    const bucket = budget * BigInt(config.emissions.convictionBucketPct) / 100n;
    const ordinary = budget - bucket, flat = ordinary * BigInt(config.emissions.split.flatPct) / 100n, initialHeat = ordinary - flat;
    const capped = positions.map(p => {
        const candidate = total.candidateSeconds ? bucket * p.candidateSeconds / total.candidateSeconds : 0n;
        const cap = total.heatSeconds ? initialHeat * p.sealSeconds / total.heatSeconds : 0n;
        return candidate < cap ? candidate : cap;
    });
    const escrowPaid = capped.reduce((a, b) => a + b, 0n), heat = initialHeat + bucket - escrowPaid;
    const payouts = positions.map((p, i) => ({ id: p.id, ordinary: flat * p.stakeSeconds / total.stakeSeconds + heat * p.heatSeconds / total.heatSeconds, escrow: capped[i] }));
    return { payouts, flatBudget: flat, heatBudget: heat, escrowPaid, residue: budget - payouts.reduce((n, p) => n + p.ordinary + p.escrow, 0n) };
}
/** Headroom arithmetic only. The caller must authenticate the global ledger and burn credits. */
export function allocateMint(cap, globallyAccounted, reserved, baseTarget, authorizedAshfall) {
    nonnegative(cap, globallyAccounted, reserved, baseTarget, authorizedAshfall);
    const headroom = cap > globallyAccounted + reserved ? cap - globallyAccounted - reserved : 0n;
    const total = baseTarget + authorizedAshfall, available = total < headroom ? total : headroom;
    const base = total ? available * baseTarget / total : 0n, ashfall = total ? available * authorizedAshfall / total : 0n;
    return { base, ashfall, unmintedResidue: available - base - ashfall };
}
/** Demand and budget must be denominated in the SAME quote asset and valuation checkpoint. */
export function allocateMatching(quoteBudget, demands) {
    nonnegative(quoteBudget);
    if (new Set(demands.map(x => x.id)).size !== demands.length)
        throw new Error('Duplicate reward credit');
    demands.forEach(x => nonnegative(x.quoteDemand));
    const total = demands.reduce((n, x) => n + x.quoteDemand, 0n);
    const grants = demands.map(x => ({ id: x.id, quote: total <= quoteBudget ? x.quoteDemand : (total ? quoteBudget * x.quoteDemand / total : 0n) }));
    return { grants, unreserved: quoteBudget - grants.reduce((n, x) => n + x.quote, 0n) };
}
/** One-use credit bookkeeping reference. No token transfer is performed. */
export class MatchReservations {
    remaining = new Map();
    constructor(grants) { for (const g of grants) {
        nonnegative(g.quote);
        if (this.remaining.has(g.id))
            throw new Error('Duplicate credit');
        this.remaining.set(g.id, g.quote);
    } }
    consume(id, quote) { nonnegative(quote); const left = this.remaining.get(id); if (left === undefined || quote > left)
        throw new Error('Unfunded or replayed match'); this.remaining.set(id, left - quote); }
    release(id) { const left = this.remaining.get(id); if (left === undefined)
        throw new Error('Unknown credit'); this.remaining.delete(id); return left; }
}
/** In-kind escrow accounting reference, not a custody smart contract. */
export class KindlingEscrow {
    state = 'open';
    positions = new Map();
    treasuryReleased = 0n;
    deposit(id, gross) {
        nonnegative(gross);
        if (this.state !== 'open' || this.positions.has(id) || gross === 0n)
            throw new Error('Invalid deposit');
        const fee = gross * 300n / BPS, record = { net: gross - fee, fee };
        this.positions.set(id, record);
        return { ...record };
    }
    cancel(id, netAmount) {
        nonnegative(netAmount);
        const p = this.positions.get(id);
        if (this.state !== 'open' || !p || netAmount > p.net)
            throw new Error('Invalid cancellation');
        p.net -= netAmount;
        return netAmount;
    }
    settle(success) {
        if (this.state !== 'open')
            throw new Error('Event already settled');
        this.state = success ? 'succeeded' : 'failed';
        if (success) {
            this.treasuryReleased = [...this.positions.values()].reduce((n, p) => n + p.fee, 0n);
            for (const p of this.positions.values())
                p.fee = 0n;
        }
        return this.treasuryReleased;
    }
    refund(id) { const p = this.positions.get(id); if (this.state !== 'failed' || !p)
        throw new Error('Refund unavailable'); this.positions.delete(id); return p.net + p.fee; }
    claimNetForLp(id) { const p = this.positions.get(id); if (this.state !== 'succeeded' || !p)
        throw new Error('LP allocation unavailable'); this.positions.delete(id); return p.net; }
}
/**
 * Canonical antiderivative of ordinary Heat squared, in RAY^2-seconds.
 * On each bump segment H(t)=A+m(t-left)+B sqrt(t/R). Expanding the square
 * gives polynomial terms and t^(3/2), t^(5/2) primitives. BigInt permits
 * wide intermediates; an EVM port requires explicitly bounded mulDiv math.
 */
export function squaredHeatPrimitive(ageSeconds, ordinaryBonusRay = 0n) {
    nonnegative(ageSeconds, ordinaryBonusRay);
    if (ordinaryBonusRay > ray('0.65'))
        throw new Error('Ordinary bonus exceeds ceiling');
    const t = ageSeconds > AGE_CAP ? AGE_CAP : ageSeconds;
    const B = ray(String(config.forge.heat.rampBonus));
    const T3 = (x) => isqrt(x * x * x * RAY * RAY / AGE_CAP);
    const T5 = (x) => isqrt(x * x * x * x * x * RAY * RAY / AGE_CAP);
    let left = 0n, bump = 0n, total = 0n;
    for (const point of BUMP_POINTS) {
        const right = t < point.at ? t : point.at, u = right - left, span = point.at - left;
        if (u > 0n) {
            const A = ray(String(config.forge.heat.startMultiplier)) + bump + ordinaryBonusRay;
            const inc = point.increment, d3 = T3(right) - T3(left), d5 = T5(right) - T5(left);
            total += A * A * u + A * inc * u * u / span + inc * inc * u * u * u / (3n * span * span)
                + B * B * (right * right - left * left) / (2n * AGE_CAP)
                + 4n * B * A * d3 / (3n * RAY)
                + 4n * B * inc * (3n * d5 - 5n * left * d3) / (15n * span * RAY);
        }
        if (t <= point.at)
            break;
        left = point.at;
        bump += point.increment;
    }
    if (ageSeconds > AGE_CAP)
        total += (ageSeconds - AGE_CAP) * (CORE_CAP + ordinaryBonusRay) ** 2n;
    return total;
}
export function integrateSquaredHeat(ageSeconds, activeSeconds, ordinaryBonusRay = 0n) {
    nonnegative(ageSeconds, activeSeconds, ordinaryBonusRay);
    const start = ageSeconds > AGE_CAP ? AGE_CAP : ageSeconds;
    return squaredHeatPrimitive(start + activeSeconds, ordinaryBonusRay) - squaredHeatPrimitive(start, ordinaryBonusRay);
}
/** Daily target accrues only during nonempty-pool intervals. No first-entrant windfall. */
export function accruedPoolBudget(epochTarget, occupiedSeconds, epochSeconds) {
    nonnegative(epochTarget, occupiedSeconds, epochSeconds);
    if (epochSeconds === 0n || occupiedSeconds > epochSeconds)
        throw new Error('Invalid occupied-time interval');
    return epochTarget * occupiedSeconds / epochSeconds;
}
