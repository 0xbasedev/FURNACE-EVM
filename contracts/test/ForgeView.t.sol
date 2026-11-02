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
    constructor(IERC20 token, address collector, address boost) ForgePool(token, true, collector, boost) {}

    function rawPosition(uint256 id) external view returns (Position memory) {
        return _positions[id];
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
        pool = new ForgePoolViewHarness(IERC20(address(token)), makeAddr("feeRouter"), makeAddr("boost"));
        handler = new ForgeHandler(pool, token, makeAddr("feeRouter"));
        targetContract(address(handler));
    }

    function invariant_viewsDecodeTheStorage() public view {
        ForgePool p = ForgePool(address(pool));
        for (uint256 i; i < handler.idCount(); ++i) {
            uint256 id = handler.ids(i);
            assertEq(abi.encode(p.positionOf(id)), abi.encode(pool.rawPosition(id)), "position");
            assertEq(p.historyMaskOf(id), pool.rawPosition(id).historyMask, "history mask");
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
