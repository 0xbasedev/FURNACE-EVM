// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {Lot, Record, Seal, SealStatus} from "../src/forge/ForgeMeasures.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {MockERC20} from "./utils/MockERC20.sol";

contract ForgeHandler is Test {
    ForgePool public pool;
    MockERC20 public token;
    address public collector;
    address[3] internal users;
    uint256[] public ids;
    uint256 public minted;
    uint256 public firstOpen;
    uint256 public lastOccupied;
    bool public monotoneBroken;
    mapping(uint256 id => uint256) internal lastS;
    mapping(uint256 id => uint256) internal lastW;

    constructor(ForgePool pool_, MockERC20 token_, address collector_) {
        (pool, token, collector) = (pool_, token_, collector_);
        for (uint256 i; i < 3; ++i) {
            users[i] = address(uint160(0x2000 + i));
            token.mint(users[i], 1e30);
            minted += 1e30;
            vm.prank(users[i]);
            token.approve(address(pool), type(uint256).max);
            vm.prank(users[i]);
            ids.push(pool.open(1e18 * (i + 1)));
        }
        firstOpen = block.timestamp;
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function open(uint256 who, uint256 amount) external {
        if (ids.length >= 6) return;
        amount = bound(amount, 1e15, 1e24);
        vm.prank(users[who % 3]);
        try pool.open(amount) returns (uint256 id) {
            ids.push(id);
            if (firstOpen == 0) firstOpen = block.timestamp;
        } catch {}
        _after();
    }

    function deposit(uint256 seed, uint256 amount) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        vm.prank(pool.positionOf(id).owner);
        try pool.deposit(id, bound(amount, 1e15, 1e24)) {} catch {}
        _after();
    }

    function request(uint256 seed, uint256 bps) public {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        uint256 active;
        for (uint256 j; j < 32; ++j) {
            (uint256 a,,,) = pool.lotAt(id, j);
            active += a;
        }
        uint256 amount = (active * bound(bps, 1, 10_000)) / 10_000;
        vm.prank(pool.positionOf(id).owner);
        try pool.requestCooling(id, amount) {} catch {}
        _after();
    }

    function execute(uint256 seed, uint256 pick, uint256 late) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        uint32[] memory pend = pool.pendingTickets(id);
        if (pend.length == 0) return request(seed, late);
        uint32 t = pend[pick % pend.length];
        uint256 maturity = pool.ticketOf(id, t).maturity;
        if (maturity > block.timestamp) vm.warp(maturity + bound(late, 0, 2 hours));
        vm.prank(pool.positionOf(id).owner);
        try pool.executeWithdrawal(id, t) {} catch {}
        _after();
    }

    function cancel(uint256 seed, uint256 pick) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        uint32[] memory pend = pool.pendingTickets(id);
        if (pend.length == 0) return request(seed, pick);
        vm.prank(pool.positionOf(id).owner);
        try pool.cancelCooling(id, pend[pick % pend.length]) {} catch {}
        _after();
    }

    function emergency(uint256 seed, uint256 coin) external {
        if (ids.length == 0 || coin % 16 != 0) return; // rare: it closes positions
        uint256 id = ids[seed % ids.length];
        vm.prank(pool.positionOf(id).owner);
        try pool.emergencyExit(id) {} catch {}
        _after();
    }

    function seal(uint256 seed, uint256 track) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        vm.prank(pool.positionOf(id).owner);
        try pool.seal(id, track % 5) {} catch {} // track 4 is unknown
        _after();
    }

    function poke(uint256 seed) external {
        if (ids.length == 0) return;
        pool.poke(ids[seed % ids.length]);
        _after();
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 3 days));
        _after();
    }

    function collect() external {
        vm.prank(collector);
        pool.collectFees();
        _after();
    }

    function _after() internal {
        for (uint256 i; i < ids.length; ++i) {
            (uint256 s, uint256 w, uint256 ss, uint256 sw,) =
                pool.epochMeasure(ids[i], 0, pool.positionOf(ids[i]).lastCheckpoint);
            if (s < lastS[ids[i]] || w < lastW[ids[i]] || ss > s || sw > w) monotoneBroken = true;
            (lastS[ids[i]], lastW[ids[i]]) = (s, w);
        }
        uint256 occ = pool.occupiedSecondsAt(block.timestamp);
        if (occ < lastOccupied) monotoneBroken = true;
        lastOccupied = occ;
    }

    function userBalances() external view returns (uint256 total) {
        for (uint256 i; i < 3; ++i) total += token.balanceOf(users[i]);
    }
}

