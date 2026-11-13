// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {ForgePoolBase} from "../src/forge/ForgePoolBase.sol";
import {ForgePoolAnnex} from "../src/forge/ForgePoolAnnex.sol";
import {ForgeView} from "../src/forge/ForgeView.sol";
import {Lot, Record, Seal, SlotMeasure} from "../src/forge/ForgeMeasures.sol";
import {HeatMath} from "../src/libraries/HeatMath.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {ForgeVectors} from "./utils/ForgeVectors.sol";
import {MockERC20, FeeOnTransferERC20} from "./utils/MockERC20.sol";
import {MockFounders} from "./utils/MockFounders.sol";

using ForgeView for ForgePool;
using ForgeView for ForgePoolHarness;

/// @dev Test-only subclass: jumps a position's ticket or record counter towards its limit.
/// @dev The harness's compounder on an LP pool (ADR 0017).
address constant HARNESS_COMPOUNDER = address(0xC0FFEE);

contract ForgePoolHarness is ForgePool {
    constructor(IERC20 stakeToken, bool isLp, address feeCollector, address boost, address deeds)
        ForgePool(stakeToken, isLp, feeCollector, boost, deeds, address(0), isLp ? HARNESS_COMPOUNDER : address(0), address(0), address(0), address(0))
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
    /// @dev The compounder of an LP pool (ADR 0017); a single-asset pool has none.
    address compounder = makeAddr("compounder");
    /// @dev Kindling on an LP pool, and the founder record every pool reads (ADR 0018).
    address kindling = makeAddr("kindling");
    MockFounders founders;
    /// @dev Ignition, the head start's granter, on every pool (ADR 0019).
    address ignition = makeAddr("ignition");

    uint256 constant FUND = 1e30;

    function _deploy(bool lp) internal {
        token = new MockERC20("Receipt", "RCPT");
        founders = new MockFounders();
        pool = new ForgePool(
            IERC20(address(token)),
            lp,
            collector,
            boost,
            deeds,
            address(0),
            lp ? compounder : address(0),
            lp ? kindling : address(0),
            address(founders),
            ignition
        );
        _fund(compounder);
        _fund(kindling);
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
        Tap,
        AddToLot,
        OpenKindling,
        RefreshFounder,
        GrantHeadStart
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
    function test_scenario_addToLotBasics() public { _replay("addToLotBasics"); }
    function test_scenario_addToLotCooling() public { _replay("addToLotCooling"); }
    function test_scenario_addToLotSeal() public { _replay("addToLotSeal"); }
    function test_scenario_addToLotDeeds() public { _replay("addToLotDeeds"); }
    function test_scenario_addToLotSingleAsset() public { _replay("addToLotSingleAsset"); }
    function test_scenario_addToLotCapacity() public { _replay("addToLotCapacity"); }
    function test_scenario_adds0() public { _replay("adds0"); }
    function test_scenario_adds1() public { _replay("adds1"); }
    function test_scenario_adds2() public { _replay("adds2"); }
    function test_scenario_firstFlameHeat() public { _replay("firstFlameHeat"); }
    function test_scenario_firstFlameRevokeAndDeed() public { _replay("firstFlameRevokeAndDeed"); }
    function test_scenario_firstFlameSeal() public { _replay("firstFlameSeal"); }
    function test_scenario_kindlingPositions() public { _replay("kindlingPositions"); }
    function test_scenario_kindlingSingleAsset() public { _replay("kindlingSingleAsset"); }
    function test_scenario_flame0() public { _replay("flame0"); }
    function test_scenario_flame1() public { _replay("flame1"); }
    function test_scenario_flame2() public { _replay("flame2"); }
    function test_scenario_headStartLot() public { _replay("headStartLot"); }
    function test_scenario_headStartCooling() public { _replay("headStartCooling"); }
    function test_scenario_headStartDeed() public { _replay("headStartDeed"); }
    function test_scenario_start0() public { _replay("start0"); }
    function test_scenario_start1() public { _replay("start1"); }
    function test_scenario_start2() public { _replay("start2"); }

    /// Every generated scenario has a test above; a new one fails this until added.
    function test_everyScenarioIsReplayed() public view {
        assertEq(vm.parseJsonStringArray(forgeJson, ".names").length, 66, "add a test_scenario_* for each new scenario");
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
            address actor = kind == Kind.Open || kind == Kind.OpenKindling ? _user(pos) : pool.ownerOf(pos);
            // The founder record answers for the owner before the call (not inside expectRevert's call).
            if (kind == Kind.RefreshFounder) founders.set(actor, arg == 1);
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
        if (kind == Kind.AddToLot) {
            vm.prank(compounder);
            pool.addToLot(pos, arg >> 128, uint128(arg));
            return;
        }
        if (kind == Kind.OpenKindling) {
            vm.prank(kindling);
            uint256 id = pool.openKindling(actor, arg);
            if (!reverts) assertEq(id, pos, "position id");
            return;
        }
        if (kind == Kind.RefreshFounder) {
            pool.refreshFounder(pos);
            return;
        }
        if (kind == Kind.GrantHeadStart) {
            vm.prank(ignition);
            pool.grantHeadStart(pos, arg >> 128, uint128(arg));
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
        (w[n], w[n + 1], w[n + 2], w[n + 3]) = (_wallet(prev.owner), prev.until, p.lastTapAt, p.founder ? 1 : 0);
        (w[n + 4], w[n + 5], w[n + 6]) = (p.headStart, p.headStartActive ? 1 : 0, p.headStartMask);
        return n + 7;
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
        new ForgePool(IERC20(address(0)), true, collector, boost, deeds, address(0), address(0), address(0), address(0), address(0));
        vm.expectRevert(ForgePoolBase.ZeroAddress.selector);
        new ForgePool(IERC20(address(token)), true, address(0), boost, deeds, address(0), address(0), address(0), address(0), address(0));
        vm.expectRevert(ForgePoolBase.ZeroAddress.selector);
        new ForgePool(IERC20(address(token)), true, collector, address(0), deeds, address(0), address(0), address(0), address(0), address(0));
        vm.expectRevert(ForgePoolBase.ZeroAddress.selector);
        new ForgePool(IERC20(address(token)), true, collector, boost, address(0), address(0), address(0), address(0), address(0), address(0));
    }

    function test_feeOnTransferTokenIsRejected() public {
        FeeOnTransferERC20 skim = new FeeOnTransferERC20();
        ForgePool skimPool = new ForgePool(IERC20(address(skim)), false, collector, boost, deeds, address(0), address(0), address(0), address(0), address(0));
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
        ForgePool hostile = new ForgePool(IERC20(address(token)), true, address(new Reverter()), boost, deeds, address(0), address(0), address(0), address(0), address(0));
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
        assertEq(annex.FLOW(), pool.FLOW());
        assertEq(annex.COMPOUNDER(), pool.COMPOUNDER());
        assertEq(pool.COMPOUNDER(), compounder, "the fixture's LP pool names its compounder");
        assertEq(annex.KINDLING(), pool.KINDLING());
        assertEq(annex.FOUNDERS(), pool.FOUNDERS());
        assertEq(annex.IGNITION(), pool.IGNITION());
        assertEq(pool.IGNITION(), ignition);
        assertEq(pool.KINDLING(), kindling);
        assertEq(pool.FOUNDERS(), address(founders));
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
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.UnknownPosition.selector, id));
        vm.prank(compounder);
        annex.addToLot(id, 0, 1e18);
    }

    // ── source-lot additions (ADR 0017) ───────────────────────────────────

    function _openAged(uint256 amount, uint256 ageDays) internal returns (uint256 id) {
        vm.prank(alice);
        id = pool.open(amount);
        skip(ageDays * 1 days);
    }

    function _add(uint256 id, uint256 slot, uint256 amount) internal {
        vm.prank(compounder);
        pool.addToLot(id, slot, amount);
    }

    function test_addToLot_onlyTheCompounder() public {
        uint256 id = _openAged(100e18, 1);
        for (uint256 i; i < 3; ++i) {
            address caller = [alice, boost, address(0)][i];
            vm.expectRevert(ForgePoolBase.NotCompounder.selector);
            vm.prank(caller);
            pool.addToLot(id, 0, 1e18);
        }
    }

    /// With no compounder set, nobody can add, not even a caller that is the zero address.
    function test_addToLot_zeroCompounderAddsNothing() public {
        ForgePool none = new ForgePool(IERC20(address(token)), true, collector, boost, deeds, address(0), address(0), address(0), address(0), address(0));
        vm.startPrank(alice);
        token.approve(address(none), type(uint256).max);
        uint256 id = none.open(100e18);
        vm.stopPrank();
        vm.expectRevert(ForgePoolBase.NotCompounder.selector);
        vm.prank(address(0));
        none.addToLot(id, 0, 1e18);
    }

    function test_compounderNeedsAnLpPool() public {
        vm.expectRevert(ForgePoolBase.CompounderNeedsLp.selector);
        new ForgePool(IERC20(address(token)), false, collector, boost, deeds, address(0), compounder, address(0), address(0), address(0));
        ForgePool single = new ForgePool(IERC20(address(token)), false, collector, boost, deeds, address(0), address(0), address(0), address(0), address(0));
        assertEq(single.COMPOUNDER(), address(0));
    }

    /// The addition takes the lot's own age and participation, books no fee, uses no slot,
    /// keeps the Streak and grows active principal by exactly what the compounder sent.
    function test_addToLot_atTheSourceLotsAge() public {
        uint256 id = _openAged(1000e18, 50);
        vm.prank(alice);
        pool.deposit(id, 500e18); // slot 1, age 0
        skip(10 days);
        uint256 fees = pool.feesOwed(0);
        uint256 active = pool.activePrincipal();
        uint256 streak = pool.positionOf(id).streakStart;
        uint256 sent = token.balanceOf(compounder);
        vm.expectEmit(address(pool));
        emit ForgePoolBase.AddedToLot(id, 0, 200e18);
        _add(id, 0, 200e18);
        (uint256 amount, uint256 age, uint256 part, uint256 heldBy) = pool.lotAt(id, 0);
        assertEq(amount, 990e18 + 200e18, "the whole addition, no fee");
        assertEq(age, 60 days, "the source lot's age");
        assertEq(part, P.ASHFALL_MIN_PARTICIPATION, "and its participation");
        assertEq(heldBy, 0);
        assertEq(pool.lotOf(id, 0).since, block.timestamp, "a new head from now");
        (, age, part,) = pool.lotAt(id, 1);
        assertEq(age, 10 days, "the other lot is untouched");
        assertEq(pool.lotCount(id), 2, "no slot used");
        assertEq(pool.feesOwed(0), fees, "no fee booked");
        assertEq(pool.activePrincipal(), active + 200e18);
        assertEq(pool.positionOf(id).streakStart, streak, "the Streak is kept");
        assertEq(sent - token.balanceOf(compounder), 200e18, "pulled from the compounder");
        assertEq(token.balanceOf(address(pool)), pool.activePrincipal() + pool.frozenPrincipal() + pool.feesOwed(0));
        skip(5 days);
        pool.poke(id);
        (, age,,) = pool.lotAt(id, 0);
        assertEq(age, 65 days, "and it keeps ageing from there");
    }

    /// An addition is measured from its instant onward, at the lot's Heat: S and W over the
    /// past are unchanged, and the next interval integrates the larger amount at the old age.
    function test_addToLot_measuresOnlyFromNow() public {
        uint256 id = _openAged(1000e18, 40);
        pool.poke(id);
        uint256 t1 = block.timestamp;
        (uint256 s0, uint256 w0,,,) = pool.epochMeasure(id, 0, t1);
        _add(id, 0, 100e18);
        skip(1 days);
        pool.poke(id);
        (uint256 s1, uint256 w1,,,) = pool.epochMeasure(id, 0, t1);
        assertEq(abi.encode(s1, w1), abi.encode(s0, w0), "the past is unchanged");
        (uint256 s2, uint256 w2,,,) = pool.epochMeasure(id, t1, block.timestamp);
        assertEq(s2, 1090e18 * 1 days);
        assertEq(w2, 1090e18 * HeatMath.integrateHeat(40 days, 1 days, 0));
    }

    function test_addToLot_keepsTheSealCohort() public {
        uint256 id = _openAged(1000e18, 1);
        vm.prank(alice);
        uint256 k = pool.seal(id, 0);
        skip(1 days);
        _add(id, 0, 100e18);
        assertEq(pool.lotOf(id, 0).seal, k, "the source cohort's tag");
        skip(1 days);
        pool.poke(id);
        (uint256 s,, uint256 ss,,) = pool.epochMeasure(id, block.timestamp - 1 days, block.timestamp);
        assertEq(ss, s, "the addition earns under the Seal");
    }

    function test_addToLot_refusals() public {
        uint256 id = _openAged(100e18, 1);
        vm.startPrank(compounder);
        vm.expectRevert(ForgePoolBase.ZeroAmount.selector);
        pool.addToLot(id, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NotActiveLot.selector, id, 1));
        pool.addToLot(id, 1, 1e18); // never used
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NotActiveLot.selector, id, 32));
        pool.addToLot(id, 32, 1e18);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.UnknownPosition.selector, 9));
        pool.addToLot(9, 0, 1e18);
        vm.stopPrank();
        // Wholly frozen: the slot is reserved for its slice, not active.
        vm.prank(alice);
        uint32 t = pool.requestCooling(id, 99e18);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NotActiveLot.selector, id, 0));
        _add(id, 0, 1e18);
        vm.prank(alice);
        pool.cancelCooling(id, t);
        _add(id, 0, 1e18); // active again
        // Listed: the reward travels with the Deed instead.
        vm.prank(deeds);
        pool.list(id, alice);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.Listed.selector, id));
        _add(id, 0, 1e18);
        vm.prank(alice);
        pool.unlist(id);
        // Closed: never resurrected (§98).
        vm.prank(alice);
        pool.emergencyExit(id);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.Closed.selector, id));
        _add(id, 0, 1e18);
    }

    function test_addToLot_partlyCoolingLotGrows() public {
        uint256 id = _openAged(1000e18, 10);
        vm.prank(alice);
        pool.requestCooling(id, 99e18);
        _add(id, 0, 9e18);
        (uint256 amount,,,) = pool.lotAt(id, 0);
        assertEq(amount, 891e18 + 9e18);
        assertEq(pool.frozenPrincipal(), 99e18, "the ticket is untouched");
    }

    /// At 32 lots a deposit has no slot, but an addition needs none.
    function test_addToLot_usesNoSlotAtCapacity() public {
        uint256 id = _openAged(1e18, 0);
        vm.startPrank(alice);
        for (uint256 i = 1; i < 32; ++i) pool.deposit(id, 1e18);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.LotCapacity.selector, id));
        pool.deposit(id, 1e18);
        vm.stopPrank();
        _add(id, 31, 5e18);
        assertEq(pool.lotCount(id), 32);
    }

    /// A bonus is diluted exactly as a deposit of the same size would dilute it.
    function test_addToLot_dilutesTheBonusLikeADeposit() public {
        uint256 id = _openAged(100e18, 1);
        vm.prank(boost);
        pool.setOrdinaryBonus(id, 50_000);
        vm.expectEmit(address(pool));
        emit ForgePoolBase.OrdinaryBonusSet(id, 12_500); // 50000 · 99 / (99 + 297)
        _add(id, 0, 297e18);
        assertEq(pool.positionOf(id).ordinaryBonus, 12_500);
    }

    function test_addToLot_amountWidthIsChecked() public {
        uint256 id = _openAged(100e18, 1);
        vm.expectRevert(); // SafeCast: the lot's amount is a uint96
        _add(id, 0, uint256(type(uint96).max) - 99e18 + 1);
        _add(id, 0, uint256(type(uint96).max) - 99e18); // exactly full
        (uint256 amount,,,) = pool.lotAt(id, 0);
        assertEq(amount, type(uint96).max);
    }

    // ── Kindling positions and First Flame (ADR 0018) ─────────────────────

    function test_openKindling_atTheStandardFee() public {
        uint256 fees = pool.feesOwed(0);
        uint256 sent = token.balanceOf(kindling);
        uint256 own = token.balanceOf(alice);
        vm.expectEmit(address(pool));
        emit ForgePoolBase.Opened(1, alice);
        vm.prank(kindling);
        uint256 id = pool.openKindling(alice, 1000e18);
        assertEq(pool.ownerOf(id), alice, "the contributor owns it");
        assertEq(pool.feesOwed(0) - fees, 10e18, "the 1% deposit fee, booked");
        assertEq(sent - token.balanceOf(kindling), 1000e18, "pulled from Kindling");
        assertEq(token.balanceOf(alice), own, "not from the contributor");
        (uint256 amount, uint256 age, uint256 part,) = pool.lotAt(id, 0);
        assertEq(abi.encode(amount, age, part), abi.encode(990e18, 0, 0), "a fresh lot: nothing backdated");
        assertEq(pool.positionOf(id).streakStart, block.timestamp, "a Streak from now");
        vm.prank(alice);
        pool.deposit(id, 100e18); // the contributor's own position from here
        assertEq(pool.lotCount(id), 2);
    }

    function test_openKindling_onlyKindling() public {
        vm.expectRevert(ForgePoolBase.NotKindling.selector);
        vm.prank(alice);
        pool.openKindling(alice, 100e18);
        vm.expectRevert(ForgePoolBase.ZeroAddress.selector);
        vm.prank(kindling);
        pool.openKindling(address(0), 100e18);
        ForgePool none =
            new ForgePool(IERC20(address(token)), true, collector, boost, deeds, address(0), address(0), address(0), address(0), address(0));
        vm.expectRevert(ForgePoolBase.NotKindling.selector);
        vm.prank(address(0));
        none.openKindling(alice, 100e18);
    }

    function test_kindlingNeedsAnLpPool() public {
        vm.expectRevert(ForgePoolBase.KindlingNeedsLp.selector);
        new ForgePool(IERC20(address(token)), false, collector, boost, deeds, address(0), address(0), kindling, address(0), address(0));
        // First Flame applies in every pool: a single-asset pool may name the founder record.
        ForgePool single = new ForgePool(
            IERC20(address(token)), false, collector, boost, deeds, address(0), address(0), address(0), address(founders), address(0)
        );
        assertEq(single.FOUNDERS(), address(founders));
    }

    function _twins() internal returns (uint256 a, uint256 b) {
        vm.prank(alice);
        a = pool.open(1000e18);
        vm.prank(bob);
        b = pool.open(1000e18);
        founders.set(alice, true);
    }

    /// A founder's financial Heat reads 15 days older. S, lot ages, participation and the Ashfall
    /// weight do not change.
    function test_firstFlame_offsetsFinancialHeatOnly() public {
        (uint256 a, uint256 b) = _twins();
        vm.expectEmit(address(pool));
        emit ForgePoolBase.FounderSet(a, true);
        assertTrue(pool.refreshFounder(a));
        assertFalse(pool.refreshFounder(b));
        uint256 t0 = block.timestamp;
        skip(60 days);
        pool.poke(a);
        pool.poke(b);
        (uint256 sa, uint256 wa,,, uint256 qa) = pool.epochMeasure(a, t0, block.timestamp);
        (uint256 sb, uint256 wb,,, uint256 qb) = pool.epochMeasure(b, t0, block.timestamp);
        assertEq(sa, sb, "stake-seconds are equal");
        assertEq(wa, 990e18 * HeatMath.integrateHeat(P.FIRST_FLAME_AGE, 60 days, 0), "Heat from day 15");
        assertEq(wb, 990e18 * HeatMath.integrateHeat(0, 60 days, 0), "Heat from day 0");
        assertGt(qa, 0);
        assertEq(qa, qb, "the Ashfall weight never sees it");
        (, uint256 ageA, uint256 partA,) = pool.lotAt(a, 0);
        (, uint256 ageB, uint256 partB,) = pool.lotAt(b, 0);
        assertEq(abi.encode(ageA, partA), abi.encode(ageB, partB), "lot age and participation are untouched");
    }

    function test_firstFlame_saturatesAtTheAgeCap() public {
        (uint256 a, uint256 b) = _twins();
        skip(360 days);
        pool.refreshFounder(a);
        pool.poke(b);
        uint256 t0 = block.timestamp;
        skip(10 days);
        pool.poke(a);
        pool.poke(b);
        (, uint256 wa,,,) = pool.epochMeasure(a, t0, block.timestamp);
        (, uint256 wb,,,) = pool.epochMeasure(b, t0, block.timestamp);
        assertEq(wa, 990e18 * HeatMath.integrateHeat(P.HEAT_AGE_CAP, 10 days, 0), "capped from the start");
        assertEq(wb, 990e18 * HeatMath.integrateHeat(360 days, 10 days, 0));
    }

    function test_firstFlame_sealedHeatToo() public {
        (uint256 a,) = _twins();
        vm.prank(alice);
        pool.seal(a, 0);
        pool.refreshFounder(a);
        uint256 t0 = block.timestamp;
        skip(5 days);
        pool.poke(a);
        (, uint256 w,, uint256 ws,) = pool.epochMeasure(a, t0, block.timestamp);
        assertEq(ws, w, "the sealed W reads the offset too");
        assertEq(w, 990e18 * HeatMath.integrateHeat(P.FIRST_FLAME_AGE, 5 days, 0));
    }

    /// The flag follows the record, a sale clears it, and an unchanged answer writes nothing.
    function test_firstFlame_followsTheRecordAndNeverTransfers() public {
        (uint256 a,) = _twins();
        pool.refreshFounder(a);
        uint256 recs = pool.lotOf(a, 0).records;
        skip(1 days);
        assertTrue(pool.refreshFounder(a));
        assertEq(pool.lotOf(a, 0).records, recs, "an unchanged flag rewrites no record");
        founders.set(alice, false);
        assertFalse(pool.refreshFounder(a), "revoked");
        skip(1 days);
        founders.set(alice, true);
        pool.refreshFounder(a);
        vm.prank(deeds);
        uint32 listing = pool.list(a, alice);
        skip(1 days);
        vm.prank(deeds);
        pool.settle(a, bob, listing);
        assertFalse(pool.positionOf(a).founder, "a sale clears it: First Flame does not transfer");
        assertFalse(pool.refreshFounder(a), "bob holds no founder record");
        founders.set(bob, true);
        assertTrue(pool.refreshFounder(a), "until he does");
        vm.prank(bob);
        pool.emergencyExit(a);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.Closed.selector, a));
        pool.refreshFounder(a);
    }

    /// A founder record that reverts, has no code or answers malformed counts as none.
    function test_firstFlame_brokenRecordsCountAsNone() public {
        address[4] memory sources = [address(new Reverter()), makeAddr("codeless"), address(new TwoFounders()), address(0)];
        for (uint256 i; i < sources.length; ++i) {
            ForgePool p2 =
                new ForgePool(IERC20(address(token)), true, collector, boost, deeds, address(0), address(0), address(0), sources[i], address(0));
            vm.startPrank(alice);
            token.approve(address(p2), type(uint256).max);
            uint256 id = p2.open(100e18);
            vm.stopPrank();
            assertFalse(p2.refreshFounder(id), "no founder");
            assertFalse(p2.positionOf(id).founder);
        }
    }

    function test_gas_refreshFounder() public {
        vm.startPrank(alice);
        uint256 id = pool.open(1e18);
        for (uint256 i = 1; i < 32; ++i) pool.deposit(id, 1e18);
        vm.stopPrank();
        founders.set(alice, true);
        skip(1 days);
        uint256 g = gasleft();
        pool.refreshFounder(id);
        emit log_named_uint("refreshFounder, rewriting 32 lots", g - gasleft());
        vm.prank(kindling);
        g = gasleft();
        pool.openKindling(bob, 100e18);
        emit log_named_uint("openKindling", g - gasleft());
    }

    // ── the head start (ADR 0019) ─────────────────────────────────────────

    function _grant(uint256 id, uint256 slot, uint256 secs) internal {
        vm.prank(ignition);
        pool.grantHeadStart(id, slot, secs);
    }

    function _slotW(uint256 id, uint256 slot, uint256 t0) internal view returns (uint256 w, uint256 q) {
        SlotMeasure memory m = pool.measureSlot(id, slot, t0, block.timestamp, 0, type(uint256).max, true);
        return (m.heatSeconds, m.ashfallQuotient);
    }

    /// Only the granted lot reads the head start; a later deposit and a twin do not. Lot ages,
    /// participation and the Ashfall weight never see it.
    function test_headStart_coversTheGrantedLotOnly() public {
        (uint256 a, uint256 b) = _twins();
        vm.prank(alice);
        pool.deposit(a, 1000e18); // slot 1: new capital
        vm.expectEmit(address(pool));
        emit ForgePoolBase.HeadStartGranted(a, 0, 60 days);
        _grant(a, 0, 60 days);
        ForgePoolBase.Position memory p = pool.positionOf(a);
        assertEq(abi.encode(p.headStart, p.headStartActive, p.headStartMask), abi.encode(60 days, true, 1));
        uint256 t0 = block.timestamp;
        skip(40 days);
        pool.poke(a);
        pool.poke(b);
        (uint256 w0, uint256 q0) = _slotW(a, 0, t0);
        (uint256 w1,) = _slotW(a, 1, t0);
        (uint256 wb, uint256 qb) = _slotW(b, 0, t0);
        assertEq(w0, 990e18 * HeatMath.integrateHeat(60 days, 40 days, 0), "the granted lot reads 60 days older");
        assertEq(w1, 990e18 * HeatMath.integrateHeat(0, 40 days, 0), "the deposit does not");
        assertEq(wb, w1, "nor the twin");
        assertEq(q0, qb, "the Ashfall weight never sees it");
        (, uint256 age0, uint256 part0,) = pool.lotAt(a, 0);
        (, uint256 ageB, uint256 partB,) = pool.lotAt(b, 0);
        assertEq(abi.encode(age0, part0), abi.encode(ageB, partB), "lot age and participation are untouched");
    }

    function test_headStart_stacksWithFirstFlame() public {
        (uint256 a,) = _twins();
        pool.refreshFounder(a);
        _grant(a, 0, 60 days);
        uint256 t0 = block.timestamp;
        skip(10 days);
        pool.poke(a);
        (uint256 w,) = _slotW(a, 0, t0);
        assertEq(w, 990e18 * HeatMath.integrateHeat(60 days + P.FIRST_FLAME_AGE, 10 days, 0), "both, stacked");
        _grant2Cap(a);
    }

    /// Stacked past the cap, the age saturates like any age.
    function _grant2Cap(uint256) internal {
        vm.prank(bob);
        uint256 c = pool.open(1000e18);
        founders.set(bob, true);
        pool.refreshFounder(c);
        _grant(c, 0, 360 days);
        uint256 t0 = block.timestamp;
        skip(1 days);
        pool.poke(c);
        (uint256 w,) = _slotW(c, 0, t0);
        assertEq(w, 990e18 * HeatMath.integrateHeat(P.HEAT_AGE_CAP, 1 days, 0), "capped");
    }

    function test_headStart_gating() public {
        (uint256 a,) = _twins();
        vm.expectRevert(ForgePoolBase.NotIgnition.selector);
        vm.prank(alice);
        pool.grantHeadStart(a, 0, 1 days);
        vm.startPrank(ignition);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.BadHeadStart.selector, 0));
        pool.grantHeadStart(a, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.BadHeadStart.selector, P.HEAT_AGE_CAP + 1));
        pool.grantHeadStart(a, 0, P.HEAT_AGE_CAP + 1);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NotActiveLot.selector, a, 1));
        pool.grantHeadStart(a, 1, 1 days);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NotActiveLot.selector, a, 32));
        pool.grantHeadStart(a, 32, 1 days);
        pool.grantHeadStart(a, 0, 1 days);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.HeadStartUsed.selector, a));
        pool.grantHeadStart(a, 0, 2 days);
        vm.stopPrank();
        ForgePool none = new ForgePool(
            IERC20(address(token)), true, collector, boost, deeds, address(0), address(0), address(0), address(0), address(0)
        );
        vm.expectRevert(ForgePoolBase.NotIgnition.selector);
        vm.prank(address(0));
        none.grantHeadStart(1, 0, 1 days);
    }

    function test_headStart_refusesListedAndClosed() public {
        (uint256 a, uint256 b) = _twins();
        vm.prank(deeds);
        pool.list(a, alice);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.Listed.selector, a));
        _grant(a, 0, 1 days);
        vm.prank(bob);
        pool.emergencyExit(b);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.Closed.selector, b));
        _grant(b, 0, 1 days);
    }

    /// A sale ends the head start: it is never sold as financial age. It cannot be granted again.
    function test_headStart_endsAtSale() public {
        (uint256 a,) = _twins();
        _grant(a, 0, 60 days);
        vm.prank(deeds);
        uint32 listing = pool.list(a, alice);
        skip(1 days);
        vm.prank(deeds);
        pool.settle(a, bob, listing);
        ForgePoolBase.Position memory p = pool.positionOf(a);
        assertFalse(p.headStartActive, "ended");
        assertEq(p.headStart, 60 days, "the amount stays, for the seller's records");
        uint256 t0 = block.timestamp;
        skip(5 days);
        pool.poke(a);
        (uint256 w,) = _slotW(a, 0, t0);
        (, uint256 age,,) = pool.lotAt(a, 0);
        assertEq(w, 990e18 * HeatMath.integrateHeat(age - 5 days, 5 days, 0), "the buyer's lot reads its carried age only");
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.HeadStartUsed.selector, a));
        _grant(a, 0, 1 days);
    }

    /// The granted lot's principal keeps it wherever its slices return; a freed slot loses it.
    function test_headStart_followsItsPrincipal() public {
        (uint256 a,) = _twins();
        _grant(a, 0, 30 days);
        vm.startPrank(alice);
        uint32 t = pool.requestCooling(a, 990e18); // the whole lot, held by the ticket
        skip(3 days);
        pool.executeWithdrawal(a, t);
        assertEq(pool.positionOf(a).headStartMask, 0, "the slot freed, and the head start with it");
        pool.deposit(a, 500e18); // slot 0 again: new capital
        vm.stopPrank();
        assertEq(pool.positionOf(a).headStartMask, 0);
        uint256 t0 = block.timestamp;
        skip(1 days);
        pool.poke(a);
        (uint256 w,) = _slotW(a, 0, t0);
        assertEq(w, 495e18 * HeatMath.integrateHeat(0, 1 days, 0), "no head start for the new lot");
    }

    function test_gas_grantHeadStart() public {
        vm.prank(alice);
        uint256 id = pool.open(100e18);
        skip(1 days);
        vm.prank(ignition);
        uint256 g = gasleft();
        pool.grantHeadStart(id, 0, 30 days);
        emit log_named_uint("grantHeadStart", g - gasleft());
    }

    /// The addition alone, and with a bonus to dilute across 32 lots (the worst case).
    function test_gas_addToLot() public {
        uint256 id = _openAged(100e18, 0);
        vm.startPrank(alice);
        for (uint256 i = 1; i < 32; ++i) pool.deposit(id, 1e18);
        vm.stopPrank();
        skip(1 days);
        vm.prank(compounder);
        uint256 g = gasleft();
        pool.addToLot(id, 0, 1e18);
        emit log_named_uint("addToLot, no bonus", g - gasleft());
        vm.prank(boost);
        pool.setOrdinaryBonus(id, 50_000);
        skip(1 days);
        vm.prank(compounder);
        g = gasleft();
        pool.addToLot(id, 0, 1e18);
        emit log_named_uint("addToLot, diluting a bonus across 32 lots", g - gasleft());
    }

    function test_addToLot_respectsTheRecordLimit() public {
        ForgePoolHarness h = new ForgePoolHarness(IERC20(address(token)), true, collector, boost, deeds);
        vm.startPrank(alice);
        token.approve(address(h), type(uint256).max);
        uint256 id = h.open(100e18);
        vm.stopPrank();
        token.mint(HARNESS_COMPOUNDER, 10e18);
        vm.prank(HARNESS_COMPOUNDER);
        token.approve(address(h), type(uint256).max);
        h.setRecordsForTest(id, 0, uint24(h.BOOST_RECORD_LIMIT()));
        skip(1 days);
        vm.prank(HARNESS_COMPOUNDER);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.RecordLimit.selector, id, 0));
        h.addToLot(id, 0, 1e18);
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

    /// The lower edges of Eternal (its 25% share) and Bedrock (its 60-day window), to the second.
    function test_tapTierEdges() public {
        vm.startPrank(alice);
        uint256 id = pool.open(1000e18); // 990 active
        uint256 start = pool.positionOf(id).streakStart;
        vm.warp(start + P.TAP_TIER_1_STREAK - 1); // still Blaze: 10%
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.TapQuotaExceeded.selector, 99e18 + 1, 99e18));
        pool.requestTap(id, 99e18 + 1);
        skip(1); // Eternal: 25%
        pool.cancelCooling(id, pool.requestTap(id, 247.5e18));
        uint256 last = start + P.TAP_TIER_2_STREAK - P.TAP_TIER_2_EVERY - 1;
        vm.warp(last);
        pool.cancelCooling(id, pool.requestTap(id, 1e18));
        vm.warp(last + P.TAP_TIER_2_EVERY); // a second before Bedrock: Eternal's 90-day window
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.TapTooSoon.selector, last + P.TAP_TIER_1_EVERY));
        pool.requestTap(id, 1e18);
        skip(1); // Bedrock: 60 days have passed
        pool.requestTap(id, 1e18);
        vm.stopPrank();
    }

    /// The tier follows the Streak, not the position's age: an ordinary execution ends the perk.
    function test_tapNeedsTheStreakNotTheAge() public {
        vm.startPrank(alice);
        uint256 id = pool.open(1000e18);
        skip(100 days);
        uint32 t = pool.requestCooling(id, 10e18);
        skip(P.WITHDRAW_TIER_0_SECONDS);
        pool.executeWithdrawal(id, t); // the Streak restarts
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NoTap.selector, id));
        pool.requestTap(id, 1e18);
        vm.warp(pool.positionOf(id).streakStart + P.TAP_TIER_0_STREAK);
        pool.requestTap(id, 1e18);
        vm.stopPrank();
    }

    /// The share is of active principal: principal already cooling does not count.
    function test_tapQuotaIsOfActivePrincipal() public {
        vm.startPrank(alice);
        uint256 id = pool.open(1000e18); // 990
        skip(P.TAP_TIER_0_STREAK);
        pool.requestCooling(id, 90e18); // 900 active, 90 frozen
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.TapQuotaExceeded.selector, 90e18 + 1, 90e18));
        pool.requestTap(id, 90e18 + 1);
        pool.requestTap(id, 90e18); // 10% of 900
        vm.stopPrank();
    }

    /// Lots past the age cap tie: the Tap draws the lower slot first.
    function test_tapTiesGoToTheLowerSlot() public {
        vm.startPrank(alice);
        uint256 id = pool.open(1000e18); // slot 0: 990
        skip(1 days);
        pool.deposit(id, 100e18); // slot 1: 99
        skip(P.HEAT_AGE_CAP + 1 days); // both capped
        pool.poke(id); // lotAt reads at the last checkpoint
        (, uint256 age0,,) = pool.lotAt(id, 0);
        (, uint256 age1,,) = pool.lotAt(id, 1);
        assertEq(age0, age1, "a tie");
        pool.requestTap(id, 50e18);
        assertEq(pool.lotOf(id, 0).amount, 940e18, "the lower slot drawn");
        assertEq(pool.lotOf(id, 1).amount, 99e18, "the higher slot untouched");
        vm.stopPrank();
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

/// @dev Answers 2 for every wallet: not a boolean, so no founder (ADR 0018).
contract TwoFounders {
    function isFounder(address) external pure returns (uint256) {
        return 2;
    }
}

contract Reverter {
    fallback() external payable {
        revert("no");
    }
}
