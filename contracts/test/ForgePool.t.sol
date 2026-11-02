// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {ForgePoolBase} from "../src/forge/ForgePoolBase.sol";
import {ForgePoolAnnex} from "../src/forge/ForgePoolAnnex.sol";
import {ForgeView} from "../src/forge/ForgeView.sol";
import {Lot, Record, Seal} from "../src/forge/ForgeMeasures.sol";
import {HeatMath} from "../src/libraries/HeatMath.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {ForgeVectors} from "./utils/ForgeVectors.sol";
import {MockERC20, FeeOnTransferERC20} from "./utils/MockERC20.sol";

using ForgeView for ForgePool;
using ForgeView for ForgePoolHarness;

/// @dev Test-only subclass: jumps a position's ticket or record counter towards its limit.
contract ForgePoolHarness is ForgePool {
    constructor(IERC20 stakeToken, bool isLp, address feeCollector, address boost, address deeds)
        ForgePool(stakeToken, isLp, feeCollector, boost, deeds)
    {}

    function setNextTicketIdForTest(uint256 id, uint32 value) external {
        _positions[id].nextTicketId = value;
    }

    function setRecordsForTest(uint256 id, uint256 slot, uint24 n) external {
        _lots[id][slot].records = n;
    }

    function setPhantomForTest(uint256 id, bool founder, bool active, uint32 headStart) external {
        Position storage p = _positions[id];
        (p.founder, p.headStartActive, p.headStart) = (founder, active, headStart);
    }
}

abstract contract ForgeFixture is ForgeVectors {
    MockERC20 token;
    ForgePool pool;
    address collector = makeAddr("feeRouter");
    address boost = makeAddr("boost");
    address deeds = makeAddr("deeds");

    uint256 constant FUND = 1e30;

    function _deploy(bool lp) internal {
        token = new MockERC20("Receipt", "RCPT");
        pool = new ForgePool(IERC20(address(token)), lp, collector, boost, deeds);
    }

    function _user(uint256 pos) internal pure returns (address) {
        return address(uint160(0x1000 + pos));
    }

    function _fund(address who) internal {
        token.mint(who, FUND);
        vm.prank(who);
        token.approve(address(pool), type(uint256).max);
    }
}

