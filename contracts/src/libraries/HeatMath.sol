// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";

/// @title HeatMath
/// @notice Heat accounting at RAY (1e27) scale with ages in seconds (spec v5.5).
///         heatPrimitive / integrateHeat / cooledAge / deedAge are EXACT integer ports of
///         canonical/accounting.ts (bit-for-bit equal on the generated vectors).
///         lotHeat is the instantaneous display multiplier (float oracle, 1e-12).
library HeatMath {
    error OrdinaryBonusAboveCeiling(uint256 bonusRay);
    error InvalidWithdrawal(uint256 withdrawn, uint256 referenceStake);
    error LengthMismatch();

    /// @dev Financial age is capped before any further math (spec §1, §cooling).
    function cappedAge(uint256 ageSeconds) internal pure returns (uint256) {
        return ageSeconds < P.HEAT_AGE_CAP ? ageSeconds : P.HEAT_AGE_CAP;
    }

    /// @notice Canonical antiderivative of lot Heat, RAY-seconds, rounded once per evaluation.
    ///         ∫(1 + 1.5·√(a/R) + bump(a)) da with the bump integrated per linear segment;
    ///         past the cap Heat is constant at the core cap (3.0×).
    function heatPrimitive(uint256 ageSeconds) internal pure returns (uint256 result) {
        uint256 a = cappedAge(ageSeconds);
        // ∫1.5·√(a/R) = a^(3/2)/√R  →  isqrt(a³·RAY²/R) · (2·1.5·RAY) / (3·RAY)
        uint256 sqrtPrimitive = Math.sqrt(Math.mulDiv(a * a * a, P.RAY * P.RAY, P.HEAT_AGE_CAP));
        result = a * P.HEAT_START_RAY + (sqrtPrimitive * (2 * P.HEAT_RAMP_BONUS_RAY)) / (3 * P.RAY);
        uint256 left;
        uint256 bump;
        for (uint256 i; i < P.MILESTONE_COUNT; ++i) {
            (uint256 at, uint256 inc) = _milestone(i);
            uint256 duration = (a < at ? a : at) - left;
            if (duration > 0) result += duration * bump + (inc * duration * duration) / (2 * (at - left));
            if (a <= at) break;
            left = at;
            bump += inc;
        }
        if (ageSeconds > P.HEAT_AGE_CAP) result += (ageSeconds - P.HEAT_AGE_CAP) * P.HEAT_CORE_CAP_RAY;
    }

    /// @notice Time-integrated Heat of one lot over [age, age+active], plus a constant
    ///         ordinary bonus (Capstone + Pyre, ≤ 0.65×). Differences telescope under
    ///         checkpoint subdivision, so page/checkpoint boundaries never change totals.
    function integrateHeat(uint256 ageSeconds, uint256 activeSeconds, uint256 ordinaryBonusRay)
        internal
        pure
        returns (uint256)
    {
        if (ordinaryBonusRay > P.MAX_ORDINARY_BONUS_RAY) revert OrdinaryBonusAboveCeiling(ordinaryBonusRay);
        uint256 start = cappedAge(ageSeconds);
        return heatPrimitive(start + activeSeconds) - heatPrimitive(start) + ordinaryBonusRay * activeSeconds;
    }

    /// @notice Canonical antiderivative of ordinary Heat SQUARED (the Ashfall weight), RAY²-seconds.
    ///         Exact port of `squaredHeatPrimitive`: on each bump interval H = A + m·(a−left) + B·√(a/R)
    ///         is squared into polynomial terms plus a^(3/2) and a^(5/2) primitives, each floored as the
    ///         reference floors it. Past the cap Heat is constant at the core cap plus the bonus.
    function squaredHeatPrimitive(uint256 ageSeconds, uint256 ordinaryBonusRay) internal pure returns (uint256) {
        return _squaredBetween(0, ageSeconds, ordinaryBonusRay);
    }

    /// @notice ∫H² over [age, age+active] at a constant ordinary bonus: exactly
    ///         `squaredHeatPrimitive(end) − squaredHeatPrimitive(start)` of `integrateSquaredHeat`.
    function integrateSquaredHeat(uint256 ageSeconds, uint256 activeSeconds, uint256 ordinaryBonusRay)
        internal
        pure
        returns (uint256)
    {
        uint256 start = cappedAge(ageSeconds);
        return _squaredBetween(start, start + activeSeconds, ordinaryBonusRay);
    }

    /// @dev P(to) − P(from) for from ≤ R. Both primitives sum the same floored terms for every
    ///      interval that ends at or before `from`, so those cancel exactly and are skipped: the
    ///      walk starts at the interval holding `from`, adds each term up to `to`, and subtracts
    ///      that interval's partial term up to `from`. The roots at the milestones are generated
    ///      constants; only `from` and `to` need live roots.
    function _squaredBetween(uint256 from, uint256 to, uint256 ordinaryBonusRay) private pure returns (uint256 total) {
        if (ordinaryBonusRay > P.MAX_ORDINARY_BONUS_RAY) revert OrdinaryBonusAboveCeiling(ordinaryBonusRay);
        uint256 t = cappedAge(to);
        uint256 a = P.HEAT_START_RAY + ordinaryBonusRay;
        uint256 left;
        for (uint256 i; i < P.MILESTONE_COUNT; ++i) {
            (uint256 at, uint256 inc) = _milestone(i);
            if (at > from) {
                uint256 right = t < at ? t : at;
                if (right > left) total += _termTo(i, a, left, right);
                if (from > left) {
                    total -= _termTo(i, a, left, from);
                    from = 0; // only the first interval walked holds `from`
                }
            }
            if (t <= at) break;
            left = at;
            a += inc;
        }
        if (to > P.HEAT_AGE_CAP) {
            uint256 c = P.HEAT_CORE_CAP_RAY + ordinaryBonusRay;
            total += (to - P.HEAT_AGE_CAP) * c * c;
        }
    }

    /// @dev The term of bump interval i from its left end to x (left < x ≤ the milestone).
    function _termTo(uint256 i, uint256 a, uint256 left, uint256 x) private pure returns (uint256) {
        (uint256 at, uint256 inc) = _milestone(i);
        (uint256 t3Left, uint256 t5Left) = i == 0 ? (0, 0) : _roots(i - 1);
        (uint256 t3, uint256 t5) = x == at ? _roots(i) : (_t3(x), _t5(x));
        return _squaredTerm(a, inc, left, x, at - left, t3 - t3Left, t5 - t5Left);
    }

    /// @notice Executed ordinary withdrawal of `withdrawn` out of `referenceStake`: the
    ///         surviving lot's age is capped FIRST, then scaled by the surviving fraction.
    ///         Not applied on arm/cancel/lapse, or to Taps.
    function cooledAge(uint256 ageSeconds, uint256 withdrawn, uint256 referenceStake) internal pure returns (uint256) {
        if (referenceStake == 0 || withdrawn > referenceStake) revert InvalidWithdrawal(withdrawn, referenceStake);
        return Math.mulDiv(cappedAge(ageSeconds), referenceStake - withdrawn, referenceStake);
    }

    /// @notice Deed buyer inherits 80% of the capped financial AGE — not of the multiplier.
    function deedAge(uint256 sellerAgeSeconds) internal pure returns (uint256) {
        return (cappedAge(sellerAgeSeconds) * P.DEED_HEAT_CARRY_PCT) / 100;
    }

    /// @notice Instantaneous lot multiplier (display / previews): 1 + 1.5·√(a/R) + bump(a).
    function lotHeat(uint256 ageSeconds) internal pure returns (uint256) {
        uint256 a = cappedAge(ageSeconds);
        uint256 rootRay = Math.sqrt(Math.mulDiv(a, P.RAY * P.RAY, P.HEAT_AGE_CAP));
        return P.HEAT_START_RAY + Math.mulDiv(P.HEAT_RAMP_BONUS_RAY, rootRay, P.RAY) + milestoneBump(a);
    }

    /// @notice Milestone bumps prorated linearly between milestones — no step cliffs.
    function milestoneBump(uint256 ageSeconds) internal pure returns (uint256 total) {
        uint256 prev;
        for (uint256 i; i < P.MILESTONE_COUNT; ++i) {
            (uint256 at, uint256 inc) = _milestone(i);
            if (ageSeconds >= at) {
                total += inc;
                prev = at;
            } else {
                return total + (inc * (ageSeconds - prev)) / (at - prev);
            }
        }
    }

    /// @notice Stake-weighted instantaneous position Heat: Σ(lp·lotHeat)/Σlp. Lots are never merged.
    function positionHeat(uint256[] memory lotLp, uint256[] memory lotAgeSeconds) internal pure returns (uint256) {
        if (lotLp.length != lotAgeSeconds.length) revert LengthMismatch();
        uint256 weighted;
        uint256 total;
        for (uint256 i; i < lotLp.length; ++i) {
            weighted += lotLp[i] * lotHeat(lotAgeSeconds[i]);
            total += lotLp[i];
        }
        return total == 0 ? 0 : weighted / total;
    }

    /// @dev The reference's six terms for [left, right] in a bump interval of length `span`, in its
    ///      order and with its floors. Bounds (a ≤ 2.05e27, span ≤ 185 days, d3 ≤ R·RAY,
    ///      d5 ≤ R²·RAY) keep the first four within 256 bits; the root terms go through mulDiv.
    ///      (3·d5 − 5·left·d3) is ∝ ∫(x−left)√x dx ≥ 0, and its floor errors (≤ 3 + 5·left) are far
    ///      below its value for any u ≥ 1, so the checked subtraction never underflows and the
    ///      reference's BigInt truncation equals this floor.
    function _squaredTerm(uint256 a, uint256 inc, uint256 left, uint256 right, uint256 span, uint256 d3, uint256 d5)
        private
        pure
        returns (uint256 r)
    {
        uint256 u = right - left;
        uint256 b = P.HEAT_RAMP_BONUS_RAY;
        r = a * a * u + (a * inc * u * u) / span + (inc * inc * u * u * u) / (3 * span * span)
            + (b * b * (right * right - left * left)) / (2 * P.HEAT_AGE_CAP);
        r += Math.mulDiv(4 * b * a, d3, 3 * P.RAY);
        r += Math.mulDiv(4 * b * inc, 3 * d5 - 5 * left * d3, 15 * span * P.RAY);
    }

    /// @dev T3(x) = isqrt(x³·RAY²/R) for x ≤ R (the radicand fits 256 bits).
    function _t3(uint256 x) private pure returns (uint256) {
        return Math.sqrt(Math.mulDiv(x * x * x, P.RAY * P.RAY, P.HEAT_AGE_CAP));
    }

    /// @dev T5(x) = isqrt(⌊x⁵·RAY²/R⌋) for x ≤ R. The radicand needs ~280 bits, so this runs
    ///      Newton's integer square root with ⌊N/s⌋ = ⌊x⁵·RAY²/(R·s)⌋ from mulDiv, starting
    ///      from an over-estimate: √N = 1e9·√(x⁵·1e36/R) ≤ 1e9·(isqrt(⌊x⁵·1e36/R⌋) + 1).
    function _t5(uint256 x) private pure returns (uint256 s) {
        if (x == 0) return 0;
        uint256 q = x * x * x * x * x;
        s = (Math.sqrt(Math.mulDiv(q, 1e36, P.HEAT_AGE_CAP)) + 1) * 1e9;
        while (true) {
            uint256 next = (s + Math.mulDiv(q, P.RAY * P.RAY, P.HEAT_AGE_CAP * s)) / 2;
            if (next >= s) return s;
            s = next;
        }
    }

    function _roots(uint256 i) private pure returns (uint256 t3, uint256 t5) {
        if (i == 0) return (P.MILESTONE_0_T3, P.MILESTONE_0_T5);
        if (i == 1) return (P.MILESTONE_1_T3, P.MILESTONE_1_T5);
        if (i == 2) return (P.MILESTONE_2_T3, P.MILESTONE_2_T5);
        if (i == 3) return (P.MILESTONE_3_T3, P.MILESTONE_3_T5);
        return (P.MILESTONE_4_T3, P.MILESTONE_4_T5);
    }

    function _milestone(uint256 i) private pure returns (uint256 at, uint256 inc) {
        if (i == 0) return (P.MILESTONE_0_SECONDS, P.MILESTONE_0_BUMP_RAY);
        if (i == 1) return (P.MILESTONE_1_SECONDS, P.MILESTONE_1_BUMP_RAY);
        if (i == 2) return (P.MILESTONE_2_SECONDS, P.MILESTONE_2_BUMP_RAY);
        if (i == 3) return (P.MILESTONE_3_SECONDS, P.MILESTONE_3_BUMP_RAY);
        return (P.MILESTONE_4_SECONDS, P.MILESTONE_4_BUMP_RAY);
    }
}
