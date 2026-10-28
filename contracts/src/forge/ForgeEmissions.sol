// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";
import {EmissionMath} from "../libraries/EmissionMath.sol";
import {ForgePool} from "./ForgePool.sol";

/// @notice The Mantle surface the distributor uses.
interface IMantleDistribution {
    function START() external view returns (uint256);
    function nextEpoch() external view returns (uint256);
    function budgets(uint256 epoch)
        external
        view
        returns (
            uint128 base,
            uint128 ashfall,
            uint128 baseMinted,
            uint128 ashfallMinted,
            uint128 baseReleased,
            uint128 ashfallRolled
        );
    function mintBase(uint256 epoch, address to, uint256 amount) external;
    function releaseBase(uint256 epoch, uint256 amount) external;
}

/// @title ForgeEmissions
/// @notice The Mantle's distributor and the Forge's index of its four pools (ADR 0005).
///         Each epoch, in order and permissionlessly:
///         1. `openEpoch` splits the Mantle's global base by pool weight and admits each
///            pool's share only for the time it held active principal
///            (`accruedPoolBudget`); everything not admitted is released, never re-issued.
///         2. `advance` pages through the pool's positions: it syncs each one and reads
///            its exact epoch measures from the pool's checkpoint records. A page visits
///            at most 32 lots and SEGMENTS_PER_PAGE record segments and resumes where the
///            last one stopped, so no position can make a page unboundedly expensive. A
///            monotone cursor visits every position exactly once.
///         3. When the totals are final, the Conviction bucket is reserved and, with no
///            Seals yet, returned whole to the Heat budget (the canonical 27/73 split).
///         4. `advance` then credits each earning position
///            ⌊flat·S_i/S⌋ + ⌊heat·W_i/W⌋, minting each page's sum once; the floor residue
///            is released.
///         Claims: a fee-free 24h click-start snapshot of a position's credited rewards.
///         Principal exits never wait on any of this. No owner, no pause, no upgrade.
contract ForgeEmissions is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 public constant POOL_COUNT = 4;
    /// @notice [P] Record segments one measure page may examine (≈8k gas each). With the
    ///         spec's ≤32 lots per page, this bounds every page however many records a
    ///         position has: a position larger than one page resumes on the next.
    uint256 public constant SEGMENTS_PER_PAGE = 256;

    enum Phase {
        None,
        Measuring,
        Crediting,
        Done
    }

    struct PoolEpoch {
        Phase phase;
        uint32 positions; // N: the pool's position count when the epoch opened
        uint32 cursor; // positions measured
        uint32 credited; // earners credited
        uint128 target; // the pool's weighted share of the base
        uint128 admitted; // E = accruedPoolBudget(target, occupied, epoch)
        uint128 flat; // ⌊(E − bucket)·30%⌋
        uint128 heat; // E − bucket − flat + unused bucket
        uint128 paid; // Σ credited payouts (all minted)
        uint256 stakeSeconds; // S = Σ S_i
        uint256 heatSeconds; // W = Σ W_i
    }

    struct Measure {
        uint256 stakeSeconds;
        uint256 heatSeconds;
    }

    struct Claim {
        uint128 amount;
        uint40 maturesAt;
    }

    /// @dev A position measured across pages: where to resume and what is summed so far.
    struct Progress {
        uint32 id; // 0 = between positions
        uint8 slot;
        uint32 seg; // 1-based resume segment within `slot` (0 = from the start)
        uint256 stakeSeconds;
        uint256 heatSeconds;
    }

    IMantleDistribution public immutable MANTLE;
    IERC20 public immutable EMBER;
    uint256 public immutable START;
    ForgePool internal immutable POOL_0;
    ForgePool internal immutable POOL_1;
    ForgePool internal immutable POOL_2;
    ForgePool internal immutable POOL_3;

    uint256 public nextEpoch;
    mapping(uint256 epoch => mapping(uint256 pool => PoolEpoch)) internal _epochs;
    mapping(uint256 epoch => mapping(uint256 pool => uint256[])) internal _earners;
    mapping(uint256 epoch => mapping(uint256 pool => mapping(uint256 id => Measure))) internal _measures;
    mapping(uint256 epoch => mapping(uint256 pool => Progress)) internal _progress;
    mapping(uint256 pool => mapping(uint256 id => uint256)) public unclaimed;
    mapping(uint256 pool => mapping(uint256 id => Claim)) internal _claims;

    event EpochOpened(uint256 indexed epoch, uint256 base, uint256 released);
    event PoolEpochOpened(uint256 indexed epoch, uint256 indexed pool, uint256 target, uint256 admitted, uint256 positions);
    event Measured(uint256 indexed epoch, uint256 indexed pool, uint256 id, uint256 stakeSeconds, uint256 heatSeconds);
    event Budgeted(uint256 indexed epoch, uint256 indexed pool, uint256 flat, uint256 heat, uint256 unusedBucket);
    event Credited(uint256 indexed epoch, uint256 indexed pool, uint256 id, uint256 amount);
    event ResidueReleased(uint256 indexed epoch, uint256 indexed pool, uint256 amount);
    event ClaimRequested(uint256 indexed pool, uint256 indexed id, uint256 amount, uint256 maturesAt);
    event ClaimPaid(uint256 indexed pool, uint256 indexed id, address to, uint256 amount);

    error ZeroAddress();
    error PoolMismatch(uint256 pool);
    error NotNextEpoch(uint256 epoch, uint256 expected);
    error EpochNotFinalized(uint256 epoch);
    error NothingToAdvance(uint256 epoch, uint256 pool);
    error UnknownPool(uint256 pool);
    error NotOwner(uint256 pool, uint256 id);
    error ClaimPending(uint256 pool, uint256 id);
    error NothingToClaim(uint256 pool, uint256 id);
    error ClaimNotMatured(uint256 maturesAt);

    constructor(IMantleDistribution mantle, IERC20 ember, ForgePool[4] memory pools) {
        if (address(mantle) == address(0) || address(ember) == address(0)) revert ZeroAddress();
        bool[4] memory isLp = [P.FORGE_POOL_0_IS_LP, P.FORGE_POOL_1_IS_LP, P.FORGE_POOL_2_IS_LP, P.FORGE_POOL_3_IS_LP];
        for (uint256 i; i < POOL_COUNT; ++i) {
            if (address(pools[i]) == address(0)) revert ZeroAddress();
            if (pools[i].IS_LP() != isLp[i]) revert PoolMismatch(i);
        }
        MANTLE = mantle;
        EMBER = ember;
        START = mantle.START();
        (POOL_0, POOL_1, POOL_2, POOL_3) = (pools[0], pools[1], pools[2], pools[3]);
    }

    // ── settlement ────────────────────────────────────────────────────────

    /// @notice Open the next epoch once the Mantle has finalized it: split the global
    ///         base by pool weight, admit each share for its pool's occupied time, and
    ///         release the rest.
    function openEpoch() external nonReentrant returns (uint256 epoch) {
        epoch = nextEpoch;
        if (MANTLE.nextEpoch() <= epoch) revert EpochNotFinalized(epoch);
        (uint128 base,,,,,) = MANTLE.budgets(epoch);
        (uint256 start, uint256 end) = epochBounds(epoch);
        uint256 released = base;
        for (uint256 i; i < POOL_COUNT; ++i) {
            ForgePool pool = poolAt(i);
            uint256 target = Math.mulDiv(base, allocPoints(i), P.FORGE_ALLOC_POINTS_TOTAL);
            uint256 occupied = pool.occupiedSecondsAt(end) - pool.occupiedSecondsAt(start);
            uint256 admitted = EmissionMath.accruedPoolBudget(target, occupied, P.EPOCH_SECONDS);
            released -= admitted;
            PoolEpoch storage pe = _epochs[epoch][i];
            pe.target = uint128(target);
            pe.admitted = uint128(admitted);
            pe.positions = uint32(pool.positionCount());
            pe.phase = admitted == 0 ? Phase.Done : Phase.Measuring;
            emit PoolEpochOpened(epoch, i, target, admitted, pe.positions);
        }
        nextEpoch = epoch + 1;
        if (released != 0) MANTLE.releaseBase(epoch, released);
        emit EpochOpened(epoch, base, released);
    }

    /// @notice One bounded page of whichever phase the pool-epoch is in. Anyone may call.
    function advance(uint256 epoch, uint256 pool) external nonReentrant {
        PoolEpoch storage pe = _epochs[epoch][pool];
        if (pe.phase == Phase.Measuring) _measurePage(epoch, pool, pe);
        else if (pe.phase == Phase.Crediting) _creditPage(epoch, pool, pe);
        else revert NothingToAdvance(epoch, pool);
    }

    /// @dev Visits at most 32 lot slots and SEGMENTS_PER_PAGE record segments, resuming
    ///      mid-position (even mid-slot) where the previous page stopped. Records are
    ///      append-only and every lapse due by the epoch end is resolved when a position
    ///      is first entered, so resuming later reads exactly the same segments.
    function _measurePage(uint256 epoch, uint256 i, PoolEpoch storage pe) internal {
        ForgePool pool = poolAt(i);
        Progress memory pr = _progress[epoch][i]; // worked in memory, stored once per page
        bool wasStored = pr.id != 0;
        uint256 budget = SEGMENTS_PER_PAGE;
        uint256 slots;
        while (budget != 0) {
            if (pr.id == 0) {
                if (pe.cursor == pe.positions || slots == P.SETTLEMENT_MAX_LOTS_PER_PAGE) break;
                uint256 next = pe.cursor + 1;
                pool.poke(next); // resolve lapses due by now: their records are back-dated
                pr.id = uint32(next);
            }
            uint32 mask = pool.historyMaskOf(pr.id);
            uint256 j = pr.slot;
            while (j < 32 && mask & (1 << j) == 0) ++j;
            if (j == 32) {
                _finishPosition(epoch, i, pe, pr);
                pr = Progress(0, 0, 0, 0, 0);
                --budget;
                continue;
            }
            if (slots == P.SETTLEMENT_MAX_LOTS_PER_PAGE) break;
            ++slots;
            budget -= _measureSlot(epoch, pool, pr, j, budget);
        }
        if (pr.id != 0) _progress[epoch][i] = pr;
        else if (wasStored) delete _progress[epoch][i];
        if (pr.id == 0 && pe.cursor == pe.positions) _budget(epoch, i, pe);
    }

    function _measureSlot(uint256 epoch, ForgePool pool, Progress memory pr, uint256 j, uint256 budget)
        internal
        view
        returns (uint256 used)
    {
        uint256 next;
        bool done;
        {
            uint256 start = START + epoch * P.EPOCH_SECONDS;
            uint256 s;
            uint256 w;
            (s, w, next, used, done) = pool.measureSlot(pr.id, j, start, start + P.EPOCH_SECONDS, pr.seg, budget);
            pr.stakeSeconds += s;
            pr.heatSeconds += w;
        }
        if (done) {
            pr.slot = uint8(j + 1);
            pr.seg = 0;
        } else {
            pr.slot = uint8(j);
            pr.seg = uint32(next);
        }
    }

    function _finishPosition(uint256 epoch, uint256 i, PoolEpoch storage pe, Progress memory pr) internal {
        (uint256 id, uint256 s, uint256 w) = (pr.id, pr.stakeSeconds, pr.heatSeconds);
        if (s != 0) {
            _measures[epoch][i][id] = Measure(s, w);
            _earners[epoch][i].push(id);
            pe.stakeSeconds += s;
            pe.heatSeconds += w;
            emit Measured(epoch, i, id, s, w);
        }
        pe.cursor += 1;
    }

    /// @dev Totals are final: reserve the Conviction bucket, split the rest 30/70, and
    ///      return the unused bucket to Heat. Seals will set escrow here; until then the
    ///      whole bucket is unused (spec §10: "With no eligible Seals it yields 27/73").
    function _budget(uint256 epoch, uint256 i, PoolEpoch storage pe) internal {
        uint256 e = pe.admitted;
        if (pe.stakeSeconds == 0) {
            pe.phase = Phase.Done;
            MANTLE.releaseBase(epoch, e);
            emit ResidueReleased(epoch, i, e);
            return;
        }
        uint256 bucket = (e * P.CONVICTION_BUCKET_PCT) / 100;
        uint256 flat = ((e - bucket) * P.SPLIT_FLAT_PCT) / 100;
        uint256 escrow; // Σ capped Seal escrow: none until Seals exist
        uint256 heat = e - bucket - flat + (bucket - escrow);
        pe.flat = uint128(flat);
        pe.heat = uint128(heat);
        pe.phase = Phase.Crediting;
        emit Budgeted(epoch, i, flat, heat, bucket - escrow);
    }

    function _creditPage(uint256 epoch, uint256 i, PoolEpoch storage pe) internal {
        uint256[] storage earners = _earners[epoch][i];
        uint256 k = pe.credited;
        uint256 end = Math.min(earners.length, k + P.SETTLEMENT_MAX_LOTS_PER_PAGE);
        uint256 sum;
        for (; k < end; ++k) {
            uint256 id = earners[k];
            Measure storage m = _measures[epoch][i][id];
            uint256 amount = Math.mulDiv(pe.flat, m.stakeSeconds, pe.stakeSeconds)
                + Math.mulDiv(pe.heat, m.heatSeconds, pe.heatSeconds);
            unclaimed[i][id] += amount;
            sum += amount;
            emit Credited(epoch, i, id, amount);
        }
        pe.credited = uint32(k);
        pe.paid += uint128(sum);
        if (sum != 0) MANTLE.mintBase(epoch, address(this), sum);
        if (k == earners.length) {
            pe.phase = Phase.Done;
            uint256 residue = pe.admitted - pe.paid;
            if (residue != 0) {
                MANTLE.releaseBase(epoch, residue);
                emit ResidueReleased(epoch, i, residue);
            }
        }
    }

    // ── claims ────────────────────────────────────────────────────────────

    /// @notice Snapshot the position's credited rewards and start the 24h timer.
    ///         Rewards credited later are not added to this claim.
    function requestClaim(uint256 pool, uint256 id) external nonReentrant returns (uint256 amount) {
        _onlyOwner(pool, id);
        Claim storage c = _claims[pool][id];
        if (c.amount != 0) revert ClaimPending(pool, id);
        amount = unclaimed[pool][id];
        if (amount == 0) revert NothingToClaim(pool, id);
        unclaimed[pool][id] = 0;
        uint256 maturesAt = block.timestamp + P.CLAIM_SECONDS;
        (c.amount, c.maturesAt) = (uint128(amount), uint40(maturesAt));
        emit ClaimRequested(pool, id, amount, maturesAt);
    }

    /// @notice Pay a matured claim to the position's owner. No fee.
    function executeClaim(uint256 pool, uint256 id) external nonReentrant returns (uint256 amount) {
        address owner = _onlyOwner(pool, id);
        Claim memory c = _claims[pool][id];
        if (c.amount == 0) revert NothingToClaim(pool, id);
        if (block.timestamp < c.maturesAt) revert ClaimNotMatured(c.maturesAt);
        delete _claims[pool][id];
        amount = c.amount;
        emit ClaimPaid(pool, id, owner, amount);
        EMBER.safeTransfer(owner, amount);
    }

    // ── views ─────────────────────────────────────────────────────────────

    function poolAt(uint256 i) public view returns (ForgePool) {
        if (i == 0) return POOL_0;
        if (i == 1) return POOL_1;
        if (i == 2) return POOL_2;
        if (i == 3) return POOL_3;
        revert UnknownPool(i);
    }

    function allocPoints(uint256 i) public pure returns (uint256) {
        if (i == 0) return P.FORGE_POOL_0_ALLOC_POINTS;
        if (i == 1) return P.FORGE_POOL_1_ALLOC_POINTS;
        if (i == 2) return P.FORGE_POOL_2_ALLOC_POINTS;
        if (i == 3) return P.FORGE_POOL_3_ALLOC_POINTS;
        revert UnknownPool(i);
    }

    function epochBounds(uint256 epoch) public view returns (uint256 start, uint256 end) {
        start = START + epoch * P.EPOCH_SECONDS;
        end = start + P.EPOCH_SECONDS;
    }

    function poolEpoch(uint256 epoch, uint256 pool) external view returns (PoolEpoch memory) {
        return _epochs[epoch][pool];
    }

    function measureOf(uint256 epoch, uint256 pool, uint256 id) external view returns (Measure memory) {
        return _measures[epoch][pool][id];
    }

    function earnerCount(uint256 epoch, uint256 pool) external view returns (uint256) {
        return _earners[epoch][pool].length;
    }

    function earnerAt(uint256 epoch, uint256 pool, uint256 k) external view returns (uint256) {
        return _earners[epoch][pool][k];
    }

    function progressOf(uint256 epoch, uint256 pool) external view returns (Progress memory) {
        return _progress[epoch][pool];
    }

    function claimOf(uint256 pool, uint256 id) external view returns (Claim memory) {
        return _claims[pool][id];
    }

    function _onlyOwner(uint256 pool, uint256 id) internal view returns (address owner) {
        owner = poolAt(pool).positionOf(id).owner;
        if (owner != msg.sender) revert NotOwner(pool, id);
    }
}
