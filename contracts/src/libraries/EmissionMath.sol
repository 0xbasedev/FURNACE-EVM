// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";
import {ScheduleTable} from "../generated/ScheduleTable.sol";

/// @title EmissionMath
/// @notice Base schedule, shared mint headroom and occupied-time pool budgets (spec v5.5).
///         allocateMint / accruedPoolBudget are EXACT ports of canonical/accounting.ts;
///         baseEmissionPerDay is the EXACT port of scripts/schedule.ts (ADR 0002).
library EmissionMath {
    uint256 internal constant WAD = 1e18;

    error InvalidOccupiedInterval(uint256 occupiedSeconds, uint256 epochSeconds);

    /// @notice Network-wide daily target at epoch-day `day`: max(floor, start · 2^(−day/halfLife)),
    ///         evaluated exactly: q = day / H, r = day % H,
    ///         curve = ⌊START · F[r] / 1e18⌋ >> q  (nested floors commute, so the order of the
    ///         division and the shift cannot change the result; ADR 0002).
    ///         A TARGET evaluated at epoch start; what mints is bounded by allocateMint.
    function baseEmissionPerDay(uint256 day) internal pure returns (uint256) {
        uint256 q = day / P.EMISSION_HALF_LIFE_DAYS;
        uint256 curve;
        if (q < 256) {
            curve = (P.EMISSION_START_PER_DAY * ScheduleTable.factor(day % P.EMISSION_HALF_LIFE_DAYS)) / WAD >> q;
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
