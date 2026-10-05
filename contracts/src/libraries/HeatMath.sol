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

    function _milestone(uint256 i) private pure returns (uint256 at, uint256 inc) {
        if (i == 0) return (P.MILESTONE_0_SECONDS, P.MILESTONE_0_BUMP_RAY);
        if (i == 1) return (P.MILESTONE_1_SECONDS, P.MILESTONE_1_BUMP_RAY);
        if (i == 2) return (P.MILESTONE_2_SECONDS, P.MILESTONE_2_BUMP_RAY);
        if (i == 3) return (P.MILESTONE_3_SECONDS, P.MILESTONE_3_BUMP_RAY);
        return (P.MILESTONE_4_SECONDS, P.MILESTONE_4_BUMP_RAY);
    }
}
