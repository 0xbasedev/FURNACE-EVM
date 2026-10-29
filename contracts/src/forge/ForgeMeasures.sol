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
///      `seal` is the position's Seal (1-based) this lot earns its bonus under from
///      `since`, or 0; the bonus stops at that Seal's end (ADR 0006).
struct Lot {
    uint40 since;
    uint96 amount;
    uint32 age;
    uint32 participated;
    uint24 heldBy;
    uint24 records;
    uint8 seal;
}

/// @dev A superseded head, valid from `since` until the next record's `since`.
struct Record {
    uint40 since;
    uint96 amount;
    uint32 age;
    uint32 participated;
    uint8 seal;
}

enum SealStatus {
    None,
    Active,
    Completed,
    Forfeited
}

/// @dev One Seal of a position (ADR 0006). `pausedSeconds` extends the term; while
///      `pausedAt != 0` a cooling request is pending and no lot carries its tag.
///      `endedAt` is the completion (back-dated to the due time) or the forfeit.
struct Seal {
    uint8 track;
    SealStatus status;
    uint40 start;
    uint40 pausedAt;
    uint40 pausedSeconds;
    uint40 endedAt;
    uint32 cohortMask;
}

/// @dev One slot's measures over an interval. `sealedStakeSeconds` and
///      `sealedHeatSeconds` cover the tagged segments, clipped at their Seal's end and
///      not yet scaled by the bonus; `seal` is the last tag that contributed.
struct SlotMeasure {
    uint256 stakeSeconds;
    uint256 heatSeconds;
    uint256 sealedStakeSeconds;
    uint256 sealedHeatSeconds;
    uint256 seal;
    uint256 next;
    uint256 used;
    bool done;
}

/// @title ForgeMeasures
/// @notice Exact time-integrated measures of one ForgePool slot over [t0, t1] from its
///         checkpoint records (ADR 0005, ADR 0006). An external library: the pool
///         reaches it by DELEGATECALL with pointers into its own storage, which keeps
///         the pool's runtime code under the EIP-170 limit (ADR 0004 §3).
library ForgeMeasures {
    /// @dev Scratch state of one slot scan (keeps the scan loop within the stack).
    struct SlotScan {
        uint256 n;
        uint256 i;
        uint256 t0;
        uint256 t1;
        uint256 tag; // cached Seal: its index and end
        uint256 tagEnd;
    }

    /// @notice A Seal's end: when it ended, else when it is due if it keeps running.
    ///         While paused no lot carries its tag, so the due time without the open
    ///         pause never clips a tagged segment early.
    function sealEnd(Seal memory s) internal pure returns (uint256) {
        if (s.endedAt != 0) return s.endedAt;
        return uint256(s.start) + trackSeconds(s.track) + s.pausedSeconds;
    }

    function trackSeconds(uint256 track) internal pure returns (uint256) {
        if (track == 0) return P.SEAL_TRACK_0_SECONDS;
        if (track == 1) return P.SEAL_TRACK_1_SECONDS;
        if (track == 2) return P.SEAL_TRACK_2_SECONDS;
        return P.SEAL_TRACK_3_SECONDS;
    }

    function trackBonus(uint256 track) internal pure returns (uint256) {
        if (track == 0) return P.SEAL_TRACK_0_BONUS_RAY;
        if (track == 1) return P.SEAL_TRACK_1_BONUS_RAY;
        if (track == 2) return P.SEAL_TRACK_2_BONUS_RAY;
        return P.SEAL_TRACK_3_BONUS_RAY;
    }

    /// @notice One slot's S = ∫stake dt and W = ∫stake·Heat dt (RAY) over [t0, t1], plus
    ///         their sealed parts: segment i is history[i] (or the head for i == n) and
    ///         lasts until the next segment begins. Examines at most `maxSegs` segments
    ///         from `from` (1-based; 0 = binary-search the first that can overlap t0) and
    ///         returns the 1-based resume index `next` when it stops early.
    function slotMeasure(
        mapping(uint256 => Record) storage history,
        Lot storage head,
        mapping(uint256 => Seal) storage seals,
        uint256 t0,
        uint256 t1,
        uint256 from,
        uint256 maxSegs
    ) public view returns (SlotMeasure memory m) {
        SlotScan memory c;
        (c.n, c.t0, c.t1) = (head.records, t0, t1);
        c.i = from != 0 ? from - 1 : _firstSegment(history, c.n, head.since, t0);
        for (; c.i <= c.n; ++c.i) {
            if (m.used == maxSegs) {
                m.next = c.i + 1;
                return m;
            }
            if (!_scanSegment(history, head, seals, c, m)) break;
        }
        m.done = true;
    }

    /// @notice A position's measures over [t0, t1]: every slot in `mask`, unbounded.
    function positionMeasure(
        mapping(uint256 => mapping(uint256 => Record)) storage history,
        Lot[32] storage lots,
        mapping(uint256 => Seal) storage seals,
        uint32 mask,
        uint256 t0,
        uint256 t1
    ) external view returns (SlotMeasure memory total) {
        if (t1 <= t0) return total;
        for (uint256 j; j < 32; ++j) {
            if (mask & (1 << j) == 0) continue;
            SlotMeasure memory m = slotMeasure(history[j], lots[j], seals, t0, t1, 0, type(uint256).max);
            total.stakeSeconds += m.stakeSeconds;
            total.heatSeconds += m.heatSeconds;
            total.sealedStakeSeconds += m.sealedStakeSeconds;
            total.sealedHeatSeconds += m.sealedHeatSeconds;
        }
    }

    /// @dev Adds segment `c.i` if it starts before t1; false once segments pass t1.
    function _scanSegment(
        mapping(uint256 => Record) storage history,
        Lot storage head,
        mapping(uint256 => Seal) storage seals,
        SlotScan memory c,
        SlotMeasure memory m
    ) private view returns (bool) {
        Record memory r =
            c.i < c.n ? history[c.i] : Record(head.since, head.amount, head.age, head.participated, head.seal);
        if (r.since >= c.t1) return false;
        ++m.used;
        uint256 segEnd = c.i + 1 < c.n ? history[c.i + 1].since : (c.i + 1 == c.n ? head.since : type(uint256).max);
        if (segEnd <= c.t0 || r.amount == 0) return true;
        uint256 a = r.since > c.t0 ? r.since : c.t0;
        uint256 b = segEnd < c.t1 ? segEnd : c.t1;
        uint256 age = Math.min(r.age + (a - r.since), P.HEAT_AGE_CAP);
        uint256 s = uint256(r.amount) * (b - a);
        uint256 w = uint256(r.amount) * HeatMath.integrateHeat(age, b - a, 0);
        m.stakeSeconds += s;
        m.heatSeconds += w;
        if (r.seal == 0) return true;
        if (c.tag != r.seal) (c.tag, c.tagEnd) = (r.seal, sealEnd(seals[r.seal]));
        if (c.tagEnd <= a) return true;
        if (c.tagEnd < b) {
            s = uint256(r.amount) * (c.tagEnd - a);
            w = uint256(r.amount) * HeatMath.integrateHeat(age, c.tagEnd - a, 0);
        }
        m.sealedStakeSeconds += s;
        m.sealedHeatSeconds += w;
        m.seal = r.seal;
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
}
