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
contract ForgePool is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using LapseHeap for LapseHeap.Heap;

    /// @dev Literal so it can size storage arrays; uint32 slot masks need exactly 32.
    ///      The constructor checks it against the generated config value.
    uint256 internal constant MAX_LOTS = 32;
    /// @notice [P] Concurrent cooling tickets per position (not in the canonical config).
    uint256 public constant MAX_PENDING_TICKETS = 8;
    /// @notice [P] A BOOST rewrite reverts once an active slot holds this many records, so
    ///         the rest of the uint24 record counter stays with the owner's own actions.
    uint256 public constant BOOST_RECORD_LIMIT = 1 << 23;

    enum Status {
        None,
        Pending,
        Executed,
        Cancelled,
        Lapsed,
        Emergency
    }

    enum FeeKind {
        Deposit,
        Withdraw,
        Emergency
    }

    struct Slice {
        uint128 amount;
        uint32 age;
        uint32 participated;
    }

    struct Ticket {
        uint128 amount;
        uint40 maturity;
        Status status;
        bool poolApplied;
        uint32 sliceMask;
    }

    struct Plan {
        uint40 start;
        uint128 referenceBalance;
        uint128 requested;
    }

    struct Position {
        address owner;
        uint40 lastCheckpoint;
        uint40 streakStart;
        uint16 ordinaryBonus; // Capstone + Pyre, units of ORDINARY_BONUS_UNIT_RAY (ADR 0008)
        uint8 reservedSlots;
        uint8 pendingCount;
        uint32 usedMask; // slot j in use ⇔ amount > 0 or heldBy != 0
        uint32 historyMask; // slot j has ever held a head (its records matter)
        uint32 nextTicketId;
        uint64 coolingPausedSeconds;
        bool ashfallForfeited;
        uint40 openedAt;
        uint40 closedAt; // emergency exit; measures stop here, records stay
        uint8 sealCount; // the latest Seal is `_seals[id][sealCount]`
        Plan plan;
    }

    struct Occupancy {
        uint40 time;
        uint64 cumulative;
        bool on;
    }

    IERC20 public immutable STAKE_TOKEN;
    bool public immutable IS_LP;
    address public immutable FEE_COLLECTOR;
    /// @notice The only caller of `setOrdinaryBonus` (Capstone + Pyre; ADR 0008).
    address public immutable BOOST;

    uint256 public positionCount;
    /// @notice Principal that earns now. Lapsed slices not yet processed are still
    ///         counted in `frozenPrincipal`; the two always sum to custody principal.
    uint256 public activePrincipal;
    uint256 public frozenPrincipal;
    uint256[3] public feesOwed;

    Occupancy[] internal _occupancy;
    LapseHeap.Heap internal _lapses;
    mapping(uint256 id => Position) internal _positions;
    mapping(uint256 id => Lot[MAX_LOTS]) internal _lots;
    mapping(uint256 id => mapping(uint256 slot => mapping(uint256 i => Record))) internal _history;
    mapping(uint256 id => uint32[MAX_PENDING_TICKETS]) internal _pending;
    mapping(uint256 id => mapping(uint32 ticketId => Ticket)) internal _tickets;
    mapping(uint256 id => mapping(uint32 ticketId => mapping(uint256 slot => Slice))) internal _slices;
    mapping(uint256 id => mapping(uint256 k => Seal)) internal _seals;

    event Opened(uint256 indexed id, address indexed owner);
    event Deposited(uint256 indexed id, uint256 slot, uint256 net, uint256 fee);
    event CoolingRequested(uint256 indexed id, uint32 indexed ticketId, uint256 amount, uint256 maturity);
    event WithdrawalExecuted(uint256 indexed id, uint32 indexed ticketId, uint256 net, uint256 fee);
    event CoolingResumed(uint256 indexed id, uint32 indexed ticketId, Status status, uint256 at);
    event EmergencyExited(uint256 indexed id, uint256 net, uint256 fee);
    event FeesCollected(uint256 deposit, uint256 withdraw, uint256 emergency);
    event Sealed(uint256 indexed id, uint256 indexed k, uint256 track, uint32 cohortMask);
    event SealPaused(uint256 indexed id, uint256 indexed k, uint256 at);
    event SealResumed(uint256 indexed id, uint256 indexed k, uint256 at);
    event SealEnded(uint256 indexed id, uint256 indexed k, SealStatus status, uint256 at);
    event OrdinaryBonusSet(uint256 indexed id, uint256 units);

    error ZeroAddress();
    error UnknownPosition(uint256 id);
    error NotOwner(uint256 id);
    error Closed(uint256 id);
    error ZeroAmount();
    error BelowMinimum(uint256 net);
    error NonStandardToken();
    error LotCapacity(uint256 id);
    error ExceedsActive(uint256 amount, uint256 active);
    error PlanQuotaExceeded(uint256 requested, uint256 referenceBalance);
    error TooManyPendingTickets(uint256 id);
    error NotPending(uint256 id, uint32 ticketId);
    error NotMatured(uint256 maturity);
    error NothingToExit(uint256 id);
    error NotCollector();
    error FutureTime(uint256 t);
    error ConfigMismatch();
    error TicketIdOverflow(uint256 id);
    error NotSynced(uint256 id, uint256 lastCheckpoint);
    error BadInterval(uint256 t0, uint256 t1);
    error UnknownTrack(uint256 track);
    error CoolingPending(uint256 id);
    error SealActive(uint256 id, uint256 k);
    error SealGap(uint256 readyAt);
    error SealLimit(uint256 id);
    error NothingToSeal(uint256 id);
    error NotBoost();
    error BonusAboveCeiling(uint256 units);
    error RecordLimit(uint256 id, uint256 slot);

    constructor(IERC20 stakeToken, bool isLp, address feeCollector, address boost) {
        if (address(stakeToken) == address(0) || feeCollector == address(0) || boost == address(0)) revert ZeroAddress();
        if (P.MAX_LOTS_PER_POSITION != MAX_LOTS || P.WITHDRAW_TIER_COUNT != 5) revert ConfigMismatch();
        STAKE_TOKEN = stakeToken;
        IS_LP = isLp;
        FEE_COLLECTOR = feeCollector;
        BOOST = boost;
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
        Position storage p = _touchOwned(id);
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

        uint256 fee = (total * P.EMERGENCY_EXIT_FEE_PCT) / 100;
        net = total - fee;
        feesOwed[uint256(FeeKind.Emergency)] += fee;
        frozenPrincipal -= frozen;
        activePrincipal -= active;
        _afterDecrease(uint40(block.timestamp));
        emit EmergencyExited(id, net, fee);
        STAKE_TOKEN.safeTransfer(p.owner, net);
    }

    /// @notice Seal the position's current lots for `track`'s term (ADR 0006). Later
    ///         deposits never join; a pending cooling request pauses the Seal and extends
    ///         its term; an executed withdrawal or emergency exit forfeits its unvested
    ///         escrow, never principal. [P] A new Seal starts at least one epoch after the
    ///         previous one ended, so each epoch's bonus belongs to exactly one Seal.
    function seal(uint256 id, uint256 track) external nonReentrant returns (uint256 k) {
        Position storage p = _touchOwned(id);
        if (p.closedAt != 0) revert Closed(id);
        if (track >= P.SEAL_TRACK_COUNT) revert UnknownTrack(track);
        if (p.pendingCount != 0) revert CoolingPending(id);
        if (p.usedMask == 0) revert NothingToSeal(id);
        k = p.sealCount;
        Seal storage last = _seals[id][k];
        if (last.status == SealStatus.Active) revert SealActive(id, k);
        if (k != 0 && block.timestamp < uint256(last.endedAt) + P.EPOCH_SECONDS) {
            revert SealGap(uint256(last.endedAt) + P.EPOCH_SECONDS);
        }
        if (k == type(uint8).max) revert SealLimit(id);
        p.sealCount = uint8(++k);
        // No ticket is pending, so every used slot is an active lot: the cohort.
        _seals[id][k] = Seal(uint8(track), SealStatus.Active, uint40(block.timestamp), 0, 0, 0, p.usedMask);
        _retag(id, p, p.usedMask, block.timestamp);
        emit Sealed(id, k, track, p.usedMask);
    }

    /// @notice BOOST sets a position's ordinary bonus in units of ORDINARY_BONUS_UNIT_RAY.
    ///         The position syncs and every active lot is rewritten at now first, so each
    ///         record segment keeps one bonus. A closed position keeps its last bonus: its
    ///         measures end at the exit.
    function setOrdinaryBonus(uint256 id, uint256 units) external nonReentrant {
        if (msg.sender != BOOST) revert NotBoost();
        if (units > P.MAX_ORDINARY_BONUS_UNITS) revert BonusAboveCeiling(units);
        if (_positions[id].closedAt != 0) return;
        _setBonus(id, _touch(id), units, BOOST_RECORD_LIMIT);
    }

    /// @notice Bring a position up to date: resolve due lapses (back-dated) and move its
    ///         checkpoint to now. Permissionless; settlement calls it before measuring.
    function poke(uint256 id) external nonReentrant {
        _touch(id);
    }

    /// @notice The fee router pulls booked fees. Exits never call it.
    function collectFees() external nonReentrant returns (uint256 dep, uint256 wd, uint256 em) {
        if (msg.sender != FEE_COLLECTOR) revert NotCollector();
        (dep, wd, em) = (feesOwed[0], feesOwed[1], feesOwed[2]);
        delete feesOwed;
        emit FeesCollected(dep, wd, em);
        STAKE_TOKEN.safeTransfer(FEE_COLLECTOR, dep + wd + em);
    }

    // ── views (raw state as of each position's last checkpoint) ──────────

    function positionOf(uint256 id) external view returns (Position memory) {
        return _positions[id];
    }

    /// @notice Raw head of a slot (state as of `since`).
    function lotOf(uint256 id, uint256 slot) external view returns (Lot memory) {
        return _lots[id][slot];
    }

    /// @notice A slot's state at the position's last checkpoint (zero once closed).
    function lotAt(uint256 id, uint256 slot)
        external
        view
        returns (uint256 amount, uint256 age, uint256 participated, uint256 heldBy)
    {
        Position storage p = _positions[id];
        if (p.closedAt != 0) return (0, 0, 0, 0);
        Lot memory lot = _lots[id][slot];
        (age, participated) = _lotAt(lot, p.lastCheckpoint);
        return (lot.amount, age, participated, lot.heldBy);
    }

    /// @notice A position's custody principal, active plus frozen (zero once closed). Lapses
    ///         move principal between the two, so it needs no sync.
    function custodyOf(uint256 id) external view returns (uint256) {
        Position storage p = _positions[id];
        return _activeOf(id, p) + _frozenOf(id, p);
    }

    function historyLength(uint256 id, uint256 slot) external view returns (uint256) {
        return _lots[id][slot].records;
    }

    function historyAt(uint256 id, uint256 slot, uint256 i) external view returns (Record memory) {
        return _history[id][slot][i];
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

    /// @notice Pending tickets whose lapse is due by now: the lapses a sync would resolve.
    function dueLapses(uint256 id) external view returns (uint256 n) {
        Position storage p = _positions[id];
        for (uint256 k; k < p.pendingCount; ++k) {
            if (_deadline(_tickets[id][_pending[id][k]]) <= block.timestamp) ++n;
        }
    }

    function sealOf(uint256 id, uint256 k) external view returns (Seal memory) {
        return _seals[id][k];
    }

    function historyMaskOf(uint256 id) external view returns (uint32) {
        return _positions[id].historyMask;
    }

    function ticketOf(uint256 id, uint32 ticketId) external view returns (Ticket memory) {
        return _tickets[id][ticketId];
    }

    function sliceOf(uint256 id, uint32 ticketId, uint256 slot) external view returns (Slice memory) {
        return _slices[id][ticketId][slot];
    }

    function pendingTickets(uint256 id) external view returns (uint32[] memory ids) {
        ids = new uint32[](_positions[id].pendingCount);
        for (uint256 k; k < ids.length; ++k) ids[k] = _pending[id][k];
    }

    function lotCount(uint256 id) external view returns (uint256) {
        return _popcount(_positions[id].usedMask);
    }

    function occupancyLength() external view returns (uint256) {
        return _occupancy.length;
    }

    function occupancyAt(uint256 i) external view returns (Occupancy memory) {
        return _occupancy[i];
    }

    function lapseQueueLength() external view returns (uint256) {
        return _lapses.length();
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

    // ── internals ─────────────────────────────────────────────────────────

    function _pull(uint256 amount) internal returns (uint256) {
        uint256 before = STAKE_TOKEN.balanceOf(address(this));
        STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        if (STAKE_TOKEN.balanceOf(address(this)) - before != amount) revert NonStandardToken();
        return amount;
    }

    function _addLot(uint256 id, Position storage p, uint256 amount, uint40 now_) internal returns (uint256 net) {
        uint256 fee = (amount * P.FORGE_DEPOSIT_FEE_PCT) / 100;
        net = amount - fee;
        if (IS_LP ? net < P.MIN_STAKE_LP : net == 0) revert BelowMinimum(net);
        if (_popcount(p.usedMask) + p.reservedSlots >= MAX_LOTS) revert LotCapacity(id);
        uint256 slot = _firstFree(p.usedMask);
        _setHead(id, p, slot, _head(now_, net, 0, 0, 0));
        p.usedMask |= uint32(1 << slot);
        feesOwed[uint256(FeeKind.Deposit)] += fee;
        _increaseActive(net, now_);
        emit Deposited(id, slot, net, fee);
    }

    function _touch(uint256 id) internal returns (Position storage p) {
        p = _positions[id];
        if (p.owner == address(0)) revert UnknownPosition(id);
        uint40 now_ = uint40(block.timestamp);
        _poolSync(now_);
        _sync(id, p, now_);
    }

    function _touchOwned(uint256 id) internal returns (Position storage p) {
        p = _touch(id);
        if (p.owner != msg.sender) revert NotOwner(id);
    }

    /// @dev Resolve every lapse due by `now_` in deadline order, each back-dated to its
    ///      deadline, then move the checkpoint to `now_`. Lots age implicitly.
    function _sync(uint256 id, Position storage p, uint40 now_) internal {
        while (true) {
            (uint32 due, uint256 dueAt) = _earliestDue(id, p, now_);
            if (due == 0) break;
            _advance(p, uint40(dueAt));
            _resume(id, p, due, Status.Lapsed, uint40(dueAt), now_);
        }
        _advance(p, now_);
        // A running Seal has no pending ticket, so no lapse can precede its due time.
        Seal storage s = _seals[id][p.sealCount];
        if (s.status == SealStatus.Active && s.pausedAt == 0) {
            uint256 due = ForgeMeasures.sealEnd(s);
            if (due <= now_) _endSeal(id, p, SealStatus.Completed, due);
        }
    }

    function _earliestDue(uint256 id, Position storage p, uint40 now_)
        internal
        view
        returns (uint32 best, uint256 bestAt)
    {
        for (uint256 k; k < p.pendingCount; ++k) {
            uint32 ticketId = _pending[id][k];
            uint256 at = _deadline(_tickets[id][ticketId]);
            if (at <= now_ && (best == 0 || at < bestAt || (at == bestAt && ticketId < best))) {
                (best, bestAt) = (ticketId, at);
            }
        }
    }

    function _advance(Position storage p, uint40 t) internal {
        uint256 dt = t - p.lastCheckpoint;
        if (dt == 0) return;
        if (p.pendingCount != 0) p.coolingPausedSeconds += uint64(dt);
        p.lastCheckpoint = t;
    }

    /// @dev Return a ticket's slices. A slice that emptied its lot goes back to that
    ///      slot; any other uses its reserved slot unless the parent's financial state
    ///      is identical (then sharing storage is exact).
    function _resume(uint256 id, Position storage p, uint32 ticketId, Status status, uint40 at, uint40 now_)
        internal
    {
        Ticket storage t = _tickets[id][ticketId];
        Lot[MAX_LOTS] storage lots = _lots[id];
        uint32 mask = t.sliceMask;
        for (uint256 j; j < MAX_LOTS; ++j) {
            if (mask & (1 << j) == 0) continue;
            Slice memory s = _slices[id][ticketId][j];
            Lot memory lot = lots[j];
            if (lot.heldBy == ticketId) {
                _setHead(id, p, j, _head(at, s.amount, s.age, s.participated, 0));
            } else {
                (uint256 age, uint256 part) = _lotAt(lot, at);
                // Merge only into an identical state, and never past the amount width.
                if (lot.amount != 0 && age == s.age && part == s.participated && lot.amount + s.amount <= type(uint96).max) {
                    _setHead(id, p, j, _head(at, lot.amount + s.amount, age, part, 0));
                } else {
                    _returnToFreeSlot(id, p, j, s, at);
                }
                p.reservedSlots -= 1;
            }
        }
        _dropPending(id, p, ticketId, status);
        if (p.pendingCount == 0) _unpauseSeal(id, p, at);
        if (!t.poolApplied) {
            _lapses.remove(_key(id, ticketId));
            frozenPrincipal -= t.amount;
            _increaseActive(t.amount, now_);
        }
        emit CoolingResumed(id, ticketId, status, at);
    }

    /// @dev A slice from slot j takes the first free slot; a sealed cohort's capital stays
    ///      in the cohort.
    function _returnToFreeSlot(uint256 id, Position storage p, uint256 j, Slice memory s, uint40 at) internal {
        uint256 slot = _firstFree(p.usedMask);
        Seal storage seal_ = _seals[id][p.sealCount];
        if (seal_.status == SealStatus.Active && seal_.cohortMask & (1 << j) != 0) {
            seal_.cohortMask |= uint32(1 << slot);
        }
        _setHead(id, p, slot, _head(at, s.amount, s.age, s.participated, 0));
        p.usedMask |= uint32(1 << slot);
    }

    /// @dev The last pending ticket resolved at `at`: the Seal resumes and its term
    ///      extends by the pause.
    function _unpauseSeal(uint256 id, Position storage p, uint40 at) internal {
        Seal storage s = _seals[id][p.sealCount];
        if (s.status != SealStatus.Active) return;
        s.pausedSeconds += uint40(at - s.pausedAt);
        s.pausedAt = 0;
        _retag(id, p, s.cohortMask, at);
        emit SealResumed(id, p.sealCount, at);
    }

    function _dropPending(uint256 id, Position storage p, uint32 ticketId, Status status) internal {
        _tickets[id][ticketId].status = status;
        uint32[MAX_PENDING_TICKETS] storage list = _pending[id];
        uint256 n = p.pendingCount;
        uint256 k;
        while (list[k] != ticketId) ++k;
        for (; k + 1 < n; ++k) list[k] = list[k + 1];
        delete list[n - 1];
        p.pendingCount = uint8(n - 1);
    }

    // ── pool occupancy ────────────────────────────────────────────────────

    /// @dev With no active principal, the earliest due lapse re-activates the pool at
    ///      its deadline. One is enough: occupancy only depends on active > 0.
    function _poolSync(uint40 now_) internal {
        if (activePrincipal != 0) return;
        (bool ok, uint256 due, uint256 key) = _lapses.peek();
        if (ok && due <= now_) {
            _setOn(uint40(due));
            _applyLapse(key);
        }
    }

    function _afterDecrease(uint40 now_) internal {
        if (activePrincipal != 0) return;
        (bool ok, uint256 due, uint256 key) = _lapses.peek();
        if (ok && due <= now_) _applyLapse(key);
        else _setOff(now_);
    }

    function _applyLapse(uint256 key) internal {
        Ticket storage t = _tickets[key >> 32][uint32(key)];
        t.poolApplied = true;
        _lapses.remove(key);
        activePrincipal += t.amount;
        frozenPrincipal -= t.amount;
    }

    function _increaseActive(uint256 amount, uint40 now_) internal {
        if (activePrincipal == 0) _setOn(now_);
        activePrincipal += amount;
    }

    function _setOn(uint40 t) internal {
        uint256 n = _occupancy.length;
        if (n != 0 && _occupancy[n - 1].on) return;
        _occupancy.push(Occupancy(t, n == 0 ? 0 : _occupancy[n - 1].cumulative, true));
    }

    function _setOff(uint40 t) internal {
        uint256 n = _occupancy.length;
        if (n == 0 || !_occupancy[n - 1].on) return;
        Occupancy memory last = _occupancy[n - 1];
        _occupancy.push(Occupancy(t, last.cumulative + (t - last.time), false));
    }

    // ── records ───────────────────────────────────────────────────────────

    /// @dev Age and participation of a head extrapolated to `t` (≥ since).
    function _lotAt(Lot memory lot, uint256 t) internal pure returns (uint256 age, uint256 part) {
        if (lot.amount == 0) return (lot.age, lot.participated);
        uint256 dt = t - lot.since;
        return (Math.min(lot.age + dt, P.HEAT_AGE_CAP), Math.min(lot.participated + dt, P.ASHFALL_MIN_PARTICIPATION));
    }

    /// @dev Replace a slot's head. The old head moves to history unless it began at
    ///      the same instant (a zero-length segment carries no measure).
    function _setHead(uint256 id, Position storage p, uint256 slot, Lot memory next) internal {
        Lot memory head = _lots[id][slot];
        uint32 bit = uint32(1 << slot);
        next.records = head.records;
        next.seal = _tag(id, p, slot);
        if (p.historyMask & bit != 0 && head.since != next.since) {
            _history[id][slot][head.records] = Record(
                head.since, head.amount, head.age, uint24(head.participated), head.seal, p.streakStart, p.ordinaryBonus
            );
            next.records = head.records + 1;
        }
        _lots[id][slot] = next;
        p.historyMask |= bit;
    }

    function _head(uint256 since, uint256 amount, uint256 age, uint256 part, uint256 heldBy)
        internal
        pure
        returns (Lot memory)
    {
        return Lot(uint40(since), amount.toUint96(), uint32(age), uint32(part), uint24(heldBy), 0, 0);
    }

    // ── Seals ─────────────────────────────────────────────────────────────

    /// @dev The tag a head written now carries: the latest Seal while it runs, for its
    ///      cohort's slots; otherwise 0.
    function _tag(uint256 id, Position storage p, uint256 slot) internal view returns (uint8) {
        uint256 k = p.sealCount;
        if (k == 0) return 0;
        Seal storage s = _seals[id][k];
        if (s.status != SealStatus.Active || s.pausedAt != 0 || s.cohortMask & (1 << slot) == 0) return 0;
        return uint8(k);
    }

    /// @dev Rewrite at `t` every active lot in `mask` whose tag is stale (a Seal starts,
    ///      pauses or resumes). Heads already written at `t` are overwritten in place.
    function _retag(uint256 id, Position storage p, uint32 mask, uint256 t) internal {
        Lot[MAX_LOTS] storage lots = _lots[id];
        for (uint256 j; j < MAX_LOTS; ++j) {
            if (mask & (1 << j) == 0) continue;
            Lot memory lot = lots[j];
            if (lot.amount == 0 || lot.seal == _tag(id, p, j)) continue;
            (uint256 age, uint256 part) = _lotAt(lot, t);
            _setHead(id, p, j, _head(t, lot.amount, age, part, lot.heldBy));
        }
    }

    /// @dev Complete (at its due time) or forfeit the running or paused Seal. No writes to
    ///      lots: measures clip every tagged segment at `endedAt`.
    function _endSeal(uint256 id, Position storage p, SealStatus status, uint256 at) internal {
        uint256 k = p.sealCount;
        Seal storage s = _seals[id][k];
        if (s.status != SealStatus.Active) return;
        if (s.pausedAt != 0) {
            s.pausedSeconds += uint40(at - s.pausedAt);
            s.pausedAt = 0;
        }
        s.status = status;
        s.endedAt = uint40(at);
        emit SealEnded(id, k, status, at);
    }

    /// @dev Checks a measure interval and clips it at an emergency exit.
    function _measurable(uint256 id, uint256 t0, uint256 t1) internal view returns (uint256) {
        if (t0 > t1) revert BadInterval(t0, t1);
        Position storage p = _positions[id];
        if (t1 > p.lastCheckpoint) revert NotSynced(id, p.lastCheckpoint);
        if (p.closedAt != 0 && p.closedAt < t1) t1 = p.closedAt;
        return t1;
    }

    // ── helpers ───────────────────────────────────────────────────────────

    /// @dev Start or continue the cooling plan, charge `amount` against its frozen
    ///      reference, and return the tier timer for the cumulative request.
    function _chargePlan(uint256 id, Position storage p, uint256 amount, uint256 active)
        internal
        returns (uint256 tierSeconds)
    {
        Plan storage plan = p.plan;
        if (plan.start == 0 || (block.timestamp >= uint256(plan.start) + P.COOLING_PLAN_HORIZON && p.pendingCount == 0)) {
            plan.start = uint40(block.timestamp);
            plan.referenceBalance = active.toUint128();
            plan.requested = 0;
        }
        uint256 requested = plan.requested + amount;
        if (requested > plan.referenceBalance) revert PlanQuotaExceeded(requested, plan.referenceBalance);
        if (p.pendingCount >= MAX_PENDING_TICKETS) revert TooManyPendingTickets(id);
        plan.requested = uint128(requested);
        return _tierSeconds(requested, plan.referenceBalance);
    }

    /// @dev Move `take` out of the lots into the ticket's slices. A lot left with an
    ///      active remainder reserves one slot for its slice to return to.
    function _freeze(uint256 id, Position storage p, uint32 ticketId, uint256[MAX_LOTS] memory take)
        internal
        returns (uint32 sliceMask)
    {
        uint256 splits;
        for (uint256 j; j < MAX_LOTS; ++j) {
            if (take[j] == 0) continue;
            if (_freezeSlot(id, p, ticketId, j, take[j])) ++splits;
            sliceMask |= uint32(1 << j);
        }
        if (_popcount(p.usedMask) + p.reservedSlots + splits > MAX_LOTS) revert LotCapacity(id);
        p.reservedSlots += uint8(splits);
    }


    /// @dev An executed ticket frees the slots its slices held or reserved.
    function _releaseSlots(uint256 id, Position storage p, uint32 ticketId, uint32 mask) internal {
        Lot[MAX_LOTS] storage lots = _lots[id];
        for (uint256 j; j < MAX_LOTS; ++j) {
            if (mask & (1 << j) == 0) continue;
            if (lots[j].heldBy == ticketId) {
                lots[j].heldBy = 0; // amount is already 0: no measure changes, no record
                p.usedMask &= ~uint32(1 << j);
            } else {
                p.reservedSlots -= 1;
            }
        }
    }

    /// @dev Scale every surviving lot's capped age, and every other pending slice's,
    ///      by the surviving fraction (balance − w) / balance.
    function _haircut(uint256 id, Position storage p, uint256 w, uint256 balance) internal {
        _rewriteActive(id, p, w, balance, type(uint256).max);
        for (uint256 k; k < p.pendingCount; ++k) {
            uint32 other = _pending[id][k];
            uint32 otherMask = _tickets[id][other].sliceMask;
            for (uint256 j; j < MAX_LOTS; ++j) {
                if (otherMask & (1 << j) == 0) continue;
                Slice storage s = _slices[id][other][j];
                s.age = uint32(_cooled(s.age, w, balance));
            }
        }
    }

    /// @dev Rewrite every active head at now with its capped age scaled by (balance − w) /
    ///      balance (w = 0: unchanged), so a change of the position's anchors starts new
    ///      record segments. Reverts at a slot holding `limit` records.
    function _rewriteActive(uint256 id, Position storage p, uint256 w, uint256 balance, uint256 limit) internal {
        for (uint256 j; j < MAX_LOTS; ++j) {
            Lot memory lot = _lots[id][j];
            if (lot.amount == 0) continue;
            if (lot.records >= limit) revert RecordLimit(id, j);
            (uint256 age, uint256 part) = _lotAt(lot, block.timestamp);
            age = _cooled(age, w, balance);
            _setHead(id, p, j, _head(block.timestamp, lot.amount, age, part, 0));
        }
    }

    /// @dev Change the position's ordinary bonus after closing every active segment at now.
    function _setBonus(uint256 id, Position storage p, uint256 units, uint256 limit) internal {
        if (units == p.ordinaryBonus) return;
        _rewriteActive(id, p, 0, 1, limit);
        p.ordinaryBonus = uint16(units);
        emit OrdinaryBonusSet(id, units);
    }

    function _anchor(Position storage p) internal view returns (uint256) {
        return ForgeMeasures.anchorOf(p.streakStart, p.ordinaryBonus);
    }

    /// @dev Freeze `take` of slot j at its current age; true if the lot keeps a remainder.
    function _freezeSlot(uint256 id, Position storage p, uint32 ticketId, uint256 j, uint256 take)
        internal
        returns (bool split)
    {
        Lot memory lot = _lots[id][j];
        (uint256 age, uint256 part) = _lotAt(lot, block.timestamp);
        _slices[id][ticketId][j] = Slice(uint128(take), uint32(age), uint32(part));
        lot.since = uint40(block.timestamp);
        lot.amount -= uint96(take);
        (lot.age, lot.participated) = (uint32(age), uint32(part));
        lot.heldBy = lot.amount == 0 ? uint24(ticketId) : 0;
        _setHead(id, p, j, lot);
        return lot.amount != 0;
    }

    /// @dev floor(a_j·amount/active) per active lot in slot order; the floor dust goes
    ///      to the first lots with room. Sums exactly to `amount` (≤ active).
    function _proRata(Lot[MAX_LOTS] storage lots, uint32 mask, uint256 amount, uint256 active)
        internal
        view
        returns (uint256[MAX_LOTS] memory take)
    {
        uint256[MAX_LOTS] memory have;
        uint256 sum;
        for (uint256 j; j < MAX_LOTS; ++j) {
            if (mask & (1 << j) == 0) continue;
            have[j] = lots[j].amount;
            take[j] = have[j] * amount / active; // < 2^96 · 2^101: exact without mulDiv
            sum += take[j];
        }
        uint256 dust = amount - sum;
        for (uint256 j; j < MAX_LOTS && dust != 0; ++j) {
            uint256 add = Math.min(dust, have[j] - take[j]);
            take[j] += add;
            dust -= add;
        }
    }

    /// @dev HeatMath.cooledAge for the pool's own operands: ages are already capped and
    ///      0 ≤ w ≤ balance < 2^130, so the product fits and plain division is exact.
    function _cooled(uint256 age, uint256 w, uint256 balance) internal pure returns (uint256) {
        return age * (balance - w) / balance;
    }

    function _activeOf(uint256 id, Position storage p) internal view returns (uint256 total) {
        uint32 mask = p.usedMask;
        for (uint256 j; j < MAX_LOTS; ++j) {
            if (mask & (1 << j) != 0) total += _lots[id][j].amount;
        }
    }

    function _frozenOf(uint256 id, Position storage p) internal view returns (uint256 total) {
        for (uint256 k; k < p.pendingCount; ++k) total += _tickets[id][_pending[id][k]].amount;
    }

    function _tierSeconds(uint256 requested, uint256 referenceBalance) internal pure returns (uint256) {
        for (uint256 i; i < P.WITHDRAW_TIER_COUNT; ++i) {
            (uint256 maxPct, uint256 seconds_) = _tier(i);
            if (requested * 100 <= referenceBalance * maxPct) return seconds_;
        }
        return P.WITHDRAW_TIER_4_SECONDS; // unreachable: the last tier covers 100%
    }

    function _tier(uint256 i) internal pure returns (uint256 maxPct, uint256 seconds_) {
        if (i == 0) return (P.WITHDRAW_TIER_0_MAX_PCT, P.WITHDRAW_TIER_0_SECONDS);
        if (i == 1) return (P.WITHDRAW_TIER_1_MAX_PCT, P.WITHDRAW_TIER_1_SECONDS);
        if (i == 2) return (P.WITHDRAW_TIER_2_MAX_PCT, P.WITHDRAW_TIER_2_SECONDS);
        if (i == 3) return (P.WITHDRAW_TIER_3_MAX_PCT, P.WITHDRAW_TIER_3_SECONDS);
        return (P.WITHDRAW_TIER_4_MAX_PCT, P.WITHDRAW_TIER_4_SECONDS);
    }

    function _deadline(Ticket storage t) internal view returns (uint256) {
        return uint256(t.maturity) + P.WITHDRAW_EXECUTION_WINDOW;
    }

    function _key(uint256 id, uint32 ticketId) internal pure returns (uint256) {
        return (id << 32) | ticketId;
    }

    function _firstFree(uint32 mask) internal pure returns (uint256 slot) {
        while (mask & (1 << slot) != 0) ++slot;
    }

    function _popcount(uint32 x) internal pure returns (uint256 n) {
        while (x != 0) {
            x &= x - 1;
            ++n;
        }
    }
}
