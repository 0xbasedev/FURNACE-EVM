// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HeatMath} from "../src/libraries/HeatMath.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {OracleVectors} from "./utils/OracleVectors.sol";

contract HeatMathHarness {
    function integrateHeat(uint256 a, uint256 t, uint256 b) external pure returns (uint256) { return HeatMath.integrateHeat(a, t, b); }
    function cooledAge(uint256 a, uint256 w, uint256 r) external pure returns (uint256) { return HeatMath.cooledAge(a, w, r); }
}

contract HeatMathTest is OracleVectors {
    uint256 constant RAY = 1e27;
    HeatMathHarness h;

    function setUp() public {
        _loadVectors();
        h = new HeatMathHarness();
    }

    // ── Exact differential vs canonical/accounting.ts (BigInt) ───────────
    function test_heatPrimitive_exact() public view {
        uint256[] memory ages = _uints(".primitive.ageSeconds");
        uint256[] memory want = _uints(".primitive.ray");
        for (uint256 i; i < ages.length; ++i) assertEq(HeatMath.heatPrimitive(ages[i]), want[i], "heatPrimitive");
    }

    function test_integrateHeat_exact() public view {
        uint256[] memory a = _uints(".integrate.ageSeconds");
        uint256[] memory t = _uints(".integrate.activeSeconds");
        uint256[] memory b = _uints(".integrate.bonusRay");
        uint256[] memory want = _uints(".integrate.ray");
        for (uint256 i; i < a.length; ++i) assertEq(HeatMath.integrateHeat(a[i], t[i], b[i]), want[i], "integrateHeat");
    }

    function test_cooledAge_exact() public view {
        uint256[] memory a = _uints(".cool.ageSeconds");
        uint256[] memory w = _uints(".cool.withdrawn");
        uint256[] memory r = _uints(".cool.reference");
        uint256[] memory want = _uints(".cool.out");
        for (uint256 i; i < a.length; ++i) assertEq(HeatMath.cooledAge(a[i], w[i], r[i]), want[i], "cooledAge");
    }

    function test_deedAge_exact() public view {
        uint256[] memory a = _uints(".deed.ageSeconds");
        uint256[] memory want = _uints(".deed.out");
        for (uint256 i; i < a.length; ++i) assertEq(HeatMath.deedAge(a[i]), want[i], "deedAge");
    }

    function test_lotHeat_matchesFloatOracle() public view {
        uint256[] memory a = _uints(".lotHeat.ageSeconds");
        uint256[] memory want = _uints(".lotHeat.ray");
        for (uint256 i; i < a.length; ++i) _assertNearFloat(HeatMath.lotHeat(a[i]), want[i], "lotHeat");
    }

    // ── Spec anchors ─────────────────────────────────────────────────────
    function test_specAnchors() public pure {
        assertEq(HeatMath.lotHeat(0), RAY, "0d = 1.00x");
        assertEq(HeatMath.lotHeat(365 days), 3 * RAY, "365d = 3.00x");
        assertEq(HeatMath.lotHeat(730 days), 3 * RAY, "age capped");
        assertEq(HeatMath.milestoneBump(135 days), 0.35e27, "135d bump +0.35");
        assertEq(HeatMath.cooledAge(730 days, 1, 2), 182.5 days, "cap before scaling");
        assertEq(HeatMath.deedAge(730 days), 292 days, "cap before carry");
        // A full day at the cap integrates to exactly 3.0x · 1 day.
        assertEq(HeatMath.integrateHeat(365 days, 1 days, 0), 3 * RAY * 1 days);
    }

    function test_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(HeatMath.OrdinaryBonusAboveCeiling.selector, 0.65e27 + 1));
        h.integrateHeat(0, 1, 0.65e27 + 1);
        vm.expectRevert(abi.encodeWithSelector(HeatMath.InvalidWithdrawal.selector, 3, 2));
        h.cooledAge(1 days, 3, 2);
        vm.expectRevert(abi.encodeWithSelector(HeatMath.InvalidWithdrawal.selector, 0, 0));
        h.cooledAge(1 days, 0, 0);
    }

    // ── Properties ───────────────────────────────────────────────────────
    /// Checkpoint subdivision must not change the measure (± rounding of one extra evaluation).
    function testFuzz_integral_telescopes(uint256 age, uint256 t1, uint256 t2, uint256 bonus) public pure {
        age = bound(age, 0, 400 days);
        t1 = bound(t1, 0, 60 days);
        t2 = bound(t2, 0, 60 days);
        bonus = bound(bonus, 0, P.MAX_ORDINARY_BONUS_RAY);
        uint256 start = HeatMath.cappedAge(age);
        uint256 whole = HeatMath.integrateHeat(start, t1 + t2, bonus);
        uint256 split = HeatMath.integrateHeat(start, t1, bonus) + HeatMath.integrateHeat(start + t1, t2, bonus);
        assertEq(whole, split, "primitive differences telescope exactly");
    }

    function testFuzz_integral_boundedByMultiplierRange(uint256 age, uint256 t) public pure {
        age = bound(age, 0, 400 days);
        t = bound(t, 1, 60 days);
        uint256 m = HeatMath.integrateHeat(age, t, 0);
        assertGe(m + 1, RAY * t, ">= 1.0x per second (one rounding)");
        assertLe(m, 3 * RAY * t + 1, "<= 3.0x per second");
    }

    function testFuzz_lotHeat_boundedMonotone(uint256 a, uint256 b) public pure {
        a = bound(a, 0, 1000 days);
        b = bound(b, a, 1000 days);
        uint256 ha = HeatMath.lotHeat(a);
        assertGe(ha, P.HEAT_START_RAY);
        assertLe(ha, P.HEAT_CORE_CAP_RAY);
        assertLe(ha, HeatMath.lotHeat(b), "non-decreasing");
    }

    function testFuzz_cooledAge_bounds(uint256 age, uint256 ref, uint256 w) public pure {
        age = bound(age, 0, 3650 days);
        ref = bound(ref, 1, type(uint128).max);
        w = bound(w, 0, ref);
        uint256 c = HeatMath.cooledAge(age, w, ref);
        assertLe(c, HeatMath.cappedAge(age));
        if (w == 0) assertEq(c, HeatMath.cappedAge(age));
        if (w == ref) assertEq(c, 0);
    }

    function test_positionHeat_lotsNotAveraged() public pure {
        uint256[] memory lp = new uint256[](2);
        uint256[] memory ages = new uint256[](2);
        lp[0] = 1e18; lp[1] = 1e18; ages[0] = 0; ages[1] = 365 days;
        assertEq(HeatMath.positionHeat(lp, ages), 2 * RAY, "(1.0 + 3.0)/2");
        assertGt(HeatMath.lotHeat(182.5 days), 2.4e27, "timestamp averaging would overpay");
    }
}
