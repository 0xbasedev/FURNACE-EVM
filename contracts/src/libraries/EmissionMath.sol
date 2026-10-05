// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";

/// @title EmissionMath
/// @notice Base schedule, shared mint headroom and occupied-time pool budgets (spec v5.5).
///         allocateMint / accruedPoolBudget are EXACT ports of canonical/accounting.ts.
library EmissionMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant LN2_WAD = 693147180559945309;
    /// @dev Past 59 half-lives 2^-d ≈ 1.7e-18: the curve term is zero at WAD precision.
    uint256 internal constant NEGLIGIBLE_HALF_LIVES = 59;

    error InvalidOccupiedInterval(uint256 occupiedSeconds, uint256 epochSeconds);

    /// @notice Network-wide daily target at epoch-day `day`: max(floor, start · 2^(−day/halfLife)).
    ///         A TARGET evaluated at epoch start; what mints is bounded by allocateMint.
    function baseEmissionPerDay(uint256 day) internal pure returns (uint256) {
        uint256 curve;
        if (day < NEGLIGIBLE_HALF_LIVES * P.EMISSION_HALF_LIFE_DAYS) {
            int256 x = -int256((LN2_WAD * day) / P.EMISSION_HALF_LIFE_DAYS);
            curve = Math.mulDiv(P.EMISSION_START_PER_DAY, uint256(FixedPointMathLib.expWad(x)), WAD);
        }
        return curve > P.EMISSION_FLOOR_PER_DAY ? curve : P.EMISSION_FLOOR_PER_DAY;
    }

    /// @notice ONE headroom budget for base + authorized Ashfall:
    ///         21M − globallyAccounted − reserved (Genesis/vesting reservations).
    ///         When short, both scale pro-rata; the floor-rounding residue stays unminted and tagged.
    /// @param globallyAccounted must come from the Mantle's authenticated global ledger
    ///        (including outstanding transport claims) — never a local totalSupply().
    function allocateMint(uint256 globallyAccounted, uint256 reserved, uint256 baseTarget, uint256 authorizedAshfall)
        internal
        pure
        returns (uint256 base, uint256 ashfall, uint256 unmintedResidue)
    {
        uint256 used = globallyAccounted + reserved;
        uint256 headroom = P.EMBER_MAX_SUPPLY > used ? P.EMBER_MAX_SUPPLY - used : 0;
        uint256 total = baseTarget + authorizedAshfall;
        uint256 available = total < headroom ? total : headroom;
        if (total != 0) {
            base = Math.mulDiv(available, baseTarget, total);
            ashfall = Math.mulDiv(available, authorizedAshfall, total);
        }
        unmintedResidue = available - base - ashfall;
    }

    /// @notice The daily target accrues only while the pool has active stake: no
    ///         first-entrant windfall from a previously empty day.
    function accruedPoolBudget(uint256 epochTarget, uint256 occupiedSeconds, uint256 epochSeconds)
        internal
        pure
        returns (uint256)
    {
        if (epochSeconds == 0 || occupiedSeconds > epochSeconds) revert InvalidOccupiedInterval(occupiedSeconds, epochSeconds);
        return Math.mulDiv(epochTarget, occupiedSeconds, epochSeconds);
    }
}
