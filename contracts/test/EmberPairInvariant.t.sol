// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {EmberPair} from "../src/pairs/EmberPair.sol";
import {MockERC20, MockDecimalsERC20} from "./utils/MockERC20.sol";

contract PairHandler is Test {
    EmberPair public pair;
    MockERC20 public ember;
    MockERC20 public quote;
    address public router;
    address public flow;
    address public guardian;
    address[3] internal users;

    uint256 public donatedEmber;
    uint256 public donatedQuote;
    uint256 public collected;
    /// Protocol fees the handler expects, from the fee rule applied to each successful swap.
    uint256 public expectedFees;
    uint256 public lastK;
    uint256 public lastCumulative;
    /// Ghost flags: set if k fell outside a redeem, a share's value fell, a redemption reverted
    /// for a holder with enough to redeem, or a round trip profited.
    bool public kFell;
    bool public shareValueFell;
    bool public redeemBlocked;
    bool public roundTripProfit;
    bool public cumulativeFell;
    uint256 public swaps;
    uint256 public redeems;
    uint256 public pausedRedeems;

    constructor(EmberPair pair_, address router_, address flow_, address guardian_) {
        (pair, router, flow, guardian) = (pair_, router_, flow_, guardian_);
        ember = MockERC20(address(pair_.EMBER()));
        quote = MockERC20(address(pair_.QUOTE()));
        for (uint256 i; i < 3; ++i) {
            users[i] = address(uint160(0x3000 + i));
            _fund(users[i]);
        }
        _fund(flow);
        (uint112 rE, uint112 rQ,) = pair.getReserves();
        lastK = uint256(rE) * rQ;
    }

    function _fund(address who) internal {
        ember.mint(who, 1e32);
        quote.mint(who, 1e32);
        vm.startPrank(who);
        ember.approve(address(pair), type(uint256).max);
        quote.approve(address(pair), type(uint256).max);
        vm.stopPrank();
    }

    function _fee(uint256 g, bool isBuy, uint256 share) internal pure returns (uint256 protocol) {
        uint256 b = isBuy ? P.PAIR_BUY_BURN_PPM : P.PAIR_SELL_BURN_PPM;
        uint256 l = isBuy ? P.PAIR_BUY_LIQUIDITY_PPM : P.PAIR_SELL_LIQUIDITY_PPM;
        uint256 y = isBuy ? 0 : P.PAIR_SELL_QUOTE_YIELD_PPM;
        return Math.ceilDiv(g * b * share, 1e12) + Math.ceilDiv(g * l * share, 1e12) + Math.ceilDiv(g * y * share, 1e12);
    }

    /// value per share² = k / supply², compared without overflow: k·s0² ≥ k0·s².
    function _shareValueHeld(uint256 k0, uint256 s0, uint256 k1, uint256 s1) internal pure returns (bool) {
        (uint256 aHi, uint256 aLo) = _mul512(k1, s0 * s0);
        (uint256 bHi, uint256 bLo) = _mul512(k0, s1 * s1);
        return aHi > bHi || (aHi == bHi && aLo >= bLo);
    }

    function _mul512(uint256 a, uint256 b) internal pure returns (uint256 hi, uint256 lo) {
        return Math.mul512(a, b);
    }

    function _state() internal view returns (uint256 k, uint256 s) {
        (uint112 rE, uint112 rQ,) = pair.getReserves();
        return (uint256(rE) * rQ, pair.totalSupply());
    }

    function _after(bool wasRedeem, uint256 k0, uint256 s0) internal {
        (uint256 k, uint256 s) = _state();
        if (!wasRedeem && k < k0) kFell = true;
        if (!_shareValueHeld(k0, s0, k, s)) shareValueFell = true;
        lastK = k;
        (uint256 cum,) = pair.currentCumulativePrice();
        lastCumulative = cum;
    }

    function buy(uint256 who, uint256 amount, uint256 shareSeed, bool viaFlow) external {
        (uint256 k0, uint256 s0) = _state();
        amount = _logScale(amount, 24);
        uint256 share = viaFlow ? bound(shareSeed, 0, 1e6) : 1e6;
        address caller = viaFlow ? flow : users[who % 3];
        (bool ok, uint256 got) = _swap(true, viaFlow, caller, amount, share);
        if (ok) {
            // A round trip at the same share never returns more quote than it spent.
            (bool ok2, uint256 back) = _swap(false, viaFlow, caller, got, share);
            if (ok2 && back >= amount) roundTripProfit = true;
        }
        _after(false, k0, s0);
    }

    function sell(uint256 who, uint256 amount, uint256 shareSeed, bool viaFlow) external {
        (uint256 k0, uint256 s0) = _state();
        amount = _logScale(amount, 27);
        uint256 share = viaFlow ? bound(shareSeed, 0, 1e6) : 1e6;
        _swap(false, viaFlow, viaFlow ? flow : users[who % 3], amount, share);
        _after(false, k0, s0);
    }

    /// One swap; on success the handler adds what the fee rule charges on its fee base (a buy's
    /// input, a sell's gross output at the reserves before it).
    function _swap(bool isBuy, bool viaFlow, address caller, uint256 amount, uint256 share)
        internal
        returns (bool ok, uint256 out)
    {
        (uint112 rE, uint112 rQ,) = pair.getReserves();
        uint256 base = isBuy ? amount : (uint256(rQ) * amount) / (uint256(rE) + amount);
        try this.swapAs(isBuy, viaFlow, caller, amount, share) returns (uint256 got) {
            ++swaps;
            expectedFees += _fee(base, isBuy, share);
            return (true, got);
        } catch {
            return (false, 0);
        }
    }

    /// External so that `_swap` can `try` it; only the handler itself may call it.
    function swapAs(bool isBuy, bool viaFlow, address caller, uint256 amount, uint256 share) external returns (uint256) {
        require(msg.sender == address(this), "handler only");
        vm.prank(caller);
        if (viaFlow) return isBuy ? pair.flowBuy(amount, 0, caller, share) : pair.flowSell(amount, 0, caller, share);
        return isBuy ? pair.buy(amount, 0, caller) : pair.sell(amount, 0, caller);
    }

    function add(uint256 who, uint256 e, uint256 q) external {
        (uint256 k0, uint256 s0) = _state();
        vm.prank(users[who % 3]);
        try pair.addLiquidity(_logScale(e, 26), _logScale(q, 26), 0, 0, users[who % 3]) {} catch {}
        _after(false, k0, s0);
    }

    function redeem(uint256 who, uint256 fraction) external {
        address u = users[who % 3];
        uint256 bal = pair.balanceOf(u);
        if (bal == 0) return;
        (uint256 k0, uint256 s0) = _state();
        uint256 l = bound(fraction, 1, bal);
        (uint112 rE, uint112 rQ,) = pair.getReserves();
        bool pays = (l * rE) / s0 != 0 || (l * rQ) / s0 != 0;
        vm.prank(u);
        try pair.redeem(l, 0, 0, u) {
            ++redeems;
            if (pair.swapsPaused()) ++pausedRedeems;
        } catch {
            if (pays) redeemBlocked = true;
        }
        _after(true, k0, s0);
    }

    function donate(uint256 e, uint256 q) external {
        (uint256 k0, uint256 s0) = _state();
        e = bound(e, 0, 1e24);
        q = bound(q, 0, 1e24);
        vm.startPrank(users[0]);
        ember.transfer(address(pair), e);
        quote.transfer(address(pair), q);
        vm.stopPrank();
        (donatedEmber, donatedQuote) = (donatedEmber + e, donatedQuote + q);
        _after(false, k0, s0);
    }

    /// Paused an eighth of the time (and never by the fuzzer's favourite 0), so swaps dominate.
    function pause(uint256 seed) external {
        vm.prank(guardian);
        pair.setSwapsPaused(seed % 8 == 1);
    }

    /// Spread over orders of magnitude: 1 up to 10^maxExp, log-uniform in the exponent.
    function _logScale(uint256 seed, uint256 maxExp) internal pure returns (uint256) {
        return bound(seed >> 8, 1, 10 ** (seed % (maxExp + 1)));
    }

    function collect() external {
        vm.prank(router);
        (uint256 b, uint256 l, uint256 y) = pair.collectProtocolFees();
        collected += b + l + y;
    }

    function warp(uint256 dt) external {
        (uint256 k0, uint256 s0) = _state();
        skip(bound(dt, 1, 2 hours));
        if (dt % 2 == 0) pair.checkpoint();
        (uint256 cum,) = pair.currentCumulativePrice();
        if (cum < lastCumulative) cumulativeFell = true; // no wrap at these sizes
        _after(false, k0, s0);
    }
}

