// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {ForgeView} from "../src/forge/ForgeView.sol";
import {ForgeLens} from "../src/forge/ForgeLens.sol";
import {Lot, Record, Seal} from "../src/forge/ForgeMeasures.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {ForgeHandler} from "./ForgePoolInvariant.t.sol";

using ForgeView for ForgePool;

/// @dev The pool's own storage, returned by Solidity's accessors, and the views ForgePool
///      used to define itself (before ADR 0010): the reference ForgeView must reproduce.
contract ForgePoolViewHarness is ForgePool {
    constructor(IERC20 token, address collector, address boost, address deeds)
        ForgePool(token, true, collector, boost, deeds)
    {}

    function rawPosition(uint256 id) external view returns (Position memory) {
        return _positions[id];
    }

    function rawOwnership(uint256 id, uint256 n) external view returns (Ownership memory) {
        return _owners[id][n];
    }

    /// Kindling's phantom terms are not built (ADR 0011); this exercises their decoding and
    /// their clearing at settlement.
    function setPhantomForTest(uint256 id, bool founder, uint32 headStart) external {
        (_positions[id].founder, _positions[id].headStart) = (founder, headStart);
    }

    function rawLot(uint256 id, uint256 j) external view returns (Lot memory) {
        return _lots[id][j];
    }

    function rawRecord(uint256 id, uint256 j, uint256 i) external view returns (Record memory) {
        return _history[id][j][i];
    }

    function rawPending(uint256 id) external view returns (uint32[] memory ids) {
        ids = new uint32[](_positions[id].pendingCount);
        for (uint256 k; k < ids.length; ++k) ids[k] = _pending[id][k];
    }

    function rawTicket(uint256 id, uint32 t) external view returns (Ticket memory) {
        return _tickets[id][t];
    }

    function rawSlice(uint256 id, uint32 t, uint256 j) external view returns (Slice memory) {
        return _slices[id][t][j];
    }

    function rawSeal(uint256 id, uint256 k) external view returns (Seal memory) {
        return _seals[id][k];
    }

    function rawOccupancy() external view returns (Occupancy[] memory) {
        return _occupancy;
    }

    function rawLapses() external view returns (uint256) {
        return _lapses.nodes.length;
    }

    function rawCustody(uint256 id) external view returns (uint256) {
        Position storage p = _positions[id];
        return _activeOf(id, p) + _frozenOf(id, p);
    }

    function rawLotAt(uint256 id, uint256 j) external view returns (uint256, uint256, uint256, uint256) {
        Position storage p = _positions[id];
        if (p.closedAt != 0) return (0, 0, 0, 0);
        Lot memory lot = _lots[id][j];
        (uint256 age, uint256 part) = _lotAt(lot, p.lastCheckpoint);
        return (lot.amount, age, part, lot.heldBy);
    }

    function rawDue(uint256 id) external view returns (uint256 n) {
        Position storage p = _positions[id];
        for (uint256 k; k < p.pendingCount; ++k) {
            if (_deadline(_tickets[id][_pending[id][k]]) <= block.timestamp) ++n;
        }
    }
}