/// @notice Random action sequences against one pool. Every principal path must stay
///         conserved, bounded and exitable, whatever the order.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 200
contract ForgePoolInvariantTest is Test {
    ForgeHandler handler;
    ForgePool pool;
    MockERC20 token;
    address collector = makeAddr("feeRouter");

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new MockERC20("Receipt", "RCPT");
        pool = new ForgePool(IERC20(address(token)), true, collector);
        handler = new ForgeHandler(pool, token, collector);
        targetContract(address(handler));
    }

    /// Custody: the pool holds exactly principal plus uncollected fees.
    function invariant_principalAndFeesAreBacked() public view {
        uint256 fees = pool.feesOwed(0) + pool.feesOwed(1) + pool.feesOwed(2);
        assertEq(token.balanceOf(address(pool)), pool.activePrincipal() + pool.frozenPrincipal() + fees);
    }

    /// Nothing is created or destroyed: users + pool + fee router = minted.
    function invariant_tokensConserved() public view {
        assertEq(handler.userBalances() + token.balanceOf(address(pool)) + token.balanceOf(collector), handler.minted());
    }

    /// Pool totals equal the positions' lots plus pending slices.
    function invariant_custodyMatchesPositions() public view {
        uint256 sum;
        uint256 queued;
        for (uint256 i; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            for (uint256 j; j < 32; ++j) {
                (uint256 a,,,) = pool.lotAt(id, j);
                sum += a;
            }
            uint32[] memory pend = pool.pendingTickets(id);
            for (uint256 k; k < pend.length; ++k) {
                ForgePool.Ticket memory t = pool.ticketOf(id, pend[k]);
                sum += t.amount;
                if (!t.poolApplied) ++queued;
            }
        }
        assertEq(sum, pool.activePrincipal() + pool.frozenPrincipal());
        assertEq(pool.lapseQueueLength(), queued, "queue holds exactly the unprocessed pending tickets");
    }

    /// Slots: used ⇔ amount or holder; lots + reservations ≤ 32; ages ≤ caps.
    function invariant_slotsAndAgesBounded() public view {
        for (uint256 i; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ForgePool.Position memory p = pool.positionOf(id);
            assertLe(pool.lotCount(id) + p.reservedSlots, 32);
            assertLe(p.pendingCount, pool.MAX_PENDING_TICKETS());
            for (uint256 j; j < 32; ++j) {
                Lot memory l = pool.lotOf(id, j);
                bool used = p.usedMask & (1 << j) != 0;
                if (p.closedAt == 0) assertEq(used, l.amount != 0 || l.heldBy != 0, "usedMask");
                else assertFalse(used, "closed positions use no slots");
                assertLe(l.since, block.timestamp);
                assertLe(l.age, P.HEAT_AGE_CAP);
                assertLe(l.participated, P.ASHFALL_MIN_PARTICIPATION);
                assertTrue(l.since == 0 || p.historyMask & (1 << j) != 0, "historyMask covers every head");
            }
            uint32[] memory pend = pool.pendingTickets(id);
            for (uint256 k; k < pend.length; ++k) {
                for (uint256 j; j < 32; ++j) assertLe(pool.sliceOf(id, pend[k], j).age, P.HEAT_AGE_CAP);
            }
        }
    }

    /// Seals: a running Seal has no pending ticket and a paused one has one; tags name
    ///        only the latest Seal and only its cohort's slots; the cohort is real history.
    function invariant_sealStateConsistent() public view {
        for (uint256 i; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ForgePool.Position memory p = pool.positionOf(id);
            Seal memory s = pool.sealOf(id, p.sealCount);
            if (s.status == SealStatus.Active) {
                assertEq(s.pausedAt != 0, p.pendingCount != 0, "paused exactly while cooling is pending");
                assertEq(p.closedAt, 0, "a closed position has no running Seal");
            } else {
                assertEq(s.pausedAt, 0);
            }
            assertEq(s.cohortMask & ~p.historyMask, 0, "the cohort is made of real slots");
            for (uint256 j; j < 32; ++j) {
                uint256 tag = pool.lotOf(id, j).seal;
                if (tag == 0) continue;
                assertEq(tag, p.sealCount, "only the latest Seal tags heads");
                assertTrue(s.cohortMask & (1 << j) != 0, "only cohort slots are tagged");
            }
        }
    }

    /// Each active record segment has one Streak anchor (ADR 0007): the anchor is at or before
    /// the segment's start, and the next segment's anchor is either the same or a reset at the
    /// boundary. A reset strictly inside an active segment would give it the wrong anchor.
    function invariant_streakAnchorsAlignWithRecords() public view {
        for (uint256 i; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ForgePool.Position memory p = pool.positionOf(id);
            for (uint256 j; j < 32; ++j) {
                Lot memory head = pool.lotOf(id, j);
                if (head.amount != 0 && p.closedAt == 0) assertLe(p.streakStart, head.since, "active head after its anchor");
                for (uint256 k; k < head.records; ++k) {
                    Record memory r = pool.historyAt(id, j, k);
                    if (r.amount == 0) continue;
                    assertLe(r.streak, r.since, "anchor at or before the segment");
                    (uint256 nextSince, uint256 nextStreak) = k + 1 < head.records
                        ? (pool.historyAt(id, j, k + 1).since, pool.historyAt(id, j, k + 1).streak)
                        : (head.since, p.streakStart);
                    if (nextStreak != r.streak && p.closedAt == 0) {
                        assertGe(nextStreak, nextSince, "no Streak reset inside an active segment");
                    }
                }
            }
        }
    }

    function invariant_measuresAndOccupancyMonotone() public view {
        assertFalse(handler.monotoneBroken());
        if (handler.firstOpen() != 0) {
            assertLe(pool.occupiedSecondsAt(block.timestamp), block.timestamp - handler.firstOpen());
        }
    }

    /// Emergency exit works for every open position holding principal, in any state.
    function invariant_emergencyExitAlwaysAvailable() public {
        for (uint256 i; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ForgePool.Position memory p = pool.positionOf(id);
            if (p.closedAt != 0) continue;
            uint256 snap = vm.snapshotState();
            pool.poke(id);
            uint256 total;
            for (uint256 j; j < 32; ++j) {
                (uint256 a,,,) = pool.lotAt(id, j);
                total += a;
            }
            uint32[] memory pend = pool.pendingTickets(id);
            for (uint256 k; k < pend.length; ++k) total += pool.ticketOf(id, pend[k]).amount;
            if (total != 0) {
                uint256 before = token.balanceOf(p.owner);
                vm.prank(p.owner);
                uint256 net = pool.emergencyExit(id);
                assertEq(net, total - (total * P.EMERGENCY_EXIT_FEE_PCT) / 100);
                assertEq(token.balanceOf(p.owner) - before, net);
            }
            vm.revertToState(snap);
        }
    }
}
