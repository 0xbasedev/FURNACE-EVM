// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {HeatMath} from "../src/libraries/HeatMath.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {ForgeVectors} from "./utils/ForgeVectors.sol";
import {MockERC20, FeeOnTransferERC20} from "./utils/MockERC20.sol";

abstract contract ForgeFixture is ForgeVectors {
    MockERC20 token;
    ForgePool pool;
    address collector = makeAddr("feeRouter");

    uint256 constant FUND = 1e30;

    function _deploy(bool lp) internal {
        token = new MockERC20("Receipt", "RCPT");
        pool = new ForgePool(IERC20(address(token)), lp, collector);
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
        Collect
    }

    function setUp() public {
        _loadForgeVectors();
    }

    function test_scenario_basicCycle() public { _replay("basicCycle"); }
    function test_scenario_cumulativeTiers() public { _replay("cumulativeTiers"); }
    function test_scenario_overlapHaircut() public { _replay("overlapHaircut"); }
    function test_scenario_lapseLateTouch() public { _replay("lapseLateTouch"); }
    function test_scenario_lapseIdlePool() public { _replay("lapseIdlePool"); }
    function test_scenario_cappedMerge() public { _replay("cappedMerge"); }
    function test_scenario_emergencyWithPending() public { _replay("emergencyWithPending"); }
    function test_scenario_capacity16() public { _replay("capacity16"); }
    function test_scenario_capacity17() public { _replay("capacity17"); }
    function test_scenario_lotCap() public { _replay("lotCap"); }
    function test_scenario_random0() public { _replay("random0"); }
    function test_scenario_random1() public { _replay("random1"); }
    function test_scenario_random2() public { _replay("random2"); }
    function test_scenario_random3() public { _replay("random3"); }
    function test_scenario_random4() public { _replay("random4"); }
    function test_scenario_random5() public { _replay("random5"); }

    /// Every generated scenario has a test above; a new one fails this until added.
    function test_everyScenarioIsReplayed() public view {
        assertEq(vm.parseJsonStringArray(forgeJson, ".names").length, 16, "add a test_scenario_* for each new scenario");
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
        for (uint256 k = 1; k <= positions; ++k) _fund(_user(k));

        for (uint256 i; i < hashes.length; ++i) {
            (Kind kind, uint256 time, uint256 pos, uint256 arg, bool reverts) =
                (Kind(a[5 * i]), a[5 * i + 1], a[5 * i + 2], a[5 * i + 3], a[5 * i + 4] == 1);
            vm.warp(time);
            string memory where = string.concat(name, " step ", vm.toString(i));
            if (reverts) vm.expectRevert();
            _act(kind, pos, arg);

            ForgePool.Position memory p1 = pool.positionOf(1);
            assertEq(p1.stakeSeconds, probe[5 * i], string.concat(where, ": S(1)"));
            assertEq(p1.heatSeconds, probe[5 * i + 1], string.concat(where, ": W(1)"));
            assertEq(pool.activePrincipal(), probe[5 * i + 2], string.concat(where, ": active"));
            assertEq(pool.frozenPrincipal(), probe[5 * i + 3], string.concat(where, ": frozen"));
            assertEq(pool.occupiedSecondsAt(time), probe[5 * i + 4], string.concat(where, ": occupied"));
            assertEq(this.snapshot(positions), hashes[i], string.concat(where, ": state hash"));
        }
    }

    function _act(Kind kind, uint256 pos, uint256 arg) internal {
        if (kind == Kind.Collect) {
            vm.prank(collector);
            pool.collectFees();
            return;
        }
        vm.prank(_user(pos));
        if (kind == Kind.Open) assertEq(pool.open(arg), pos, "position id");
        else if (kind == Kind.Deposit) pool.deposit(pos, arg);
        else if (kind == Kind.Request) pool.requestCooling(pos, arg);
        else if (kind == Kind.Execute) pool.executeWithdrawal(pos, uint32(arg));
        else if (kind == Kind.Cancel) pool.cancelCooling(pos, uint32(arg));
        else if (kind == Kind.Emergency) pool.emergencyExit(pos);
        else pool.poke(pos);
    }

    /// @dev Word layout mirrored by scripts/forge-scenarios.ts::words. External so each
    ///      call gets fresh memory (a long replay would otherwise exhaust it).
    function snapshot(uint256 positions) external view returns (bytes32) {
        uint256[] memory w = new uint256[](3_000);
        uint256 n;
        for (uint256 id = 1; id <= positions; ++id) {
            n = _pushHead(w, n, id);
            for (uint256 j; j < 32; ++j) {
                ForgePool.Lot memory l = pool.lotOf(id, j);
                n = _put4(w, n, l.amount, l.age, l.participated, l.heldBy);
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
        for (uint256 id = 1; id <= positions; ++id) w[n++] = token.balanceOf(_user(id));
        assembly ("memory-safe") {
            mstore(w, n)
        }
        return keccak256(abi.encodePacked(w));
    }

    function _pushHead(uint256[] memory w, uint256 n, uint256 id) internal view returns (uint256) {
        ForgePool.Position memory p = pool.positionOf(id);
        n = _put4(w, n, p.stakeSeconds, p.heatSeconds, pool.lotCount(id), p.reservedSlots);
        n = _put4(w, n, p.pendingCount, p.coolingPausedSeconds, p.streakStart, p.lastCheckpoint);
        n = _put4(w, n, p.closed ? 1 : 0, p.ashfallForfeited ? 1 : 0, p.plan.start, p.plan.referenceBalance);
        w[n++] = p.plan.requested;
        w[n++] = p.nextTicketId;
        return n;
    }

    function _pushTicket(uint256[] memory w, uint256 n, uint256 id, uint32 ticketId) internal view returns (uint256) {
        ForgePool.Ticket memory t = pool.ticketOf(id, ticketId);
        n = _put4(w, n, ticketId, t.amount, t.maturity, uint256(t.status));
        w[n++] = t.poolApplied ? 1 : 0;
        for (uint256 j; j < 32; ++j) {
            ForgePool.Slice memory s = pool.sliceOf(id, ticketId, j);
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
        vm.expectRevert(ForgePool.ZeroAddress.selector);
        new ForgePool(IERC20(address(0)), true, collector);
        vm.expectRevert(ForgePool.ZeroAddress.selector);
        new ForgePool(IERC20(address(token)), true, address(0));
    }

    function test_feeOnTransferTokenIsRejected() public {
        FeeOnTransferERC20 skim = new FeeOnTransferERC20();
        ForgePool skimPool = new ForgePool(IERC20(address(skim)), false, collector);
        skim.mint(alice, 1e18);
        vm.startPrank(alice);
        skim.approve(address(skimPool), type(uint256).max);
        vm.expectRevert(ForgePool.NonStandardToken.selector);
        skimPool.open(1e18);
        vm.stopPrank();
    }

    function test_onlyOwnerMovesPrincipal() public {
        vm.prank(alice);
        uint256 id = pool.open(100e18);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(ForgePool.NotOwner.selector, id));
        pool.requestCooling(id, 1e18);
        vm.expectRevert(abi.encodeWithSelector(ForgePool.NotOwner.selector, id));
        pool.emergencyExit(id);
        vm.expectRevert(abi.encodeWithSelector(ForgePool.NotOwner.selector, id));
        pool.deposit(id, 1e18);
        vm.stopPrank();
        pool.poke(id); // permissionless sync is fine
    }

    function test_measuresMatchHeatMathForOneLot() public {
        vm.prank(alice);
        uint256 id = pool.open(100e18);
        uint256 net = 99e18;
        skip(200 days);
        (uint256 s, uint256 w) = pool.poke(id);
        assertEq(s, net * 200 days);
        assertEq(w, net * HeatMath.integrateHeat(0, 200 days, 0));
        // Checkpoint subdivision telescopes: two more pokes equal one long interval.
        skip(100 days);
        pool.poke(id);
        skip(100 days);
        (, uint256 w2) = pool.poke(id);
        assertEq(w2, net * HeatMath.integrateHeat(0, 400 days, 0));
    }

    function test_frozenSliceDoesNotAgeOrEarn() public {
        vm.prank(alice);
        uint256 id = pool.open(100e18);
        skip(10 days);
        vm.prank(alice);
        pool.requestCooling(id, 99e18); // the whole lot
        (uint256 s0, uint256 w0) = pool.poke(id);
        skip(1 days);
        (uint256 s1, uint256 w1) = pool.poke(id);
        assertEq(s1, s0, "no stake-seconds while frozen");
        assertEq(w1, w0, "no heat-seconds while frozen");
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
        vm.expectRevert(abi.encodeWithSelector(ForgePool.PlanQuotaExceeded.selector, 99e18 + 1, 99e18));
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
        ForgePool hostile = new ForgePool(IERC20(address(token)), true, address(new Reverter()));
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

    function test_onlyCollectorCollects() public {
        vm.prank(alice);
        pool.open(100e18);
        vm.expectRevert(ForgePool.NotCollector.selector);
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
        assertEq(uint256(pool.ticketOf(id, t).status), uint256(ForgePool.Status.Lapsed));
        assertEq(pool.occupiedSecondsAt(block.timestamp), 1 days + (block.timestamp - lapse));
    }

    function test_futureOccupancyQueryReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ForgePool.FutureTime.selector, block.timestamp + 1));
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
        for (uint256 j; j < 32; ++j) active += pool.lotOf(b, j).amount;
        skip(P.COOLING_PLAN_HORIZON); // the old plan's quota is spent; let it reset
        pool.requestCooling(b, active); // 100% of what resumed: no splits needed
        g = gasleft();
        pool.emergencyExit(b);
        emit log_named_uint("emergencyExit, all lots frozen", g - gasleft());
        vm.stopPrank();
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
        g = gasleft();
        uint32 t = pool.requestCooling(id, pool.lotOf(id, 0).amount * 32); // 100%: no splits
        emit log_named_uint("requestCooling 100% (32 lots)", g - gasleft());
        skip(72 hours);
        g = gasleft();
        pool.executeWithdrawal(id, t);
        emit log_named_uint("executeWithdrawal (32 lots)", g - gasleft());
        vm.stopPrank();
    }
}

contract Reverter {
    fallback() external payable {
        revert("no");
    }
}
