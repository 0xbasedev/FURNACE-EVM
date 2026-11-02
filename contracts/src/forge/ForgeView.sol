// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";
import {ForgePool} from "./ForgePool.sol";
import {ForgePoolBase} from "./ForgePoolBase.sol";
import {Lot, Record, Seal, SealStatus} from "./ForgeMeasures.sol";

/// @title ForgeView
/// @notice ForgePool's read API, decoded from its raw storage through `extsload` (ADR 0010).
///         The views moved out of the pool so its runtime code has room for the hooks an
///         immutable pool still needs. Use it with `using ForgeView for ForgePool;`, so
///         `pool.positionOf(id)` reads as before.
///
///         The slots below are ForgePool's storage layout (`forge inspect ForgePool
///         storage-layout`). A deployed pool never changes it; a source change that moves a
///         field must update this library, and ForgeViewTest compares every view with the
///         pool's own storage.
library ForgeView {
    uint256 internal constant OCCUPANCY_SLOT = 6;
    uint256 internal constant LAPSES_SLOT = 7; // LapseHeap.Heap: `nodes` (its length) first
    uint256 internal constant POSITIONS_SLOT = 9;
    uint256 internal constant LOTS_SLOT = 10;
    uint256 internal constant HISTORY_SLOT = 11;
    uint256 internal constant PENDING_SLOT = 12;
    uint256 internal constant TICKETS_SLOT = 13;
    uint256 internal constant SLICES_SLOT = 14;
    uint256 internal constant SEALS_SLOT = 15;
    uint256 internal constant OWNERS_SLOT = 16;

    // ── raw reads ─────────────────────────────────────────────────────────

    function _map(uint256 key, uint256 slot) private pure returns (uint256) {
        return uint256(keccak256(abi.encode(key, slot)));
    }

    function _read(ForgePool pool, uint256 slot) private view returns (uint256) {
        bytes32[] memory s = new bytes32[](1);
        s[0] = bytes32(slot);
        return uint256(pool.extsload(s)[0]);
    }

    function _readN(ForgePool pool, uint256 slot, uint256 n) private view returns (bytes32[] memory) {
        bytes32[] memory s = new bytes32[](n);
        for (uint256 i; i < n; ++i) s[i] = bytes32(slot + i);
        return pool.extsload(s);
    }

    function _bits(uint256 word, uint256 offsetBytes, uint256 sizeBytes) private pure returns (uint256) {
        return (word >> (8 * offsetBytes)) & ((1 << (8 * sizeBytes)) - 1);
    }

    // ── positions ─────────────────────────────────────────────────────────

    function positionOf(ForgePool pool, uint256 id) internal view returns (ForgePoolBase.Position memory p) {
        bytes32[] memory w = _readN(pool, _map(id, POSITIONS_SLOT), 5);
        (uint256 w0, uint256 w1, uint256 w2, uint256 w3, uint256 w4) =
            (uint256(w[0]), uint256(w[1]), uint256(w[2]), uint256(w[3]), uint256(w[4]));
        p.owner = address(uint160(w0));
        p.lastCheckpoint = uint40(_bits(w0, 20, 5));
        p.streakStart = uint40(_bits(w0, 25, 5));
        p.ordinaryBonus = uint16(_bits(w0, 30, 2));
        p.reservedSlots = uint8(_bits(w1, 0, 1));
        p.pendingCount = uint8(_bits(w1, 1, 1));
        p.usedMask = uint32(_bits(w1, 2, 4));
        p.historyMask = uint32(_bits(w1, 6, 4));
        p.nextTicketId = uint32(_bits(w1, 10, 4));
        p.coolingPausedSeconds = uint64(_bits(w1, 14, 8));
        p.ashfallForfeited = _bits(w1, 22, 1) != 0;
        p.openedAt = uint40(_bits(w1, 23, 5));
        p.listing = uint32(_bits(w1, 28, 4));
        p.closedAt = uint40(_bits(w2, 0, 5));
        p.sealCount = uint8(_bits(w2, 5, 1));
        p.transfers = uint32(_bits(w2, 6, 4));
        p.founder = _bits(w2, 10, 1) != 0;
        p.headStartActive = _bits(w2, 11, 1) != 0;
        p.headStart = uint32(_bits(w2, 12, 4));
        p.plan = ForgePoolBase.Plan(uint40(_bits(w3, 0, 5)), uint128(_bits(w3, 5, 16)), uint128(_bits(w4, 0, 16)));
    }

    /// @notice What Boost checks on every action, from the first three position words: the
    ///         owner, closure, ordinary bonus, listing (odd while listed) and completed sales.
    function briefOf(ForgePool pool, uint256 id)
        internal
        view
        returns (address owner, uint256 closedAt, uint256 ordinaryBonus, uint256 listing, uint256 transfers)
    {
        bytes32[] memory w = _readN(pool, _map(id, POSITIONS_SLOT), 3);
        (owner, ordinaryBonus) = (address(uint160(uint256(w[0]))), _bits(uint256(w[0]), 30, 2));
        listing = _bits(uint256(w[1]), 28, 4);
        (closedAt, transfers) = (_bits(uint256(w[2]), 0, 5), _bits(uint256(w[2]), 6, 4));
    }

    /// @notice The position's listing nonce: odd while listed on DEEDS.
    function listingOf(ForgePool pool, uint256 id) internal view returns (uint32) {
        return uint32(_bits(_read(pool, _map(id, POSITIONS_SLOT) + 1), 28, 4));
    }

    /// @notice The `n`th previous owner and the end of its tenure (n < transfers).
    function ownershipAt(ForgePool pool, uint256 id, uint256 n) internal view returns (ForgePoolBase.Ownership memory o) {
        uint256 w = _read(pool, _map(n, _map(id, OWNERS_SLOT)));
        (o.owner, o.until) = (address(uint160(w)), uint40(_bits(w, 20, 5)));
    }

    /// @notice When the current owner's tenure began: the last sale, or the opening. Evidence
    ///         for Keystone's continuous-ownership test, together with `ownershipAt`.
    function ownedSince(ForgePool pool, uint256 id) internal view returns (uint256) {
        bytes32[] memory w = _readN(pool, _map(id, POSITIONS_SLOT) + 1, 2);
        uint256 n = _bits(uint256(w[1]), 6, 4);
        if (n == 0) return _bits(uint256(w[0]), 23, 5);
        return ownershipAt(pool, id, n - 1).until;
    }

    function ownerOf(ForgePool pool, uint256 id) internal view returns (address) {
        return address(uint160(_read(pool, _map(id, POSITIONS_SLOT))));
    }

    function historyMaskOf(ForgePool pool, uint256 id) internal view returns (uint32) {
        return uint32(_bits(_read(pool, _map(id, POSITIONS_SLOT) + 1), 6, 4));
    }

    function ashfallForfeitedOf(ForgePool pool, uint256 id) internal view returns (bool) {
        return _bits(_read(pool, _map(id, POSITIONS_SLOT) + 1), 22, 1) != 0;
    }

    function sealOf(ForgePool pool, uint256 id, uint256 k) internal view returns (Seal memory s) {
        uint256 w = _read(pool, _map(k, _map(id, SEALS_SLOT)));
        s.track = uint8(_bits(w, 0, 1));
        s.status = SealStatus(_bits(w, 1, 1));
        s.start = uint40(_bits(w, 2, 5));
        s.pausedAt = uint40(_bits(w, 7, 5));
        s.pausedSeconds = uint40(_bits(w, 12, 5));
        s.endedAt = uint40(_bits(w, 17, 5));
        s.cohortMask = uint32(_bits(w, 22, 4));
    }

    // ── lots and records ──────────────────────────────────────────────────

    /// @notice Raw head of a slot (state as of `since`).
    function lotOf(ForgePool pool, uint256 id, uint256 slot) internal view returns (Lot memory) {
        return _lot(_read(pool, _map(id, LOTS_SLOT) + slot));
    }

    function _lot(uint256 w) private pure returns (Lot memory l) {
        l.since = uint40(_bits(w, 0, 5));
        l.amount = uint96(_bits(w, 5, 12));
        l.age = uint32(_bits(w, 17, 4));
        l.participated = uint32(_bits(w, 21, 4));
        l.heldBy = uint24(_bits(w, 25, 3));
        l.records = uint24(_bits(w, 28, 3));
        l.seal = uint8(_bits(w, 31, 1));
    }

    /// @notice A slot's state at the position's last checkpoint (zero once closed).
    function lotAt(ForgePool pool, uint256 id, uint256 slot)
        internal
        view
        returns (uint256 amount, uint256 age, uint256 participated, uint256 heldBy)
    {
        ForgePoolBase.Position memory p = positionOf(pool, id);
        if (p.closedAt != 0) return (0, 0, 0, 0);
        Lot memory l = lotOf(pool, id, slot);
        (amount, age, participated, heldBy) = (l.amount, l.age, l.participated, l.heldBy);
        if (amount != 0) {
            uint256 dt = p.lastCheckpoint - l.since;
            (age, participated) = (Math.min(age + dt, P.HEAT_AGE_CAP), Math.min(participated + dt, P.ASHFALL_MIN_PARTICIPATION));
        }
    }

    function historyLength(ForgePool pool, uint256 id, uint256 slot) internal view returns (uint256) {
        return lotOf(pool, id, slot).records;
    }

    function historyAt(ForgePool pool, uint256 id, uint256 slot, uint256 i) internal view returns (Record memory r) {
        uint256 w = _read(pool, _map(i, _map(slot, _map(id, HISTORY_SLOT))));
        r.since = uint40(_bits(w, 0, 5));
        r.amount = uint96(_bits(w, 5, 12));
        r.age = uint32(_bits(w, 17, 4));
        r.participated = uint24(_bits(w, 21, 3));
        r.seal = uint8(_bits(w, 24, 1));
        r.streak = uint40(_bits(w, 25, 5));
        r.ordinaryBonus = uint16(_bits(w, 30, 2));
    }

    function lotCount(ForgePool pool, uint256 id) internal view returns (uint256 n) {
        for (uint32 x = positionOf(pool, id).usedMask; x != 0; x &= x - 1) ++n;
    }

    /// @notice Custody principal, active plus frozen (zero once closed). Lapses move principal
    ///         between the two, so it needs no sync. Reads only the used lots and pending tickets.
    function custodyOf(ForgePool pool, uint256 id) internal view returns (uint256 total) {
        (uint256 used, uint32[] memory pend) = _maskAndPending(pool, id);
        uint256 n = pend.length;
        for (uint32 x = uint32(used); x != 0; x &= x - 1) ++n;
        bytes32[] memory s = new bytes32[](n);
        uint256 k;
        uint256 lots = _map(id, LOTS_SLOT);
        for (uint256 j; j < 32; ++j) {
            if (used & (1 << j) != 0) s[k++] = bytes32(lots + j);
        }
        uint256 tickets = _map(id, TICKETS_SLOT);
        for (uint256 t; t < pend.length; ++t) s[k++] = bytes32(_map(pend[t], tickets));
        bytes32[] memory w = pool.extsload(s);
        for (uint256 i; i < w.length; ++i) {
            total += i < w.length - pend.length ? _bits(uint256(w[i]), 5, 12) : _bits(uint256(w[i]), 0, 16);
        }
    }

    /// @dev usedMask and the pending ticket ids; the pending word is read only when needed.
    function _maskAndPending(ForgePool pool, uint256 id) private view returns (uint256 used, uint32[] memory ids) {
        uint256 w1 = _read(pool, _map(id, POSITIONS_SLOT) + 1);
        used = _bits(w1, 2, 4);
        uint256 n = _bits(w1, 1, 1);
        ids = new uint32[](n);
        if (n == 0) return (used, ids);
        uint256 w = _read(pool, _map(id, PENDING_SLOT));
        for (uint256 k; k < n; ++k) ids[k] = uint32(_bits(w, 4 * k, 4));
    }

    // ── cooling ───────────────────────────────────────────────────────────

    function pendingTickets(ForgePool pool, uint256 id) internal view returns (uint32[] memory ids) {
        (, ids) = _maskAndPending(pool, id);
    }

    function ticketOf(ForgePool pool, uint256 id, uint32 ticketId) internal view returns (ForgePoolBase.Ticket memory t) {
        uint256 w = _read(pool, _map(ticketId, _map(id, TICKETS_SLOT)));
        t.amount = uint128(_bits(w, 0, 16));
        t.maturity = uint40(_bits(w, 16, 5));
        t.status = ForgePoolBase.Status(_bits(w, 21, 1));
        t.poolApplied = _bits(w, 22, 1) != 0;
        t.sliceMask = uint32(_bits(w, 23, 4));
    }

    function sliceOf(ForgePool pool, uint256 id, uint32 ticketId, uint256 slot)
        internal
        view
        returns (ForgePoolBase.Slice memory s)
    {
        uint256 w = _read(pool, _map(slot, _map(ticketId, _map(id, SLICES_SLOT))));
        (s.amount, s.age, s.participated) = (uint128(_bits(w, 0, 16)), uint32(_bits(w, 16, 4)), uint32(_bits(w, 20, 4)));
    }

    /// @notice Pending tickets whose lapse is due by now: the lapses a sync would resolve.
    function dueLapses(ForgePool pool, uint256 id) internal view returns (uint256 n) {
        (, uint32[] memory pend) = _maskAndPending(pool, id);
        if (pend.length == 0) return 0;
        bytes32[] memory s = new bytes32[](pend.length);
        uint256 tickets = _map(id, TICKETS_SLOT);
        for (uint256 k; k < pend.length; ++k) s[k] = bytes32(_map(pend[k], tickets));
        bytes32[] memory w = pool.extsload(s);
        for (uint256 k; k < w.length; ++k) {
            if (_bits(uint256(w[k]), 16, 5) + P.WITHDRAW_EXECUTION_WINDOW <= block.timestamp) ++n;
        }
    }

    // ── pool ──────────────────────────────────────────────────────────────

    function occupancyLength(ForgePool pool) internal view returns (uint256) {
        return _read(pool, OCCUPANCY_SLOT);
    }

    function occupancyAt(ForgePool pool, uint256 i) internal view returns (ForgePoolBase.Occupancy memory o) {
        uint256 w = _read(pool, uint256(keccak256(abi.encode(OCCUPANCY_SLOT))) + i);
        (o.time, o.cumulative, o.on) = (uint40(_bits(w, 0, 5)), uint64(_bits(w, 5, 8)), _bits(w, 13, 1) != 0);
    }

    function lapseQueueLength(ForgePool pool) internal view returns (uint256) {
        return _read(pool, LAPSES_SLOT);
    }
}