/// @notice EmberPair invariants (ADR 0015) over random swaps, Flow swaps, adds, redeems,
///         donations, pauses, collections and time.
contract EmberPairInvariantTest is Test {
    PairHandler handler;
    EmberPair pair;
    address router = makeAddr("router");
    address flow = makeAddr("flow");
    address guardian = makeAddr("guardian");

    function setUp() public {
        vm.warp(1_790_000_000);
        MockERC20 ember = new MockERC20("Ember", "EMBER");
        MockDecimalsERC20 usdc = new MockDecimalsERC20("USD Coin", "USDC", 6);
        address init = makeAddr("initializer");
        pair = new EmberPair("B", "B", IERC20(address(ember)), IERC20(address(usdc)), router, flow, guardian, init);
        ember.mint(init, 1e24);
        usdc.mint(init, 1e12);
        vm.startPrank(init);
        ember.approve(address(pair), type(uint256).max);
        usdc.approve(address(pair), type(uint256).max);
        pair.addLiquidity(1e24, 1e12, 0, 0, init); // 1M EMBER and 1M USDC
        vm.stopPrank();
        handler = new PairHandler(pair, router, flow, guardian);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = PairHandler.buy.selector;
        selectors[1] = PairHandler.sell.selector;
        selectors[2] = PairHandler.add.selector;
        selectors[3] = PairHandler.redeem.selector;
        selectors[4] = PairHandler.donate.selector;
        selectors[5] = PairHandler.pause.selector;
        selectors[6] = PairHandler.collect.selector;
        selectors[7] = PairHandler.warp.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// The reserves plus booked fees are exactly the balances, less what was donated.
    function invariant_balancesAreReservesFeesAndDonations() public view {
        (uint112 rE, uint112 rQ,) = pair.getReserves();
        (uint256 b, uint256 l, uint256 y) = pair.protocolFees();
        assertEq(pair.EMBER().balanceOf(address(pair)), uint256(rE) + handler.donatedEmber());
        assertEq(pair.QUOTE().balanceOf(address(pair)), uint256(rQ) + b + l + y + handler.donatedQuote());
    }

    /// The protocol fees booked (and collected) equal those the fee rule charges on each swap.
    function invariant_feesBookedEqualFeesCharged() public view {
        (uint256 b, uint256 l, uint256 y) = pair.protocolFees();
        assertEq(b + l + y + handler.collected(), handler.expectedFees());
    }

    function invariant_kNeverFallsOutsideRedeem() public view {
        assertFalse(handler.kFell());
    }

    /// Rounding on adds and redeems favours the holders who stay: k / supply² never falls.
    function invariant_shareValueNeverFalls() public view {
        assertFalse(handler.shareValueFell());
    }

    /// Receipts stay backed: the locked minimum keeps both reserves positive.
    function invariant_receiptsBacked() public view {
        (uint112 rE, uint112 rQ,) = pair.getReserves();
        assertGe(pair.totalSupply(), pair.MINIMUM_LIQUIDITY());
        assertGt(rE, 0);
        assertGt(rQ, 0);
        assertEq(pair.balanceOf(P.BURN_ADDRESS), pair.MINIMUM_LIQUIDITY());
    }

    /// A redemption that pays something never reverts, paused or not.
    function invariant_redeemNeverBlocked() public view {
        assertFalse(handler.redeemBlocked());
    }

    function invariant_roundTripNeverProfits() public view {
        assertFalse(handler.roundTripProfit());
    }

    function invariant_cumulativePriceNeverFalls() public view {
        assertFalse(handler.cumulativeFell());
    }
}
