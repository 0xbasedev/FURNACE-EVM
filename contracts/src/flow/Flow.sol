// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";
import {EmberPair} from "../pairs/EmberPair.sol";
import {ForgePool} from "../forge/ForgePool.sol";

/// @notice A wallet's Relic fee rebate, in percent of the protocol's swap-fee share (spec v5.5 §9,
///         §14). Implemented by Relics, which is not built.
interface IFeeRebate {
    function rebatePctOf(address wallet) external view returns (uint256);
}

/// @title Flow
/// @notice The protocol's swap and zap entrypoint (spec v5.5 §14; ADR 0016): routes on the two
///         EMBER pairs at the caller's Relic rebate, single-sided zaps in and out, and the
///         fee-free "same-route" stake of the LP a zap forms (§4). Only `COMPOUNDER` gets the
///         Compound waiver. Flow holds nothing between calls and has no admin. Not audited.
contract Flow is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint256 internal constant PPM = 1_000_000;

    IERC20 public immutable EMBER;
    EmberPair public immutable PAIR0; // BlastPool, EMBER/USDC
    EmberPair public immutable PAIR1; // SmelterPool, EMBER/WETH
    ForgePool public immutable POOL0; // stakes PAIR0's receipt
    ForgePool public immutable POOL1; // stakes PAIR1's receipt
    IFeeRebate public immutable REBATES;
    /// @notice The only caller of `compoundSwap` (the future Stoke-into-LP / Casting consumer).
    address public immutable COMPOUNDER;

    event Routed(address indexed user, uint256 pair, bool buy, uint256 amountIn, uint256 amountOut, uint256 share);
    event Zapped(
        address indexed user, uint256 pair, bool fromQuote, uint256 amountIn, uint256 swapped, uint256 liquidity, uint256 position
    );
    event Unzapped(address indexed user, uint256 pair, bool toQuote, uint256 liquidity, uint256 amountOut);

    error ZeroAddress();
    error UnknownPair(uint256 pair);
    error Expired(uint256 deadline);
    error ZeroAmount();
    error NoLiquidity();
    error ZapTooLarge();
    error Slippage(uint256 got, uint256 minimum);
    error NotCompounder();

    constructor(
        IERC20 ember,
        EmberPair pair0,
        EmberPair pair1,
        ForgePool pool0,
        ForgePool pool1,
        IFeeRebate rebates,
        address compounder
    ) {
        if (address(ember) == address(0) || address(pair0) == address(0) || address(pair1) == address(0)) {
            revert ZeroAddress();
        }
        if (address(pool0) == address(0) || address(pool1) == address(0)) revert ZeroAddress();
        // No call to any of them: Flow, the pairs and the pools deploy in any order (CREATE3).
        (EMBER, PAIR0, PAIR1, POOL0, POOL1, REBATES, COMPOUNDER) = (ember, pair0, pair1, pool0, pool1, rebates, compounder);
    }

    // ── routes ────────────────────────────────────────────────────────────

    /// @notice An exact-in swap on `pair` (0 BlastPool, 1 SmelterPool) at the caller's rebate.
    function swap(uint256 pair, bool buy, uint256 amountIn, uint256 minOut, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 out)
    {
        _live(deadline);
        uint256 share = rebateShareOf(msg.sender);
        out = _route(_pair(pair), buy, amountIn, minOut, to, share, true);
        emit Routed(msg.sender, pair, buy, amountIn, out, share);
    }

    /// @notice COMPOUNDER only: a swap with the protocol share waived (spec v5.5 §14).
    function compoundSwap(uint256 pair, bool buy, uint256 amountIn, uint256 minOut, address to, uint256 deadline)
        external
        nonReentrant
        returns (uint256 out)
    {
        if (COMPOUNDER == address(0) || msg.sender != COMPOUNDER) revert NotCompounder();
        _live(deadline);
        out = _route(_pair(pair), buy, amountIn, minOut, to, 0, true);
        emit Routed(msg.sender, pair, buy, amountIn, out, 0);
    }

    /// @notice Single-sided liquidity: swap the split, add at the new ratio, refund the dust. The
    ///         receipts go to the caller.
    function zapIn(uint256 pair, bool fromQuote, uint256 amountIn, uint256 minLiquidity, uint256 deadline)
        external
        nonReentrant
        returns (uint256 liquidity)
    {
        _live(deadline);
        uint256 swapped;
        (liquidity, swapped) = _zap(_pair(pair), fromQuote, amountIn, minLiquidity, msg.sender);
        emit Zapped(msg.sender, pair, fromQuote, amountIn, swapped, liquidity, 0);
    }

    /// @notice A zap whose receipts are staked fee-free in the pair's Forge pool: `position` 0
    ///         opens one for the caller, any other id adds to the caller's own position. Only LP
    ///         formed in this call can be staked this way (spec v5.5 §4).
    function zapAndStake(
        uint256 pair,
        bool fromQuote,
        uint256 amountIn,
        uint256 minLiquidity,
        uint256 position,
        uint256 deadline
    ) external nonReentrant returns (uint256 liquidity, uint256 positionId) {
        _live(deadline);
        EmberPair p = _pair(pair);
        ForgePool pool = pair == 0 ? POOL0 : POOL1;
        uint256 swapped;
        (liquidity, swapped) = _zap(p, fromQuote, amountIn, minLiquidity, address(this));
        IERC20(address(p)).forceApprove(address(pool), liquidity);
        if (position == 0) {
            positionId = pool.openFor(msg.sender, liquidity);
        } else {
            pool.depositFor(position, msg.sender, liquidity);
            positionId = position;
        }
        emit Zapped(msg.sender, pair, fromQuote, amountIn, swapped, liquidity, positionId);
    }

    /// @notice Redeem the caller's receipts and sell the other side into one token, at the
    ///         caller's rebate. A selling route: the caller's signature, `minOut` and `deadline`
    ///         are the consent (spec v5.5 §4).
    function zapOut(uint256 pair, uint256 liquidity, bool toQuote, uint256 minOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 out)
    {
        _live(deadline);
        EmberPair p = _pair(pair);
        IERC20(address(p)).safeTransferFrom(msg.sender, address(this), liquidity);
        (uint256 e, uint256 q) = p.redeem(liquidity, 0, 0, address(this));
        uint256 share = rebateShareOf(msg.sender);
        if (toQuote) out = q + (e == 0 ? 0 : _route(p, false, e, 0, address(this), share, false));
        else out = e + (q == 0 ? 0 : _route(p, true, q, 0, address(this), share, false));
        if (out < minOut) revert Slippage(out, minOut);
        (toQuote ? p.QUOTE() : EMBER).safeTransfer(msg.sender, out);
        emit Unzapped(msg.sender, pair, toQuote, liquidity, out);
    }

    // ── the rebate ────────────────────────────────────────────────────────

    /// @notice The protocol-share scale (ppm) a wallet's swaps pay: 10⁶ − tier·10⁴, the tier
    ///         being the highest configured rebate at or below what `REBATES` reports. A source
    ///         that is unset, has no code, reverts or answers malformed data gives no rebate.
    function rebateShareOf(address wallet) public view returns (uint256) {
        if (address(REBATES) == address(0)) return PPM;
        (bool ok, bytes memory ret) = address(REBATES).staticcall(abi.encodeCall(IFeeRebate.rebatePctOf, (wallet)));
        if (!ok || ret.length != 32) return PPM;
        uint256 pct = abi.decode(ret, (uint256));
        uint256 tier = pct >= P.FLOW_REBATE_TIER_1_PCT ? P.FLOW_REBATE_TIER_1_PCT : pct >= P.FLOW_REBATE_TIER_0_PCT
            ? P.FLOW_REBATE_TIER_0_PCT
            : 0;
        return PPM - tier * 10_000;
    }

    // ── the zap split (ADR 0016 §4) ───────────────────────────────────────

    /// @notice How much of a single-sided `amountIn` a zap swaps, at `share`.
    function splitOf(uint256 pair, bool fromQuote, uint256 amountIn, uint256 share) public view returns (uint256) {
        (uint112 rE, uint112 rQ,) = _pair(pair).getReserves();
        return _split(rE, rQ, fromQuote, amountIn, share);
    }

    function _split(uint256 rE, uint256 rQ, bool fromQuote, uint256 a, uint256 share) internal pure returns (uint256) {
        uint256 protocol = fromQuote
            ? P.PAIR_BUY_BURN_PPM + P.PAIR_BUY_LIQUIDITY_PPM
            : P.PAIR_SELL_BURN_PPM + P.PAIR_SELL_LIQUIDITY_PPM + P.PAIR_SELL_QUOTE_YIELD_PPM;
        uint256 pi = (protocol * share) / PPM;
        uint256 f = P.PAIR_LP_FEE_PPM + pi;
        if (fromQuote) {
            uint256 inner = rQ * (2 * PPM - f) ** 2 + 4 * (PPM - pi) * (PPM - f) * a;
            uint256 root = Math.sqrt(rQ * inner);
            return Math.mulDiv(2 * a * PPM, rQ, rQ * (2 * PPM - f) + root);
        }
        uint256 lead = rE * (2 * PPM - f);
        uint256 lp = a * P.PAIR_LP_FEE_PPM;
        if (lead <= lp) revert ZapTooLarge();
        uint256 b = lead - lp;
        uint256 root2 = Math.sqrt(b * b + 4 * (PPM - pi) * PPM * a * rE);
        return Math.mulDiv(2 * a * PPM, rE, b + root2);
    }

    // ── internals ─────────────────────────────────────────────────────────

    function _zap(EmberPair p, bool fromQuote, uint256 a, uint256 minLiquidity, address receiver)
        internal
        returns (uint256 liquidity, uint256 s)
    {
        if (a == 0) revert ZeroAmount();
        if (p.totalSupply() == 0) revert NoLiquidity();
        (fromQuote ? p.QUOTE() : EMBER).safeTransferFrom(msg.sender, address(this), a);
        uint256 share = rebateShareOf(msg.sender);
        (uint112 rE, uint112 rQ,) = p.getReserves();
        s = _split(rE, rQ, fromQuote, a, share);
        uint256 got = _route(p, fromQuote, s, 0, address(this), share, false);
        (uint256 eDesired, uint256 qDesired) = fromQuote ? (got, a - s) : (a - s, got);
        liquidity = _addAndRefund(p, eDesired, qDesired, receiver);
        if (liquidity < minLiquidity) revert Slippage(liquidity, minLiquidity);
    }

    /// @dev Add what the pair takes at its ratio, clear the leftover approval, refund the dust.
    function _addAndRefund(EmberPair p, uint256 eDesired, uint256 qDesired, address receiver)
        internal
        returns (uint256 liquidity)
    {
        IERC20 quote = p.QUOTE();
        EMBER.forceApprove(address(p), eDesired);
        quote.forceApprove(address(p), qDesired);
        (uint256 e, uint256 q, uint256 l) = p.addLiquidity(eDesired, qDesired, 0, 0, receiver);
        liquidity = l;
        if (e != eDesired) {
            EMBER.forceApprove(address(p), 0);
            EMBER.safeTransfer(msg.sender, eDesired - e);
        }
        if (q != qDesired) {
            quote.forceApprove(address(p), 0);
            quote.safeTransfer(msg.sender, qDesired - q);
        }
    }

    /// @dev One swap on `p`; `pull` takes the input from the caller first (else Flow holds it).
    function _route(EmberPair p, bool buy, uint256 amountIn, uint256 minOut, address to, uint256 share, bool pull)
        internal
        returns (uint256 out)
    {
        IERC20 tokenIn = buy ? p.QUOTE() : EMBER;
        if (pull) tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        tokenIn.forceApprove(address(p), amountIn);
        out = buy ? p.flowBuy(amountIn, minOut, to, share) : p.flowSell(amountIn, minOut, to, share);
    }

    function _pair(uint256 pair) internal view returns (EmberPair) {
        if (pair == 0) return PAIR0;
        if (pair == 1) return PAIR1;
        revert UnknownPair(pair);
    }

    function _live(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert Expired(deadline);
    }
}
