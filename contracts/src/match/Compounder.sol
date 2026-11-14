// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";
import {EmberPair} from "../pairs/EmberPair.sol";
import {ForgePool} from "../forge/ForgePool.sol";
import {ForgePoolBase} from "../forge/ForgePoolBase.sol";
import {ForgeView} from "../forge/ForgeView.sol";
import {Lot} from "../forge/ForgeMeasures.sol";
import {Vent} from "../vent/Vent.sol";

/// @notice What the Compounder reads and consumes of ForgeEmissions (ADR 0026).
interface ICastLedger {
    function castOf(uint256 epoch, uint256 pool, uint256 id) external view returns (uint256);
    function castDemand(uint256 epoch, uint256 pool) external view returns (uint256 demand, bool done);
    function castTaken(uint256 epoch, uint256 pool, uint256 id) external view returns (bool);
    function takeCast(uint256 epoch, uint256 pool, uint256 id, uint256 used) external returns (uint256);
    function takeMatchReserve() external returns (uint256);
}

/// @notice The Vent's liquidity lane, as the Compounder draws it.
interface IMatchVent {
    function lane(uint256 j) external view returns (Vent.Lane memory);
    function drawMatchReserve(uint256 j, uint256 amount) external;
}

/// @title Compounder — Casting and the idle auto-pair: the match reserve (spec v5.5 §7, §13)
/// @notice One contract fills two fixed slots [P]: every LP pool's, Flow's and the Vent's
///         `COMPOUNDER`, and ForgeEmissions' `MATCH_RESERVE`. No admin, no pause, no upgrade, no
///         rescue. Two inventories, accounted apart (§13):
///         - **Matching quote**, per pair: the Vent's liquidity lane, drawn by `refill`. Each
///           settled pool-epoch `freeze`s a budget from what is unreserved, priced at the pair's
///           1800 s TWAP and capped at the quote its Cast demand needs; positions share it
///           pro-rata to their Cast shares, one use each (§7).
///         - **Seed EMBER**: ForgeEmissions' match ledger (25% of Seal forfeits) and any funding
///           sent to `fundSeed`. Only the idle auto-pair spends it.
///         `cast` pairs a position's Cast share with its reserved quote at the spot ratio, inside
///         the 2% band, and returns the LP to the position's youngest active lot already open
///         when the epoch ended, at that lot's age (`addToLot`). The LP is the owner's; the quote
///         is a disclosed subsidy. Whatever is not cast (a dry reserve, a closed position, no
///         such lot, a ratio that moved) returns to the owner's unclaimed rewards: nothing is
///         sold and nothing is confiscated. A reservation lasts MATCH_RESERVATION_EPOCHS after
///         its epoch; then the quote returns to the unreserved inventory and the reward to the
///         owner. After IDLE_EPOCHS_BEFORE_AUTO_PAIR epochs with no Cast on a pair, `autoPair`
///         pairs its unreserved quote with seed EMBER into the permanent sink; it never touches
///         reserved quote, and a short seed pairs only what it covers.
contract Compounder is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using ForgeView for ForgePool;

    uint256 public constant PAIR_COUNT = 2;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant NO_LOT = type(uint256).max;

    /// @notice One pair's matching inventory: `free` is unreserved, `reserved` is held for
    ///         frozen budgets. `lastActiveEpoch` is the epoch of its last Cast.
    struct Reserve {
        uint128 free;
        uint128 reserved;
        uint64 lastActiveEpoch;
    }

    /// @notice A pool-epoch's frozen budget: its Cast demand D (EMBER), the quote it would need at
    ///         the TWAP, the quote reserved B = min(free, need), and what of B is still held.
    struct Budget {
        uint128 demand;
        uint128 need;
        uint128 budget;
        uint128 remaining;
        bool frozen;
        bool closed;
    }

    /// @notice Why a Cast share went back to its owner instead of into LP.
    enum Release {
        Expired, // the reservation's window passed
        Uncovered, // the budget covers nothing of it (a dry reserve)
        Closed, // the position left by emergency exit
        NoLot, // no active lot open at the epoch's end can take it
        Dust // the covered part forms no LP
    }

    IERC20 public immutable EMBER;
    ICastLedger public immutable EMISSIONS;
    IMatchVent public immutable VENT;
    /// @notice The permanent LP sink (PermanentLiquidity, ADR 0021).
    address public immutable SINK;
    EmberPair public immutable PAIR_0;
    EmberPair public immutable PAIR_1;
    ForgePool public immutable POOL_0;
    ForgePool public immutable POOL_1;
    /// @notice ForgeEmissions' epoch 0 start (the Mantle's START).
    uint256 public immutable START;

    Reserve[2] internal _reserves;
    /// @notice Seed EMBER for the idle auto-pair.
    uint256 public seed;
    mapping(uint256 epoch => mapping(uint256 pool => Budget)) internal _budgets;

    event Refilled(uint256 indexed pair, uint256 amount);
    event SeedFunded(address indexed from, uint256 amount);
    event Frozen(uint256 indexed epoch, uint256 indexed pool, uint256 demand, uint256 need, uint256 budget);
    event BudgetClosed(uint256 indexed epoch, uint256 indexed pool, uint256 returned);
    /// @notice What of the share was paired, and the LP added to `slot`; ForgeEmissions'
    ///         CastConsumed reports what returned liquid.
    event Cast(
        uint256 indexed epoch, uint256 indexed pool, uint256 indexed id, uint256 slot, uint256 ember, uint256 quote, uint256 liquidity
    );
    event CastReleased(uint256 indexed epoch, uint256 indexed pool, uint256 indexed id, uint256 amount, Release why);
    event AutoPaired(uint256 indexed pair, uint256 ember, uint256 quote, uint256 liquidity);

    error ZeroAddress();
    error ZeroAmount();
    error NonStandardToken();
    error UnknownPool(uint256 pool);
    error NotSettled(uint256 epoch, uint256 pool);
    error AlreadyFrozen(uint256 epoch, uint256 pool);
    error NotFrozen(uint256 epoch, uint256 pool);
    error Expired(uint256 epoch);
    error NotExpired(uint256 epoch, uint256 expiresAt);
    error NothingToCast(uint256 epoch, uint256 pool, uint256 id);
    error AlreadyCast(uint256 epoch, uint256 pool, uint256 id);
    error Listed(uint256 pool, uint256 id);
    error NoOracle(uint256 pair);
    error StaleOracle(uint256 pair, uint256 elapsed);
    error OutOfBand(uint256 pair, uint256 spot, uint256 twap);
    error NotIdle(uint256 pair, uint256 idleFrom);
    error NothingToPair(uint256 pair);

    constructor(
        IERC20 ember,
        ICastLedger emissions,
        IMatchVent vent,
        address sink,
        EmberPair[2] memory pairs,
        ForgePool[2] memory pools,
        uint256 start
    ) {
        if (address(ember) == address(0) || address(emissions) == address(0) || address(vent) == address(0)) revert ZeroAddress();
        if (sink == address(0)) revert ZeroAddress();
        for (uint256 j; j < PAIR_COUNT; ++j) {
            if (address(pairs[j]) == address(0) || address(pools[j]) == address(0)) revert ZeroAddress();
        }
        (EMBER, EMISSIONS, VENT, SINK, START) = (ember, emissions, vent, sink, start);
        (PAIR_0, PAIR_1, POOL_0, POOL_1) = (pairs[0], pairs[1], pools[0], pools[1]);
    }

    // ── inventories ───────────────────────────────────────────────────────

    /// @notice Draw the Vent's whole liquidity lane for pair `j` into the unreserved inventory.
    ///         Anyone may call; `freeze` and `autoPair` do it first.
    function refill(uint256 j) external nonReentrant returns (uint256) {
        _pairAt(j);
        return _refill(j);
    }

    /// @notice Take ForgeEmissions' match ledger (25% of Seal forfeits) into the seed [P].
    function pullForfeits() external nonReentrant returns (uint256 amount) {
        uint256 before = EMBER.balanceOf(address(this));
        amount = EMISSIONS.takeMatchReserve();
        if (EMBER.balanceOf(address(this)) - before != amount) revert NonStandardToken();
        if (amount == 0) return 0;
        seed += amount;
        emit SeedFunded(address(EMISSIONS), amount);
    }

    /// @notice Add EMBER to the seed, pulled exactly. Anyone may fund it [P]; the Treasury's
    ///         match-seed bucket is its intended source (spec §16). It cannot be withdrawn.
    function fundSeed(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 before = EMBER.balanceOf(address(this));
        EMBER.safeTransferFrom(msg.sender, address(this), amount);
        if (EMBER.balanceOf(address(this)) - before != amount) revert NonStandardToken();
        seed += amount;
        emit SeedFunded(msg.sender, amount);
    }

    // ── Casting ───────────────────────────────────────────────────────────

    /// @notice Freeze a settled pool-epoch's matching budget, once, before its window ends: the
    ///         Cast demand D priced at the pair's TWAP is the quote it needs, and B = min(unreserved,
    ///         need) is reserved for it [P]. A stale or missing oracle reverts: try again later.
    function freeze(uint256 epoch, uint256 pool) external nonReentrant returns (uint256 budget) {
        uint256 j = _castPool(pool);
        Budget storage b = _budgets[epoch][pool];
        if (b.frozen) revert AlreadyFrozen(epoch, pool);
        if (block.timestamp >= expiresAt(epoch)) revert Expired(epoch);
        (uint256 demand, bool done) = EMISSIONS.castDemand(epoch, pool);
        if (!done) revert NotSettled(epoch, pool);
        uint256 need;
        if (demand != 0) {
            _refill(j);
            (,,, uint256 twap) = _market(j, false);
            need = Math.mulDiv(demand, twap, 1 << 112);
            Reserve storage r = _reserves[j];
            budget = Math.min(r.free, need);
            if (budget != 0) {
                r.free = uint128(r.free - budget);
                r.reserved = SafeCast.toUint128(r.reserved + budget);
            }
        }
        b.demand = SafeCast.toUint128(demand);
        b.need = SafeCast.toUint128(need);
        (b.budget, b.remaining, b.frozen) = (uint128(budget), uint128(budget), true);
        emit Frozen(epoch, pool, demand, need, budget);
    }

    /// @notice Cast a position's share for a settled epoch (anyone may call; there is no tip [P]).
    ///         Inside its window the covered part is paired with its reserved quote at the spot
    ///         ratio and the LP added to the position's source lot; the rest of the share returns
    ///         liquid. A listed position waits, and a stale oracle or a spot outside the band
    ///         reverts, releasing nothing. After the window the whole share returns liquid.
    function cast(uint256 epoch, uint256 pool, uint256 id) external nonReentrant returns (uint256) {
        uint256 j = _castPool(pool);
        uint256 c = EMISSIONS.castOf(epoch, pool, id);
        if (c == 0) revert NothingToCast(epoch, pool, id);
        if (EMISSIONS.castTaken(epoch, pool, id)) revert AlreadyCast(epoch, pool, id);
        Budget storage b = _budgets[epoch][pool];
        if (block.timestamp >= expiresAt(epoch)) {
            _close(epoch, pool, j, b);
            return _release(epoch, pool, id, c, Release.Expired);
        }
        if (!b.frozen) revert NotFrozen(epoch, pool);
        uint256 q = Math.mulDiv(b.budget, c, b.demand);
        uint256 e = b.need == 0 ? 0 : Math.mulDiv(c, b.budget, b.need);
        if (e == 0) return _unreserve(epoch, pool, id, c, q, Release.Uncovered);
        return _castInto(epoch, pool, id, c, q, e);
    }

    /// @notice Return an expired budget's unused quote to the unreserved inventory. Anyone may
    ///         call; `cast` does it for the first expired share it meets.
    function close(uint256 epoch, uint256 pool) external nonReentrant returns (uint256 returned) {
        uint256 j = _castPool(pool);
        uint256 at = expiresAt(epoch);
        if (block.timestamp < at) revert NotExpired(epoch, at);
        return _close(epoch, pool, j, _budgets[epoch][pool]);
    }

    // ── the idle auto-pair ────────────────────────────────────────────────

    /// @notice After IDLE_EPOCHS_BEFORE_AUTO_PAIR epochs with no Cast on pair `j`, pair its
    ///         unreserved quote with seed EMBER at the spot ratio, inside the band, and send the LP
    ///         to the permanent sink. Reserved quote is never used; a short seed pairs only what it
    ///         covers and the rest waits [P]. An auto-pair is not a Cast: the pair stays idle.
    function autoPair(uint256 j) external nonReentrant returns (uint256 liquidity) {
        _pairAt(j);
        Reserve storage r = _reserves[j];
        uint256 idleFrom = uint256(r.lastActiveEpoch) + P.IDLE_EPOCHS_BEFORE_AUTO_PAIR;
        if (currentEpoch() < idleFrom) revert NotIdle(j, idleFrom);
        _refill(j);
        (uint256 rE, uint256 rQ, uint256 supply,) = _market(j, true);
        uint256 e = Math.mulDiv(r.free, rE, rQ);
        if (e > seed) e = seed;
        uint256 q = Math.mulDiv(e, rQ, rE);
        if (e == 0 || q == 0 || Math.min(e * supply / rE, q * supply / rQ) == 0) revert NothingToPair(j);
        liquidity = _pairInto(j, e, q, SINK);
        seed -= e;
        r.free = uint128(r.free - q);
        emit AutoPaired(j, e, q, liquidity);
    }

    // ── views ─────────────────────────────────────────────────────────────

    function currentEpoch() public view returns (uint256) {
        return block.timestamp <= START ? 0 : (block.timestamp - START) / P.EPOCH_SECONDS;
    }

    /// @notice When epoch `epoch`'s reservations end: MATCH_RESERVATION_EPOCHS after it ends.
    function expiresAt(uint256 epoch) public view returns (uint256) {
        return START + (epoch + 1 + P.MATCH_RESERVATION_EPOCHS) * P.EPOCH_SECONDS;
    }

    function reserveOf(uint256 j) external view returns (Reserve memory) {
        _pairAt(j);
        return _reserves[j];
    }

    function budgetOf(uint256 epoch, uint256 pool) external view returns (Budget memory) {
        return _budgets[epoch][pool];
    }

    /// @notice A position's Cast share for an epoch and what its frozen budget covers: the EMBER
    ///         it can pair and the quote reserved for it (zero before the freeze).
    function reservationOf(uint256 epoch, uint256 pool, uint256 id)
        external
        view
        returns (uint256 share, uint256 ember, uint256 quote)
    {
        share = EMISSIONS.castOf(epoch, pool, id);
        Budget memory b = _budgets[epoch][pool];
        if (share == 0 || !b.frozen || b.closed) return (share, 0, 0);
        quote = Math.mulDiv(b.budget, share, b.demand);
        ember = b.need == 0 ? 0 : Math.mulDiv(share, b.budget, b.need);
    }

    // ── internals ─────────────────────────────────────────────────────────

    function _refill(uint256 j) internal returns (uint256 amount) {
        amount = VENT.lane(j).matchReserve;
        if (amount == 0) return 0;
        IERC20 quote = _pairAt(j).QUOTE();
        uint256 before = quote.balanceOf(address(this));
        VENT.drawMatchReserve(j, amount);
        if (quote.balanceOf(address(this)) - before != amount) revert NonStandardToken();
        _reserves[j].free = SafeCast.toUint128(_reserves[j].free + amount);
        emit Refilled(j, amount);
    }

    /// @dev The share goes back to its owner and its reservation to the unreserved inventory.
    function _unreserve(uint256 epoch, uint256 pool, uint256 id, uint256 c, uint256 q, Release why) internal returns (uint256) {
        if (q != 0) _spend(epoch, pool, q, 0);
        return _release(epoch, pool, id, c, why);
    }

    /// @dev A reservation of `q` leaves its budget: `used` of it went into LP, the rest is unreserved.
    function _spend(uint256 epoch, uint256 pool, uint256 q, uint256 used) internal {
        Budget storage b = _budgets[epoch][pool];
        Reserve storage r = _reserves[pool];
        b.remaining = uint128(b.remaining - q);
        r.reserved = uint128(r.reserved - q);
        r.free = SafeCast.toUint128(r.free + (q - used));
    }

    /// @dev Inside the window, with something covered: find the source lot, pair at the spot ratio
    ///      and add the LP to it. What is not paired returns liquid through takeCast.
    function _castInto(uint256 epoch, uint256 pool, uint256 id, uint256 c, uint256 q, uint256 e)
        internal
        returns (uint256 minted)
    {
        ForgePool p = _poolAt(pool);
        if (_closed(p, pool, id)) return _unreserve(epoch, pool, id, c, q, Release.Closed);
        p.poke(id); // resolve due lapses first, so the lots read below are what addToLot sees
        uint256 slot = _sourceLot(p, id, epoch);
        if (slot == NO_LOT) return _unreserve(epoch, pool, id, c, q, Release.NoLot);
        (uint256 eUsed, uint256 qUsed) = _amounts(pool, e, q);
        if (eUsed == 0) return _unreserve(epoch, pool, id, c, q, Release.Dust);
        EMISSIONS.takeCast(epoch, pool, id, eUsed);
        minted = _pairInto(pool, eUsed, qUsed, address(this));
        IERC20(address(_pairAt(pool))).forceApprove(address(p), minted);
        p.addToLot(id, slot, minted);
        _spend(epoch, pool, q, qUsed);
        _reserves[pool].lastActiveEpoch = SafeCast.toUint64(currentEpoch());
        emit Cast(epoch, pool, id, slot, eUsed, qUsed, minted);
    }

    /// @dev Whether the position left by emergency exit; a listed one waits (addToLot refuses it).
    function _closed(ForgePool p, uint256 pool, uint256 id) internal view returns (bool) {
        ForgePoolBase.Position memory pos = p.positionOf(id);
        if (pos.closedAt != 0) return true;
        if (pos.listing & 1 != 0) revert Listed(pool, id);
        return false;
    }

    /// @dev Add exactly (e, q) to pair j, which the caller sized to its ratio; the LP goes to `to`.
    function _pairInto(uint256 j, uint256 e, uint256 q, address to) internal returns (uint256 liquidity) {
        EmberPair pair = _pairAt(j);
        EMBER.forceApprove(address(pair), e);
        pair.QUOTE().forceApprove(address(pair), q);
        (,, liquidity) = pair.addLiquidity(e, q, e, q, to);
    }

    /// @dev At the spot ratio inside the band, the most of (e EMBER, q quote) the pair takes: it
    ///      takes exactly (eUsed, ⌊eUsed·rQ/rE⌋) for these desired amounts. Zero if no LP forms.
    function _amounts(uint256 j, uint256 e, uint256 q) internal view returns (uint256 eUsed, uint256 qUsed) {
        (uint256 rE, uint256 rQ, uint256 supply,) = _market(j, true);
        eUsed = Math.mulDiv(e, rQ, rE) > q ? Math.mulDiv(q, rE, rQ) : e;
        qUsed = Math.mulDiv(eUsed, rQ, rE);
        if (eUsed == 0 || qUsed == 0 || Math.min(eUsed * supply / rE, qUsed * supply / rQ) == 0) return (0, 0);
    }

    function _release(uint256 epoch, uint256 pool, uint256 id, uint256 c, Release why) internal returns (uint256) {
        EMISSIONS.takeCast(epoch, pool, id, 0);
        emit CastReleased(epoch, pool, id, c, why);
        return 0;
    }

    function _close(uint256 epoch, uint256 pool, uint256 j, Budget storage b) internal returns (uint256 returned) {
        if (!b.frozen || b.closed) return 0;
        b.closed = true;
        returned = b.remaining;
        if (returned != 0) {
            Reserve storage r = _reserves[j];
            b.remaining = 0;
            r.reserved = uint128(r.reserved - returned);
            r.free = SafeCast.toUint128(r.free + returned);
        }
        emit BudgetClosed(epoch, pool, returned);
    }

    /// @dev The position's youngest active lot that was already open when the epoch ended (its
    ///      age now is at least the time since), and can still take an addition [P]. For a
    ///      single-lot position it is the lot that earned; it never ages a reward into older Heat.
    function _sourceLot(ForgePool p, uint256 id, uint256 epoch) internal view returns (uint256 best) {
        best = NO_LOT;
        uint256 since = block.timestamp - (START + (epoch + 1) * P.EPOCH_SECONDS);
        uint256 bestAge = type(uint256).max;
        uint32 mask = p.positionOf(id).usedMask;
        uint256 limit = p.BOOST_RECORD_LIMIT();
        for (uint256 s; s < 32; ++s) {
            if (mask >> s & 1 == 0) continue;
            Lot memory l = p.lotOf(id, s);
            if (l.amount == 0 || l.records >= limit) continue;
            uint256 age = Math.min(l.age + (block.timestamp - l.since), P.HEAT_AGE_CAP);
            if (age >= since && age < bestAge) (best, bestAge) = (s, age);
        }
    }

    /// @dev The pair's reserves, supply and fresh TWAP; with `band`, the spot must sit within
    ///      VENT_BAND_BPS of it (the Vent's own market checks).
    function _market(uint256 j, bool band) internal view returns (uint256 rE, uint256 rQ, uint256 supply, uint256 twap) {
        EmberPair pair = _pairAt(j);
        (uint112 e, uint112 q,) = pair.getReserves();
        (rE, rQ, supply) = (e, q, pair.totalSupply());
        if (rE == 0 || rQ == 0 || supply == 0) revert NoOracle(j);
        uint32 elapsed;
        try pair.consult(uint32(P.PAIR_TWAP_SECONDS)) returns (uint256 px, uint32 el) {
            (twap, elapsed) = (px, el);
        } catch {
            revert NoOracle(j);
        }
        if (elapsed > P.VENT_ORACLE_MAX_AGE || twap == 0) revert StaleOracle(j, elapsed);
        if (band) {
            uint256 spot = (rQ << 112) / rE;
            uint256 gap = spot > twap ? spot - twap : twap - spot;
            if (gap * BPS > twap * P.VENT_BAND_BPS) revert OutOfBand(j, spot, twap);
        }
    }

    /// @dev Pool j stakes pair j's LP: only the two LP pools cast.
    function _castPool(uint256 pool) internal pure returns (uint256) {
        if (pool >= PAIR_COUNT) revert UnknownPool(pool);
        return pool;
    }

    function _pairAt(uint256 j) internal view returns (EmberPair) {
        if (j == 0) return PAIR_0;
        if (j == 1) return PAIR_1;
        revert UnknownPool(j);
    }

    function _poolAt(uint256 j) internal view returns (ForgePool) {
        return j == 0 ? POOL_0 : POOL_1;
    }
}
