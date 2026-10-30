// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";
import {EmissionMath} from "../libraries/EmissionMath.sol";
import {ForgePool} from "./ForgePool.sol";
import {Seal, SealStatus, SlotMeasure, ForgeMeasures} from "./ForgeMeasures.sol";

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
    function mintAshfall(uint256 epoch, address to, uint256 amount) external;
    function rollAshfall(uint256 epoch, uint256 amount) external;
    function burnForfeited(uint256 amount) external;
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
///         3. When the totals are final, the Conviction bucket is reserved. If any lot was
///            sealed, `advance` pages through the sealed positions and sets each one's
///            escrow min(⌊bucket·C_i/C⌋, ⌊L·B_i/W⌋) (ADR 0006); the unused bucket returns
///            to the Heat budget (with no Seals, the canonical 27/73 split).
///         4. `advance` then credits each earning position
///            ⌊flat·S_i/S⌋ + ⌊heat·W_i/W⌋ as claimable and its escrow to its Seal,
///            minting each page's sum once; the floor residue is released.
///         Ashfall (ADR 0007): the Mantle's epoch Ashfall budget is split by the same pool
///         weights. When a pool's share is nonzero, the measure pages also read each
///         position's Ashfall weight Q_i (stake·Heat² over time when its lot's actual
///         participation and its Streak are both ≥ 30 days), and the credit pages add
///         ⌊share·Q_i/Q⌋ to its claimable rewards (one `mintAshfall` per page). A pool
///         nobody was eligible in, the floor residue, and the shares of positions that left
///         by emergency exit before being credited roll back to the Mantle's queue.
///         Claims: a fee-free 24h click-start snapshot of a position's credited rewards.
///         Escrow stays locked until its Seal ends: a completed term moves it to the
///         position's Capstone ledger, a forfeit routes it 50/25/25. Each ledger has one
///         consumer fixed at deployment: the Capstone, the match reserve and the Sealed-pot
///         stream pull theirs; the burn lane is burned through the Mantle.
///         Principal exits never wait on any of this. No owner, no pause, no upgrade.
contract ForgeEmissions is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 public constant POOL_COUNT = 4;
    /// @notice [P] Record segments one measure page may examine (≈8k gas each). With the
    ///         spec's ≤32 lots per page, this bounds every page however many records a
    ///         position has: a position larger than one page resumes on the next.
    uint256 public constant SEGMENTS_PER_PAGE = 256;
    /// @notice [P] Page budget charged per lapse a position's sync must resolve before it is
    ///         measured (a lapse rewrites up to 32 heads). A page enters such a position only
    ///         if the budget covers it; one that does not fit waits to be the next page's
    ///         first work, so a page pays for at most one oversized sync.
    uint256 public constant LAPSE_UNITS = 64;
    /// @notice [P] Page budget charged per record segment while a pool-epoch also measures
    ///         Ashfall: the Heat² integral roughly doubles a segment's cost (ADR 0007).
    uint256 public constant ASHFALL_SEGMENT_UNITS = 2;

    enum Phase {
        None,
        Measuring,
        Escrowing,
        Crediting,
        Done
    }

    struct PoolEpoch {
        Phase phase;
        uint32 positions; // N: the pool's position count when the epoch opened
        uint32 cursor; // positions measured
        uint32 credited; // earners credited
        uint32 escrowed; // sealed earners whose escrow is set
        uint128 target; // the pool's weighted share of the base
        uint128 admitted; // E = accruedPoolBudget(target, occupied, epoch)
        uint128 bucket; // ⌊E·10%⌋
        uint128 flat; // ⌊(E − bucket)·30%⌋
        uint128 heat; // L = E − bucket − flat while escrowing; then L + bucket − escrow
        uint128 escrow; // Σ capped Seal escrow
        uint128 paid; // Σ credited payouts and escrow (all minted)
        uint256 stakeSeconds; // S = Σ S_i
        uint256 heatSeconds; // W = Σ W_i
        uint256 candidateSeconds; // C = Σ C_i
        uint128 ashfall; // the pool's share of the epoch's Ashfall budget
        uint128 ashfallPaid; // Σ credited Ashfall (all minted); the rest rolls back
        uint256 ashfallWeight; // Q = Σ Q_i
    }

    /// @dev A position's epoch measures. B = ∫sealed stake·bonus dt and
    ///      C = ⌊∫sealed stake·Heat dt · bonus⌋, both of the one Seal (`seal`) it earned under.
    struct Measure {
        uint256 stakeSeconds;
        uint256 heatSeconds;
        uint256 sealSeconds;
        uint256 candidateSeconds;
        uint128 escrow;
        uint8 seal;
        uint256 ashfallWeight; // Q_i = ⌊∫eligible stake·Heat² dt / RAY⌋
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
        uint8 seal;
        uint256 stakeSeconds;
        uint256 heatSeconds;
        uint256 sealedStakeSeconds;
        uint256 sealedHeatSeconds;
        uint256 ashfallQuotient; // the Ashfall weight so far, exactly: quotient·RAY + remainder
        uint256 ashfallRemainder;
    }

    IMantleDistribution public immutable MANTLE;
    IERC20 public immutable EMBER;
    uint256 public immutable START;
    ForgePool internal immutable POOL_0;
    ForgePool internal immutable POOL_1;
    ForgePool internal immutable POOL_2;
    ForgePool internal immutable POOL_3;
    /// @notice The consumers of the held Seal ledgers, fixed at deployment (ADR 0007). Each
    ///         pulls its own ledger; until it exists the EMBER stays here.
    address public immutable CAPSTONE;
    address public immutable MATCH_RESERVE;
    address public immutable SEALED_POT;

    uint256 public nextEpoch;
    mapping(uint256 epoch => mapping(uint256 pool => PoolEpoch)) internal _epochs;
    mapping(uint256 epoch => mapping(uint256 pool => uint256[])) internal _earners;
    mapping(uint256 epoch => mapping(uint256 pool => uint256[])) internal _sealedEarners;
    mapping(uint256 epoch => mapping(uint256 pool => mapping(uint256 id => Measure))) internal _measures;
    mapping(uint256 epoch => mapping(uint256 pool => Progress)) internal _progress;
    mapping(uint256 pool => mapping(uint256 id => uint256)) public unclaimed;
    mapping(uint256 pool => mapping(uint256 id => Claim)) internal _claims;
    /// @notice Funded escrow of a running Seal, locked until it ends.
    mapping(uint256 pool => mapping(uint256 id => mapping(uint256 k => uint256))) public sealEscrow;
    /// @notice Vested escrow owed to the position's Capstone: held, never liquid, until
    ///         CAPSTONE pulls it.
    mapping(uint256 pool => mapping(uint256 id => uint256)) public capstoneOwed;
    /// @notice Forfeited escrow by route: the burn lane (50%, burned by `burnForfeits`), the
    ///         match reserve (25%) and each pool's Sealed pot (25%), pulled by their consumers.
    ///         [P] The Sealed-pot stream period is not in the config: its streaming contract
    ///         decides it, not this one.
    uint256 public burnLane;
    uint256 public matchReserve;
    mapping(uint256 pool => uint256) public sealedPot;

    event EpochOpened(uint256 indexed epoch, uint256 base, uint256 released);
    event PoolEpochOpened(uint256 indexed epoch, uint256 indexed pool, uint256 target, uint256 admitted, uint256 positions);
    event Measured(uint256 indexed epoch, uint256 indexed pool, uint256 id, uint256 stakeSeconds, uint256 heatSeconds);
    event Budgeted(uint256 indexed epoch, uint256 indexed pool, uint256 flat, uint256 heat, uint256 unusedBucket);
    event Credited(uint256 indexed epoch, uint256 indexed pool, uint256 id, uint256 amount);
    event Escrowed(uint256 indexed epoch, uint256 indexed pool, uint256 id, uint256 seal, uint256 amount);
    event SealVested(uint256 indexed pool, uint256 indexed id, uint256 seal, uint256 amount);
    event SealForfeitRouted(uint256 indexed pool, uint256 indexed id, uint256 seal, uint256 burn, uint256 reserve, uint256 pot);
    event ResidueReleased(uint256 indexed epoch, uint256 indexed pool, uint256 amount);
    event AshfallCredited(uint256 indexed epoch, uint256 indexed pool, uint256 id, uint256 amount);
    event AshfallRolled(uint256 indexed epoch, uint256 indexed pool, uint256 amount);
    event ForfeitsBurned(uint256 amount);
    event LedgerTaken(address indexed consumer, uint256 indexed pool, uint256 id, uint256 amount);
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
    error SealNotEnded(uint256 pool, uint256 id, uint256 seal);
    error NothingToSettle(uint256 pool, uint256 id, uint256 seal);
    error NotConsumer(address caller);

    constructor(
        IMantleDistribution mantle,
        IERC20 ember,
        ForgePool[4] memory pools,
        address capstone,
        address matchReserve_,
        address sealedPot_
    ) {
        if (address(mantle) == address(0) || address(ember) == address(0)) revert ZeroAddress();
        if (capstone == address(0) || matchReserve_ == address(0) || sealedPot_ == address(0)) revert ZeroAddress();
        bool[4] memory isLp = [P.FORGE_POOL_0_IS_LP, P.FORGE_POOL_1_IS_LP, P.FORGE_POOL_2_IS_LP, P.FORGE_POOL_3_IS_LP];
        for (uint256 i; i < POOL_COUNT; ++i) {
            if (address(pools[i]) == address(0)) revert ZeroAddress();
            if (pools[i].IS_LP() != isLp[i]) revert PoolMismatch(i);
        }
        MANTLE = mantle;
        EMBER = ember;
        START = mantle.START();
        (POOL_0, POOL_1, POOL_2, POOL_3) = (pools[0], pools[1], pools[2], pools[3]);
        (CAPSTONE, MATCH_RESERVE, SEALED_POT) = (capstone, matchReserve_, sealedPot_);
    }

    // ── settlement ────────────────────────────────────────────────────────

    /// @notice Open the next epoch once the Mantle has finalized it: split the global
    ///         base by pool weight, admit each share for its pool's occupied time, and
    ///         release the rest. The epoch's Ashfall is split by the same weights [P]; the
    ///         split's floor residue, and the share of a pool with nothing admitted, roll back.
    function openEpoch() external nonReentrant returns (uint256 epoch) {
        epoch = nextEpoch;
        if (MANTLE.nextEpoch() <= epoch) revert EpochNotFinalized(epoch);
        (uint128 base, uint128 ashfall,,,,) = MANTLE.budgets(epoch);
        (uint256 start, uint256 end) = epochBounds(epoch);
        uint256 released = base;
        uint256 rolled = ashfall;
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
            if (admitted != 0) {
                pe.ashfall = uint128(Math.mulDiv(ashfall, allocPoints(i), P.FORGE_ALLOC_POINTS_TOTAL));
                rolled -= pe.ashfall;
            }
            emit PoolEpochOpened(epoch, i, target, admitted, pe.positions);
        }
        nextEpoch = epoch + 1;
        if (released != 0) MANTLE.releaseBase(epoch, released);
        if (rolled != 0) {
            MANTLE.rollAshfall(epoch, rolled);
            emit AshfallRolled(epoch, POOL_COUNT, rolled);
        }
        emit EpochOpened(epoch, base, released);
    }

    /// @notice One bounded page of whichever phase the pool-epoch is in. Anyone may call.
    function advance(uint256 epoch, uint256 pool) external nonReentrant {
        PoolEpoch storage pe = _epochs[epoch][pool];
        if (pe.phase == Phase.Measuring) _measurePage(epoch, pool, pe);
        else if (pe.phase == Phase.Escrowing) _escrowPage(epoch, pool, pe);
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
        uint256 unit = pe.ashfall != 0 ? ASHFALL_SEGMENT_UNITS : 1;
        uint256 slots;
        while (budget != 0) {
            if (pr.id == 0) {
                if (pe.cursor == pe.positions || slots == P.SETTLEMENT_MAX_LOTS_PER_PAGE) break;
                uint256 next = pe.cursor + 1;
                uint256 cost = pool.dueLapses(next) * LAPSE_UNITS;
                if (cost <= budget) budget -= cost;
                else if (budget != SEGMENTS_PER_PAGE) break; // too heavy: first work of the next page
                pool.poke(next); // resolve lapses due by now: their records are back-dated
                pr.id = uint32(next);
            }
            uint32 mask = pool.historyMaskOf(pr.id);
            uint256 j = pr.slot;
            while (j < 32 && mask & (1 << j) == 0) ++j;
            if (j == 32) {
                _finishPosition(epoch, i, pe, pr);
                pr = Progress(0, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                --budget;
                continue;
            }
            if (slots == P.SETTLEMENT_MAX_LOTS_PER_PAGE || budget < unit) break;
            ++slots;
            budget -= _measureSlot(epoch, pool, pr, j, budget / unit, unit != 1) * unit;
        }
        if (pr.id != 0) _progress[epoch][i] = pr;
        else if (wasStored) delete _progress[epoch][i];
        if (pr.id == 0 && pe.cursor == pe.positions) _budget(epoch, i, pe);
    }

    function _measureSlot(uint256 epoch, ForgePool pool, Progress memory pr, uint256 j, uint256 maxSegs, bool ashfall)
        internal
        view
        returns (uint256 used)
    {
        uint256 start = START + epoch * P.EPOCH_SECONDS;
        SlotMeasure memory m = pool.measureSlot(pr.id, j, start, start + P.EPOCH_SECONDS, pr.seg, maxSegs, ashfall);
        pr.stakeSeconds += m.stakeSeconds;
        pr.heatSeconds += m.heatSeconds;
        pr.sealedStakeSeconds += m.sealedStakeSeconds;
        pr.sealedHeatSeconds += m.sealedHeatSeconds;
        uint256 r = pr.ashfallRemainder + m.ashfallRemainder;
        (pr.ashfallQuotient, pr.ashfallRemainder) =
            r >= P.RAY ? (pr.ashfallQuotient + m.ashfallQuotient + 1, r - P.RAY) : (pr.ashfallQuotient + m.ashfallQuotient, r);
        if (m.seal != 0) pr.seal = uint8(m.seal); // [P] at most one Seal per position-epoch
        if (m.done) {
            pr.slot = uint8(j + 1);
            pr.seg = 0;
        } else {
            pr.slot = uint8(j);
            pr.seg = uint32(m.next);
        }
        return m.used;
    }

    /// @dev B, C and Q are formed once per position-epoch from the unscaled sums, so they
    ///      do not depend on how records subdivide the epoch.
    function _finishPosition(uint256 epoch, uint256 i, PoolEpoch storage pe, Progress memory pr) internal {
        (uint256 id, uint256 s, uint256 w) = (pr.id, pr.stakeSeconds, pr.heatSeconds);
        if (s != 0) {
            Measure memory m = Measure(s, w, 0, 0, 0, 0, pr.ashfallQuotient);
            pe.ashfallWeight += pr.ashfallQuotient;
            if (pr.sealedStakeSeconds != 0) {
                uint256 bonus = ForgeMeasures.trackBonus(poolAt(i).sealOf(id, pr.seal).track);
                m.sealSeconds = pr.sealedStakeSeconds * bonus;
                m.candidateSeconds = Math.mulDiv(pr.sealedHeatSeconds, bonus, P.RAY);
                m.seal = pr.seal;
                _sealedEarners[epoch][i].push(id);
                pe.candidateSeconds += m.candidateSeconds;
            }
            _measures[epoch][i][id] = m;
            _earners[epoch][i].push(id);
            pe.stakeSeconds += s;
            pe.heatSeconds += w;
            emit Measured(epoch, i, id, s, w);
        }
        pe.cursor += 1;
    }

    /// @dev Totals are final: reserve the Conviction bucket and split the rest 30/70.
    ///      With sealed lots, escrow pages come first; otherwise the whole bucket returns
    ///      to Heat (spec §10: "With no eligible Seals it yields 27/73").
    function _budget(uint256 epoch, uint256 i, PoolEpoch storage pe) internal {
        uint256 e = pe.admitted;
        if (pe.ashfallWeight == 0) _rollAshfall(epoch, i, pe); // nobody was eligible: carry it forward
        if (pe.stakeSeconds == 0) {
            pe.phase = Phase.Done;
            MANTLE.releaseBase(epoch, e);
            emit ResidueReleased(epoch, i, e);
            return;
        }
        uint256 bucket = (e * P.CONVICTION_BUCKET_PCT) / 100;
        uint256 flat = ((e - bucket) * P.SPLIT_FLAT_PCT) / 100;
        pe.bucket = uint128(bucket);
        pe.flat = uint128(flat);
        pe.heat = uint128(e - bucket - flat); // L, the pre-return Heat budget
        if (pe.candidateSeconds != 0) pe.phase = Phase.Escrowing;
        else _finalHeat(epoch, i, pe);
    }

    /// @dev Each sealed position's escrow: its share of the bucket by C, capped at the
    ///      additive worth of its bonus in the pre-return Heat budget, L·B_i/W.
    function _escrowPage(uint256 epoch, uint256 i, PoolEpoch storage pe) internal {
        uint256[] storage list = _sealedEarners[epoch][i];
        uint256 k = pe.escrowed;
        uint256 end = Math.min(list.length, k + P.SETTLEMENT_MAX_LOTS_PER_PAGE);
        uint256 sum;
        for (; k < end; ++k) {
            Measure storage m = _measures[epoch][i][list[k]];
            uint256 candidate = Math.mulDiv(pe.bucket, m.candidateSeconds, pe.candidateSeconds);
            uint256 cap = Math.mulDiv(pe.heat, m.sealSeconds, pe.heatSeconds);
            uint256 escrow = Math.min(candidate, cap);
            m.escrow = uint128(escrow);
            sum += escrow;
        }
        pe.escrowed = uint32(k);
        pe.escrow += uint128(sum);
        if (k == list.length) _finalHeat(epoch, i, pe);
    }

    function _finalHeat(uint256 epoch, uint256 i, PoolEpoch storage pe) internal {
        uint256 unused = pe.bucket - pe.escrow;
        pe.heat += uint128(unused);
        pe.phase = Phase.Crediting;
        emit Budgeted(epoch, i, pe.flat, pe.heat, unused);
    }

    function _creditPage(uint256 epoch, uint256 i, PoolEpoch storage pe) internal {
        uint256[] storage earners = _earners[epoch][i];
        uint256 k = pe.credited;
        uint256 end = Math.min(earners.length, k + P.SETTLEMENT_MAX_LOTS_PER_PAGE);
        uint256 sum;
        uint256 ashSum;
        for (; k < end; ++k) {
            uint256 id = earners[k];
            sum += _credit(epoch, i, pe, id);
            ashSum += _creditAshfall(epoch, i, pe, id);
        }
        pe.credited = uint32(k);
        pe.paid += uint128(sum);
        pe.ashfallPaid += uint128(ashSum);
        if (sum != 0) MANTLE.mintBase(epoch, address(this), sum);
        if (ashSum != 0) MANTLE.mintAshfall(epoch, address(this), ashSum);
        if (k == earners.length) {
            pe.phase = Phase.Done;
            uint256 residue = pe.admitted - pe.paid;
            if (residue != 0) {
                MANTLE.releaseBase(epoch, residue);
                emit ResidueReleased(epoch, i, residue);
            }
            _rollAshfall(epoch, i, pe);
        }
    }

    /// @dev ⌊share·Q_i/Q⌋ becomes claimable, unless the position left by emergency exit
    ///      before this credit: its pending Ashfall is forfeited and rolls back to the
    ///      Mantle's queue for everyone who stayed (config `forfeitsAshfall`).
    function _creditAshfall(uint256 epoch, uint256 i, PoolEpoch storage pe, uint256 id) internal returns (uint256 amount) {
        uint256 q = _measures[epoch][i][id].ashfallWeight;
        if (q == 0) return 0;
        if (poolAt(i).positionOf(id).ashfallForfeited) return 0;
        amount = Math.mulDiv(pe.ashfall, q, pe.ashfallWeight);
        unclaimed[i][id] += amount;
        emit AshfallCredited(epoch, i, id, amount);
    }

    /// @dev Whatever of the pool's Ashfall share was not credited goes back to the Mantle's
    ///      queue (never re-issued twice: the Mantle re-reserves it for a later epoch).
    function _rollAshfall(uint256 epoch, uint256 i, PoolEpoch storage pe) internal {
        uint256 rest = pe.ashfall - pe.ashfallPaid;
        if (rest == 0) return;
        pe.ashfall = pe.ashfallPaid;
        MANTLE.rollAshfall(epoch, rest);
        emit AshfallRolled(epoch, i, rest);
    }

    /// @dev Ordinary reward becomes claimable; escrow goes to its Seal as it stands now:
    ///      locked while it runs, to the Capstone ledger once completed, routed if forfeited.
    function _credit(uint256 epoch, uint256 i, PoolEpoch storage pe, uint256 id) internal returns (uint256) {
        Measure storage m = _measures[epoch][i][id];
        uint256 amount = Math.mulDiv(pe.flat, m.stakeSeconds, pe.stakeSeconds)
            + Math.mulDiv(pe.heat, m.heatSeconds, pe.heatSeconds);
        unclaimed[i][id] += amount;
        emit Credited(epoch, i, id, amount);
        uint256 escrow = m.escrow;
        if (escrow != 0) {
            emit Escrowed(epoch, i, id, m.seal, escrow);
            SealStatus status = sealStatus(i, id, m.seal);
            if (status == SealStatus.Active) sealEscrow[i][id][m.seal] += escrow;
            else _release(i, id, m.seal, status, escrow);
        }
        return amount + escrow;
    }

    /// @notice Release a Seal's escrow once it has ended: to the position's Capstone ledger
    ///         if the term completed, routed 50/25/25 if it was forfeited. Anyone may call.
    function settleSeal(uint256 pool, uint256 id, uint256 k) external nonReentrant returns (uint256 amount) {
        SealStatus status = sealStatus(pool, id, k);
        if (status != SealStatus.Completed && status != SealStatus.Forfeited) revert SealNotEnded(pool, id, k);
        amount = sealEscrow[pool][id][k];
        if (amount == 0) revert NothingToSettle(pool, id, k);
        sealEscrow[pool][id][k] = 0;
        _release(pool, id, k, status, amount);
    }

    function _release(uint256 pool, uint256 id, uint256 k, SealStatus status, uint256 amount) internal {
        if (status == SealStatus.Completed) {
            capstoneOwed[pool][id] += amount;
            emit SealVested(pool, id, k, amount);
            return;
        }
        uint256 burn = (amount * P.SEAL_FORFEIT_BURN_PCT) / 100;
        uint256 reserve = (amount * P.SEAL_FORFEIT_MATCH_RESERVE_PCT) / 100;
        uint256 pot = amount - burn - reserve; // [P] the floor dust joins the Sealed pot
        burnLane += burn;
        matchReserve += reserve;
        sealedPot[pool] += pot;
        emit SealForfeitRouted(pool, id, k, burn, reserve, pot);
    }

    // ── ledger consumers (ADR 0007) ───────────────────────────────────────

    /// @notice Burn the burn lane through the Mantle: a recognized burn with no Ashfall
    ///         credit (Seal forfeits are not a configured Ashfall source). Anyone may call.
    function burnForfeits() external nonReentrant returns (uint256 amount) {
        amount = burnLane;
        if (amount == 0) return 0;
        burnLane = 0;
        EMBER.forceApprove(address(MANTLE), amount);
        MANTLE.burnForfeited(amount);
        emit ForfeitsBurned(amount);
    }

    /// @notice The Capstone pulls a position's vested escrow.
    function takeCapstone(uint256 pool, uint256 id) external nonReentrant returns (uint256 amount) {
        if (msg.sender != CAPSTONE) revert NotConsumer(msg.sender);
        amount = capstoneOwed[pool][id];
        capstoneOwed[pool][id] = 0;
        _hand(pool, id, amount);
    }

    /// @notice The match reserve pulls its share of forfeited escrow.
    function takeMatchReserve() external nonReentrant returns (uint256 amount) {
        if (msg.sender != MATCH_RESERVE) revert NotConsumer(msg.sender);
        amount = matchReserve;
        matchReserve = 0;
        _hand(POOL_COUNT, 0, amount);
    }

    /// @notice The Sealed-pot stream pulls a pool's pot.
    function takeSealedPot(uint256 pool) external nonReentrant returns (uint256 amount) {
        if (msg.sender != SEALED_POT) revert NotConsumer(msg.sender);
        poolAt(pool);
        amount = sealedPot[pool];
        sealedPot[pool] = 0;
        _hand(pool, 0, amount);
    }

    function _hand(uint256 pool, uint256 id, uint256 amount) internal {
        emit LedgerTaken(msg.sender, pool, id, amount);
        if (amount != 0) EMBER.safeTransfer(msg.sender, amount);
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

    function sealedEarnerCount(uint256 epoch, uint256 pool) external view returns (uint256) {
        return _sealedEarners[epoch][pool].length;
    }

    function sealedEarnerAt(uint256 epoch, uint256 pool, uint256 k) external view returns (uint256) {
        return _sealedEarners[epoch][pool][k];
    }

    function progressOf(uint256 epoch, uint256 pool) external view returns (Progress memory) {
        return _progress[epoch][pool];
    }

    /// @notice A Seal's status as of now, without a pool sync: a running Seal past its due
    ///         time has completed (back-dated), whatever happens next.
    function sealStatus(uint256 pool, uint256 id, uint256 k) public view returns (SealStatus) {
        Seal memory s = poolAt(pool).sealOf(id, k);
        if (s.status == SealStatus.Active && s.pausedAt == 0 && ForgeMeasures.sealEnd(s) <= block.timestamp) {
            return SealStatus.Completed;
        }
        return s.status;
    }

    function claimOf(uint256 pool, uint256 id) external view returns (Claim memory) {
        return _claims[pool][id];
    }

    function _onlyOwner(uint256 pool, uint256 id) internal view returns (address owner) {
        owner = poolAt(pool).positionOf(id).owner;
        if (owner != msg.sender) revert NotOwner(pool, id);
    }
}
