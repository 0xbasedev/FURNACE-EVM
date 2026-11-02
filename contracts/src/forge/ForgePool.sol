// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";
import {LapseHeap} from "./LapseHeap.sol";
import {Lot, Record, Seal, SealStatus, SlotMeasure, ForgeMeasures} from "./ForgeMeasures.sol";
import {ForgePoolBase} from "./ForgePoolBase.sol";
import {ForgePoolAnnex} from "./ForgePoolAnnex.sol";
/// @title ForgePool
/// @notice Principal custody for one Forge pool (spec v5.5 §4, §9-§11; ADR 0004).
///         A position holds at most 32 lots, each with its own financial age. Exits
///         are in kind and depend on nothing but `STAKE_TOKEN.transfer`: no oracle,
///         swap, bridge, reward pass or fee router. There is no owner, pause, rescue
///         or upgrade path.
///
///         Cooling: a plan freezes a reference balance; each request freezes a pro-rata
///         slice of every active lot, which neither earns nor ages. Execution inside
///         [maturity, maturity + 24h) pays the slice out and scales every surviving
///         age by the surviving fraction. Cancel or lapse resumes the frozen state;
///         a lapse needs no transaction and is back-dated to its deadline.
///
///         Records: each slot keeps a head (its state as of `since`) and the history
///         of every superseded head, so `epochMeasure` integrates S = ∫stake dt and
///         W = ∫stake·Heat dt over ANY past interval exactly, however late settlement
///         runs (ADR 0005). Between records a lot only ages, so syncs write nothing.
///         Pool occupancy (time with active principal) is an append-only log.
///
///         Seals (ADR 0006): an owner commits the position's current lots to a 30-365
///         day term for a marginal bonus paid from the Conviction bucket into escrow.
///         Lots earn under the Seal through a tag in their records; any pending cooling
///         pauses it and extends the term; an executed withdrawal or emergency exit
///         forfeits it; completion is back-dated to its due time. None of this adds an
///         external call to any exit.
///
///         Ordinary bonus (ADR 0008): the immutable BOOST contract sets each position's
///         Capstone + Pyre Heat bonus (≤ 0.65). It enters W, the sealed W and the Ashfall
///         weight through the records, segment by segment. A top-up dilutes it until
///         BOOST refreshes it; exits never call BOOST.
///
///         Deeds (ADR 0011): the immutable DEEDS market lists a position for its owner, which
///         locks the owner's mutations until the listing ends; emergency exit still works and
///         ends it. A sale settles here once, with no external call: the seller's record
///         segments close, the buyer receives 80% of capped age, a new Streak, a zero bonus,
///         no wallet-bound terms and a fresh cooling plan, and the seller joins the ownership
///         log that proves each owner's tenure.
///
///         Annex (ADR 0012): Seals, BOOST's bonus, Deed listing and settlement, and fee
///         collection run in ForgePoolAnnex, which this pool deploys at construction and calls
///         by DELEGATECALL. Principal paths, exits and views stay here.
contract ForgePool is ForgePoolBase {
    using SafeERC20 for IERC20;
    using LapseHeap for LapseHeap.Heap;

    /// @notice This pool's annex: its cold paths, run in this pool's storage (ADR 0012).
    address public immutable ANNEX;

    constructor(IERC20 stakeToken, bool isLp, address feeCollector, address boost, address deeds)
        ForgePoolBase(stakeToken, isLp, feeCollector, boost, deeds)
    {
        ANNEX = address(new ForgePoolAnnex(stakeToken, isLp, feeCollector, boost, deeds));
    }

    // ── principal paths ───────────────────────────────────────────────────

    /// @notice Open a position with its first lot. 1% deposit fee, booked here.
    function open(uint256 amount) external nonReentrant returns (uint256 id) {
        uint40 now_ = uint40(block.timestamp);
        _poolSync(now_);
        id = ++positionCount;
        Position storage p = _positions[id];
        p.owner = msg.sender;
        p.lastCheckpoint = now_;
        p.streakStart = now_;
        p.openedAt = now_;
        emit Opened(id, msg.sender);
        _addLot(id, p, _pull(amount), now_);
    }

    /// @notice Add a new lot (age 0) to an open position. [P] A bonus is diluted by
    ///         custody before/after: exact for Capstone's linear part, below the true value
    ///         otherwise, until BOOST refreshes it (ADR 0008).
    function deposit(uint256 id, uint256 amount) external nonReentrant {
        Position storage p = _touchOwned(id);
        if (p.closedAt != 0) revert Closed(id);
        uint256 units = p.ordinaryBonus;
        uint256 custody = units == 0 ? 0 : _activeOf(id, p) + _frozenOf(id, p);
        uint256 net = _addLot(id, p, _pull(amount), uint40(block.timestamp));
        if (units != 0) _setBonus(id, p, units * custody / (custody + net), type(uint256).max);
    }

    /// @notice Freeze `amount` pro-rata across the active lots and start its timer.
    ///         The tier follows the plan's cumulative request against its frozen
    ///         reference, so splitting a large exit cannot buy short timers.
    function requestCooling(uint256 id, uint256 amount) external nonReentrant returns (uint32 ticketId) {
        Position storage p = _touchOwned(id);
        if (p.closedAt != 0) revert Closed(id);
        if (amount == 0) revert ZeroAmount();
        uint256 active = _activeOf(id, p);
        if (amount > active) revert ExceedsActive(amount, active);
        uint256 maturity = block.timestamp + _chargePlan(id, p, amount, active);

        ticketId = ++p.nextTicketId;
        if (ticketId > type(uint24).max) revert TicketIdOverflow(id);
        Seal storage seal_ = _seals[id][p.sealCount];
        bool pauses = p.pendingCount == 0 && seal_.status == SealStatus.Active;
        if (pauses) seal_.pausedAt = uint40(block.timestamp); // before the freeze: its heads drop the tag
        uint32 sliceMask = _freeze(id, p, ticketId, _proRata(_lots[id], p.usedMask, amount, active));
        if (pauses) {
            _retag(id, p, seal_.cohortMask, block.timestamp);
            emit SealPaused(id, p.sealCount, block.timestamp);
        }
        _tickets[id][ticketId] = Ticket(uint128(amount), uint40(maturity), Status.Pending, false, sliceMask);
        _pending[id][p.pendingCount++] = ticketId;

        activePrincipal -= amount;
        frozenPrincipal += amount;
        _lapses.push(maturity + P.WITHDRAW_EXECUTION_WINDOW, _key(id, ticketId));
        _afterDecrease(uint40(block.timestamp));
        emit CoolingRequested(id, ticketId, amount, maturity);
    }

    /// @notice Pay out a matured ticket in kind (1% fee). Every surviving lot, and
    ///         every other pending slice, has its capped age scaled by the surviving
    ///         fraction of custody principal. Resets Streak.
    function executeWithdrawal(uint256 id, uint32 ticketId) external nonReentrant returns (uint256 net) {
        Position storage p = _touchOwned(id);
        Ticket storage t = _tickets[id][ticketId];
        if (t.status != Status.Pending) revert NotPending(id, ticketId);
        if (block.timestamp < t.maturity) revert NotMatured(t.maturity);
        uint256 w = t.amount;
        uint256 balance = _activeOf(id, p) + _frozenOf(id, p);

        _endSeal(id, p, SealStatus.Forfeited, block.timestamp);
        _releaseSlots(id, p, ticketId, t.sliceMask);
        _dropPending(id, p, ticketId, Status.Executed);
        _haircut(id, p, w, balance);
        p.streakStart = uint40(block.timestamp);

        uint256 fee = (w * P.FORGE_WITHDRAW_FEE_PCT) / 100;
        net = w - fee;
        feesOwed[uint256(FeeKind.Withdraw)] += fee;
        frozenPrincipal -= w;
        _lapses.remove(_key(id, ticketId));
        emit WithdrawalExecuted(id, ticketId, net, fee);
        STAKE_TOKEN.safeTransfer(p.owner, net);
    }

    /// @notice Cancel a pending ticket; its slices resume from their frozen state.
    ///         The plan's request allowance stays consumed.
    function cancelCooling(uint256 id, uint32 ticketId) external nonReentrant {
        Position storage p = _touchOwned(id);
        if (_tickets[id][ticketId].status != Status.Pending) revert NotPending(id, ticketId);
        uint40 now_ = uint40(block.timestamp);
        _resume(id, p, ticketId, Status.Cancelled, now_, now_);
    }

    /// @notice Leave immediately with all principal, active and frozen, in kind.
    ///         8% fee (routed 50/25/25 later by the fee router); pending Ashfall is
    ///         forfeited. Closes the position; its measures remain.
    function emergencyExit(uint256 id) external nonReentrant returns (uint256 net) {
        Position storage p = _touch(id); // not _touchOwned: a listing never blocks this exit
        if (p.owner != msg.sender) revert NotOwner(id);
        if (p.closedAt != 0) revert Closed(id);
        uint256 active = _activeOf(id, p);
        uint256 frozen = _frozenOf(id, p);
        uint256 total = active + frozen;
        if (total == 0) revert NothingToExit(id);

        for (uint256 k; k < p.pendingCount; ++k) {
            uint32 ticketId = _pending[id][k];
            _tickets[id][ticketId].status = Status.Emergency;
            _lapses.remove(_key(id, ticketId));
            delete _pending[id][k];
        }
        p.pendingCount = 0;
        _endSeal(id, p, SealStatus.Forfeited, block.timestamp);
        // Heads and history stay: measures stop at `closedAt`, so no per-slot writes.
        p.usedMask = 0;
        p.reservedSlots = 0;
        p.closedAt = uint40(block.timestamp);
        p.ashfallForfeited = true;
        if (p.listing & 1 != 0) {
            unchecked {
                ++p.listing; // the sale can no longer settle
            }
        }

        uint256 fee = (total * P.EMERGENCY_EXIT_FEE_PCT) / 100;
        net = total - fee;
        feesOwed[uint256(FeeKind.Emergency)] += fee;
        frozenPrincipal -= frozen;
        activePrincipal -= active;
        _afterDecrease(uint40(block.timestamp));
        emit EmergencyExited(id, net, fee);
        STAKE_TOKEN.safeTransfer(p.owner, net);
    }

    /// @notice Bring a position up to date: resolve due lapses (back-dated) and move its
    ///         checkpoint to now. Permissionless; settlement calls it before measuring.
    function poke(uint256 id) external nonReentrant {
        _touch(id);
    }

    // ── annex (ADR 0012): each runs ForgePoolAnnex's function of the same name ──

    /// @notice See ForgePoolAnnex.seal.
    function seal(uint256, uint256) external returns (uint256) {
        _annex();
    }

    /// @notice See ForgePoolAnnex.setOrdinaryBonus.
    function setOrdinaryBonus(uint256, uint256) external {
        _annex();
    }

    /// @notice See ForgePoolAnnex.list.
    function list(uint256, address) external returns (uint32) {
        _annex();
    }

    /// @notice See ForgePoolAnnex.unlist.
    function unlist(uint256) external {
        _annex();
    }

    /// @notice See ForgePoolAnnex.settle.
    function settle(uint256, address, uint32) external {
        _annex();
    }

    /// @notice See ForgePoolAnnex.collectFees.
    function collectFees() external returns (uint256, uint256, uint256) {
        _annex();
    }

    // ── views ─────────────────────────────────────────────────────────────

    /// @notice Raw storage words. Positions, lots, records, tickets, slices, Seals and the
    ///         occupancy log are read through ForgeView, which decodes this layout (ADR 0010).
    function extsload(bytes32[] calldata slots) external view returns (bytes32[] memory out) {
        out = new bytes32[](slots.length);
        for (uint256 i; i < slots.length; ++i) {
            bytes32 slot = slots[i];
            bytes32 v;
            assembly ("memory-safe") {
                v := sload(slot)
            }
            out[i] = v;
        }
    }

    /// @notice Exact time-integrated measures of a position over [t0, t1]:
    ///         S = ∫stake dt and W = ∫stake·Heat dt (RAY), summed over its records.
    ///         Requires the position synced past t1, so every lapse due by t1 has its
    ///         back-dated record. Measures stop at an emergency exit.
    ///         Also returns their Seal-tagged parts, clipped at each Seal's end and not yet
    ///         scaled by its bonus: Ss = ∫sealed stake dt and Ws = ∫sealed stake·Heat dt,
    ///         and the Ashfall weight Q = ⌊∫eligible stake·Heat² dt / RAY⌋ (ADR 0007).
    function epochMeasure(uint256 id, uint256 t0, uint256 t1)
        external
        view
        returns (uint256 s, uint256 w, uint256 ss, uint256 sw, uint256 q)
    {
        t1 = _measurable(id, t0, t1);
        Position storage p = _positions[id];
        SlotMeasure memory m = ForgeMeasures.positionMeasure(
            _history[id], _lots[id], _seals[id], _anchor(p), p.historyMask, t0, t1
        );
        return (m.stakeSeconds, m.heatSeconds, m.sealedStakeSeconds, m.sealedHeatSeconds, m.ashfallQuotient);
    }

    /// @notice One slot's measures over [t0, t1], resumable: examines at most `maxSegs`
    ///         record segments starting at `from` (0 = the first that can overlap t0).
    ///         Returns the resume point `next` when not `done`. Settlement pages use this
    ///         so a slot with any number of records settles over bounded calls. The
    ///         Ashfall weight is measured only if `ashfall`.
    function measureSlot(uint256 id, uint256 slot, uint256 t0, uint256 t1, uint256 from, uint256 maxSegs, bool ashfall)
        external
        view
        returns (SlotMeasure memory m)
    {
        t1 = _measurable(id, t0, t1);
        if (t1 <= t0) {
            m.done = true;
            return m;
        }
        return ForgeMeasures.slotMeasure(
            _history[id][slot], _lots[id][slot], _seals[id], _anchor(_positions[id]), ashfall, t0, t1, from, maxSegs
        );
    }

    /// @notice Cumulative seconds with active principal up to `t` (t ≤ now). Includes
    ///         a lapse that has come due but no transaction has processed yet.
    function occupiedSecondsAt(uint256 t) public view returns (uint256 total) {
        if (t > block.timestamp) revert FutureTime(t);
        uint256 n = _occupancy.length;
        (uint256 lo, uint256 hi) = (0, n);
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (_occupancy[mid].time <= t) lo = mid + 1;
            else hi = mid;
        }
        bool lastOn;
        if (lo != 0) {
            Occupancy memory o = _occupancy[lo - 1];
            total = o.cumulative + (o.on ? t - o.time : 0);
            lastOn = o.on;
        }
        if (lo == n && !lastOn && activePrincipal == 0) {
            (bool ok, uint256 due,) = _lapses.peek();
            if (ok && due <= t) total += t - due;
        }
    }

    /// @dev Run this call's calldata in the annex, in this contract's storage, and return or
    ///      revert with exactly what it returned. The annex functions hold the reentrancy
    ///      guard; the stubs do not, since its transient slot is this contract's.
    function _annex() private {
        address annex = ANNEX;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), annex, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}
