// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HeatMath} from "../src/libraries/HeatMath.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {OracleVectors} from "./utils/OracleVectors.sol";

contract HeatMathHarness {
    function lotHeat(uint256 a) external pure returns (uint256) { return HeatMath.lotHeat(a); }
    function cooledAge(uint256 a, uint256 f) external pure returns (uint256) { return HeatMath.cooledAge(a, f); }
    function positionHeat(uint256[] memory lp, uint256[] memory ages) external pure returns (uint256) {
        return HeatMath.positionHeat(lp, ages);
    }
}

contract HeatMathTest is OracleVectors {
    uint256 constant WAD = 1e18;
    HeatMathHarness h;

    function setUp() public {
        _loadVectors();
        h = new HeatMathHarness();
    }

    // ── Differential vs furnace.config.ts ────────────────────────────────
    function test_lotHeat_matchesOracle() public view {
        uint256[] memory ages = _uints(".heat.ageSeconds");
        uint256[] memory want = _uints(".heat.wad");
        for (uint256 i; i < ages.length; ++i) _assertNear(HeatMath.lotHeat(ages[i]), want[i], "lotHeat");
    }

    function test_cooledAge_matchesOracle() public view {
        uint256[] memory ages = _uints(".cool.ageSeconds");
        uint256[] memory f = _uints(".cool.fractionWad");
        uint256[] memory want = _uints(".cool.expectedSeconds");
        for (uint256 i; i < ages.length; ++i) assertApproxEqAbs(HeatMath.cooledAge(ages[i], f[i]), want[i], 1, "cooledAge");
    }

    function test_deedHeatAge_matchesOracle() public view {
        uint256[] memory ages = _uints(".deed.ageSeconds");
        uint256[] memory want = _uints(".deed.expectedSeconds");
        for (uint256 i; i < ages.length; ++i) assertApproxEqAbs(HeatMath.deedHeatAge(ages[i]), want[i], 1, "deedHeatAge");
    }

    // ── Spec anchors ─────────────────────────────────────────────────────
    function test_specTable() public pure {
        assertEq(HeatMath.lotHeat(0), 1e18, "0d = 1.00x");
        assertEq(HeatMath.lotHeat(365 days), 3e18, "365d = 3.00x");
        assertEq(HeatMath.lotHeat(730 days), 3e18, "age capped");
        assertApproxEqAbs(HeatMath.lotHeat(180 days), 2.45337e18, 1e13, "180d = 1 + 1.5*sqrt(180/365) + 0.4");
        assertApproxEqAbs(HeatMath.milestoneBump(135 days), 0.35e18, 1, "135d bump +0.35");
    }

    function test_cooling_capsBeforeScaling() public pure {
        assertEq(HeatMath.cooledAge(730 days, 0.5e18), 182.5 days, "two-year lot cools like a one-year lot");
        assertEq(HeatMath.cooledAge(365 days, 0.5e18), 182.5 days);
        assertEq(HeatMath.deedHeatAge(730 days), 292 days, "cap before carry");
    }

    function test_cooling_rejectsFractionAboveOne() public {
        vm.expectRevert(abi.encodeWithSelector(HeatMath.FractionAboveOne.selector, WAD + 1));
        h.cooledAge(1 days, WAD + 1);
    }

    function test_positionHeat_lotsNotAveraged() public pure {
        // Equal LP in a 0-day and a 365-day lot: (1.0 + 3.0) / 2 = 2.0x.
        // Averaging timestamps instead (182.5d) would give ~2.46x — the lossy merge the spec forbids.
        uint256[] memory lp = new uint256[](2);
        uint256[] memory ages = new uint256[](2);
        lp[0] = 1e18; lp[1] = 1e18; ages[0] = 0; ages[1] = 365 days;
        assertEq(HeatMath.positionHeat(lp, ages), 2e18);
        assertGt(HeatMath.lotHeat(182.5 days), 2.4e18);
    }

    // ── Properties ───────────────────────────────────────────────────────
    function testFuzz_heat_boundedAndMonotonic(uint256 a, uint256 b) public pure {
        a = bound(a, 0, 1000 days);
        b = bound(b, a, 1000 days);
        uint256 ha = HeatMath.lotHeat(a);
        assertGe(ha, P.HEAT_START_WAD);
        assertLe(ha, 3e18);
        assertLe(ha, HeatMath.lotHeat(b), "non-decreasing in age");
    }

    function testFuzz_heat_noCliffs(uint256 a) public pure {
        a = bound(a, 1, 400 days);
        // One second of age never moves Heat by more than the steepest slope allows
        // (sqrt term near 0 dominates: 1.5·√(1/R) ≈ 2.7e-4 for the first second).
        uint256 d = HeatMath.lotHeat(a) - HeatMath.lotHeat(a - 1);
        assertLe(d, 2.7e14);
    }

    function testFuzz_cooledAge_bounds(uint256 age, uint256 f) public pure {
        age = bound(age, 0, 3650 days);
        f = bound(f, 0, WAD);
        uint256 c = HeatMath.cooledAge(age, f);
        assertLe(c, HeatMath.cappedAge(age));
        if (f == 0) assertEq(c, HeatMath.cappedAge(age));
        if (f == WAD) assertEq(c, 0);
    }

    function testFuzz_positionHeat_withinLotRange(uint96 lp0, uint96 lp1, uint32 a0, uint32 a1) public pure {
        vm.assume(uint256(lp0) + lp1 > 0);
        uint256[] memory lp = new uint256[](2);
        uint256[] memory ages = new uint256[](2);
        lp[0] = lp0; lp[1] = lp1; ages[0] = a0; ages[1] = a1;
        uint256 ph = HeatMath.positionHeat(lp, ages);
        uint256 h0 = HeatMath.lotHeat(a0);
        uint256 h1 = HeatMath.lotHeat(a1);
        assertGe(ph + 1, h0 < h1 ? h0 : h1);
        assertLe(ph, h0 > h1 ? h0 : h1);
    }
}