/// @notice ForgeView against the pool's own storage after random custody, cooling, Seal,
///         bonus and emergency actions: every position, lot, record, ticket, slice, Seal,
///         occupancy entry and derived view must decode exactly.
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 60
contract ForgeViewTest is Test {
    ForgeHandler handler;
    ForgePoolViewHarness pool;

    function setUp() public {
        vm.warp(1_700_000_000);
        MockERC20 token = new MockERC20("Receipt", "RCPT");
        pool = new ForgePoolViewHarness(IERC20(address(token)), makeAddr("feeRouter"), makeAddr("boost"), makeAddr("deeds"));
        handler = new ForgeHandler(pool, token, makeAddr("feeRouter"));
        targetContract(address(handler));
    }

    function invariant_viewsDecodeTheStorage() public view {
        ForgePool p = ForgePool(address(pool));
        for (uint256 i; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            assertEq(abi.encode(p.positionOf(id)), abi.encode(pool.rawPosition(id)), "position");
            assertEq(p.historyMaskOf(id), pool.rawPosition(id).historyMask, "history mask");
            assertEq(p.listingOf(id), pool.rawPosition(id).listing, "listing");
            _ownership(p, id);
            assertEq(p.custodyOf(id), pool.rawCustody(id), "custody");
            assertEq(p.dueLapses(id), pool.rawDue(id), "due lapses");
            assertEq(abi.encode(p.pendingTickets(id)), abi.encode(pool.rawPending(id)), "pending");
            _lots(p, id);
            _tickets(p, id);
            for (uint256 k; k <= pool.rawPosition(id).sealCount; ++k) {
                assertEq(abi.encode(p.sealOf(id, k)), abi.encode(pool.rawSeal(id, k)), "seal");
            }
        }
        ForgePool.Occupancy[] memory occ = pool.rawOccupancy();
        assertEq(p.occupancyLength(), occ.length, "occupancy length");
        for (uint256 i; i < occ.length; ++i) assertEq(abi.encode(p.occupancyAt(i)), abi.encode(occ[i]), "occupancy");
        assertEq(p.lapseQueueLength(), pool.rawLapses(), "lapses");
    }

    /// A lapse is due at its deadline itself, as the pool's sync resolves it (`<=`).
    function test_lapseDueAtItsDeadline() public {
        handler.request(0, 1_000); // ≤10%: 6h, lapses at +30h
        ForgePool p = ForgePool(address(pool));
        uint256 id = handler.ids(0);
        uint32 t = p.pendingTickets(id)[0];
        uint256 deadline = uint256(p.ticketOf(id, t).maturity) + P.WITHDRAW_EXECUTION_WINDOW;
        vm.warp(deadline - 1);
        assertEq(p.dueLapses(id), 0);
        vm.warp(deadline);
        assertEq(p.dueLapses(id), 1);
        assertEq(p.dueLapses(id), pool.rawDue(id));
    }

    /// Every Deed field decodes at a non-zero value: a listed position with phantom terms, then
    /// a sale (which clears them) and a second listing.
    function test_deedFieldsDecode() public {
        ForgePool p = ForgePool(address(pool));
        uint256 id = handler.ids(0);
        pool.setPhantomForTest(id, true, 0xabcdef12);
        handler.list(0, 1);
        ForgePool.Position memory raw = pool.rawPosition(id);
        assertTrue(raw.founder && raw.headStart == 0xabcdef12 && raw.listing == 1, "set up");
        assertEq(abi.encode(p.positionOf(id)), abi.encode(raw), "listed, phantom terms");
        vm.warp(block.timestamp + 3 days);
        handler.settle(0, 1);
        handler.list(0, 1);
        raw = pool.rawPosition(id);
        assertTrue(!raw.founder && raw.headStart == 0 && raw.transfers == 1 && raw.listing == 3, "sold, relisted");
        assertEq(abi.encode(p.positionOf(id)), abi.encode(raw), "sold");
        assertEq(abi.encode(p.ownershipAt(id, 0)), abi.encode(pool.rawOwnership(id, 0)), "log");
        assertEq(p.ownedSince(id), block.timestamp, "tenure");
        assertEq(p.listingOf(id), 3, "listing");
    }

    /// The lens is the same library behind external calls.
    function test_lensMatchesTheLibrary() public {
        ForgeLens lens = new ForgeLens();
        handler.request(0, 3_000);
        ForgePool p = ForgePool(address(pool));
        uint256 id = handler.ids(0);
        assertEq(abi.encode(lens.positionOf(p, id)), abi.encode(p.positionOf(id)));
        assertEq(abi.encode(lens.lotOf(p, id, 0)), abi.encode(p.lotOf(id, 0)));
        assertEq(lens.custodyOf(p, id), p.custodyOf(id));
        assertEq(abi.encode(lens.pendingTickets(p, id)), abi.encode(p.pendingTickets(id)));
        assertEq(abi.encode(lens.ticketOf(p, id, 1)), abi.encode(p.ticketOf(id, 1)));
        assertEq(lens.occupancyLength(p), p.occupancyLength());
        assertEq(lens.lapseQueueLength(p), p.lapseQueueLength());
        vm.warp(block.timestamp + 2 days); // the 10% ticket lapses; listing syncs it first
        handler.list(0, 1);
        handler.settle(0, 2);
        assertEq(lens.listingOf(p, id), p.listingOf(id));
        assertEq(abi.encode(lens.ownershipAt(p, id, 0)), abi.encode(p.ownershipAt(id, 0)));
        assertEq(lens.ownedSince(p, id), p.ownedSince(id));
        assertEq(p.positionOf(id).transfers, 1, "the sale happened");
    }

    function _lots(ForgePool p, uint256 id) internal view {
        uint256 used;
        for (uint256 j; j < 32; ++j) {
            Lot memory raw = pool.rawLot(id, j);
            assertEq(abi.encode(p.lotOf(id, j)), abi.encode(raw), "lot");
            uint256[4] memory got;
            uint256[4] memory want;
            (got[0], got[1], got[2], got[3]) = p.lotAt(id, j);
            (want[0], want[1], want[2], want[3]) = pool.rawLotAt(id, j);
            assertEq(abi.encode(got), abi.encode(want), "lotAt");
            assertEq(p.historyLength(id, j), raw.records, "records");
            for (uint256 k; k < raw.records; ++k) {
                assertEq(abi.encode(p.historyAt(id, j, k)), abi.encode(pool.rawRecord(id, j, k)), "record");
            }
            if (pool.rawPosition(id).usedMask & (1 << j) != 0) ++used;
        }
        assertEq(p.lotCount(id), used, "lot count");
    }

    function _ownership(ForgePool p, uint256 id) internal view {
        ForgePool.Position memory raw = pool.rawPosition(id);
        uint256 since = raw.openedAt;
        for (uint256 k; k < raw.transfers; ++k) {
            assertEq(abi.encode(p.ownershipAt(id, k)), abi.encode(pool.rawOwnership(id, k)), "ownership");
            since = pool.rawOwnership(id, k).until;
        }
        assertEq(p.ownedSince(id), since, "owned since");
        (address owner, uint256 closedAt, uint256 bonus, uint256 listing, uint256 transfers) = p.briefOf(id);
        assertEq(abi.encode(owner, closedAt, bonus, listing, transfers),
            abi.encode(raw.owner, raw.closedAt, raw.ordinaryBonus, raw.listing, raw.transfers), "brief");
    }

    function _tickets(ForgePool p, uint256 id) internal view {
        uint32 n = pool.rawPosition(id).nextTicketId;
        for (uint32 t = 1; t <= n; ++t) {
            assertEq(abi.encode(p.ticketOf(id, t)), abi.encode(pool.rawTicket(id, t)), "ticket");
            for (uint256 j; j < 32; ++j) {
                assertEq(abi.encode(p.sliceOf(id, t, j)), abi.encode(pool.rawSlice(id, t, j)), "slice");
            }
        }
    }
}
