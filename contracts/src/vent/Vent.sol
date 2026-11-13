// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";

/// @notice A Forge pool's fee ledgers, pulled by the Vent (its FEE_COLLECTOR).
interface IVentFeePool {
    function collectFees() external returns (uint256 deposit, uint256 withdrawal, uint256 emergency);
    function STAKE_TOKEN() external view returns (IERC20);
}

/// @notice What the Vent uses of an EMBER pair (its FEE_ROUTER).
interface IVentPair {
    function QUOTE() external view returns (IERC20);
    function totalSupply() external view returns (uint256);
    function getReserves() external view returns (uint112 ember, uint112 quote, uint32 updatedAt);
    function swapsPaused() external view returns (bool);
    function consult(uint32 window) external view returns (uint256 priceX112, uint32 elapsed);
    function quoteBuy(uint256 quoteIn, uint256 share) external view returns (uint256 emberOut, uint256 fee);
    function buy(uint256 quoteIn, uint256 minEmberOut, address to) external returns (uint256 emberOut);
    function redeem(uint256 liquidity, uint256 emberMin, uint256 quoteMin, address to)
        external
        returns (uint256 ember, uint256 quote);
    function collectProtocolFees() external returns (uint256 burn, uint256 liquidity, uint256 quoteYield);
}

/// @notice The Mantle's registered burn: burning recognizes the burn and books its Ashfall credit.
interface IVentMantle {
    function burnRegistered(uint256 amount) external returns (uint256 credit);
    function registrarCategory(address registrar) external view returns (uint8);
}

