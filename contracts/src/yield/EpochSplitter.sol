// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";
import {ForgePool} from "../forge/ForgePool.sol";
import {ForgeView} from "../forge/ForgeView.sol";
import {ForgeEmissions} from "../forge/ForgeEmissions.sol";

/// @notice What a splitter reads of ForgeEmissions: its clock, its pools, each settled pool
///         epoch's totals and each position's measures in it.
interface IEpochMeasures {
    function START() external view returns (uint256);
    function poolAt(uint256 i) external view returns (ForgePool);
    function poolEpoch(uint256 epoch, uint256 pool) external view returns (ForgeEmissions.PoolEpoch memory);
    function measureOf(uint256 epoch, uint256 pool, uint256 id) external view returns (ForgeEmissions.Measure memory);
}

/// @title EpochSplitter: a funded budget paid by a settled epoch's measures (ADR 0024)
/// @notice The shape shared by ForgeAsh, the stayers' share, Quote yield and the Sealed pot.
///         Funds are assigned to an (epoch, pool, token) budget. Once ForgeEmissions has
///         settled that pool's epoch (phase Done), each position measured in it may claim
///         `floor(budget · its measure / the pool's total)`, once, paid to the position's owner.
///         The measures are ForgeEmissions' own, so nothing here re-measures a lot.
///
///         - `Stake`: stake-seconds S. `Ordinary`: the base's shape, 30% by S and 70% by Heat W.
///           `Ashfall`: the Heat² weight Q of eligible lots. `Conviction`: the Seal measure C.
///         - An epoch whose pool total is zero pays nobody; `roll` passes its budget to the next.
///         - A listed position's share waits for the sale, as its base rewards do (ADR 0011).
///         - The floors' dust stays here. Nothing is ever redirected.
///         No admin, no pause, no upgrade. Not audited.
abstract contract EpochSplitter is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using ForgeView for ForgePool;

    enum Measure {
        Stake,
        Ordinary,
        Ashfall,
        Conviction
    }

    uint256 internal constant POOLS = 4;

    IEpochMeasures public immutable EMISSIONS;
    Measure public immutable MEASURE;

    /// @notice Budget assigned to (epoch, pool, token) here: bookings, streams and rolls in.
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) public assigned;
    mapping(uint256 => mapping(uint256 => mapping(address => uint256))) public paidOut;
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) public rolled;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => mapping(address => bool)))) public claimed;
    /// @notice What is owed in each token: assigned and not yet paid (rolls move it, never add).
    mapping(address => uint256) public liability;

    event Assigned(uint256 indexed epoch, uint256 indexed pool, address indexed token, uint256 amount);
    event Claimed(uint256 indexed epoch, uint256 indexed pool, uint256 indexed id, address token, address to, uint256 amount);
    event Rolled(uint256 indexed epoch, uint256 indexed pool, address indexed token, uint256 amount);

    error ZeroAddress();
    error NotSettled(uint256 epoch, uint256 pool);
    error NotEmpty(uint256 epoch, uint256 pool);
    error AlreadyRolled(uint256 epoch, uint256 pool, address token);
    error Listed(uint256 pool, uint256 id);
    error NothingOwed(uint256 epoch, uint256 pool, uint256 id, address token);

    constructor(IEpochMeasures emissions, Measure measure) {
        if (address(emissions) == address(0)) revert ZeroAddress();
        (EMISSIONS, MEASURE) = (emissions, measure);
    }

    // ── claims ────────────────────────────────────────────────────────────

    /// @notice Pay position `id` of pool `pool` its share of the epoch's `token` budget.
    ///         Permissionless; the share only ever goes to the position's owner.
    function claim(uint256 epoch, uint256 pool, uint256 id, address token)
        external
        nonReentrant
        returns (uint256 amount)
    {
        amount = _claim(epoch, pool, id, token);
        if (amount == 0) revert NothingOwed(epoch, pool, id, token);
    }

    /// @notice `claim` over a caller-sized list of epochs; nothing owed is skipped.
    function claimMany(uint256[] calldata epochs, uint256 pool, uint256 id, address token)
        external
        nonReentrant
        returns (uint256 total)
    {
        for (uint256 k; k < epochs.length; ++k) total += _claim(epochs[k], pool, id, token);
    }

    /// @notice Permissionless: an epoch whose pool total is zero passes its budget on.
    function roll(uint256 epoch, uint256 pool, address token) external nonReentrant returns (uint256 amount) {
        ForgeEmissions.PoolEpoch memory pe = _settled(epoch, pool);
        if (_total(pe) != 0) revert NotEmpty(epoch, pool);
        if (rolled[epoch][pool][token]) revert AlreadyRolled(epoch, pool, token);
        rolled[epoch][pool][token] = true;
        amount = budgetOf(epoch, pool, token);
        assigned[epoch + 1][pool][token] += amount;
        emit Rolled(epoch, pool, token, amount);
    }

    // ── views ─────────────────────────────────────────────────────────────

    /// @notice The (epoch, pool, token) budget. ForgeAsh adds its vested slice.
    function budgetOf(uint256 epoch, uint256 pool, address token) public view virtual returns (uint256) {
        return assigned[epoch][pool][token];
    }

    /// @notice What `id` could claim now (zero before settlement, after a claim or a roll).
    function shareOf(uint256 epoch, uint256 pool, uint256 id, address token) external view returns (uint256) {
        if (pool >= POOLS || claimed[epoch][pool][id][token] || rolled[epoch][pool][token]) return 0;
        ForgeEmissions.PoolEpoch memory pe = EMISSIONS.poolEpoch(epoch, pool);
        if (pe.phase != ForgeEmissions.Phase.Done) return 0;
        return _amount(pe, EMISSIONS.measureOf(epoch, pool, id), budgetOf(epoch, pool, token));
    }

    /// @notice The epoch containing `t`, on ForgeEmissions' clock (epoch 0 before START).
    function epochAt(uint256 t) public view returns (uint256) {
        uint256 start = EMISSIONS.START();
        return t <= start ? 0 : (t - start) / P.EPOCH_SECONDS;
    }

    // ── internals ─────────────────────────────────────────────────────────

    function _claim(uint256 epoch, uint256 pool, uint256 id, address token) internal returns (uint256 amount) {
        ForgeEmissions.PoolEpoch memory pe = _settled(epoch, pool);
        if (claimed[epoch][pool][id][token] || rolled[epoch][pool][token]) return 0;
        (address owner,,, uint256 listing,) = EMISSIONS.poolAt(pool).briefOf(id);
        if (listing & 1 != 0) revert Listed(pool, id);
        amount = _amount(pe, EMISSIONS.measureOf(epoch, pool, id), budgetOf(epoch, pool, token));
        if (amount == 0) return 0;
        claimed[epoch][pool][id][token] = true;
        paidOut[epoch][pool][token] += amount;
        _debit(token, amount);
        _pay(token, owner, amount);
        emit Claimed(epoch, pool, id, token, owner, amount);
    }

    function _settled(uint256 epoch, uint256 pool) internal view returns (ForgeEmissions.PoolEpoch memory pe) {
        EMISSIONS.poolAt(pool);
        pe = EMISSIONS.poolEpoch(epoch, pool);
        if (pe.phase != ForgeEmissions.Phase.Done) revert NotSettled(epoch, pool);
    }

    /// @dev The pool's total under this splitter's measure; zero means nobody can be paid.
    function _total(ForgeEmissions.PoolEpoch memory pe) internal view returns (uint256) {
        if (MEASURE == Measure.Stake || MEASURE == Measure.Ordinary) return pe.stakeSeconds;
        if (MEASURE == Measure.Ashfall) return pe.ashfallWeight;
        return pe.candidateSeconds;
    }

    function _amount(ForgeEmissions.PoolEpoch memory pe, ForgeEmissions.Measure memory m, uint256 budget)
        internal
        view
        returns (uint256)
    {
        if (budget == 0) return 0;
        if (MEASURE == Measure.Stake) return pe.stakeSeconds == 0 ? 0 : (budget * m.stakeSeconds) / pe.stakeSeconds;
        if (MEASURE == Measure.Ashfall) {
            return pe.ashfallWeight == 0 ? 0 : (budget * m.ashfallWeight) / pe.ashfallWeight;
        }
        if (MEASURE == Measure.Conviction) {
            return pe.candidateSeconds == 0 ? 0 : (budget * m.candidateSeconds) / pe.candidateSeconds;
        }
        // Ordinary: the base's own shape, flat by S and heat by W [P].
        if (pe.stakeSeconds == 0) return 0;
        uint256 flat = (budget * P.SPLIT_FLAT_PCT) / 100;
        uint256 out = (flat * m.stakeSeconds) / pe.stakeSeconds;
        if (pe.heatSeconds != 0) out += ((budget - flat) * m.heatSeconds) / pe.heatSeconds;
        return out;
    }

    /// @dev Assign `amount` of `token` to (epoch, pool) and owe it.
    function _assign(uint256 epoch, uint256 pool, address token, uint256 amount) internal {
        if (amount == 0) return;
        assigned[epoch][pool][token] += amount;
        liability[token] += amount;
        emit Assigned(epoch, pool, token, amount);
    }

    /// @dev Split `amount` of `token` over the pools by `points`, the floor's remainder to pool 0.
    function _assignByPoints(uint256 epoch, address token, uint256 amount, uint256[4] memory points, uint256 total)
        internal
    {
        uint256 rest = amount;
        for (uint256 i = 1; i < POOLS; ++i) {
            uint256 share = (amount * points[i]) / total;
            rest -= share;
            _assign(epoch, i, token, share);
        }
        _assign(epoch, 0, token, rest);
    }

    function _debit(address token, uint256 amount) internal virtual {
        liability[token] -= amount;
    }

    function _pay(address token, address to, uint256 amount) internal virtual {
        IERC20(token).safeTransfer(to, amount);
    }
}