/// @notice Differential replay: every action of every generated scenario runs against
///         ForgePool and must revert exactly when the BigInt model reverts; after each
///         step a keccak of the full raw state must equal the model's.
contract ForgePoolDifferentialTest is ForgeFixture {
    enum Kind {
        Open,
        Deposit,
        Request,
        Execute,
        Cancel,
        Emergency,
        Poke,
        Collect,
        Seal,
        Boost,
        List,
        Unlist,
        Settle,
        Tap
    }

    /// @dev Wallets beyond the openers, which only buy Deeds (scripts/forge-scenarios.ts BUYERS).
    uint256 constant BUYERS = 2;
    /// @dev The listing the market recorded at each position's last successful List.
    mapping(uint256 pos => uint32) market;

    function setUp() public {
        _loadForgeVectors();
    }

    function test_scenario_basicCycle() public { _replay("basicCycle"); }
    function test_scenario_cumulativeTiers() public { _replay("cumulativeTiers"); }
    function test_scenario_overlapHaircut() public { _replay("overlapHaircut"); }
    function test_scenario_lapseLateTouch() public { _replay("lapseLateTouch"); }
    function test_scenario_lapseIdlePool() public { _replay("lapseIdlePool"); }
    function test_scenario_cappedMerge() public { _replay("cappedMerge"); }
    function test_scenario_ashfallStreakReset() public { _replay("ashfallStreakReset"); }
    function test_scenario_emergencyWithPending() public { _replay("emergencyWithPending"); }
    function test_scenario_capacity16() public { _replay("capacity16"); }
    function test_scenario_capacity17() public { _replay("capacity17"); }
    function test_scenario_lotCap() public { _replay("lotCap"); }
    function test_scenario_sealPauseExtend() public { _replay("sealPauseExtend"); }
    function test_scenario_sealLapseUnpause() public { _replay("sealLapseUnpause"); }
    function test_scenario_sealForfeitExecute() public { _replay("sealForfeitExecute"); }
    function test_scenario_sealCohortJoin() public { _replay("sealCohortJoin"); }
    function test_scenario_sealEmergency() public { _replay("sealEmergency"); }
    function test_scenario_boostCycle() public { _replay("boostCycle"); }
    function test_scenario_boostSealDeposit() public { _replay("boostSealDeposit"); }
    function test_scenario_random0() public { _replay("random0"); }
    function test_scenario_random1() public { _replay("random1"); }
    function test_scenario_random2() public { _replay("random2"); }
    function test_scenario_random3() public { _replay("random3"); }
    function test_scenario_random4() public { _replay("random4"); }
    function test_scenario_random5() public { _replay("random5"); }
    function test_scenario_deedCycle() public { _replay("deedCycle"); }
    function test_scenario_deedExitEnds() public { _replay("deedExitEnds"); }
    function test_scenario_deedRelist() public { _replay("deedRelist"); }
    function test_scenario_deedLapseThenList() public { _replay("deedLapseThenList"); }
    function test_scenario_deedSealTravels() public { _replay("deedSealTravels"); }
    function test_scenario_deedPlanReset() public { _replay("deedPlanReset"); }
    function test_scenario_deeds0() public { _replay("deeds0"); }
    function test_scenario_deeds1() public { _replay("deeds1"); }
    function test_scenario_deeds2() public { _replay("deeds2"); }
    function test_scenario_deeds3() public { _replay("deeds3"); }
    function test_scenario_tapCycle() public { _replay("tapCycle"); }
    function test_scenario_tapYoungestFirst() public { _replay("tapYoungestFirst"); }
    function test_scenario_tapSealForfeit() public { _replay("tapSealForfeit"); }
    function test_scenario_tapStreakResetBetween() public { _replay("tapStreakResetBetween"); }
    function test_scenario_tapAfterDeed() public { _replay("tapAfterDeed"); }
    function test_scenario_tapLotCapacity() public { _replay("tapLotCapacity"); }
    function test_scenario_taps0() public { _replay("taps0"); }
    function test_scenario_taps1() public { _replay("taps1"); }
    function test_scenario_taps2() public { _replay("taps2"); }

    /// Every generated scenario has a test above; a new one fails this until added.
    function test_everyScenarioIsReplayed() public view {
        assertEq(vm.parseJsonStringArray(forgeJson, ".names").length, 43, "add a test_scenario_* for each new scenario");
    }

    function test_provisionalConstantsMatchModel() public {
        _deploy(true);
        assertEq(pool.MAX_PENDING_TICKETS(), vm.parseJsonUint(forgeJson, ".maxPendingTickets"));
        assertEq(P.MAX_LOTS_PER_POSITION, vm.parseJsonUint(forgeJson, ".maxLots"));
    }

    function _replay(string memory name) internal {
        string memory base = string.concat(".scenarios.", name);
        bool lp = vm.parseJsonBool(forgeJson, string.concat(base, ".lp"));
        uint256 positions = vm.parseJsonUint(forgeJson, string.concat(base, ".positions"));
        uint256[] memory a = _forgeUints(string.concat(base, ".actions"));
        bytes32[] memory hashes = _forgeHashes(string.concat(base, ".hash"));
        uint256[] memory probe = _forgeUints(string.concat(base, ".probe"));
        assertEq(a.length, hashes.length * 5, "layout");

        _deploy(lp);
        for (uint256 k = 1; k <= positions + BUYERS; ++k) _fund(_user(k));

        for (uint256 i; i < hashes.length; ++i) {
            (Kind kind, uint256 time, uint256 pos, uint256 arg, bool reverts) =
                (Kind(a[5 * i]), a[5 * i + 1], a[5 * i + 2], a[5 * i + 3], a[5 * i + 4] == 1);
            vm.warp(time);
            string memory where = string.concat(name, " step ", vm.toString(i));
            // The owner acts for its position; read before expectRevert claims the next call.
            address actor = kind == Kind.Open ? _user(pos) : pool.ownerOf(pos);
            if (reverts) vm.expectRevert();
            _act(kind, pos, arg, actor, reverts);

            _probe(probe, i, time, where);
            assertEq(this.snapshot(positions), hashes[i], string.concat(where, ": state hash"));
        }
    }

    function _probe(uint256[] memory probe, uint256 i, uint256 time, string memory where) internal view {
        (uint256 s1, uint256 w1, uint256 ss1,,) = pool.epochMeasure(1, 0, pool.positionOf(1).lastCheckpoint);
        assertEq(s1, probe[6 * i], string.concat(where, ": S(1)"));
        assertEq(w1, probe[6 * i + 1], string.concat(where, ": W(1)"));
        assertEq(pool.activePrincipal(), probe[6 * i + 2], string.concat(where, ": active"));
        assertEq(pool.frozenPrincipal(), probe[6 * i + 3], string.concat(where, ": frozen"));
        assertEq(pool.occupiedSecondsAt(time), probe[6 * i + 4], string.concat(where, ": occupied"));
        assertEq(ss1, probe[6 * i + 5], string.concat(where, ": sealed S(1)"));
    }

    function _act(Kind kind, uint256 pos, uint256 arg, address actor, bool reverts) internal {
        if (kind == Kind.List) {
            vm.prank(deeds);
            if (reverts) pool.list(pos, _user(arg));
            else market[pos] = pool.list(pos, _user(arg));
            return;
        }
        if (kind == Kind.Settle) {
            vm.prank(deeds);
            pool.settle(pos, _user(arg), market[pos]);
            return;
        }
        if (kind == Kind.Unlist) {
            vm.prank(arg == 1 ? deeds : actor);
            pool.unlist(pos);
            return;
        }
        if (kind == Kind.Collect) {
            vm.prank(collector);
            pool.collectFees();
            return;
        }
        if (kind == Kind.Boost) {
            vm.prank(boost);
            pool.setOrdinaryBonus(pos, arg);
            return;
        }
        vm.prank(actor);
        if (kind == Kind.Open) assertEq(pool.open(arg), pos, "position id");
        else if (kind == Kind.Deposit) pool.deposit(pos, arg);
        else if (kind == Kind.Request) pool.requestCooling(pos, arg);
        else if (kind == Kind.Execute) pool.executeWithdrawal(pos, uint32(arg));
        else if (kind == Kind.Cancel) pool.cancelCooling(pos, uint32(arg));
        else if (kind == Kind.Emergency) pool.emergencyExit(pos);
        else if (kind == Kind.Seal) pool.seal(pos, arg);
        else if (kind == Kind.Tap) pool.requestTap(pos, arg);
        else pool.poke(pos);
    }

    /// @dev Word layout mirrored by scripts/forge-scenarios.ts::words. External so each
    ///      call gets fresh memory (a long replay would otherwise exhaust it).
    function snapshot(uint256 positions) external view returns (bytes32) {
        uint256[] memory w = new uint256[](4_000);
        uint256 n;
        for (uint256 id = 1; id <= positions; ++id) {
            uint256[5] memory m;
            (m[0], m[1], m[2], m[3], m[4]) = pool.epochMeasure(id, 0, pool.positionOf(id).lastCheckpoint);
            n = _pushHead(w, n, id, m[0], m[1]);
            n = _pushSeal(w, n, id, m[2], m[3]);
            w[n++] = m[4]; // Ashfall weight from records; the model accrues it independently
            w[n++] = pool.positionOf(id).ordinaryBonus;
            n = _pushOwnership(w, n, id);
            for (uint256 j; j < 32; ++j) {
                n = _pushLot(w, n, id, j);
            }
            uint32[] memory pend = pool.pendingTickets(id);
            for (uint256 k; k < pend.length; ++k) n = _pushTicket(w, n, id, pend[k]);
        }
        uint256[11] memory tail = [
            pool.activePrincipal(),
            pool.frozenPrincipal(),
            pool.occupiedSecondsAt(block.timestamp),
            pool.occupancyLength(),
            pool.feesOwed(0),
            pool.feesOwed(1),
            pool.feesOwed(2),
            token.balanceOf(address(pool)),
            pool.lapseQueueLength(),
            pool.positionCount(),
            token.balanceOf(collector)
        ];
        for (uint256 k; k < 11; ++k) w[n++] = tail[k];
        for (uint256 k = 1; k <= positions + BUYERS; ++k) w[n++] = token.balanceOf(_user(k));
        assembly ("memory-safe") {
            mstore(w, n)
        }
        return keccak256(abi.encodePacked(w));
    }

    function _pushHead(uint256[] memory w, uint256 n, uint256 id, uint256 sm, uint256 wm)
        internal
        view
        returns (uint256)
    {
        ForgePoolBase.Position memory p = pool.positionOf(id);
        n = _put4(w, n, sm, wm, pool.lotCount(id), p.reservedSlots);
        n = _put4(w, n, p.pendingCount, p.coolingPausedSeconds, p.streakStart, p.lastCheckpoint);
        n = _put4(w, n, p.closedAt != 0 ? 1 : 0, p.ashfallForfeited ? 1 : 0, p.plan.start, p.plan.referenceBalance);
        w[n++] = p.plan.requested;
        w[n++] = p.nextTicketId;
        return n;
    }

    /// @dev Owner wallet, listing, sales, tenure start and the latest previous owner (ADR 0011).
    function _pushOwnership(uint256[] memory w, uint256 n, uint256 id) internal view returns (uint256) {
        ForgePoolBase.Position memory p = pool.positionOf(id);
        n = _put4(w, n, _wallet(p.owner), p.listing, p.transfers, pool.ownedSince(id));
        ForgePoolBase.Ownership memory prev;
        if (p.transfers != 0) prev = pool.ownershipAt(id, p.transfers - 1);
        (w[n], w[n + 1], w[n + 2]) = (_wallet(prev.owner), prev.until, p.lastTapAt);
        return n + 3;
    }

    function _wallet(address who) internal pure returns (uint256) {
        return who == address(0) ? 0 : uint160(who) - 0x1000;
    }

    function _pushLot(uint256[] memory w, uint256 n, uint256 id, uint256 j) internal view returns (uint256) {
        (uint256 amount, uint256 age, uint256 part, uint256 heldBy) = pool.lotAt(id, j);
        n = _put4(w, n, amount, age, part, heldBy);
        w[n] = pool.lotOf(id, j).seal;
        return n + 1;
    }

    function _pushSeal(uint256[] memory w, uint256 n, uint256 id, uint256 ss, uint256 sw)
        internal
        view
        returns (uint256)
    {
        ForgePoolBase.Position memory p = pool.positionOf(id);
        Seal memory s = pool.sealOf(id, p.sealCount);
        n = _put4(w, n, ss, sw, p.sealCount, s.track);
        n = _put4(w, n, uint256(s.status), s.start, s.pausedAt, s.pausedSeconds);
        (w[n], w[n + 1]) = (s.endedAt, s.cohortMask);
        return n + 2;
    }

    function _pushTicket(uint256[] memory w, uint256 n, uint256 id, uint32 ticketId) internal view returns (uint256) {
        ForgePoolBase.Ticket memory t = pool.ticketOf(id, ticketId);
        n = _put4(w, n, ticketId, t.amount, t.maturity, uint256(t.status));
        (w[n], w[n + 1]) = (t.poolApplied ? 1 : 0, t.tap ? 1 : 0);
        n += 2;
        for (uint256 j; j < 32; ++j) {
            ForgePoolBase.Slice memory s = pool.sliceOf(id, ticketId, j);
            (w[n], w[n + 1], w[n + 2]) = (s.amount, s.age, s.participated);
            n += 3;
        }
        return n;
    }

    function _put4(uint256[] memory w, uint256 n, uint256 a, uint256 b, uint256 c, uint256 d)
        internal
        pure
        returns (uint256)
    {
        (w[n], w[n + 1], w[n + 2], w[n + 3]) = (a, b, c, d);
        return n + 4;
    }
}