/// @title Vent
/// @notice The fee router (spec v5.5 §13; `CONTRACTS.md` FeeRouter; ADR 0020). It books every
///         protocol fee as a liability when it arrives and converts it later, under guards, with
///         nothing an administrator can redirect.
///
///         - Sources are immutable: the four Forge pools and the two EMBER pairs. Deed fees come
///           only from the immutable DEEDS market.
///         - Splits: standard Forge fees 40 burn / 40 liquidity / 10 Hearth / 10 Treasury,
///           emergency fees 50 / 25 / 25 stakers, Deed fees 50 / 50. Floors, remainder to burn.
///         - By asset: a pair's LP is redeemed at once (pro-rata, no oracle, never paused); EMBER's
///           burn and liquidity shares burn now through the Mantle; a pair's quote waits in that
///           pair's burn lane (bought back by `vent`) or match reserve (drawn by COMPOUNDER).
///           Hearth, Treasury, stakers' and Quote-yield shares are owed in kind and pushed to
///           their immutable recipients by `release`.
///         - `vent(pair)` buys EMBER back with the burn lane's quote in that pair and burns it. It
///           never reverts on an unsafe market: it defers, and the quote waits (§13 "fail closed").
///         - Accounting is in ledgers, never in balances: a donation changes nothing.
///         - No admin, no pause, no upgrade. Principal exits never touch it.
///         Not audited.
contract Vent is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 public constant FULL_SHARE = 1_000_000;
    uint256 public constant BPS = 10_000;
    uint8 internal constant PROTOCOL_BURN = 1; // Mantle.BurnCategory.Protocol

    /// @notice Who an owed share is pushed to.
    enum Recipient {
        Hearth,
        Treasury,
        Stakers,
        QuoteYield
    }

    /// @notice Why a `vent` did not buy. `None` means it bought.
    enum Deferral {
        None,
        Empty, // nothing in the burn lane
        NotEligible, // below the batch threshold and inside the wait
        Paused, // the pair's swaps are paused
        NoOracle, // no liquidity, or `consult` reverts
        Stale, // the TWAP spans more than VENT_ORACLE_MAX_AGE
        Band, // spot more than VENT_BAND_BPS from the TWAP
        Window, // the window's or the reserve's allowance is spent
        Unsafe // the buy would return less than the TWAP value less VENT_SLIPPAGE_BPS
    }

    /// @notice One pair's lanes and its window.
    struct Lane {
        uint128 burnQuote; // the burn lane: quote awaiting buyback
        uint128 matchReserve; // the liquidity lane: quote awaiting matching
        uint64 pendingSince; // when the burn lane last became nonempty
        bool draining; // a buyback started: drain until empty
        uint64 windowId; // block.timestamp / VENT_WINDOW_SECONDS of the window below
        uint128 windowBase; // the quote reserve at the window's first in-band vent
        uint128 windowSpent; // quote spent in that window
    }

    IERC20 public immutable EMBER;
    IVentMantle public immutable MANTLE;
    IVentFeePool public immutable POOL_0;
    IVentFeePool public immutable POOL_1;
    IVentFeePool public immutable POOL_2;
    IVentFeePool public immutable POOL_3;
    /// @notice BlastPool: its quote is a USD stablecoin, so its burn lane also has the batch
    ///         threshold [P].
    IVentPair public immutable PAIR_0;
    /// @notice SmelterPool: the 24 h clock alone [P].
    IVentPair public immutable PAIR_1;
    address public immutable HEARTH;
    address public immutable TREASURY;
    /// @notice The emergency-exit stakers' share (config `emergencyExit.routing.stakersPct`) [P].
    address public immutable STAKERS;
    /// @notice The sell-side Quote yield's Heat²-weighted distributor.
    address public immutable QUOTE_YIELD;
    /// @notice The Deed market: the only booker of Deed fees; zero means none can be booked.
    address public immutable DEEDS;
    /// @notice The only drawer of match-reserve quote (the Stoke-into-LP and Casting consumer);
    ///         zero means none can be drawn.
    address public immutable COMPOUNDER;

    Lane[2] internal _lanes;
    /// @notice Shares owed in kind, per recipient and token.
    mapping(Recipient => mapping(IERC20 => uint256)) public owed;
    /// @notice EMBER burned through the Mantle, and the Ashfall credit it booked.
    uint256 public totalBurned;
    uint256 public totalCredit;

    event FeesBooked(address indexed source, IERC20 indexed token, uint256 standard, uint256 emergency, uint256 deed);
    event PairFeesBooked(uint256 indexed pair, uint256 burn, uint256 liquidity, uint256 quoteYield);
    event Unwound(uint256 indexed pair, uint256 liquidity, uint256 ember, uint256 quote);
    event Burned(uint256 amount, uint256 credit);
    event Vented(uint256 indexed pair, uint256 quoteIn, uint256 emberOut, uint256 twapX112);
    event VentDeferred(uint256 indexed pair, Deferral reason);
    event VentOverdue(uint256 indexed pair, uint256 pendingSince);
    event WindowOpened(uint256 indexed pair, uint256 windowId, uint256 baseReserve);
    event Released(Recipient indexed recipient, IERC20 indexed token, address to, uint256 amount);
    event MatchReserveDrawn(uint256 indexed pair, uint256 amount);

    error ZeroAddress();
    error NotRegistrar();
    error BadPair(uint256 pair);
    error BadPool(uint256 pool);
    error NotDeeds();
    error NotCompounder();
    error UnknownAsset(IERC20 token);
    error ZeroAmount();
    error NonStandardToken();
    error ExceedsReserve(uint256 amount, uint256 available);

    constructor(
        IERC20 ember,
        IVentMantle mantle,
        IVentFeePool[4] memory pools,
        IVentPair[2] memory pairs,
        address hearth,
        address treasury,
        address stakers,
        address quoteYield,
        address deeds,
        address compounder
    ) {
        if (address(ember) == address(0) || address(mantle) == address(0)) revert ZeroAddress();
        for (uint256 i; i < 4; ++i) {
            if (address(pools[i]) == address(0)) revert ZeroAddress();
        }
        if (address(pairs[0]) == address(0) || address(pairs[1]) == address(0)) revert ZeroAddress();
        if (hearth == address(0) || treasury == address(0) || stakers == address(0) || quoteYield == address(0)) {
            revert ZeroAddress();
        }
        // The pools and pairs may not exist yet (the pairs are an add-on): nothing is called on
        // them here. The Mantle is, since its registrars are fixed when it is built.
        if (mantle.registrarCategory(address(this)) != PROTOCOL_BURN) revert NotRegistrar();
        (EMBER, MANTLE) = (ember, mantle);
        (POOL_0, POOL_1, POOL_2, POOL_3) = (pools[0], pools[1], pools[2], pools[3]);
        (PAIR_0, PAIR_1) = (pairs[0], pairs[1]);
        (HEARTH, TREASURY, STAKERS, QUOTE_YIELD) = (hearth, treasury, stakers, quoteYield);
        (DEEDS, COMPOUNDER) = (deeds, compounder);
    }

    // ── collection ────────────────────────────────────────────────────────

    /// @notice Pull pool `i`'s fees and book them: deposit and withdrawal fees at the standard
    ///         split, emergency fees at the emergency split.
    function collectPool(uint256 i) external nonReentrant returns (uint256 standard, uint256 emergency) {
        IVentFeePool pool = _pool(i);
        uint256 withdrawal;
        (standard, withdrawal, emergency) = pool.collectFees();
        standard += withdrawal;
        IERC20 token = pool.STAKE_TOKEN();
        _book(token, standard, emergency, 0);
        emit FeesBooked(address(pool), token, standard, emergency, 0);
    }

    /// @notice Pull pair `j`'s protocol swap fees, already in its quote and split by lane.
    function collectPair(uint256 j) external nonReentrant returns (uint256 burn, uint256 liquidity, uint256 quoteYield) {
        IVentPair pair = _pair(j);
        (burn, liquidity, quoteYield) = pair.collectProtocolFees();
        Lane storage l = _lanes[j];
        _addBurnQuote(l, burn);
        l.matchReserve = SafeCast.toUint128(l.matchReserve + liquidity);
        if (quoteYield != 0) owed[Recipient.QuoteYield][pair.QUOTE()] += quoteYield;
        emit PairFeesBooked(j, burn, liquidity, quoteYield);
    }

    /// @notice Every source in one call. A source that reverts (a pool whose pair is not deployed
    ///         yet, an unknown asset) is skipped; its fees stay where they are.
    function collectAll() external {
        for (uint256 i; i < 4; ++i) {
            try this.collectPool(i) {} catch {}
        }
        for (uint256 j; j < 2; ++j) {
            try this.collectPair(j) {} catch {}
        }
    }

    /// @notice The Deed market books its 1% sale fee, pulled exactly, at the Deed split. Only
    ///         DEEDS may: a public booking would let donations earn Protocol Ashfall credit.
    function bookDeedFee(IERC20 token, uint256 amount) external nonReentrant {
        if (DEEDS == address(0) || msg.sender != DEEDS) revert NotDeeds();
        if (amount == 0) revert ZeroAmount();
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - before != amount) revert NonStandardToken();
        _book(token, 0, 0, amount);
        emit FeesBooked(msg.sender, token, 0, 0, amount);
    }

    // ── the burn lane ─────────────────────────────────────────────────────

    /// @notice Buy EMBER back with pair `j`'s burn-lane quote, within every guard, and burn it.
    ///         Anyone may call; an unsafe or ineligible call defers and spends nothing.
    function vent(uint256 j) external nonReentrant returns (Deferral reason, uint256 quoteIn, uint256 emberOut) {
        IVentPair pair = _pair(j);
        Lane storage l = _lanes[j];
        uint256 twap;
        uint256 minOut;
        (reason, quoteIn, twap, minOut) = _size(j, pair, l);
        if (reason != Deferral.None) return (_defer(j, l, reason), 0, 0);

        uint256 left = uint256(l.burnQuote) - quoteIn;
        l.burnQuote = SafeCast.toUint128(left);
        l.windowSpent = SafeCast.toUint128(uint256(l.windowSpent) + quoteIn);
        if (left == 0) (l.draining, l.pendingSince) = (false, 0);
        else l.draining = true;

        pair.QUOTE().forceApprove(address(pair), quoteIn);
        emberOut = pair.buy(quoteIn, minOut, address(this));
        _burn(emberOut);
        emit Vented(j, quoteIn, emberOut, twap);
    }

    /// @dev Every guard in order; on success the spend, the TWAP and the minimum out.
    function _size(uint256 j, IVentPair pair, Lane storage l)
        internal
        returns (Deferral, uint256 quoteIn, uint256 twap, uint256 minOut)
    {
        uint256 pending = l.burnQuote;
        if (pending == 0) return (Deferral.Empty, 0, 0, 0);
        if (!(l.draining || block.timestamp >= l.pendingSince + P.VENT_MAX_WAIT || pending >= minBatch(j))) {
            return (Deferral.NotEligible, 0, 0, 0);
        }
        Deferral reason;
        uint256 rQ;
        (reason, twap, rQ) = _market(pair);
        if (reason != Deferral.None) return (reason, 0, 0, 0);

        // The window's base is fixed at its first in-band vent; repeated calls cannot reset it,
        // and the reserves are the pair's internal ones, which a donation cannot move.
        uint256 id = block.timestamp / P.VENT_WINDOW_SECONDS;
        if (l.windowId != id || l.windowBase == 0) {
            // A window id fits 64 bits for 10^13 years; rQ is a uint112 reserve.
            // forge-lint: disable-next-line(unsafe-typecast)
            (l.windowId, l.windowBase, l.windowSpent) = (uint64(id), uint128(rQ), 0);
            emit WindowOpened(j, id, rQ);
        }
        uint256 allowance = (uint256(l.windowBase) * P.VENT_WINDOW_MAX_BPS) / BPS;
        allowance = allowance > l.windowSpent ? allowance - l.windowSpent : 0;
        quoteIn = _min(_min(pending, (rQ * P.VENT_CHUNK_BPS) / BPS), allowance);
        if (quoteIn == 0) return (Deferral.Window, 0, 0, 0);

        // The minimum is the TWAP value of the spend less the slippage cap, the pair's fee
        // included: a buy that would return less waits.
        // quoteIn is at most a uint112 reserve's chunk, so the product stays under 2^238.
        minOut = ((quoteIn << 112) * (BPS - P.VENT_SLIPPAGE_BPS)) / (twap * BPS);
        try pair.quoteBuy(quoteIn, FULL_SHARE) returns (uint256 out, uint256) {
            if (out < minOut) return (Deferral.Unsafe, 0, 0, 0);
        } catch {
            return (Deferral.Unsafe, 0, 0, 0);
        }
        return (Deferral.None, quoteIn, twap, minOut);
    }

    /// @dev The pair's market checks: swaps live, liquidity, a fresh TWAP, and spot within the band.
    function _market(IVentPair pair) internal view returns (Deferral, uint256 twap, uint256 rQ) {
        if (pair.swapsPaused()) return (Deferral.Paused, 0, 0);
        (uint112 rE, uint112 q,) = pair.getReserves();
        if (rE == 0 || pair.totalSupply() == 0) return (Deferral.NoOracle, 0, 0);
        uint32 elapsed;
        try pair.consult(uint32(P.PAIR_TWAP_SECONDS)) returns (uint256 px, uint32 e) {
            (twap, elapsed) = (px, e);
        } catch {
            return (Deferral.NoOracle, 0, 0);
        }
        if (elapsed > P.VENT_ORACLE_MAX_AGE || twap == 0) return (Deferral.Stale, 0, 0);
        uint256 spot = (uint256(q) << 112) / rE;
        uint256 gap = spot > twap ? spot - twap : twap - spot;
        if (gap * BPS > twap * P.VENT_BAND_BPS) return (Deferral.Band, 0, 0);
        return (Deferral.None, twap, q);
    }

    /// @notice The burn lane's batch threshold in quote units: VENT_MIN_BATCH_USD whole dollars
    ///         in BlastPool's USD-stablecoin quote, none for SmelterPool (its 24 h clock alone).
    function minBatch(uint256 j) public view returns (uint256) {
        if (j != 0) return type(uint256).max;
        return P.VENT_MIN_BATCH_USD * 10 ** IERC20Metadata(address(PAIR_0.QUOTE())).decimals();
    }

    // ── releases and the match reserve ────────────────────────────────────

    /// @notice Push everything owed to `who` in `token`. Each recipient is released on its own, so
    ///         one that refuses blocks no other.
    function release(Recipient who, IERC20 token) external nonReentrant returns (uint256 amount) {
        amount = owed[who][token];
        if (amount == 0) return 0;
        owed[who][token] = 0;
        address to = recipientOf(who);
        token.safeTransfer(to, amount);
        emit Released(who, token, to, amount);
    }

    /// @notice COMPOUNDER draws match-reserve quote for its reservations (spec §7), which it
    ///         keeps; what stays here is unreserved. Never Treasury-spendable.
    function drawMatchReserve(uint256 j, uint256 amount) external nonReentrant {
        if (COMPOUNDER == address(0) || msg.sender != COMPOUNDER) revert NotCompounder();
        IVentPair pair = _pair(j);
        if (amount == 0) revert ZeroAmount();
        Lane storage l = _lanes[j];
        if (amount > l.matchReserve) revert ExceedsReserve(amount, l.matchReserve);
        l.matchReserve = SafeCast.toUint128(uint256(l.matchReserve) - amount);
        pair.QUOTE().safeTransfer(COMPOUNDER, amount);
        emit MatchReserveDrawn(j, amount);
    }

    // ── views ─────────────────────────────────────────────────────────────

    function lane(uint256 j) external view returns (Lane memory) {
        _pair(j);
        return _lanes[j];
    }

    function recipientOf(Recipient who) public view returns (address) {
        if (who == Recipient.Hearth) return HEARTH;
        if (who == Recipient.Treasury) return TREASURY;
        if (who == Recipient.Stakers) return STAKERS;
        return QUOTE_YIELD;
    }

    // ── internals ─────────────────────────────────────────────────────────

    /// @dev Book `standard`, `emergency` and `deed` amounts of `token`, which the Vent now holds.
    function _book(IERC20 token, uint256 standard, uint256 emergency, uint256 deed) internal {
        uint256 total = standard + emergency + deed;
        if (total == 0) return;
        if (token == EMBER) return _route(token, true, 0, standard, emergency, deed);
        for (uint256 j; j < 2; ++j) {
            IVentPair pair = _pair(j);
            if (address(token) == address(pair)) return _unwind(j, pair, standard, emergency, deed);
            if (token == pair.QUOTE()) return _route(token, false, j, standard, emergency, deed);
        }
        revert UnknownAsset(token);
    }

    /// @dev Redeem LP once, then split each side between the kinds by their LP weights: floors
    ///      for the standard and Deed kinds, the rest to the emergency kind. LP worth nothing on
    ///      either side is left unbooked.
    function _unwind(uint256 j, IVentPair pair, uint256 standard, uint256 emergency, uint256 deed) internal {
        uint256 total = standard + emergency + deed;
        if (_worthless(pair, total)) return;
        (uint256 e, uint256 q) = pair.redeem(total, 0, 0, address(this));
        emit Unwound(j, total, e, q);
        _routeShare(EMBER, true, 0, e, standard, emergency, total);
        _routeShare(pair.QUOTE(), false, j, q, standard, emergency, total);
    }

    /// @dev True when `liquidity` would redeem to nothing on both sides.
    function _worthless(IVentPair pair, uint256 liquidity) internal view returns (bool) {
        (uint112 rE, uint112 rQ,) = pair.getReserves();
        uint256 supply = pair.totalSupply();
        return (liquidity * rE) / supply == 0 && (liquidity * rQ) / supply == 0;
    }

    /// @dev Route `x` of one redeemed side, split between the kinds by their LP weights.
    function _routeShare(
        IERC20 token,
        bool isEmber,
        uint256 j,
        uint256 x,
        uint256 standard,
        uint256 emergency,
        uint256 total
    ) internal {
        uint256 s = (x * standard) / total;
        uint256 d = (x * (total - standard - emergency)) / total;
        _route(token, isEmber, j, s, x - s - d, d);
    }

    /// @dev Split each kind's amount into its lanes, floors with the remainder to burn, and book
    ///      them by asset: EMBER's burn and liquidity shares burn now; a quote's wait in pair `j`.
    function _route(IERC20 token, bool isEmber, uint256 j, uint256 standard, uint256 emergency, uint256 deed)
        internal
    {
        uint256 kept = _owe(token, standard, emergency);
        uint256 liquidity = (standard * P.VENT_LIQUIDITY_PCT) / 100 + (emergency * P.EMERGENCY_LIQUIDITY_PCT) / 100
            + (deed * P.DEED_FEE_LIQUIDITY_PCT) / 100;
        uint256 burn = standard + emergency + deed - kept - liquidity;
        if (isEmber) {
            _burn(burn + liquidity); // the liquidity lane's EMBER half is burned (§13)
        } else {
            Lane storage l = _lanes[j];
            _addBurnQuote(l, burn);
            l.matchReserve = SafeCast.toUint128(uint256(l.matchReserve) + liquidity);
        }
    }

    /// @dev Book the Hearth, Treasury and stakers' shares in kind; returns their sum.
    function _owe(IERC20 token, uint256 standard, uint256 emergency) internal returns (uint256 kept) {
        uint256 hearth = (standard * P.VENT_HEARTH_PCT) / 100;
        uint256 treasury = (standard * P.VENT_TREASURY_PCT) / 100;
        uint256 stakers = (emergency * P.EMERGENCY_STAKERS_PCT) / 100;
        if (hearth != 0) owed[Recipient.Hearth][token] += hearth;
        if (treasury != 0) owed[Recipient.Treasury][token] += treasury;
        if (stakers != 0) owed[Recipient.Stakers][token] += stakers;
        return hearth + treasury + stakers;
    }

    function _addBurnQuote(Lane storage l, uint256 amount) internal {
        if (amount == 0) return;
        if (l.burnQuote == 0) l.pendingSince = uint64(block.timestamp);
        l.burnQuote = SafeCast.toUint128(uint256(l.burnQuote) + amount);
    }

    function _burn(uint256 amount) internal {
        if (amount == 0) return;
        EMBER.forceApprove(address(MANTLE), amount);
        uint256 credit = MANTLE.burnRegistered(amount);
        (totalBurned, totalCredit) = (totalBurned + amount, totalCredit + credit);
        emit Burned(amount, credit);
    }

    function _defer(uint256 j, Lane storage l, Deferral reason) internal returns (Deferral) {
        if (reason != Deferral.Empty && block.timestamp >= l.pendingSince + P.VENT_ALERT_AFTER) {
            emit VentOverdue(j, l.pendingSince);
        }
        emit VentDeferred(j, reason);
        return reason;
    }

    function _pool(uint256 i) internal view returns (IVentFeePool) {
        if (i == 0) return POOL_0;
        if (i == 1) return POOL_1;
        if (i == 2) return POOL_2;
        if (i == 3) return POOL_3;
        revert BadPool(i);
    }

    function _pair(uint256 j) internal view returns (IVentPair) {
        if (j == 0) return PAIR_0;
        if (j == 1) return PAIR_1;
        revert BadPair(j);
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
