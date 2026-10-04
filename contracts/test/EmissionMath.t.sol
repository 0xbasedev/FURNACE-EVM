// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EmissionMath} from "../src/libraries/EmissionMath.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {OracleVectors} from "./utils/OracleVectors.sol";

contract EmissionMathTest is OracleVectors {
    function setUp() public {
        _loadVectors();
    }

    // ── Differential vs furnace.config.ts ────────────────────────────────
    function test_baseEmission_matchesOracle() public view {
        uint256[] memory day = _uints(".emission.day");
        uint256[] memory want = _uints(".emission.wad");
        for (uint256 i; i < day.length; ++i) _assertNear(EmissionMath.baseEmissionPerDay(day[i]), want[i], "baseEmissionPerDay");
    }

    function test_totalMint_matchesOracle() public view {
        uint256[] memory b = _uints(".mint.base");
        uint256[] memory a = _uints(".mint.ashfall");
        uint256[] memory s = _uints(".mint.supply");
        uint256[] memory eb = _uints(".mint.expBase");
        uint256[] memory ea = _uints(".mint.expAshfall");
        for (uint256 i; i < b.length; ++i) {
            (uint256 gb, uint256 ga) = EmissionMath.totalMintForEpoch(b[i], a[i], s[i]);
            _assertNear(gb, eb[i], "base");
            _assertNear(ga, ea[i], "ashfall");
        }
    }

    // ── Spec anchors ─────────────────────────────────────────────────────
    function test_curveAnchors() public pure {
        assertEq(EmissionMath.baseEmissionPerDay(0), 21_600e18);
        assertApproxEqRel(EmissionMath.baseEmissionPerDay(365), 10_800e18, 1e6, "one half-life");
        // 21,600 · 2^(−d/365) = 1,000 at d ≈ 1,618.03 (spec: "around day 1,618").
        assertGt(EmissionMath.baseEmissionPerDay(1618), 1_000e18);
        assertEq(EmissionMath.baseEmissionPerDay(1619), 1_000e18, "floor from day 1,619");
        assertEq(EmissionMath.baseEmissionPerDay(type(uint64).max), 1_000e18, "no overflow far out");
    }

    // ── Properties ───────────────────────────────────────────────────────
    function testFuzz_curve_monotoneAndBounded(uint256 d) public pure {
        d = bound(d, 0, 100_000);
        uint256 e = EmissionMath.baseEmissionPerDay(d);
        assertLe(e, P.EMISSION_START_PER_DAY);
        assertGe(e, P.EMISSION_FLOOR_PER_DAY);
        assertLe(EmissionMath.baseEmissionPerDay(d + 1), e, "non-increasing");
    }

    function testFuzz_headroom_neverExceeded(uint128 base, uint128 ash, uint256 supply) public pure {
        supply = bound(supply, 0, P.EMBER_MAX_SUPPLY + 1e24);
        (uint256 b, uint256 a) = EmissionMath.totalMintForEpoch(base, ash, supply);
        uint256 room = supply < P.EMBER_MAX_SUPPLY ? P.EMBER_MAX_SUPPLY - supply : 0;
        assertLe(b + a, room, "shared budget");
        assertLe(b, base);
        assertLe(a, ash);
        if (uint256(base) + ash <= room) {
            assertEq(b, base);
            assertEq(a, ash);
        } else {
            // Pro-rata: both buckets scale by the same factor (within 1 wei of rounding).
            assertApproxEqAbs(b * (uint256(base) + ash), uint256(base) * room, uint256(base) + ash);
            assertApproxEqAbs(a * (uint256(base) + ash), uint256(ash) * room, uint256(base) + ash);
            assertGe(b + a + 2, room, "short budget is used, minus rounding");
        }
    }
}
