// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";

/// @title EmberPair
/// @notice A full-range constant-product pair of EMBER and one quote asset, and its own receipt
///         (spec v5.5 §14; ADR 0015). Deployed twice: BlastPool (EMBER/USDC) and SmelterPool
///         (EMBER/WETH), whose receipts Forge pools 0 and 1 stake.
///
///         - Swaps are exact-in and pull-based: no callbacks, no flash swaps.
///         - Every fee is taken in the quote asset: a buy's from its input, a sell's from its
///           output. The LP fee stays in the reserves. The protocol's burn, liquidity and Quote
///           yield parts are booked outside them for the fee router to pull.
///         - Only the immutable FLOW may scale the protocol share down (a rebate or a Compound's
///           waiver); the LP fee is never reduced.
///         - The reserves are internal: donations change nothing.
///         - `redeem` pays in kind and is never paused; only swaps can be.
///         Not audited.
contract EmberPair is ERC20, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice ppm denominator, and the full protocol share.
    uint256 public constant FULL_SHARE = 1_000_000;
    /// @notice Receipt units minted to the burn address by the first deposit: a share-price floor.
    uint256 public constant MINIMUM_LIQUIDITY = 1000;
    /// @notice Observations are written at most this often, so 8 of them span more than the TWAP.
    uint32 public constant OBSERVATION_PERIOD = uint32(P.PAIR_TWAP_SECONDS / 6);
    uint256 public constant OBSERVATIONS = 8;

    IERC20 public immutable EMBER;
    IERC20 public immutable QUOTE;
    /// @notice 10^(18 − quote decimals): the first deposit scales the quote to 18 decimals.
    uint256 public immutable QUOTE_SCALE;
    /// @notice The Vent: the only caller of `collectProtocolFees`.
    address public immutable FEE_ROUTER;
    /// @notice The only caller of `flowBuy` / `flowSell`; zero means no rebate or waiver exists.
    address public immutable FLOW;
    /// @notice May pause swaps, never redemptions; zero means swaps cannot be paused.
    address public immutable GUARDIAN;
    /// @notice Makes the first deposit, which sets the price (Kindling).
    address public immutable INITIALIZER;

    struct Reserves {
        uint112 ember;
        uint112 quote;
        uint32 updatedAt; // block.timestamp mod 2^32 of the last cumulative update
    }

    struct Observation {
        uint32 timestamp;
        uint256 priceCumulative;
    }

    struct Ledger {
        uint128 burn;
        uint128 liquidity;
    }

    struct Meta {
        uint128 quoteYield;
        uint8 latest; // index of the newest observation
        uint8 count; // observations written, up to OBSERVATIONS
        bool swapsPaused;
    }

    Reserves internal _reserves;
    /// @notice Σ (quote per EMBER as UQ112.112) × seconds; wraps by design.
    uint256 public priceCumulative;
    Ledger internal _ledger;
    Meta internal _meta;
    Observation[8] internal _observations;

    struct FeeParts {
        uint256 lp;
        uint256 burn;
        uint256 liquidity;
        uint256 quoteYield;
        uint256 total;
    }

    event Swap(
        address indexed sender,
        address indexed to,
        bool buy,
        uint256 amountIn,
        uint256 amountOut,
        uint256 lpFee,
        uint256 burnFee,
        uint256 liquidityFee,
        uint256 quoteYieldFee,
        uint256 share
    );
    event LiquidityAdded(address indexed sender, address indexed to, uint256 ember, uint256 quote, uint256 liquidity);
    event LiquidityRedeemed(address indexed owner, address indexed to, uint256 liquidity, uint256 ember, uint256 quote);
    event ProtocolFeesCollected(uint256 burn, uint256 liquidity, uint256 quoteYield);
    event ReservesUpdated(uint112 ember, uint112 quote);
    event SwapsPausedSet(bool paused);

    error ZeroAddress();
    error SameToken();
    error BadDecimals(uint8 decimals);
    error ZeroAmount();
    error NoLiquidity();
    error NotInitializer();
    error NotFlow();
    error NotFeeRouter();
    error NotGuardian();
    error SwapsPaused();
    error BadShare(uint256 share);
    error TooSmall();
    error ZeroOutput();
    error ZeroLiquidity();
    error LiquidityTooLow(uint256 liquidity);
    error Slippage(uint256 got, uint256 minimum);
    error NonStandardToken();
    error ReserveOverflow();
    error BadWindow();
    error OracleNotReady();

    constructor(
        string memory name_,
        string memory symbol_,
        IERC20 ember,
        IERC20 quote,
        address feeRouter,
        address flow,
        address guardian,
        address initializer
    ) ERC20(name_, symbol_) {
        if (address(ember) == address(0) || address(quote) == address(0)) revert ZeroAddress();
        if (feeRouter == address(0) || initializer == address(0)) revert ZeroAddress();
        if (address(ember) == address(quote)) revert SameToken();
        uint8 ed = IERC20Metadata(address(ember)).decimals();
        if (ed != 18) revert BadDecimals(ed);
        uint8 qd = IERC20Metadata(address(quote)).decimals();
        if (qd > 18) revert BadDecimals(qd);
        (EMBER, QUOTE, QUOTE_SCALE) = (ember, quote, 10 ** (18 - qd));
        (FEE_ROUTER, FLOW, GUARDIAN, INITIALIZER) = (feeRouter, flow, guardian, initializer);
    }

    // ── swaps ─────────────────────────────────────────────────────────────

    /// @notice Spend `quoteIn` of the quote asset on EMBER, at the full fee.
    function buy(uint256 quoteIn, uint256 minEmberOut, address to) external nonReentrant returns (uint256 emberOut) {
        return _buy(quoteIn, minEmberOut, to, FULL_SHARE);
    }

    /// @notice Sell `emberIn` EMBER for the quote asset, at the full fee.
    function sell(uint256 emberIn, uint256 minQuoteOut, address to) external nonReentrant returns (uint256 quoteOut) {
        return _sell(emberIn, minQuoteOut, to, FULL_SHARE);
    }

    /// @notice Flow's buy, charging `share` ppm of the protocol share (10⁶ full, 5·10⁵ Bedrock, 0 a
    ///         Compound). Flow decides who qualifies; the LP fee is unchanged.
    function flowBuy(uint256 quoteIn, uint256 minEmberOut, address to, uint256 share)
        external
        nonReentrant
        returns (uint256 emberOut)
    {
        _onlyFlow(share);
        return _buy(quoteIn, minEmberOut, to, share);
    }

    /// @notice Flow's sell; see `flowBuy`.
    function flowSell(uint256 emberIn, uint256 minQuoteOut, address to, uint256 share)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        _onlyFlow(share);
        return _sell(emberIn, minQuoteOut, to, share);
    }

    function _onlyFlow(uint256 share) internal view {
        if (FLOW == address(0) || msg.sender != FLOW) revert NotFlow();
        if (share > FULL_SHARE) revert BadShare(share);
    }

    function _buy(uint256 quoteIn, uint256 minOut, address to, uint256 share) internal returns (uint256 out) {
        FeeParts memory f;
        (out, f) = _quoteBuy(quoteIn, share);
        if (out < minOut) revert Slippage(out, minOut);
        _pull(QUOTE, quoteIn);
        Reserves memory r = _updateOracle();
        _setReserves(r.ember - out, uint256(r.quote) + (quoteIn - f.total) + f.lp);
        _book(f);
        EMBER.safeTransfer(to, out);
        emit Swap(msg.sender, to, true, quoteIn, out, f.lp, f.burn, f.liquidity, f.quoteYield, share);
    }

    function _sell(uint256 emberIn, uint256 minOut, address to, uint256 share) internal returns (uint256 out) {
        FeeParts memory f;
        uint256 gross;
        (out, gross, f) = _quoteSell(emberIn, share);
        if (out < minOut) revert Slippage(out, minOut);
        _pull(EMBER, emberIn);
        Reserves memory r = _updateOracle();
        _setReserves(uint256(r.ember) + emberIn, uint256(r.quote) - gross + f.lp);
        _book(f);
        QUOTE.safeTransfer(to, out);
        emit Swap(msg.sender, to, false, emberIn, out, f.lp, f.burn, f.liquidity, f.quoteYield, share);
    }

    function _quoteBuy(uint256 quoteIn, uint256 share) internal view returns (uint256 out, FeeParts memory f) {
        if (_meta.swapsPaused) revert SwapsPaused();
        if (quoteIn == 0) revert ZeroAmount();
        if (quoteIn > type(uint112).max) revert ReserveOverflow();
        Reserves memory r = _reserves;
        if (totalSupply() == 0) revert NoLiquidity();
        f = _fees(quoteIn, P.PAIR_BUY_BURN_PPM, P.PAIR_BUY_LIQUIDITY_PPM, 0, share);
        if (f.total >= quoteIn) revert TooSmall();
        uint256 net = quoteIn - f.total;
        out = (uint256(r.ember) * net) / (uint256(r.quote) + net);
        if (out == 0) revert ZeroOutput();
    }

    function _quoteSell(uint256 emberIn, uint256 share)
        internal
        view
        returns (uint256 out, uint256 gross, FeeParts memory f)
    {
        if (_meta.swapsPaused) revert SwapsPaused();
        if (emberIn == 0) revert ZeroAmount();
        if (emberIn > type(uint112).max) revert ReserveOverflow();
        Reserves memory r = _reserves;
        if (totalSupply() == 0) revert NoLiquidity();
        gross = (uint256(r.quote) * emberIn) / (uint256(r.ember) + emberIn);
        f = _fees(gross, P.PAIR_SELL_BURN_PPM, P.PAIR_SELL_LIQUIDITY_PPM, P.PAIR_SELL_QUOTE_YIELD_PPM, share);
        if (f.total >= gross) revert TooSmall();
        out = gross - f.total;
    }

    /// @dev Every component rounds up, toward the pair; the protocol parts scale by `share` ppm.
    function _fees(uint256 g, uint256 burnPpm, uint256 liquidityPpm, uint256 quoteYieldPpm, uint256 share)
        internal
        pure
        returns (FeeParts memory f)
    {
        f.lp = Math.ceilDiv(g * P.PAIR_LP_FEE_PPM, FULL_SHARE);
        f.burn = Math.ceilDiv(g * burnPpm * share, FULL_SHARE * FULL_SHARE);
        f.liquidity = Math.ceilDiv(g * liquidityPpm * share, FULL_SHARE * FULL_SHARE);
        f.quoteYield = Math.ceilDiv(g * quoteYieldPpm * share, FULL_SHARE * FULL_SHARE);
        f.total = f.lp + f.burn + f.liquidity + f.quoteYield;
    }

    function _book(FeeParts memory f) internal {
        Ledger memory l = _ledger;
        _ledger = Ledger(SafeCast.toUint128(l.burn + f.burn), SafeCast.toUint128(l.liquidity + f.liquidity));
        if (f.quoteYield != 0) _meta.quoteYield = SafeCast.toUint128(_meta.quoteYield + f.quoteYield);
    }

    // ── liquidity ─────────────────────────────────────────────────────────

    /// @notice Add liquidity at the current ratio, taking the largest amounts within the desired
    ///         ones. The first deposit sets the price and must come from INITIALIZER.
    function addLiquidity(uint256 emberDesired, uint256 quoteDesired, uint256 emberMin, uint256 quoteMin, address to)
        external
        nonReentrant
        returns (uint256 ember, uint256 quote, uint256 liquidity)
    {
        if (emberDesired == 0 || quoteDesired == 0) revert ZeroAmount();
        if (emberDesired > type(uint112).max || quoteDesired > type(uint112).max) revert ReserveOverflow();
        uint256 supply = totalSupply();
        Reserves memory r = _reserves;
        if (supply == 0) {
            if (msg.sender != INITIALIZER) revert NotInitializer();
            (ember, quote) = (emberDesired, quoteDesired);
            liquidity = Math.sqrt(ember * quote * QUOTE_SCALE);
            if (liquidity <= MINIMUM_LIQUIDITY) revert LiquidityTooLow(liquidity);
            _mint(P.BURN_ADDRESS, MINIMUM_LIQUIDITY);
            liquidity -= MINIMUM_LIQUIDITY;
        } else {
            (ember, quote) = (emberDesired, (emberDesired * r.quote) / r.ember);
            if (quote > quoteDesired) (ember, quote) = ((quoteDesired * r.ember) / r.quote, quoteDesired);
            liquidity = Math.min((ember * supply) / r.ember, (quote * supply) / r.quote);
            if (liquidity == 0) revert ZeroLiquidity();
        }
        if (ember < emberMin) revert Slippage(ember, emberMin);
        if (quote < quoteMin) revert Slippage(quote, quoteMin);
        _pull(EMBER, ember);
        _pull(QUOTE, quote);
        r = _updateOracle();
        _setReserves(uint256(r.ember) + ember, uint256(r.quote) + quote);
        _mint(to, liquidity);
        emit LiquidityAdded(msg.sender, to, ember, quote, liquidity);
    }

    /// @notice Redeem `liquidity` of the caller's receipts for their pro-rata reserves, in kind.
    ///         No fee, no oracle, never paused.
    function redeem(uint256 liquidity, uint256 emberMin, uint256 quoteMin, address to)
        external
        nonReentrant
        returns (uint256 ember, uint256 quote)
    {
        if (liquidity == 0) revert ZeroAmount();
        uint256 supply = totalSupply();
        if (supply == 0) revert NoLiquidity();
        Reserves memory r = _reserves;
        (ember, quote) = ((liquidity * r.ember) / supply, (liquidity * r.quote) / supply);
        if (ember == 0 && quote == 0) revert ZeroOutput();
        if (ember < emberMin) revert Slippage(ember, emberMin);
        if (quote < quoteMin) revert Slippage(quote, quoteMin);
        _burn(msg.sender, liquidity);
        r = _updateOracle();
        _setReserves(r.ember - ember, r.quote - quote);
        EMBER.safeTransfer(to, ember);
        QUOTE.safeTransfer(to, quote);
        emit LiquidityRedeemed(msg.sender, to, liquidity, ember, quote);
    }

    // ── protocol fees, pausing ────────────────────────────────────────────

    /// @notice The fee router pulls the booked protocol fees, in the quote asset, split by lane.
    function collectProtocolFees() external nonReentrant returns (uint256 burn, uint256 liquidity, uint256 quoteYield) {
        if (msg.sender != FEE_ROUTER) revert NotFeeRouter();
        Ledger memory l = _ledger;
        (burn, liquidity, quoteYield) = (l.burn, l.liquidity, _meta.quoteYield);
        delete _ledger;
        _meta.quoteYield = 0;
        uint256 total = burn + liquidity + quoteYield;
        if (total != 0) QUOTE.safeTransfer(FEE_ROUTER, total);
        emit ProtocolFeesCollected(burn, liquidity, quoteYield);
    }

    function setSwapsPaused(bool paused) external {
        if (GUARDIAN == address(0) || msg.sender != GUARDIAN) revert NotGuardian();
        _meta.swapsPaused = paused;
        emit SwapsPausedSet(paused);
    }

    // ── oracle ────────────────────────────────────────────────────────────

    /// @notice Bring the cumulative price to now and write an observation if one is due.
    function checkpoint() external nonReentrant {
        if (totalSupply() == 0) revert NoLiquidity();
        _updateOracle();
        _reserves.updatedAt = uint32(block.timestamp);
    }

    /// @notice EMBER's average price in quote (UQ112.112, quote-wei per EMBER-wei) since the
    ///         newest observation at least `window` seconds old, and the span it covers (≥ window).
    function consult(uint32 window) external view returns (uint256 priceX112, uint32 elapsed) {
        if (window == 0) revert BadWindow();
        (uint256 cumNow, uint32 now_) = currentCumulativePrice();
        Meta memory m = _meta;
        for (uint256 k; k < m.count; ++k) {
            Observation memory o = _observations[(m.latest + OBSERVATIONS - k) % OBSERVATIONS];
            unchecked {
                elapsed = now_ - o.timestamp;
                if (elapsed >= window) return ((cumNow - o.priceCumulative) / elapsed, elapsed);
            }
        }
        revert OracleNotReady();
    }

    /// @notice The cumulative price extrapolated to this block at the current reserves.
    function currentCumulativePrice() public view returns (uint256 cumulative, uint32 timestamp) {
        Reserves memory r = _reserves;
        timestamp = uint32(block.timestamp);
        cumulative = priceCumulative;
        unchecked {
            uint32 dt = timestamp - r.updatedAt;
            if (dt != 0 && r.ember != 0) cumulative += _price(r) * dt;
        }
    }

    function _price(Reserves memory r) internal pure returns (uint256) {
        return (uint256(r.quote) << 112) / r.ember;
    }

    /// @dev Called before every reserve change, with the reserves as they were. The caller then
    ///      stamps the reserves with this block's time (`_setReserves`, or `checkpoint`).
    function _updateOracle() internal returns (Reserves memory r) {
        r = _reserves;
        uint32 ts = uint32(block.timestamp);
        uint256 cum = priceCumulative;
        unchecked {
            uint32 dt = ts - r.updatedAt;
            if (dt != 0 && r.ember != 0) {
                cum += _price(r) * dt;
                priceCumulative = cum;
            }
        }
        Meta memory m = _meta;
        unchecked {
            if (m.count == 0 || ts - _observations[m.latest].timestamp >= OBSERVATION_PERIOD) {
                // forge-lint: disable-next-line(unsafe-typecast) — below OBSERVATIONS (8)
                uint8 next = m.count == 0 ? 0 : uint8((m.latest + 1) % OBSERVATIONS);
                _observations[next] = Observation(ts, cum);
                _meta.latest = next;
                if (m.count < OBSERVATIONS) _meta.count = m.count + 1;
            }
        }
    }

    /// @dev Writes the whole reserves slot, stamping it with this block's time.
    function _setReserves(uint256 ember, uint256 quote) internal {
        if (ember > type(uint112).max || quote > type(uint112).max) revert ReserveOverflow();
        // Both fit uint112 (checked above); the timestamp wraps mod 2^32 by design.
        // forge-lint: disable-next-line(unsafe-typecast)
        _reserves = Reserves(uint112(ember), uint112(quote), uint32(block.timestamp));
        // forge-lint: disable-next-line(unsafe-typecast)
        emit ReservesUpdated(uint112(ember), uint112(quote));
    }

    /// @dev Pull exactly `amount`; a token that delivers anything else is refused.
    function _pull(IERC20 token, uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - before != amount) revert NonStandardToken();
    }

    // ── views ─────────────────────────────────────────────────────────────

    function getReserves() external view returns (uint112 ember, uint112 quote, uint32 updatedAt) {
        Reserves memory r = _reserves;
        return (r.ember, r.quote, r.updatedAt);
    }

    function protocolFees() external view returns (uint256 burn, uint256 liquidity, uint256 quoteYield) {
        Ledger memory l = _ledger;
        return (l.burn, l.liquidity, _meta.quoteYield);
    }

    function swapsPaused() external view returns (bool) {
        return _meta.swapsPaused;
    }

    function observation(uint256 i) external view returns (uint32 timestamp, uint256 cumulative) {
        Observation memory o = _observations[i];
        return (o.timestamp, o.priceCumulative);
    }

    function observationState() external view returns (uint8 latest, uint8 count) {
        return (_meta.latest, _meta.count);
    }

    /// @notice What a buy of `quoteIn` would return now at `share` ppm of the protocol share, and
    ///         its total fee; reverts as the buy would.
    function quoteBuy(uint256 quoteIn, uint256 share) external view returns (uint256 emberOut, uint256 fee) {
        if (share > FULL_SHARE) revert BadShare(share);
        FeeParts memory f;
        (emberOut, f) = _quoteBuy(quoteIn, share);
        fee = f.total;
    }

    /// @notice What a sell of `emberIn` would return now, and its total fee; see `quoteBuy`.
    function quoteSell(uint256 emberIn, uint256 share) external view returns (uint256 quoteOut, uint256 fee) {
        if (share > FULL_SHARE) revert BadShare(share);
        FeeParts memory f;
        (quoteOut,, f) = _quoteSell(emberIn, share);
        fee = f.total;
    }
}
