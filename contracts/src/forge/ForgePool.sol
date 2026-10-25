// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";
import {HeatMath} from "../libraries/HeatMath.sol";
import {LapseHeap} from "./LapseHeap.sol";

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
///         Measures: per position, S = ∫stake dt and W = ∫stake·Heat dt over active
///         lots, exact (HeatMath.integrateHeat telescopes), for epoch settlement.
///         Pool occupancy (time with active principal) is an append-only log.
contract ForgePool is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using LapseHeap for LapseHeap.Heap;

    /// @dev Literal so it can size storage arrays; uint32 slot masks need exactly 32.
    ///      The constructor checks it against the generated config value.
    uint256 internal constant MAX_LOTS = 32;
    /// @notice [P] Concurrent cooling tickets per position (not in the canonical config).
    uint256 public constant MAX_PENDING_TICKETS = 8;

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

    /// @dev `heldBy` is the ticket that froze the lot's entire active amount; the slot
    ///      stays reserved for that ticket's slice to return to.
    struct Lot {
        uint128 amount;
        uint32 age;
        uint32 participated;
        uint32 heldBy;
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
        uint8 reservedSlots;
        uint8 pendingCount;
        uint32 usedMask; // slot j in use ⇔ amount > 0 or heldBy != 0
        uint32 nextTicketId;
        uint64 coolingPausedSeconds;
        bool closed;
        bool ashfallForfeited;
        Plan plan;
        uint256 stakeSeconds;
        uint256 heatSeconds;
    }

    struct Occupancy {
        uint40 time;
        uint64 cumulative;
        bool on;
    }

    IERC20 public immutable STAKE_TOKEN;
    bool public immutable IS_LP;
    address public immutable FEE_COLLECTOR;

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
    mapping(uint256 id => uint32[MAX_PENDING_TICKETS]) internal _pending;
    mapping(uint256 id => mapping(uint32 ticketId => Ticket)) internal _tickets;
    mapping(uint256 id => mapping(uint32 ticketId => mapping(uint256 slot => Slice))) internal _slices;

    event Opened(uint256 indexed id, address indexed owner);
    event Deposited(uint256 indexed id, uint256 slot, uint256 net, uint256 fee);
    event CoolingRequested(uint256 indexed id, uint32 indexed ticketId, uint256 amount, uint256 maturity);
    event WithdrawalExecuted(uint256 indexed id, uint32 indexed ticketId, uint256 net, uint256 fee);
    event CoolingResumed(uint256 indexed id, uint32 indexed ticketId, Status status, uint256 at);
    event EmergencyExited(uint256 indexed id, uint256 net, uint256 fee);
    event FeesCollected(uint256 deposit, uint256 withdraw, uint256 emergency);

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

    constructor(IERC20 stakeToken, bool isLp, address feeCollector) {
        if (address(stakeToken) == address(0) || feeCollector == address(0)) revert ZeroAddress();
        if (P.MAX_LOTS_PER_POSITION != MAX_LOTS || P.WITHDRAW_TIER_COUNT != 5) revert ConfigMismatch();
        STAKE_TOKEN = stakeToken;
        IS_LP = isLp;
        FEE_COLLECTOR = feeCollector;
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
        emit Opened(id, msg.sender);
        _addLot(id, p, _pull(amount), now_);
    }

    /// @notice Add a new lot (age 0) to an open position.
    function deposit(uint256 id, uint256 amount) external nonReentrant {
        Position storage p = _touchOwned(id);
        if (p.closed) revert Closed(id);
        _addLot(id, p, _pull(amount), uint40(block.timestamp));
    }

    /// @notice Freeze `amount` pro-rata across the active lots and start its timer.
    ///         The tier follows the plan's cumulative request against its frozen
    ///         reference, so splitting a large exit cannot buy short timers.
    function requestCooling(uint256 id, uint256 amount) external nonReentrant returns (uint32 ticketId) {
        Position storage p = _touchOwned(id);
        if (p.closed) revert Closed(id);
        if (amount == 0) revert ZeroAmount();
        uint256 active = _activeOf(id, p);
        if (amount > active) revert ExceedsActive(amount, active);
        uint256 maturity = block.timestamp + _chargePlan(id, p, amount, active);

        ticketId = ++p.nextTicketId;
        uint32 sliceMask = _freeze(id, p, ticketId, _proRata(_lots[id], p.usedMask, amount, active));
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

        Lot[MAX_LOTS] storage lots = _lots[id];
        uint32 mask = t.sliceMask;
        for (uint256 j; j < MAX_LOTS; ++j) {
            if (mask & (1 << j) == 0) continue;
            if (lots[j].heldBy == ticketId) {
                lots[j].heldBy = 0;
                p.usedMask &= ~uint32(1 << j);
            } else {
                p.reservedSlots -= 1;
            }
        }
        _dropPending(id, p, ticketId, Status.Executed);

        for (uint256 j; j < MAX_LOTS; ++j) {
            if (lots[j].amount != 0) lots[j].age = uint32(HeatMath.cooledAge(lots[j].age, w, balance));
        }
        for (uint256 k; k < p.pendingCount; ++k) {
            uint32 other = _pending[id][k];
            uint32 otherMask = _tickets[id][other].sliceMask;
            for (uint256 j; j < MAX_LOTS; ++j) {
                if (otherMask & (1 << j) == 0) continue;
                Slice storage s = _slices[id][other][j];
                s.age = uint32(HeatMath.cooledAge(s.age, w, balance));
            }
        }
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
        _resume(id, p, ticketId, Status.Cancelled, uint40(block.timestamp));
    }

    /// @notice Leave immediately with all principal, active and frozen, in kind.
    ///         8% fee (routed 50/25/25 later by the fee router); pending Ashfall is
    ///         forfeited. Closes the position; its measures remain.
    function emergencyExit(uint256 id) external nonReentrant returns (uint256 net) {
        Position storage p = _touchOwned(id);
        if (p.closed) revert Closed(id);
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
        Lot[MAX_LOTS] storage lots = _lots[id];
        for (uint256 j; j < MAX_LOTS; ++j) {
            if (p.usedMask & (1 << j) != 0) delete lots[j];
        }
        p.usedMask = 0;
        p.reservedSlots = 0;
        p.closed = true;
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

    /// @notice Bring a position up to date (lapses, measures). Permissionless; also
    ///         the exact read path: eth_call it for current S and W.
    function poke(uint256 id) external nonReentrant returns (uint256 stakeSeconds, uint256 heatSeconds) {
        Position storage p = _touch(id);
        return (p.stakeSeconds, p.heatSeconds);
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

    function lotOf(uint256 id, uint256 slot) external view returns (Lot memory) {
        return _lots[id][slot];
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

    function _addLot(uint256 id, Position storage p, uint256 amount, uint40 now_) internal {
        uint256 fee = (amount * P.FORGE_DEPOSIT_FEE_PCT) / 100;
        uint256 net = amount - fee;
        if (IS_LP ? net < P.MIN_STAKE_LP : net == 0) revert BelowMinimum(net);
        if (_popcount(p.usedMask) + p.reservedSlots >= MAX_LOTS) revert LotCapacity(id);
        uint256 slot = _firstFree(p.usedMask);
        _lots[id][slot] = Lot(net.toUint128(), 0, 0, 0);
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

    /// @dev Resolve every lapse due by `now_` in deadline order, accruing exactly up to
    ///      each deadline first, then accrue to `now_`.
    function _sync(uint256 id, Position storage p, uint40 now_) internal {
        while (true) {
            (uint32 due, uint256 dueAt) = _earliestDue(id, p, now_);
            if (due == 0) break;
            _accrue(id, p, uint40(dueAt));
            _resume(id, p, due, Status.Lapsed, now_);
        }
        _accrue(id, p, now_);
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

    function _accrue(uint256 id, Position storage p, uint40 t) internal {
        uint256 dt = t - p.lastCheckpoint;
        if (dt == 0) return;
        Lot[MAX_LOTS] storage lots = _lots[id];
        uint32 mask = p.usedMask;
        uint256 s;
        uint256 w;
        for (uint256 j; j < MAX_LOTS; ++j) {
            if (mask & (1 << j) == 0) continue;
            Lot memory lot = lots[j];
            if (lot.amount == 0) continue;
            s += uint256(lot.amount) * dt;
            w += uint256(lot.amount) * HeatMath.integrateHeat(lot.age, dt, 0);
            lots[j].age = uint32(Math.min(lot.age + dt, P.HEAT_AGE_CAP));
            lots[j].participated = uint32(Math.min(lot.participated + dt, P.ASHFALL_MIN_PARTICIPATION));
        }
        p.stakeSeconds += s;
        p.heatSeconds += w;
        if (p.pendingCount != 0) p.coolingPausedSeconds += uint64(dt);
        p.lastCheckpoint = t;
    }

    /// @dev Return a ticket's slices. A slice that emptied its lot goes back to that
    ///      slot; any other uses its reserved slot unless the parent's financial state
    ///      is identical (then sharing storage is exact).
    function _resume(uint256 id, Position storage p, uint32 ticketId, Status status, uint40 now_) internal {
        Ticket storage t = _tickets[id][ticketId];
        Lot[MAX_LOTS] storage lots = _lots[id];
        uint32 mask = t.sliceMask;
        for (uint256 j; j < MAX_LOTS; ++j) {
            if (mask & (1 << j) == 0) continue;
            Slice memory s = _slices[id][ticketId][j];
            Lot storage lot = lots[j];
            if (lot.heldBy == ticketId) {
                lots[j] = Lot(s.amount, s.age, s.participated, 0);
            } else {
                if (lot.amount != 0 && lot.age == s.age && lot.participated == s.participated) {
                    lot.amount += s.amount;
                } else {
                    uint256 slot = _firstFree(p.usedMask);
                    lots[slot] = Lot(s.amount, s.age, s.participated, 0);
                    p.usedMask |= uint32(1 << slot);
                }
                p.reservedSlots -= 1;
            }
        }
        _dropPending(id, p, ticketId, status);
        if (!t.poolApplied) {
            _lapses.remove(_key(id, ticketId));
            frozenPrincipal -= t.amount;
            _increaseActive(t.amount, now_);
        }
        emit CoolingResumed(id, ticketId, status, status == Status.Lapsed ? _deadline(t) : now_);
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
        Lot[MAX_LOTS] storage lots = _lots[id];
        uint256 splits;
        for (uint256 j; j < MAX_LOTS; ++j) {
            if (take[j] == 0) continue;
            Lot storage lot = lots[j];
            _slices[id][ticketId][j] = Slice(uint128(take[j]), lot.age, lot.participated);
            lot.amount -= uint128(take[j]);
            if (lot.amount == 0) lot.heldBy = ticketId;
            else ++splits;
            sliceMask |= uint32(1 << j);
        }
        if (_popcount(p.usedMask) + p.reservedSlots + splits > MAX_LOTS) revert LotCapacity(id);
        p.reservedSlots += uint8(splits);
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
            take[j] = Math.mulDiv(have[j], amount, active);
            sum += take[j];
        }
        uint256 dust = amount - sum;
        for (uint256 j; j < MAX_LOTS && dust != 0; ++j) {
            uint256 add = Math.min(dust, have[j] - take[j]);
            take[j] += add;
            dust -= add;
        }
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
