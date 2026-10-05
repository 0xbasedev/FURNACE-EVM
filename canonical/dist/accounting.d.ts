export declare const RAY: bigint;
export declare const DAY = 86400n;
export declare function nonnegative(...values: bigint[]): void;
export declare function parseUnits(amount: string, decimals: number): bigint;
export declare const ray: (amount: string) => bigint;
export declare function isqrt(n: bigint): bigint;
export declare const AGE_CAP: bigint;
/** Canonical antiderivative, rounded ONCE at each evaluation; units RAY-seconds. */
export declare function heatPrimitive(ageSeconds: bigint): bigint;
export declare function integrateHeat(ageSeconds: bigint, activeSeconds: bigint, ordinaryBonusRay?: bigint): bigint;
export declare function cooledAge(ageSeconds: bigint, withdrawn: bigint, referenceStake: bigint): bigint;
export declare function deedAge(ageSeconds: bigint): bigint;
export declare function vested(total: bigint, elapsedSeconds: bigint, durationSeconds: bigint): bigint;
export interface Measures {
    stakeSeconds: bigint;
    heatSeconds: bigint;
    sealSeconds: bigint;
    candidateSeconds: bigint;
}
export declare function segmentMeasures(stake: bigint, ageSeconds: bigint, activeSeconds: bigint, ordinaryBonus?: bigint, sealBonus?: bigint): Measures;
export declare function sumMeasures(parts: readonly Measures[]): Measures;
export interface PositionMeasure extends Measures {
    id: string;
}
export interface EpochPayout {
    id: string;
    ordinary: bigint;
    escrow: bigint;
}
export interface Settlement {
    payouts: EpochPayout[];
    flatBudget: bigint;
    heatBudget: bigint;
    escrowPaid: bigint;
    residue: bigint;
}
/** Fixed-budget reference over complete, authenticated position measures. */
export declare function settleBaseEpoch(budget: bigint, positions: readonly PositionMeasure[]): Settlement;
/** Headroom arithmetic only. The caller must authenticate the global ledger and burn credits. */
export declare function allocateMint(cap: bigint, globallyAccounted: bigint, reserved: bigint, baseTarget: bigint, authorizedAshfall: bigint): {
    base: bigint;
    ashfall: bigint;
    unmintedResidue: bigint;
};
export interface MatchDemand {
    id: string;
    quoteDemand: bigint;
}
/** Demand and budget must be denominated in the SAME quote asset and valuation checkpoint. */
export declare function allocateMatching(quoteBudget: bigint, demands: readonly MatchDemand[]): {
    grants: {
        id: string;
        quote: bigint;
    }[];
    unreserved: bigint;
};
/** One-use credit bookkeeping reference. No token transfer is performed. */
export declare class MatchReservations {
    private remaining;
    constructor(grants: readonly {
        id: string;
        quote: bigint;
    }[]);
    consume(id: string, quote: bigint): void;
    release(id: string): bigint;
}
/** In-kind escrow accounting reference, not a custody smart contract. */
export declare class KindlingEscrow {
    state: 'open' | 'succeeded' | 'failed';
    private positions;
    treasuryReleased: bigint;
    deposit(id: string, gross: bigint): {
        net: bigint;
        fee: bigint;
    };
    cancel(id: string, netAmount: bigint): bigint;
    settle(success: boolean): bigint;
    refund(id: string): bigint;
    claimNetForLp(id: string): bigint;
}
/**
 * Canonical antiderivative of ordinary Heat squared, in RAY^2-seconds.
 * On each bump segment H(t)=A+m(t-left)+B sqrt(t/R). Expanding the square
 * gives polynomial terms and t^(3/2), t^(5/2) primitives. BigInt permits
 * wide intermediates; an EVM port requires explicitly bounded mulDiv math.
 */
export declare function squaredHeatPrimitive(ageSeconds: bigint, ordinaryBonusRay?: bigint): bigint;
export declare function integrateSquaredHeat(ageSeconds: bigint, activeSeconds: bigint, ordinaryBonusRay?: bigint): bigint;
/** Daily target accrues only during nonempty-pool intervals. No first-entrant windfall. */
export declare function accruedPoolBudget(epochTarget: bigint, occupiedSeconds: bigint, epochSeconds: bigint): bigint;
