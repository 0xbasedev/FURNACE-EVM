// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";

/// @title EmissionMath
/// @notice Base emission curve and the shared mint-headroom budget (spec §1, §12).
///         Reference oracle: baseEmissionPerDay / totalMintForEpoch in furnace.config.ts.
library EmissionMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant LN2_WAD = 693147180559945309;
    /// @dev Past 59 half-lives 2^-d ≈ 1.7e-18: the curve term is zero at WAD precision.
    uint256 internal constant NEGLIGIBLE_HALF_LIVES = 59;

    /// @notice Network-wide target for epoch-day `day`: max(floor, start · 2^(−day/halfLife)).
    ///         A TARGET only — what mints is bounded by headroom (totalMintForEpoch).
    function baseEmissionPerDay(uint256 day) internal pure returns (uint256) {
        uint256 curve;
        if (day < NEGLIGIBLE_HALF_LIVES * P.EMISSION_HALF_LIFE_DAYS) {
            int256 x = -int256((LN2_WAD * day) / P.EMISSION_HALF_LIFE_DAYS);
            curve = Math.mulDiv(P.EMISSION_START_PER_DAY, uint256(FixedPointMathLib.expWad(x)), WAD);
        }
        return curve > P.EMISSION_FLOOR_PER_DAY ? curve : P.EMISSION_FLOOR_PER_DAY;
    }

    /// @notice ONE headroom budget for base emission + Ashfall: 21M − canonical supply.
    ///         When short, both scale down pro-rata; rounding is down, so
    ///         base + ashfall ≤ headroom always. Burns reopen headroom.
    /// @param canonicalSupply must be the GLOBAL canonical supply (see docs/adr/0001).
    function totalMintForEpoch(uint256 baseTarget, uint256 ashfallTarget, uint256 canonicalSupply)
        internal
        pure
        returns (uint256 base, uint256 ashfall)
    {
        uint256 headroom = canonicalSupply < P.EMBER_MAX_SUPPLY ? P.EMBER_MAX_SUPPLY - canonicalSupply : 0;
        uint256 total = baseTarget + ashfallTarget;
        if (total <= headroom) return (baseTarget, ashfallTarget);
        base = Math.mulDiv(baseTarget, headroom, total);
        ashfall = Math.mulDiv(ashfallTarget, headroom, total);
    }
}