/// @notice Focused unit tests: policy edges the scenarios do not isolate.
contract ForgePoolTest is ForgeFixture {
    address alice = _user(1);
    address bob = _user(2);

    function setUp() public {
        vm.warp(1_700_000_000);
        _deploy(true);
        _fund(alice);
        _fund(bob);
    }

    function test_constructorRejectsZeroAddresses() public {
        vm.expectRevert(ForgePoolBase.ZeroAddress.selector);
        new ForgePool(IERC20(address(0)), true, collector, boost, deeds);
        vm.expectRevert(ForgePoolBase.ZeroAddress.selector);
        new ForgePool(IERC20(address(token)), true, address(0), boost, deeds);
        vm.expectRevert(ForgePoolBase.ZeroAddress.selector);
        new ForgePool(IERC20(address(token)), true, collector, address(0), deeds);
        vm.expectRevert(ForgePoolBase.ZeroAddress.selector);
        new ForgePool(IERC20(address(token)), true, collector, boost, address(0));
    }

    function test_feeOnTransferTokenIsRejected() public {
        FeeOnTransferERC20 skim = new FeeOnTransferERC20();
        ForgePool skimPool = new ForgePool(IERC20(address(skim)), false, collector, boost, deeds);
        skim.mint(alice, 1e18);
        vm.startPrank(alice);
        skim.approve(address(skimPool), type(uint256).max);
        vm.expectRevert(ForgePoolBase.NonStandardToken.selector);
        skimPool.open(1e18);
        vm.stopPrank();
    }

    function test_onlyOwnerMovesPrincipal() public {
        vm.prank(alice);
        uint256 id = pool.open(100e18);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NotOwner.selector, id));
        pool.requestCooling(id, 1e18);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NotOwner.selector, id));
        pool.emergencyExit(id);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NotOwner.selector, id));
        pool.deposit(id, 1e18);
        vm.stopPrank();
        pool.poke(id); // permissionless sync is fine
    }

    function test_measuresMatchHeatMathForOneLot() public {
        vm.prank(alice);
        uint256 id = pool.open(100e18);
        uint256 net = 99e18;
        uint256 t0 = block.timestamp;
        skip(200 days);
        pool.poke(id);
        (uint256 s, uint256 w,,,) = pool.epochMeasure(id, t0, block.timestamp);
        assertEq(s, net * 200 days);
        assertEq(w, net * HeatMath.integrateHeat(0, 200 days, 0));
        // Any subdivision telescopes: two halves equal the whole interval.
        skip(200 days);
        pool.poke(id);
        (, uint256 wa,,,) = pool.epochMeasure(id, t0, t0 + 123 days);
        (, uint256 wb,,,) = pool.epochMeasure(id, t0 + 123 days, block.timestamp);
        assertEq(wa + wb, net * HeatMath.integrateHeat(0, 400 days, 0));
        assertEq(pool.historyLength(id, 0), 0, "pure aging writes no records");
    }

    function test_frozenSliceDoesNotAgeOrEarn() public {
        vm.prank(alice);
        uint256 id = pool.open(100e18);
        skip(10 days);
        vm.prank(alice);
        pool.requestCooling(id, 99e18); // the whole lot
        uint256 frozenAt = block.timestamp;
        skip(1 days);
        pool.poke(id);
        (uint256 s1, uint256 w1,,,) = pool.epochMeasure(id, frozenAt, block.timestamp);
        assertEq(s1, 0, "no stake-seconds while frozen");
        assertEq(w1, 0, "no heat-seconds while frozen");
        vm.prank(alice);
        pool.cancelCooling(id, 1);
        assertEq(pool.lotOf(id, 0).age, 10 days, "resumes at the frozen age");
        assertEq(pool.positionOf(id).coolingPausedSeconds, 1 days);
    }

    function test_executionHaircutsSurvivorsProportionally() public {
        vm.prank(alice);
        uint256 id = pool.open(200e18); // net 198
        skip(730 days); // capped at 365
        vm.prank(alice);
        uint32 t = pool.requestCooling(id, 99e18); // 50% → 24h
        skip(1 days);
        vm.prank(alice);
        uint256 net = pool.executeWithdrawal(id, t);
        assertEq(net, 99e18 - 99e18 / 100);
        // The spec's example: a two-year lot at 50% withdrawal lands at 182.5 financial days.
        assertEq(pool.lotOf(id, 0).age, 182.5 days);
        assertEq(pool.positionOf(id).streakStart, block.timestamp, "Streak resets on execution");
    }

    function test_cancelKeepsQuotaConsumed() public {
        vm.prank(alice);
        uint256 id = pool.open(100e18);
        vm.startPrank(alice);
        uint32 t = pool.requestCooling(id, 99e18);
        pool.cancelCooling(id, t);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.PlanQuotaExceeded.selector, 99e18 + 1, 99e18));
        pool.requestCooling(id, 1);
        skip(P.COOLING_PLAN_HORIZON);
        pool.requestCooling(id, 1); // horizon passed with nothing pending: new plan
        vm.stopPrank();
    }

    function test_newTicketsNeverDelayMaturedTickets() public {
        vm.prank(alice);
        uint256 id = pool.open(1000e18);
        vm.startPrank(alice);
        uint32 first = pool.requestCooling(id, 99e18); // 10% → 6h
        skip(6 hours);
        pool.requestCooling(id, 500e18); // cumulative 60% → 48h for the new ticket only
        assertEq(pool.ticketOf(id, first).maturity, block.timestamp);
        pool.executeWithdrawal(id, first);
        vm.stopPrank();
    }

    function test_emergencyExitIgnoresTheFeeCollector() public {
        // Exits never call the fee collector, so one that always reverts cannot block them.
        ForgePool hostile = new ForgePool(IERC20(address(token)), true, address(new Reverter()), boost, deeds);
        vm.startPrank(alice);
        token.approve(address(hostile), type(uint256).max);
        uint256 id = hostile.open(100e18);
        hostile.requestCooling(id, 10e18);
        uint256 before = token.balanceOf(alice);
        uint256 net = hostile.emergencyExit(id);
        vm.stopPrank();
        assertEq(net, 99e18 - (99e18 * 8) / 100);
        assertEq(token.balanceOf(alice) - before, net);
        assertEq(hostile.lapseQueueLength(), 0);
    }

    function test_ticketIdsStopAtTheHeldByWidth() public {
        ForgePoolHarness h = new ForgePoolHarness(IERC20(address(token)), true, collector, boost, deeds);
        vm.startPrank(alice);
        token.approve(address(h), type(uint256).max);
        uint256 id = h.open(100e18);
        h.setNextTicketIdForTest(id, type(uint24).max - 1);
        uint32 last = h.requestCooling(id, 1e18); // the final representable id
        assertEq(last, type(uint24).max);
        h.cancelCooling(id, last);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.TicketIdOverflow.selector, id));
        h.requestCooling(id, 1e18);
        uint256 net = h.emergencyExit(id); // principal still leaves
        vm.stopPrank();
        assertEq(net, 99e18 - (99e18 * 8) / 100);
    }

    // ── ordinary bonus (ADR 0008) ────────────────────────────────────────

    function test_onlyBoostSetsTheBonusWithinTheCeiling() public {
        vm.prank(alice);
        uint256 id = pool.open(100e18);
        vm.prank(alice);
        vm.expectRevert(ForgePoolBase.NotBoost.selector);
        pool.setOrdinaryBonus(id, 1);
        vm.startPrank(boost);
        uint256 max = P.MAX_ORDINARY_BONUS_UNITS;
        assertEq(max * P.ORDINARY_BONUS_UNIT_RAY, P.MAX_ORDINARY_BONUS_RAY);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.BonusAboveCeiling.selector, max + 1));
        pool.setOrdinaryBonus(id, max + 1);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.UnknownPosition.selector, id + 1));
        pool.setOrdinaryBonus(id + 1, 1);
        vm.expectEmit(address(pool));
        emit ForgePoolBase.OrdinaryBonusSet(id, max);
        pool.setOrdinaryBonus(id, max);
        assertEq(pool.positionOf(id).ordinaryBonus, max);
        skip(1 days);
        vm.recordLogs();
        pool.setOrdinaryBonus(id, max); // unchanged: syncs, but no rewrite and no event
        vm.stopPrank();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(pool.historyLength(id, 0), 0);
        assertEq(pool.positionOf(id).lastCheckpoint, block.timestamp);
    }

    function test_bonusEntersHeatAndAshfallAtItsRate() public {
        vm.prank(alice);
        uint256 id = pool.open(100e18); // net 99
        uint256 t0 = block.timestamp;
        vm.prank(boost);
        pool.setOrdinaryBonus(id, 65_000); // same instant as the head: overwritten, no record
        assertEq(pool.historyLength(id, 0), 0);
        skip(10 days);
        vm.prank(boost);
        pool.setOrdinaryBonus(id, 50_000);
        assertEq(pool.historyLength(id, 0), 1);
        skip(90 days);
        pool.poke(id);
        (uint256 s, uint256 w,,, uint256 q) = pool.epochMeasure(id, t0, block.timestamp);
        assertEq(s, 99e18 * 100 days);
        uint256 h = HeatMath.integrateHeat(0, 10 days, 0.65e27) + HeatMath.integrateHeat(10 days, 90 days, 0.5e27);
        assertEq(w, 99e18 * h);
        // Ashfall from day 30 (Streak and participation), Heat² with the bonus of the day.
        assertEq(q, Math.mulDiv(99e18, HeatMath.integrateSquaredHeat(30 days, 70 days, 0.5e27), P.RAY));
    }

    function test_closedPositionKeepsItsBonus() public {
        vm.prank(alice);
        uint256 id = pool.open(100e18);
        vm.prank(boost);
        pool.setOrdinaryBonus(id, 20_000);
        skip(1 days);
        vm.prank(alice);
        pool.emergencyExit(id);
        skip(1 days);
        vm.recordLogs();
        vm.prank(boost);
        pool.setOrdinaryBonus(id, 0); // no revert, no sync, no event: measures ended at the exit
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(pool.positionOf(id).ordinaryBonus, 20_000);
        assertEq(pool.positionOf(id).lastCheckpoint, block.timestamp - 1 days);
    }

    function test_topUpDilutesTheBonusByCustody() public {
        vm.prank(alice);
        uint256 id = pool.open(100e18); // net 99
        vm.prank(boost);
        pool.setOrdinaryBonus(id, 50_000);
        skip(1 days);
        vm.startPrank(alice);
        pool.requestCooling(id, 9e18); // a frozen slice is still custody
        vm.expectEmit(address(pool));
        emit ForgePoolBase.OrdinaryBonusSet(id, 12_500); // 50000 · 99 / (99 + 297)
        pool.deposit(id, 300e18);
        vm.stopPrank();
        assertEq(pool.positionOf(id).ordinaryBonus, 12_500);
    }

    function test_boostCannotExhaustTheRecordCounter() public {
        ForgePoolHarness h = new ForgePoolHarness(IERC20(address(token)), true, collector, boost, deeds);
        vm.startPrank(alice);
        token.approve(address(h), type(uint256).max);
        uint256 id = h.open(100e18);
        vm.stopPrank();
        h.setRecordsForTest(id, 0, uint24(h.BOOST_RECORD_LIMIT()));
        skip(1 days);
        vm.prank(boost);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.RecordLimit.selector, id, 0));
        h.setOrdinaryBonus(id, 1);
        vm.startPrank(alice); // the owner's own actions keep the rest of the counter
        uint32 t = h.requestCooling(id, 9e18);
        skip(6 hours);
        h.executeWithdrawal(id, t);
        vm.stopPrank();
        assertEq(h.lotOf(id, 0).records, h.BOOST_RECORD_LIMIT() + 2);
    }

    function test_recordsKeepPastStateAfterChanges() public {
        vm.prank(alice);
        uint256 id = pool.open(100e18); // net 99
        uint256 t0 = block.timestamp;
        skip(10 days);
        vm.prank(alice);
        uint32 t = pool.requestCooling(id, 33e18); // the head changes; the past must not
        assertEq(pool.historyLength(id, 0), 1);
        skip(1 days);
        vm.prank(alice);
        pool.cancelCooling(id, t); // resumes into a reserved slot (ages differ by a day)
        skip(5 days);
        pool.poke(id);
        (uint256 s, uint256 w,,,) = pool.epochMeasure(id, t0, t0 + 10 days);
        assertEq(s, 99e18 * 10 days, "first ten days unchanged by later records");
        assertEq(w, 99e18 * HeatMath.integrateHeat(0, 10 days, 0));
        (uint256 sFrozen,,,,) = pool.epochMeasure(id, t0 + 10 days, t0 + 11 days);
        assertEq(sFrozen, 66e18 * 1 days, "only the unfrozen remainder earns");
    }

    function test_emergencyExitStopsMeasuresWithoutRecords() public {
        vm.prank(alice);
        uint256 id = pool.open(100e18);
        skip(3 days);
        vm.prank(alice);
        pool.emergencyExit(id);
        uint256 closedAt = block.timestamp;
        skip(4 days);
        pool.poke(id);
        (uint256 s,,,,) = pool.epochMeasure(id, closedAt - 3 days, block.timestamp);
        assertEq(s, 99e18 * 3 days);
        assertEq(pool.historyLength(id, 0), 0, "exit writes no per-slot records");
        (uint256 amount,,,) = pool.lotAt(id, 0);
        assertEq(amount, 0);
    }

    function test_onlyCollectorCollects() public {
        vm.prank(alice);
        pool.open(100e18);
        vm.expectRevert(ForgePoolBase.NotCollector.selector);
        pool.collectFees();
        vm.prank(collector);
        (uint256 dep,,) = pool.collectFees();
        assertEq(dep, 1e18);
        assertEq(token.balanceOf(collector), 1e18);
    }

    function test_occupancyStopsWhenEverythingCools() public {
        vm.prank(alice);
        uint256 id = pool.open(100e18);
        skip(1 days);
        vm.prank(alice);
        uint32 t = pool.requestCooling(id, 99e18); // 100% → 72h
        uint256 frozenAt = block.timestamp;
        skip(2 days);
        assertEq(pool.occupiedSecondsAt(block.timestamp), 1 days, "idle while all principal cools");
        // No transaction at the deadline: the view still counts from the lapse.
        skip(3 days);
        uint256 lapse = frozenAt + 72 hours + P.WITHDRAW_EXECUTION_WINDOW;
        assertEq(pool.occupiedSecondsAt(block.timestamp), 1 days + (block.timestamp - lapse));
        pool.poke(id);
        assertEq(uint256(pool.ticketOf(id, t).status), uint256(ForgePoolBase.Status.Lapsed));
        assertEq(pool.occupiedSecondsAt(block.timestamp), 1 days + (block.timestamp - lapse));
    }

    function test_futureOccupancyQueryReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.FutureTime.selector, block.timestamp + 1));
        pool.occupiedSecondsAt(block.timestamp + 1);
    }

    /// Gas for the bounded worst cases (reported in ADR 0004).
    function test_gas_worstCase() public {
        // 16 young lots: one request splits all 16 (16 + 16 reserved = 32 slots).
        vm.startPrank(alice);
        uint256 id = pool.open(1e18);
        for (uint256 i = 1; i < 16; ++i) {
            skip(1 hours);
            pool.deposit(id, 1e18);
        }
        skip(1 days);
        uint256 g = gasleft();
        uint32 t1 = pool.requestCooling(id, 1e17);
        emit log_named_uint("requestCooling, 16 lot splits", g - gasleft());
        skip(6 hours);
        g = gasleft();
        pool.executeWithdrawal(id, t1);
        emit log_named_uint("executeWithdrawal, 16 lots", g - gasleft());
        vm.stopPrank();

        // 4 lots and 7 pending tickets (4 + 7·4 = 32 slots): haircuts and lapses fan out.
        vm.startPrank(bob);
        uint256 b = pool.open(10e18);
        for (uint256 i = 1; i < 4; ++i) {
            skip(1 hours);
            pool.deposit(b, 10e18);
        }
        skip(1 days);
        for (uint256 i; i < 7; ++i) pool.requestCooling(b, 1e17);
        skip(6 hours);
        g = gasleft();
        pool.executeWithdrawal(b, 1);
        emit log_named_uint("executeWithdrawal, 4 lots + 6 pending haircut", g - gasleft());
        g = gasleft();
        pool.cancelCooling(b, 2);
        emit log_named_uint("cancelCooling, 4 slices to reserved slots", g - gasleft());
        skip(2 days);
        g = gasleft();
        pool.poke(b);
        emit log_named_uint("poke, resolving 5 lapses", g - gasleft());
        uint256 active;
        for (uint256 j; j < 32; ++j) {
            (uint256 amount,,,) = pool.lotAt(b, j);
            active += amount;
        }
        skip(P.COOLING_PLAN_HORIZON); // the old plan's quota is spent; let it reset
        pool.requestCooling(b, active); // 100% of what resumed: no splits needed
        g = gasleft();
        pool.emergencyExit(b);
        emit log_named_uint("emergencyExit, all lots frozen", g - gasleft());
        vm.stopPrank();
    }

    /// The capacity rule counts every lot left with a remainder, whatever its age: a
    /// haircut between freeze and resume can uncap a capped lot, so its slice may need
    /// its own slot. Capped lots usually get the slot back on resume.
    function test_capacityCountsCappedLotsToo() public {
        vm.startPrank(alice);
        uint256 id = pool.open(100e18);
        for (uint256 i = 1; i < 17; ++i) pool.deposit(id, 100e18);
        skip(400 days); // all 17 lots capped
        pool.poke(id);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.LotCapacity.selector, id));
        pool.requestCooling(id, 17e18);
        uint32 t = pool.requestCooling(id, 99e18 * 17); // 100%: no splits, always allowed
        pool.cancelCooling(id, t);
        vm.stopPrank();
        assertEq(pool.lotCount(id), 17);
        assertEq(pool.positionOf(id).reservedSlots, 0);
    }

    /// Emergency exit's worst case: 8 lapsed tickets resolved inside the exit itself.
    function test_gas_emergencyExitResolvingEightLapses() public {
        vm.startPrank(alice);
        uint256 id = pool.open(100e18);
        pool.deposit(id, 100e18);
        pool.deposit(id, 100e18);
        skip(1 days);
        for (uint256 i; i < 8; ++i) pool.requestCooling(id, 1e18); // 3 splits each: 3 + 24 slots
        skip(P.COOLING_PLAN_HORIZON + P.WITHDRAW_EXECUTION_WINDOW + 1); // every ticket lapsed, unprocessed
        uint256 g = gasleft();
        uint256 net = pool.emergencyExit(id);
        emit log_named_uint("emergencyExit, resolving 8 lapses first", g - gasleft());
        vm.stopPrank();
        assertEq(net, 297e18 - (297e18 * 8) / 100);
    }

    function test_gas_fullPosition() public {
        vm.startPrank(alice);
        uint256 id = pool.open(1e18);
        for (uint256 i = 1; i < 32; ++i) {
            skip(1 hours);
            pool.deposit(id, 1e18);
        }
        skip(400 days);
        uint256 g = gasleft();
        pool.poke(id);
        emit log_named_uint("poke (32 lots)", g - gasleft());
        vm.stopPrank();
        vm.prank(boost);
        g = gasleft();
        pool.setOrdinaryBonus(id, 65_000);
        emit log_named_uint("setOrdinaryBonus (32 lots)", g - gasleft());
        vm.startPrank(alice);
        g = gasleft();
        uint32 t = pool.requestCooling(id, pool.lotOf(id, 0).amount * 32); // 100%: no splits
        emit log_named_uint("requestCooling 100% (32 lots)", g - gasleft());
        skip(72 hours);
        g = gasleft();
        pool.executeWithdrawal(id, t);
        emit log_named_uint("executeWithdrawal (32 lots)", g - gasleft());
        vm.stopPrank();
    }

    // ── the annex (ADR 0012) ──────────────────────────────────────────────

    /// The annex reads its own immutables when the pool runs it: they must be the pool's.
    function test_annexSharesThePoolsConfiguration() public view {
        ForgePoolAnnex annex = ForgePoolAnnex(pool.ANNEX());
        assertGt(address(annex).code.length, 0);
        assertEq(address(annex.STAKE_TOKEN()), address(pool.STAKE_TOKEN()));
        assertEq(annex.IS_LP(), pool.IS_LP());
        assertEq(annex.FEE_COLLECTOR(), pool.FEE_COLLECTOR());
        assertEq(annex.BOOST(), pool.BOOST());
        assertEq(annex.DEEDS(), pool.DEEDS());
    }

    /// Every delegated function returns the annex's values and reverts with the annex's exact
    /// error data; its state changes and events happen in the pool.
    function test_annexStubsPassResultsAndErrorsThrough() public {
        vm.prank(alice);
        uint256 id = pool.open(100e18);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.UnknownTrack.selector, 7));
        vm.prank(alice);
        pool.seal(id, 7);
        vm.expectEmit(address(pool)); // the pool emits, not the annex
        emit ForgePoolBase.Sealed(id, 1, 0, 1);
        vm.prank(alice);
        assertEq(pool.seal(id, 0), 1, "seal returns its index");
        assertEq(pool.positionOf(id).sealCount, 1, "in the pool's storage");
        vm.prank(deeds);
        assertEq(pool.list(id, alice), 1, "list returns the listing");
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.Listed.selector, id));
        vm.prank(deeds);
        pool.list(id, alice);
        vm.prank(collector);
        (uint256 dep, uint256 wd, uint256 em) = pool.collectFees();
        assertEq(abi.encode(dep, wd, em), abi.encode(1e18, 0, 0), "collectFees returns all three");
        vm.expectRevert(ForgePoolBase.NotBoost.selector);
        pool.setOrdinaryBonus(id, 1);
    }

    /// Called directly, the annex acts on its own empty storage: nothing in the pool changes.
    function test_annexCalledDirectlyTouchesNothing() public {
        vm.prank(alice);
        uint256 id = pool.open(100e18);
        ForgePoolAnnex annex = ForgePoolAnnex(pool.ANNEX());
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.UnknownPosition.selector, id));
        vm.prank(deeds);
        annex.list(id, alice);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.UnknownPosition.selector, id));
        vm.prank(alice);
        annex.seal(id, 0);
        vm.prank(collector);
        (uint256 dep,,) = annex.collectFees();
        assertEq(dep, 0, "the annex holds no fees");
        assertEq(pool.feesOwed(0), 1e18, "the pool's fees are untouched");
        assertEq(token.balanceOf(address(annex)), 0);
        assertEq(pool.listingOf(id), 0);
    }

    // ── Taps (ADR 0014) ───────────────────────────────────────────────────

    function test_tapTiersFollowTheStreak() public {
        vm.prank(alice);
        uint256 id = pool.open(1000e18); // 990 active
        skip(P.TAP_TIER_0_STREAK - 1);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NoTap.selector, id));
        vm.prank(alice);
        pool.requestTap(id, 1e18);
        skip(1); // Blaze: 10%
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.TapQuotaExceeded.selector, 99e18 + 1, 99e18));
        vm.prank(alice);
        pool.requestTap(id, 99e18 + 1);
        vm.expectEmit(address(pool));
        emit ForgePoolBase.CoolingRequested(id, 1, 99e18, block.timestamp + P.WITHDRAW_TIER_0_SECONDS, true);
        vm.prank(alice);
        uint32 t = pool.requestTap(id, 99e18); // exactly 10%
        assertTrue(pool.ticketOf(id, t).tap);
        assertEq(pool.positionOf(id).lastTapAt, block.timestamp);
        vm.prank(alice);
        pool.cancelCooling(id, t); // the quota stays used
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.TapTooSoon.selector, block.timestamp + P.TAP_TIER_0_EVERY));
        vm.prank(alice);
        pool.requestTap(id, 1e18);
        vm.warp(pool.positionOf(id).streakStart + P.TAP_TIER_1_STREAK); // Eternal: 25%, 90 days after the last
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.TapQuotaExceeded.selector, 247.5e18 + 1, 247.5e18));
        vm.prank(alice);
        pool.requestTap(id, 247.5e18 + 1);
        vm.prank(alice);
        t = pool.requestTap(id, 247.5e18);
        vm.prank(alice);
        pool.cancelCooling(id, t);
        vm.warp(pool.positionOf(id).streakStart + P.TAP_TIER_2_STREAK); // Bedrock: every 60 days
        vm.prank(alice);
        pool.requestTap(id, 1e18);
        uint256 last = block.timestamp;
        vm.prank(alice);
        pool.cancelCooling(id, 3);
        vm.warp(last + P.TAP_TIER_2_EVERY - 1);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.TapTooSoon.selector, last + P.TAP_TIER_2_EVERY));
        vm.prank(alice);
        pool.requestTap(id, 1e18);
        skip(1);
        vm.prank(alice);
        pool.requestTap(id, 1e18);
    }

    function test_tapExecutesWithoutHaircutOrStreakReset() public {
        vm.prank(alice);
        uint256 id = pool.open(1000e18);
        skip(50 days);
        vm.prank(alice);
        pool.deposit(id, 100e18); // the younger lot: 99
        skip(50 days);
        uint256 streak = pool.positionOf(id).streakStart;
        vm.prank(alice);
        uint32 t = pool.requestTap(id, 99e18); // all of the younger lot, none of the older
        assertEq(pool.lotOf(id, 1).heldBy, t, "the younger lot drawn whole");
        assertEq(pool.lotOf(id, 0).amount, 990e18, "the older lot untouched");
        skip(P.WITHDRAW_TIER_0_SECONDS);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        uint256 net = pool.executeWithdrawal(id, t);
        assertEq(net, 99e18 - 99e18 / 100, "the normal fee");
        assertEq(token.balanceOf(alice) - before, net);
        (, uint256 age,,) = pool.lotAt(id, 0);
        assertEq(age, 100 days + P.WITHDRAW_TIER_0_SECONDS, "no haircut");
        assertEq(pool.positionOf(id).streakStart, streak, "the Streak stays");
    }

    function test_tapIsLockedWhileListed() public {
        vm.prank(alice);
        uint256 id = pool.open(1000e18);
        skip(100 days);
        vm.prank(deeds);
        pool.list(id, alice);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.Listed.selector, id));
        vm.prank(alice);
        pool.requestTap(id, 1e18);
    }

    function test_gas_tap() public {
        vm.startPrank(alice);
        uint256 id = pool.open(10e18);
        for (uint256 i = 1; i < 32; ++i) {
            skip(1 hours);
            pool.deposit(id, 10e18);
        }
        skip(400 days); // Eternal: 25%
        uint256 g = gasleft();
        uint32 t = pool.requestTap(id, 7 * 9.9e18); // the 7 youngest lots, whole (32 lots leave no slot to split)
        emit log_named_uint("requestTap, youngest-first over 32 lots (7 drawn)", g - gasleft());
        skip(P.WITHDRAW_TIER_2_SECONDS);
        g = gasleft();
        pool.executeWithdrawal(id, t);
        emit log_named_uint("executeWithdrawal of a Tap (no haircut)", g - gasleft());
        vm.stopPrank();
    }

    // ── Deeds (ADR 0011) ──────────────────────────────────────────────────

    function _listed(uint256 amount) internal returns (uint256 id, uint32 listing) {
        vm.prank(alice);
        id = pool.open(amount);
        vm.prank(deeds);
        listing = pool.list(id, alice);
    }

    function test_deedAccessAndPreconditions() public {
        vm.prank(alice);
        uint256 id = pool.open(100e18);
        vm.expectRevert(ForgePoolBase.NotDeeds.selector);
        vm.prank(alice);
        pool.list(id, alice); // only the market lists
        vm.startPrank(deeds);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NotOwner.selector, id));
        pool.list(id, bob);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.UnknownPosition.selector, 9));
        pool.list(9, alice);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NotListed.selector, id));
        pool.settle(id, bob, 0); // never listed
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NotListed.selector, id));
        pool.unlist(id);
        vm.stopPrank();
        vm.prank(alice);
        pool.requestCooling(id, 10e18);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.CoolingPending.selector, id));
        vm.prank(deeds);
        pool.list(id, alice);
        vm.prank(alice);
        pool.cancelCooling(id, 1);

        vm.prank(deeds);
        uint32 listing = pool.list(id, alice);
        assertEq(listing, 1);
        vm.startPrank(deeds);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.Listed.selector, id));
        pool.list(id, alice);
        vm.expectRevert(ForgePoolBase.ZeroAddress.selector);
        pool.settle(id, address(0), listing);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NotListed.selector, id));
        pool.settle(id, bob, listing + 1);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NotListed.selector, id));
        pool.settle(id, bob, listing - 1);
        vm.stopPrank();
        vm.expectRevert(ForgePoolBase.NotDeeds.selector);
        vm.prank(alice);
        pool.settle(id, bob, listing);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NotOwner.selector, id));
        vm.prank(bob);
        pool.unlist(id); // a stranger cannot end it
    }

    function test_deedListingLocksOwnerButNotExits() public {
        (uint256 id, uint32 listing) = _listed(100e18);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.Listed.selector, id));
        pool.deposit(id, 1e18);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.Listed.selector, id));
        pool.requestCooling(id, 1e18);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.Listed.selector, id));
        pool.seal(id, 0);
        vm.stopPrank();
        vm.prank(boost);
        pool.setOrdinaryBonus(id, 10_000); // BOOST is not the owner: not locked
        pool.poke(id);

        // The owner ends the listing directly, without the market.
        vm.expectEmit(address(pool));
        emit ForgePoolBase.ListingChanged(id, listing + 1);
        vm.prank(alice);
        pool.unlist(id);
        vm.prank(alice);
        pool.deposit(id, 1e18);

        // Emergency exit from a listing ends it: the market's sale can no longer settle.
        vm.prank(deeds);
        listing = pool.list(id, alice);
        vm.prank(alice);
        pool.emergencyExit(id);
        assertEq(pool.listingOf(id), listing + 1, "the exit ended the listing");
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NotListed.selector, id));
        vm.prank(deeds);
        pool.settle(id, bob, listing);
    }

    function test_deedSettlementCarriesEightyPercentOfCappedAge() public {
        vm.prank(alice);
        uint256 id = pool.open(200e18);
        skip(700 days);
        vm.prank(alice);
        pool.deposit(id, 100e18); // a young lot
        skip(30 days); // lot 0: 730 days, capped at 365; lot 1: 30 days
        vm.prank(alice);
        pool.requestCooling(id, 10e18); // starts a plan
        skip(7 days); // the ticket lapses and returns
        vm.prank(boost);
        pool.setOrdinaryBonus(id, 20_000);
        uint256 sellerStreak = pool.positionOf(id).streakStart;
        vm.prank(deeds);
        uint32 listing = pool.list(id, alice);
        skip(1 days);

        vm.expectEmit(address(pool));
        emit ForgePoolBase.DeedSettled(id, alice, bob);
        vm.prank(deeds);
        pool.settle(id, bob, listing);

        ForgePoolBase.Position memory p = pool.positionOf(id);
        assertEq(p.owner, bob);
        assertEq(p.streakStart, block.timestamp, "a new Streak");
        assertEq(p.ordinaryBonus, 0, "Pyre stays with the seller");
        assertEq(p.plan.start, 0, "a fresh cooling plan");
        assertEq(p.listing, listing + 1, "the listing is spent");
        assertEq(p.transfers, 1);
        assertEq(pool.ownedSince(id), block.timestamp);
        ForgePoolBase.Ownership memory o = pool.ownershipAt(id, 0);
        assertEq(o.owner, alice);
        assertEq(o.until, block.timestamp);
        for (uint256 j; j < 32; ++j) {
            (uint256 amount, uint256 age,,) = pool.lotAt(id, j);
            if (amount == 0) continue;
            Lot memory head = pool.lotOf(id, j);
            assertEq(head.since, block.timestamp, "every active segment restarts at the sale");
            Record memory closed = pool.historyAt(id, j, head.records - 1);
            assertEq(closed.streak, sellerStreak, "the closed segment keeps the seller's Streak");
            assertEq(closed.ordinaryBonus, 20_000, "and the seller's bonus");
            uint256 before = Math.min(uint256(closed.age) + (block.timestamp - closed.since), P.HEAT_AGE_CAP);
            assertEq(age, HeatMath.deedAge(before), "80% of capped age");
        }
        // The spec's example: 730 days carry 292.
        (, uint256 oldest,,) = pool.lotAt(id, 0);
        assertEq(oldest, 292 days);

        // The buyer owns every path now; the seller none.
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NotOwner.selector, id));
        vm.prank(alice);
        pool.deposit(id, 1e18);
        _fund(bob);
        vm.prank(bob);
        pool.deposit(id, 1e18);
    }

    function test_deedSettlementClearsWalletBoundTerms() public {
        ForgePoolHarness h = new ForgePoolHarness(IERC20(address(token)), true, collector, boost, deeds);
        vm.prank(alice);
        token.approve(address(h), type(uint256).max);
        vm.prank(alice);
        uint256 id = h.open(10e18);
        h.setPhantomForTest(id, true, true, 3 days);
        vm.prank(deeds);
        uint32 listing = h.list(id, alice);
        assertTrue(h.positionOf(id).founder && h.positionOf(id).headStartActive);
        vm.prank(deeds);
        h.settle(id, bob, listing);
        ForgePoolBase.Position memory p = h.positionOf(id);
        assertFalse(p.founder, "First Flame stays with its wallet");
        assertFalse(p.headStartActive, "the head start is never sold");
        assertEq(p.headStart, 3 days, "its amount stays for the seller's records");
    }

    function test_gas_deedSettle() public {
        vm.startPrank(alice);
        uint256 id = pool.open(1e18);
        for (uint256 i = 1; i < 32; ++i) {
            skip(1 hours);
            pool.deposit(id, 1e18);
        }
        vm.stopPrank();
        skip(400 days);
        vm.prank(deeds);
        uint256 g = gasleft();
        uint32 listing = pool.list(id, alice);
        emit log_named_uint("list (32 lots)", g - gasleft());
        skip(1 days);
        vm.prank(deeds);
        g = gasleft();
        pool.settle(id, bob, listing);
        emit log_named_uint("settle (32 lots)", g - gasleft());
    }
}

contract Reverter {
    fallback() external payable {
        revert("no");
    }
}
