// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";
import {HeatMath} from "../libraries/HeatMath.sol";

/// @dev A slot's head: its state as of `since`. While `amount > 0` age and
///      participation grow 1:1 with time (saturating); otherwise they hold.
///      `heldBy` is the ticket that froze the lot's entire active amount; the slot
///      stays reserved for that ticket's slice to return to.
///      `records` counts the superseded heads kept in history (no array length slot).
struct Lot {
    uint40 since;
    uint96 amount;
    uint32 age;
    uint32 participated;
    uint24 heldBy;
    uint32 records;
}

/// @dev A superseded head, valid from `since` until the next record's `since`.
struct Record {
    uint40 since;
    uint96 amount;
    uint32 age;
    uint32 participated;
}

/// @title ForgeMeasures
/// @notice Exact time-integrated measures of one ForgePool slot over [t0, t1] from its
///         checkpoint records (ADR 0005). An external library: the pool reaches it by
///         DELEGATECALL with pointers into its own storage, which keeps the pool's
///         runtime code under the EIP-170 limit (ADR 0004 §3).
library ForgeMeasures {
    /// @dev Scratch state of one slot scan (keeps the scan loop within the stack).
    struct SlotScan {
        uint256 n;
        uint256 i;
        uint256 used;
        uint256 s;
        uint256 w;
    }

    /// @notice One slot's S = ∫stake dt and W = ∫stake·Heat dt (RAY) over [t0, t1]: segment
    ///         i is history[i] (or the head for i == n) and lasts until the next segment
    ///         begins. Examines at most `maxSegs` segments from `from` (1-based; 0 = binary-
    ///         search the first that can overlap t0) and returns the 1-based resume index
    ///         `next` when it stops early (`done` false).
    function slotMeasure(
        mapping(uint256 => Record) storage history,
        Lot storage head,
        uint256 t0,
        uint256 t1,
        uint256 from,
        uint256 maxSegs
    ) external view returns (uint256, uint256, uint256, uint256, bool) {
        SlotScan memory c;
        c.n = head.records;
        c.i = from != 0 ? from - 1 : _firstSegment(history, c.n, head.since, t0);
        for (; c.i <= c.n; ++c.i) {
            if (c.used == maxSegs) return (c.s, c.w, c.i + 1, c.used, false);
            if (!_scanSegment(history, head, c, t0, t1)) break;
        }
        return (c.s, c.w, 0, c.used, true);
    }

    /// @dev Adds segment `c.i` if it starts before t1; false once segments pass t1.
    function _scanSegment(
        mapping(uint256 => Record) storage history,
        Lot storage head,
        SlotScan memory c,
        uint256 t0,
        uint256 t1
    ) private view returns (bool) {
        Record memory r = c.i < c.n ? history[c.i] : Record(head.since, head.amount, head.age, head.participated);
        if (r.since >= t1) return false;
        ++c.used;
        uint256 segEnd = c.i + 1 < c.n ? history[c.i + 1].since : (c.i + 1 == c.n ? head.since : type(uint256).max);
        (uint256 ds, uint256 dw) = _segment(r, segEnd, t0, t1);
        c.s += ds;
        c.w += dw;
        return true;
    }

    /// @dev The last segment starting at or before t0 (or the first segment).
    function _firstSegment(mapping(uint256 => Record) storage history, uint256 n, uint256 headSince, uint256 t0)
        private
        view
        returns (uint256)
    {
        if (headSince <= t0) return n;
        (uint256 lo, uint256 hi) = (0, n);
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (history[mid].since <= t0) lo = mid + 1;
            else hi = mid;
        }
        return lo == 0 ? 0 : lo - 1;
    }

    /// @dev One segment's contribution over its overlap with [t0, t1].
    function _segment(Record memory r, uint256 segEnd, uint256 t0, uint256 t1)
        private
        pure
        returns (uint256 s, uint256 w)
    {
        if (segEnd <= t0 || r.amount == 0) return (0, 0);
        uint256 a = r.since > t0 ? r.since : t0;
        uint256 b = segEnd < t1 ? segEnd : t1;
        uint256 age = Math.min(r.age + (a - r.since), P.HEAT_AGE_CAP);
        s = uint256(r.amount) * (b - a);
        w = uint256(r.amount) * HeatMath.integrateHeat(age, b - a, 0);
    }
}
