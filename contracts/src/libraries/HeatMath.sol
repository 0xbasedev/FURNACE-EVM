// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";

/// @title HeatMath
/// @notice Per-lot Heat, proportional cooling and Deed age carry (spec §1, §4, §5).
///         All multipliers are WAD (1e18 = 1.0×); ages are seconds.
///         Reference oracle: heatMultiplier / cooledAgeAfterWithdrawal / deedHeatAge
///         in furnace.config.ts (differentially tested).
library HeatMath {
    uint256 internal constant WAD = 1e18;

    error FractionAboveOne(uint256 fractionWad);
    error LengthMismatch();

    /// @dev Stored ages are capped at the ramp before any further math (spec §1).
    function cappedAge(uint256 ageSeconds) internal pure returns (uint256) {
        return ageSeconds < P.HEAT_RAMP_SECONDS ? ageSeconds : P.HEAT_RAMP_SECONDS;
    }

    /// @notice lotHeat = 1.0 + 1.5·√(age/365d) + bump(age). Continuous; max 3.0×.
    function lotHeat(uint256 ageSeconds) internal pure returns (uint256) {
        uint256 a = cappedAge(ageSeconds);
        // √(a/R) in WAD = √(a·1e36/R). a ≤ R ≈ 3.2e7, so a·1e36 cannot overflow.
        uint256 rootWad = Math.sqrt((a * 1e36) / P.HEAT_RAMP_SECONDS);
        return P.HEAT_START_WAD + (P.HEAT_RAMP_BONUS_WAD * rootWad) / WAD + milestoneBump(a);
    }

    /// @notice Milestone bumps prorated linearly between milestones — no step cliffs.
    ///         Bumps belong to the lot's age, never to badge ownership.
    function milestoneBump(uint256 ageSeconds) internal pure returns (uint256 total) {
        uint256 prev;
        for (uint256 i; i < P.MILESTONE_COUNT; ++i) {
            (uint256 at, uint256 bump) = _milestone(i);
            if (ageSeconds >= at) {
                total += bump;
                prev = at;
            } else {
                return total + (bump * (ageSeconds - prev)) / (at - prev);
            }
        }
    }

    /// @notice Stake-weighted position Heat: Σ(lp·lotHeat) / Σ(lp). Lots are never merged.
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

    /// @notice Executed ordinary withdrawal of fraction f: each remaining lot's age is
    ///         capped FIRST, then scaled by (1 − f). Not applied on arm/cancel/expiry, or to Taps.
    function cooledAge(uint256 ageSeconds, uint256 fractionWad) internal pure returns (uint256) {
        if (fractionWad > WAD) revert FractionAboveOne(fractionWad);
        return Math.mulDiv(cappedAge(ageSeconds), WAD - fractionWad, WAD);
    }

    /// @notice Deed buyer inherits heatCarry (80%) of the capped Heat AGE — not of the multiplier.
    function deedHeatAge(uint256 sellerAgeSeconds) internal pure returns (uint256) {
        return Math.mulDiv(cappedAge(sellerAgeSeconds), P.DEED_HEAT_CARRY_WAD, WAD);
    }

    function _milestone(uint256 i) private pure returns (uint256 at, uint256 bump) {
        if (i == 0) return (P.MILESTONE_0_SECONDS, P.MILESTONE_0_BUMP_WAD);
        if (i == 1) return (P.MILESTONE_1_SECONDS, P.MILESTONE_1_BUMP_WAD);
        if (i == 2) return (P.MILESTONE_2_SECONDS, P.MILESTONE_2_BUMP_WAD);
        if (i == 3) return (P.MILESTONE_3_SECONDS, P.MILESTONE_3_BUMP_WAD);
        return (P.MILESTONE_4_SECONDS, P.MILESTONE_4_BUMP_WAD);
    }
}
