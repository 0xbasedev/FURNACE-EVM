// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {ForgePoolBase} from "../src/forge/ForgePoolBase.sol";
import {ForgeView} from "../src/forge/ForgeView.sol";
import {Lot, Record, Seal, SealStatus, ForgeMeasures} from "../src/forge/ForgeMeasures.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {MockFounders} from "./utils/MockFounders.sol";

using ForgeView for ForgePool;

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
    /// Ghost log of each position's ordinary-bonus changes (BOOST or a diluting top-up).
    mapping(uint256 id => uint256[]) internal bonusTimes;
    mapping(uint256 id => uint256[]) internal bonusUnits;
    mapping(uint256 id => uint256) internal lastBonus;
    /// Deeds (ADR 0011): the listing the market holds, and a ghost of each ownership log.
    address public deeds;
    mapping(uint256 id => uint32) public market;
    mapping(uint256 id => address[]) internal sellers;
    mapping(uint256 id => uint256[]) internal soldAt;
    uint256 public sales;
    /// Taps (ADR 0014): a ghost flag set if a Tap ever haircut a survivor, reset the Streak, or
    /// drew a lot whole while leaving a younger one untouched.
    bool public tapBroken;
    uint256 public taps;
    uint256 public tapExecutions;
    /// Source-lot additions (ADR 0017): a ghost flag set if an addition ever moved a lot's age or
    /// participation, used a slot, booked a fee, touched the Streak or added a different amount.
    address public compounder;
    bool public addBroken;
    uint256 public adds;
    /// First Flame and Kindling (ADR 0018): the founder record, Kindling, and a ghost log of each
    /// position's founder flag changes.
    MockFounders public founders;
    address public kindling;
    mapping(uint256 id => uint256[]) internal founderTimes;
    mapping(uint256 id => bool[]) internal founderFlags;
    mapping(uint256 id => bool) internal lastFounder;
    uint256 public refreshes;
    uint256 public kindled;

    constructor(ForgePool pool_, MockERC20 token_, address collector_) {
        (pool, token, collector) = (pool_, token_, collector_);
        deeds = pool_.DEEDS();
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
        founders = MockFounders(pool_.FOUNDERS());
        kindling = pool_.KINDLING();
        if (kindling != address(0)) {
            token.mint(kindling, 1e30);
            minted += 1e30;
            vm.prank(kindling);
            token.approve(address(pool), type(uint256).max);
        }
        compounder = pool_.COMPOUNDER();
        if (compounder != address(0)) {
            token.mint(compounder, 1e30);
            minted += 1e30;
            vm.prank(compounder);
            token.approve(address(pool), type(uint256).max);
        }
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
        bool tap = pool.ticketOf(id, t).tap;
        if (tap) pool.poke(id); // so the ages compared below are the execution's own
        uint256[32] memory before;
        for (uint256 j; j < 32; ++j) (, before[j],,) = pool.lotAt(id, j);
        uint256 streak = pool.positionOf(id).streakStart;
        vm.prank(pool.positionOf(id).owner);
        try pool.executeWithdrawal(id, t) {
            if (tap) {
                ++tapExecutions;
                if (pool.positionOf(id).streakStart != streak) tapBroken = true;
                for (uint256 j; j < 32; ++j) {
                    (uint256 amount, uint256 age,,) = pool.lotAt(id, j);
                    if (amount != 0 && age != before[j]) tapBroken = true;
                }
            }
        } catch {}
        _after();
    }

    function tap(uint256 seed, uint256 bps) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        pool.poke(id);
        uint256 active;
        uint256[32] memory age;
        for (uint256 j; j < 32; ++j) {
            uint256 a;
            (a, age[j],,) = pool.lotAt(id, j);
            active += a;
        }
        vm.prank(pool.positionOf(id).owner);
        try pool.requestTap(id, (active * bound(bps, 1, 1_200)) / 10_000) returns (uint32 t) {
            ++taps;
            // Every lot drawn whole is no older than any lot left untouched.
            uint32 mask = pool.ticketOf(id, t).sliceMask;
            uint256 oldestWhole;
            uint256 youngestUntouched = type(uint256).max;
            for (uint256 j; j < 32; ++j) {
                (uint256 amount,,, uint256 heldBy) = pool.lotAt(id, j);
                if (mask & (1 << j) != 0 && heldBy == t && age[j] > oldestWhole) oldestWhole = age[j];
                if (mask & (1 << j) == 0 && amount != 0 && age[j] < youngestUntouched) youngestUntouched = age[j];
            }
            if (oldestWhole > youngestUntouched) tapBroken = true;
        } catch {}
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

    function boost(uint256 seed, uint256 units) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        vm.prank(pool.BOOST());
        try pool.setOrdinaryBonus(id, bound(units, 0, P.MAX_ORDINARY_BONUS_UNITS + 1)) {} catch {}
        _after();
    }

    function list(uint256 seed, uint256 coin) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        address seller = coin % 8 == 0 ? users[coin % 3] : pool.positionOf(id).owner; // sometimes wrong
        vm.prank(deeds);
        try pool.list(id, seller) returns (uint32 listing) {
            market[id] = listing;
        } catch {}
        _after();
    }

    function unlist(uint256 seed, uint256 coin) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        vm.prank(coin % 2 == 0 ? deeds : pool.positionOf(id).owner);
        try pool.unlist(id) {} catch {}
        _after();
    }

    function settle(uint256 seed, uint256 buyer) external {
        if (ids.length == 0) return;
        uint256 id = ids[seed % ids.length];
        address seller = pool.positionOf(id).owner;
        vm.prank(deeds);
        try pool.settle(id, users[buyer % 3], market[id]) {
            sellers[id].push(seller);
            soldAt[id].push(block.timestamp);
            ++sales;
        } catch {}
        _after();
    }

    /// Wallet-bound phantom terms, through a test harness's setter when the pool has one.
    function mark(uint256 seed, uint256 units) external {
        if (ids.length == 0) return;
        (bool ok,) = address(pool).call(
            abi.encodeWithSignature(
                "setPhantomForTest(uint256,bool,bool,uint32)", ids[seed % ids.length], units % 2 == 0, units % 3 == 0, uint32(units)
            )
        );
        ok;
        _after();
    }

    function soldCount(uint256 id) external view returns (uint256) {
        return sellers[id].length;
    }

    function soldBy(uint256 id, uint256 n) external view returns (address, uint256) {
        return (sellers[id][n], soldAt[id][n]);
    }

    /// The bonus in effect at `t`: the last change at or before it.
    function bonusAt(uint256 id, uint256 t) external view returns (uint256 units) {
        uint256[] storage times = bonusTimes[id];
        for (uint256 k; k < times.length && times[k] <= t; ++k) units = bonusUnits[id][k];
    }

    /// Whether the bonus changed strictly inside (a, b).
    function bonusChangedWithin(uint256 id, uint256 a, uint256 b) external view returns (bool) {
        uint256[] storage times = bonusTimes[id];
        for (uint256 k; k < times.length; ++k) {
            if (times[k] > a && times[k] < b) return true;
        }
        return false;
    }

    /// The founder record changes its answer for the owner, then anyone refreshes the position.
    function refreshFounder(uint256 seed, uint256 coin) external {
        if (ids.length == 0 || address(founders) == address(0)) return;
        uint256 id = ids[seed % ids.length];
        founders.set(pool.positionOf(id).owner, coin % 3 != 0);
        try pool.refreshFounder(id) {
            ++refreshes;
        } catch {}
        _after();
    }

    /// Kindling opens a contributor's position at the standard fee.
    function openKindling(uint256 who, uint256 amount) external {
        if (ids.length >= 6 || kindling == address(0)) return;
        vm.prank(kindling);
        try pool.openKindling(users[who % 3], bound(amount, 1e15, 1e24)) returns (uint256 id) {
            ids.push(id);
            ++kindled;
        } catch {}
        _after();
    }

    function founderAt(uint256 id, uint256 t) external view returns (bool flag) {
        uint256[] storage times = founderTimes[id];
        for (uint256 k; k < times.length && times[k] <= t; ++k) flag = founderFlags[id][k];
    }

    /// Whether the founder flag changed strictly inside (a, b).
    function founderChangedWithin(uint256 id, uint256 a, uint256 b) external view returns (bool) {
        uint256[] storage times = founderTimes[id];
        for (uint256 k; k < times.length; ++k) {
            if (times[k] > a && times[k] < b) return true;
        }
        return false;
    }

    /// The compounder returns earned LP to a lot: usually a used slot, sometimes any slot.
    function addToLot(uint256 seed, uint256 slot, uint256 amount) external {
        if (ids.length == 0 || compounder == address(0)) return;
        uint256 id = ids[seed % ids.length];
        uint32 used = pool.positionOf(id).usedMask;
        if (slot % 4 != 0 && used != 0) {
            uint256 j = slot % 32; // usually a used slot: the next one from here
            while (used & (1 << j) == 0) j = (j + 1) % 32;
            slot = j;
        } else {
            slot = slot % 40;
        }
        amount = bound(amount, 0, 1e24);
        pool.poke(id); // the lot's state at now, for the comparison below
        (uint256 a0, uint256 age0, uint256 part0,) = pool.lotAt(id, slot % 32);
        (uint256 lots0, uint256 streak0, uint256 fees0) =
            (pool.lotCount(id), pool.positionOf(id).streakStart, pool.feesOwed(0));
        vm.prank(compounder);
        try pool.addToLot(id, slot, amount) {
            ++adds;
            (uint256 a1, uint256 age1, uint256 part1,) = pool.lotAt(id, slot);
            if (
                a1 != a0 + amount || age1 != age0 || part1 != part0 || pool.lotCount(id) != lots0
                    || pool.positionOf(id).streakStart != streak0 || pool.feesOwed(0) != fees0 || a0 == 0
            ) addBroken = true;
        } catch {}
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
            bool founder = pool.positionOf(ids[i]).founder; // every change happens at now
            if (founder != lastFounder[ids[i]]) {
                founderTimes[ids[i]].push(block.timestamp);
                founderFlags[ids[i]].push(founder);
                lastFounder[ids[i]] = founder;
            }
            uint256 bonus = pool.positionOf(ids[i]).ordinaryBonus; // every change happens at now
            if (bonus != lastBonus[ids[i]]) {
                bonusTimes[ids[i]].push(block.timestamp);
                bonusUnits[ids[i]].push(bonus);
                lastBonus[ids[i]] = bonus;
            }
        }
        uint256 occ = pool.occupiedSecondsAt(block.timestamp);
        if (occ < lastOccupied) monotoneBroken = true;
        lastOccupied = occ;
    }

    function userBalances() external view returns (uint256 total) {
        for (uint256 i; i < 3; ++i) total += token.balanceOf(users[i]);
        if (compounder != address(0)) total += token.balanceOf(compounder);
        if (kindling != address(0)) total += token.balanceOf(kindling);
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
    address boost = makeAddr("boost");

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new MockERC20("Receipt", "RCPT");
        pool = new ForgePool(
            IERC20(address(token)),
            true,
            collector,
            boost,
            makeAddr("deeds"),
            address(0),
            makeAddr("compounder"),
            makeAddr("kindling"),
            address(new MockFounders())
        );
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
                ForgePoolBase.Ticket memory t = pool.ticketOf(id, pend[k]);
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
            ForgePoolBase.Position memory p = pool.positionOf(id);
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
            ForgePoolBase.Position memory p = pool.positionOf(id);
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
            ForgePoolBase.Position memory p = pool.positionOf(id);
            for (uint256 j; j < 32; ++j) {
                Lot memory head = pool.lotOf(id, j);
                if (head.amount != 0 && p.closedAt == 0) assertLe(p.streakStart, head.since, "active head after its anchor");
                for (uint256 k; k < head.records; ++k) {
                    Record memory r = pool.historyAt(id, j, k);
                    if (r.amount == 0) continue;
                    uint256 streak = r.streak & (ForgeMeasures.FOUNDER_FLAG - 1); // First Flame rides bit 39
                    assertLe(streak, r.since, "anchor at or before the segment");
                    (uint256 nextSince, uint256 nextStreak) = k + 1 < head.records
                        ? (pool.historyAt(id, j, k + 1).since, pool.historyAt(id, j, k + 1).streak & (ForgeMeasures.FOUNDER_FLAG - 1))
                        : (head.since, p.streakStart);
                    if (nextStreak != streak && p.closedAt == 0) {
                        assertGe(nextStreak, nextSince, "no Streak reset inside an active segment");
                    }
                }
            }
        }
    }

    /// Each active record segment has one ordinary bonus (ADR 0008): the one in effect when it
    /// began, with no change strictly inside it. An open active head began at or after the
    /// last change, so the current bonus is its own.
    /// First Flame (ADR 0018): each record carries the founder flag of its start, and the flag never
    /// changes inside a record segment or under an active head.
    function invariant_founderAnchorsAlignWithRecords() public view {
        for (uint256 i; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ForgePoolBase.Position memory p = pool.positionOf(id);
            for (uint256 j; j < 32; ++j) {
                Lot memory head = pool.lotOf(id, j);
                if (head.amount != 0 && p.closedAt == 0) {
                    assertFalse(handler.founderChangedWithin(id, head.since, type(uint256).max), "founder changed under a head");
                }
                for (uint256 k; k < head.records; ++k) {
                    Record memory r = pool.historyAt(id, j, k);
                    if (r.amount == 0) continue;
                    uint256 end = k + 1 < head.records ? pool.historyAt(id, j, k + 1).since : head.since;
                    assertEq((r.streak & ForgeMeasures.FOUNDER_FLAG) != 0, handler.founderAt(id, r.since), "record carries the flag of its start");
                    assertFalse(handler.founderChangedWithin(id, r.since, end), "no founder change inside a segment");
                }
            }
        }
    }

    function invariant_bonusAnchorsAlignWithRecords() public view {
        for (uint256 i; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ForgePoolBase.Position memory p = pool.positionOf(id);
            for (uint256 j; j < 32; ++j) {
                Lot memory head = pool.lotOf(id, j);
                if (head.amount != 0 && p.closedAt == 0) {
                    assertFalse(handler.bonusChangedWithin(id, head.since, type(uint256).max), "bonus changed under a head");
                }
                for (uint256 k; k < head.records; ++k) {
                    Record memory r = pool.historyAt(id, j, k);
                    if (r.amount == 0) continue;
                    uint256 end = k + 1 < head.records ? pool.historyAt(id, j, k + 1).since : head.since;
                    assertEq(r.ordinaryBonus, handler.bonusAt(id, r.since), "record carries the bonus of its start");
                    assertFalse(handler.bonusChangedWithin(id, r.since, end), "no bonus change inside a segment");
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

    /// A source-lot addition keeps its lot's age and participation, uses no slot, books no fee and
    /// leaves the Streak alone (ADR 0017).
    function invariant_additionsKeepTheSourceLot() public view {
        assertFalse(handler.addBroken());
    }

    /// A Tap never haircuts a survivor or resets the Streak, and draws the youngest lots first.
    function invariant_tapsKeepAgeAndStreak() public view {
        assertFalse(handler.tapBroken());
    }

    /// A listing exists only on an open position with no cooling pending (ADR 0011).
    function invariant_listedPositionsAreQuiet() public view {
        for (uint256 i; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ForgePoolBase.Position memory p = pool.positionOf(id);
            if (p.listing & 1 == 0) continue;
            assertEq(p.closedAt, 0, "a listed position is open");
            assertEq(p.pendingCount, 0, "a listed position has no cooling pending");
        }
    }

    /// The ownership log holds exactly each completed sale's seller and instant, and the
    /// current tenure starts at the last one.
    function invariant_ownershipLogMatchesSales() public view {
        for (uint256 i; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ForgePoolBase.Position memory p = pool.positionOf(id);
            uint256 n = handler.soldCount(id);
            assertEq(p.transfers, n, "one log entry per sale");
            uint256 since = p.openedAt;
            for (uint256 k; k < n; ++k) {
                (address seller, uint256 at) = handler.soldBy(id, k);
                ForgePoolBase.Ownership memory o = pool.ownershipAt(id, k);
                assertEq(o.owner, seller, "the seller");
                assertEq(o.until, at, "the sale instant");
                since = at;
            }
            assertEq(pool.ownedSince(id), since, "tenure start");
        }
    }

    /// Emergency exit works for every open position holding principal, in any state.
    function invariant_emergencyExitAlwaysAvailable() public {
        for (uint256 i; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            ForgePoolBase.Position memory p = pool.positionOf(id);
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
