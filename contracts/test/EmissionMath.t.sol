// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EmissionMath} from "../src/libraries/EmissionMath.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {OracleVectors} from "./utils/OracleVectors.sol";

contract EmissionHarness {
    function accruedPoolBudget(uint256 a, uint256 b, uint256 c) external pure returns (uint256) { return EmissionMath.accruedPoolBudget(a, b, c); }
}

contract EmissionMathTest is OracleVectors {
    function setUp() public {
        _loadVectors();
    }

    // ── Exact differential vs canonical/accounting.ts ────────────────────
    function test_allocateMint_exact() public view {
        uint256[] memory acc = _uints(".mint.accounted");
        uint256[] memory res = _uints(".mint.reserved");
        uint256[] memory b = _uints(".mint.base");
        uint256[] memory a = _uints(".mint.ashfall");
        uint256[] memory ob = _uints(".mint.outBase");
        uint256[] memory oa = _uints(".mint.outAshfall");
        uint256[] memory orr = _uints(".mint.outResidue");
        for (uint256 i; i < acc.length; ++i) {
            (uint256 gb, uint256 ga, uint256 gr) = EmissionMath.allocateMint(acc[i], res[i], b[i], a[i]);
            assertEq(gb, ob[i], "base");
            assertEq(ga, oa[i], "ashfall");
            assertEq(gr, orr[i], "residue");
        }
    }

    function test_accruedPoolBudget_exact() public view {
        uint256[] memory t = _uints(".poolBudget.target");
        uint256[] memory o = _uints(".poolBudget.occupied");
        uint256[] memory want = _uints(".poolBudget.out");
        for (uint256 i; i < t.length; ++i) assertEq(EmissionMath.accruedPoolBudget(t[i], o[i], P.EPOCH_SECONDS), want[i]);
    }

    function test_baseEmission_matchesFloatOracle() public view {
        uint256[] memory day = _uints(".emission.day");
        uint256[] memory want = _uints(".emission.wad");
        for (uint256 i; i < day.length; ++i) _assertNearFloat(EmissionMath.baseEmissionPerDay(day[i]), want[i], "baseEmissionPerDay");
    }

    // ── Spec anchors ─────────────────────────────────────────────────────
    function test_curveAnchors() public pure {
        assertEq(EmissionMath.baseEmissionPerDay(0), 21_600e18);
        assertApproxEqRel(EmissionMath.baseEmissionPerDay(365), 10_800e18, 1e6, "one half-life");
        // 21,600 · 2^(−d/365) = 1,000 at d ≈ 1,618.03 (spec: "around day 1,618").
        assertGt(EmissionMath.baseEmissionPerDay(1618), 1_000e18);
        assertEq(EmissionMath.baseEmissionPerDay(1619), 1_000e18);
        assertEq(EmissionMath.baseEmissionPerDay(type(uint64).max), 1_000e18, "no overflow far out");
    }

    function test_poolBudget_rejectsBadInterval() public {
        EmissionHarness h = new EmissionHarness();
        vm.expectRevert(abi.encodeWithSelector(EmissionMath.InvalidOccupiedInterval.selector, 2, 1));
        h.accruedPoolBudget(1, 2, 1);
        vm.expectRevert(abi.encodeWithSelector(EmissionMath.InvalidOccupiedInterval.selector, 0, 0));
        h.accruedPoolBudget(1, 0, 0);
    }

    // ── Properties ───────────────────────────────────────────────────────
    function testFuzz_curve_monotoneAndBounded(uint256 d) public pure {
        d = bound(d, 0, 100_000);
        uint256 e = EmissionMath.baseEmissionPerDay(d);
        assertLe(e, P.EMISSION_START_PER_DAY);
        assertGe(e, P.EMISSION_FLOOR_PER_DAY);
        assertLe(EmissionMath.baseEmissionPerDay(d + 1), e, "non-increasing");
    }

    function testFuzz_allocateMint_conservesSharedHeadroom(uint256 acc, uint256 res, uint128 base, uint128 ash) public pure {
        acc = bound(acc, 0, P.EMBER_MAX_SUPPLY + 1e24);
        res = bound(res, 0, P.EMBER_MAX_SUPPLY);
        (uint256 b, uint256 a, uint256 r) = EmissionMath.allocateMint(acc, res, base, ash);
        uint256 room = P.EMBER_MAX_SUPPLY > acc + res ? P.EMBER_MAX_SUPPLY - acc - res : 0;
        uint256 total = uint256(base) + ash;
        uint256 available = total < room ? total : room;
        assertEq(b + a + r, available, "base + ashfall + tagged residue = available");
        assertLe(b + a, room, "never past headroom");
        assertLe(r, 1, "floor residue is at most 1 wei for two buckets");
        if (total <= room) {
            assertEq(b, base);
            assertEq(a, ash);
        }
    }
}
