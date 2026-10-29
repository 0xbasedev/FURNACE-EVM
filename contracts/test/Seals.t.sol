// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {ForgeEmissions} from "../src/forge/ForgeEmissions.sol";
import {Seal, SealStatus} from "../src/forge/ForgeMeasures.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {SettlementFixture} from "./ForgeEmissions.t.sol";

/// @notice Seals (ADR 0006): custody transitions in ForgePool and escrow in ForgeEmissions.
contract SealsTest is SettlementFixture {
    address alice = _user(1);
    address bob = _user(2);
    uint256 t0;

    function setUp() public {
        vm.warp(1_800_000_000);
        t0 = block.timestamp;
        _deploySettlement(block.timestamp);
        _fund(alice);
        _fund(bob);
    }

    function _settle(uint256 e) internal {
        mantle.finalizeEpoch();
        emissions.openEpoch();
        for (uint256 i; i < 4; ++i) {
            while (true) {
                ForgeEmissions.Phase ph = emissions.poolEpoch(e, i).phase;
                if (ph == ForgeEmissions.Phase.None || ph == ForgeEmissions.Phase.Done) break;
                emissions.advance(e, i);
            }
        }
    }

    function _open(uint256 pool, address who, uint256 amount) internal returns (uint256 id) {
        vm.prank(who);
        id = pools[pool].open(amount);
    }

    function _seal(uint256 pool, address who, uint256 id, uint256 track) internal returns (uint256) {
        vm.prank(who);
        return pools[pool].seal(id, track);
    }

    // ── escrow: both sides of min(candidate, cap) ─────────────────────────

    function test_capBindsForASmallSealer() public {
        uint256 a = _open(0, alice, 100e18);
        _open(0, bob, 900e18);
        _seal(0, alice, a, 0); // +0.15 over 10% of the stake
        skip(1 days);
        _settle(0);
        ForgeEmissions.PoolEpoch memory pe = emissions.poolEpoch(0, 0);
        ForgeEmissions.Measure memory m = emissions.measureOf(0, 0, a);
        uint256 l = pe.admitted - pe.bucket - pe.flat;
        assertEq(m.escrow, Math.mulDiv(l, m.sealSeconds, pe.heatSeconds), "the cap binds");
        assertLt(m.escrow, pe.bucket, "below the candidate (the whole bucket)");
        assertEq(pe.escrow, m.escrow);
        assertEq(pe.heat, l + pe.bucket - m.escrow, "the unused bucket returns to Heat");
        assertEq(emissions.sealEscrow(0, a, 1), m.escrow, "locked under the running Seal");
        uint256 ordinary = Math.mulDiv(pe.flat, m.stakeSeconds, pe.stakeSeconds)
            + Math.mulDiv(pe.heat, m.heatSeconds, pe.heatSeconds);
        assertEq(emissions.unclaimed(0, a), ordinary, "only the ordinary part is claimable");
        (,, uint128 minted,, uint128 released,) = mantle.budgets(0);
        assertEq(minted + released, 21_600e18, "every base wei is minted or released");
    }

    function test_candidateSharesTheBucketBetweenSealers() public {
        uint256 a = _open(1, alice, 1000e18);
        uint256 b = _open(1, bob, 400e18);
        _seal(1, alice, a, 3);
        _seal(1, bob, b, 1);
        skip(1 days);
        _settle(0);
        ForgeEmissions.PoolEpoch memory pe = emissions.poolEpoch(0, 1);
        ForgeEmissions.Measure memory ma = emissions.measureOf(0, 1, a);
        ForgeEmissions.Measure memory mb = emissions.measureOf(0, 1, b);
        assertEq(ma.escrow, Math.mulDiv(pe.bucket, ma.candidateSeconds, pe.candidateSeconds), "candidate binds");
        assertEq(mb.escrow, Math.mulDiv(pe.bucket, mb.candidateSeconds, pe.candidateSeconds), "candidate binds");
        assertApproxEqAbs(pe.escrow, pe.bucket, 2, "the bucket is used up to floor dust");
        assertEq(ma.sealSeconds, ma.stakeSeconds * P.SEAL_TRACK_3_BONUS_RAY, "B = S x bonus over the whole epoch");
    }

    // ── custody transitions ───────────────────────────────────────────────

    function test_pauseExtendsTheTermAndCompletionIsBackDated() public {
        uint256 a = _open(0, alice, 100e18);
        _seal(0, alice, a, 0);
        skip(5 days);
        vm.prank(alice);
        uint32 t = pools[0].requestCooling(a, 1e18);
        assertEq(pools[0].sealOf(a, 1).pausedAt, block.timestamp, "a pending request pauses the Seal");
        assertEq(pools[0].lotOf(a, 0).seal, 0, "paused lots carry no tag");
        skip(1 days);
        vm.prank(alice);
        pools[0].cancelCooling(a, t);
        Seal memory s = pools[0].sealOf(a, 1);
        assertEq(s.pausedSeconds, 1 days);
        assertEq(pools[0].lotOf(a, 0).seal, 1, "resumed lots are tagged again");
        uint256 due = t0 + 31 days;
        vm.warp(due - 1);
        assertEq(uint256(emissions.sealStatus(0, a, 1)), uint256(SealStatus.Active));
        vm.warp(due + 3 days);
        assertEq(uint256(emissions.sealStatus(0, a, 1)), uint256(SealStatus.Completed), "complete without a sync");
        pools[0].poke(a);
        s = pools[0].sealOf(a, 1);
        assertEq(uint256(s.status), uint256(SealStatus.Completed));
        assertEq(s.endedAt, due, "back-dated to the due time");
    }

    function test_topUpNeverJoinsTheSeal() public {
        uint256 a = _open(0, alice, 100e18);
        _seal(0, alice, a, 1);
        vm.prank(alice);
        pools[0].deposit(a, 50e18);
        assertEq(pools[0].lotOf(a, 0).seal, 1);
        assertEq(pools[0].lotOf(a, 1).seal, 0, "a later deposit is not sealed");
        assertEq(pools[0].sealOf(a, 1).cohortMask, 1);
        skip(1 days);
        pools[0].poke(a);
        (uint256 s,, uint256 ss,) = pools[0].epochMeasure(a, t0, t0 + 1 days);
        assertEq(ss, 99e18 * 1 days, "only the cohort's stake-seconds are sealed");
        assertGt(s, ss);
    }

    function test_executedWithdrawalForfeitsAndRoutesEscrow() public {
        uint256 a = _open(0, alice, 600e18);
        _seal(0, alice, a, 2);
        skip(1 days);
        _settle(0);
        uint256 locked = emissions.sealEscrow(0, a, 1);
        assertGt(locked, 0);
        vm.expectRevert(abi.encodeWithSelector(ForgeEmissions.SealNotEnded.selector, 0, a, 1));
        emissions.settleSeal(0, a, 1);
        vm.prank(alice);
        uint32 t = pools[0].requestCooling(a, 6e18);
        skip(6 hours);
        vm.prank(alice);
        pools[0].executeWithdrawal(a, t);
        assertEq(uint256(pools[0].sealOf(a, 1).status), uint256(SealStatus.Forfeited));
        emissions.settleSeal(0, a, 1);
        uint256 burn = (locked * 50) / 100;
        uint256 reserve = (locked * 25) / 100;
        assertEq(emissions.burnLane(), burn);
        assertEq(emissions.matchReserve(), reserve);
        assertEq(emissions.sealedPot(0), locked - burn - reserve);
        assertEq(emissions.sealEscrow(0, a, 1), 0);
        vm.expectRevert(abi.encodeWithSelector(ForgeEmissions.NothingToSettle.selector, 0, a, 1));
        emissions.settleSeal(0, a, 1);
    }

    function test_completedTermVestsToTheCapstoneLedgerAndLateCreditsFollow() public {
        uint256 a = _open(2, alice, 500e18);
        _seal(2, alice, a, 0);
        skip(1 days);
        _settle(0);
        uint256 locked = emissions.sealEscrow(2, a, 1);
        vm.warp(t0 + 30 days);
        emissions.settleSeal(2, a, 1);
        assertEq(emissions.capstoneOwed(2, a), locked, "vested escrow is held for the Capstone, never liquid");
        _settle(1); // epoch 1 settles after the term: its escrow vests at once
        assertGt(emissions.capstoneOwed(2, a), locked);
        assertEq(emissions.sealEscrow(2, a, 1), 0);
        uint256 held = ember.balanceOf(address(emissions));
        assertEq(held, emissions.unclaimed(2, a) + emissions.capstoneOwed(2, a), "EMBER held backs every ledger");
    }

    function test_emergencyExitForfeitsAndAlwaysWorks() public {
        uint256 a = _open(0, alice, 100e18);
        _seal(0, alice, a, 3);
        vm.prank(alice);
        pools[0].requestCooling(a, 1e18); // paused
        skip(1 hours);
        vm.prank(alice);
        uint256 net = pools[0].emergencyExit(a);
        assertEq(net, 99e18 - (99e18 * 8) / 100);
        Seal memory s = pools[0].sealOf(a, 1);
        assertEq(uint256(s.status), uint256(SealStatus.Forfeited));
        assertEq(s.pausedSeconds, 1 hours, "the open pause is closed at the forfeit");
    }

    function test_sealGuards() public {
        uint256 a = _open(0, alice, 100e18);
        vm.expectRevert(abi.encodeWithSelector(ForgePool.NotOwner.selector, a));
        _seal(0, bob, a, 0);
        vm.expectRevert(abi.encodeWithSelector(ForgePool.UnknownTrack.selector, 4));
        _seal(0, alice, a, 4);
        _seal(0, alice, a, 0);
        vm.expectRevert(abi.encodeWithSelector(ForgePool.SealActive.selector, a, 1));
        _seal(0, alice, a, 1);
        vm.prank(alice);
        pools[0].requestCooling(a, 1e18);
        vm.expectRevert(abi.encodeWithSelector(ForgePool.CoolingPending.selector, a));
        _seal(0, alice, a, 1);
        skip(6 hours);
        vm.prank(alice);
        pools[0].executeWithdrawal(a, 1); // forfeits
        vm.expectRevert(abi.encodeWithSelector(ForgePool.SealGap.selector, block.timestamp + P.EPOCH_SECONDS));
        _seal(0, alice, a, 1);
        skip(1 days);
        assertEq(_seal(0, alice, a, 1), 2, "a second Seal after the gap");
        vm.prank(alice);
        pools[0].emergencyExit(a);
        vm.expectRevert(abi.encodeWithSelector(ForgePool.Closed.selector, a));
        _seal(0, alice, a, 0);
    }

    function test_noSealsKeepsTheCanonicalSplit() public {
        uint256 a = _open(0, alice, 100e18);
        skip(1 days);
        _settle(0);
        ForgeEmissions.PoolEpoch memory pe = emissions.poolEpoch(0, 0);
        assertEq(pe.escrow, 0);
        assertEq(pe.flat + pe.heat, pe.admitted, "27/73 with the bucket returned");
        assertEq(emissions.sealedEarnerCount(0, 0), 0);
        assertApproxEqAbs(emissions.unclaimed(0, a), pe.admitted, 1);
    }

    /// Near-uint96 stakes: every product in the escrow and credit math goes through mulDiv.
    function test_maxScaleSealedSettlementDoesNotOverflow() public {
        uint256 big = 7e28; // ≈ 88% of uint96
        stake[0].mint(alice, big * 2);
        uint256 a = _open(0, alice, big);
        _open(0, bob, 1e18);
        _seal(0, alice, a, 3);
        skip(1 days);
        _settle(0);
        assertGt(emissions.sealEscrow(0, a, 1), 0);
        (,, uint128 minted,, uint128 released,) = mantle.budgets(0);
        assertEq(minted + released, 21_600e18);
    }

    // ── gas ───────────────────────────────────────────────────────────────

    function test_gas_seals() public {
        uint256 a = _open(0, alice, 1e18);
        for (uint256 i = 1; i < 32; ++i) {
            vm.prank(alice);
            pools[0].deposit(a, 1e18);
        }
        skip(1 hours);
        uint256 g = gasleft();
        _seal(0, alice, a, 3);
        emit log_named_uint("seal (32 lots)", g - gasleft());
        skip(1 days); // a later pause pushes every tagged head into history
        g = gasleft();
        vm.prank(alice);
        uint32 t = pools[0].requestCooling(a, 32 * 99e16); // 100%: no splits, the pause frees every tag
        emit log_named_uint("requestCooling 100% + pause (32 lots)", g - gasleft());
        skip(1 hours);
        g = gasleft();
        vm.prank(alice);
        pools[0].cancelCooling(a, t);
        emit log_named_uint("cancelCooling + resume retag (32 lots)", g - gasleft());

        for (uint256 k = 2; k <= 33; ++k) {
            address who = _user(k);
            _fund(who);
            uint256 id = _open(1, who, 1e18);
            _seal(1, who, id, k % 4);
        }
        skip(1 days);
        uint256 e = (block.timestamp - start) / P.EPOCH_SECONDS - 1; // the last full epoch
        for (uint256 k; k <= e; ++k) {
            mantle.finalizeEpoch();
            emissions.openEpoch();
        }
        while (emissions.poolEpoch(e, 1).phase == ForgeEmissions.Phase.Measuring) emissions.advance(e, 1);
        assertEq(uint256(emissions.poolEpoch(e, 1).phase), uint256(ForgeEmissions.Phase.Escrowing));
        g = gasleft();
        emissions.advance(e, 1);
        emit log_named_uint("escrow page (32 sealed earners)", g - gasleft());
        g = gasleft();
        emissions.advance(e, 1);
        emit log_named_uint("credit page (32 sealed earners)", g - gasleft());
        vm.prank(_user(2));
        pools[1].emergencyExit(1);
        g = gasleft();
        emissions.settleSeal(1, 1, 1);
        emit log_named_uint("settleSeal (forfeit routing)", g - gasleft());
    }

    /// The poke a measure page makes on entering a position is charged LAPSE_UNITS per due
    /// lapse, so a page of positions that each resolve 8 lapses stays bounded.
    function test_gas_pageOfLapsingPositions() public {
        for (uint256 k = 1; k <= 32; ++k) {
            address who = _user(k);
            if (k > 2) _fund(who);
            uint256 id = _open(0, who, 1000e18);
            _seal(0, who, id, 0);
            for (uint256 n; n < 8; ++n) {
                vm.prank(who);
                pools[0].requestCooling(id, 1e18); // 8 tickets, each lapsing at +30h
            }
        }
        vm.warp(t0 + 3 days);
        mantle.finalizeEpoch();
        emissions.openEpoch();
        uint256 maxPage;
        uint256 pages;
        while (emissions.poolEpoch(0, 0).phase == ForgeEmissions.Phase.Measuring) {
            uint256 g = gasleft();
            emissions.advance(0, 0);
            uint256 used = g - gasleft();
            if (used > maxPage) maxPage = used;
            ++pages;
        }
        emit log_named_uint("measure pages, 32 positions x 8 due lapses", pages);
        emit log_named_uint("heaviest such page", maxPage);
        assertEq(pages, 32, "one lapsing position per page");
        assertLt(maxPage, 6_000_000, "every page stays bounded");
    }
}
