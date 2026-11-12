// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {EmberPair} from "../src/pairs/EmberPair.sol";
import {MockERC20, MockDecimalsERC20, FeeOnTransferERC20} from "./utils/MockERC20.sol";

/// @notice EmberPair (ADR 0015): fees, access, liquidity, pausing, the oracle, and an exact replay
///         of the BigInt model's scenarios (scripts/pair-model.ts).
contract EmberPairTest is Test {
    uint256 constant E = 1e18;
    uint256 constant U = 1e6;
    MockERC20 ember;
    MockDecimalsERC20 usdc;
    EmberPair pair;
    address lp = makeAddr("initializer");
    address trader = makeAddr("trader");
    address router = makeAddr("router");
    address flow = makeAddr("flow");
    address guardian = makeAddr("guardian");

    function setUp() public {
        vm.warp(1_790_000_000);
        ember = new MockERC20("Ember", "EMBER");
        usdc = new MockDecimalsERC20("USD Coin", "USDC", 6);
        pair = _pair(IERC20(address(usdc)), flow, guardian);
        _fund(lp, pair);
        _fund(trader, pair);
    }

    function _pair(IERC20 quote, address flow_, address guardian_) internal returns (EmberPair) {
        return new EmberPair("Blast Furnace EMBER/USDC", "BLAST-LP", IERC20(address(ember)), quote, router, flow_, guardian_, lp);
    }

    function _fund(address who, EmberPair p) internal {
        ember.mint(who, 1e30);
        MockERC20(address(p.QUOTE())).mint(who, 1e30);
        vm.startPrank(who);
        ember.approve(address(p), type(uint256).max);
        p.QUOTE().approve(address(p), type(uint256).max);
        vm.stopPrank();
    }

    function _seed(uint256 e, uint256 q) internal returns (uint256 l) {
        vm.prank(lp);
        (,, l) = pair.addLiquidity(e, q, 0, 0, lp);
    }

    function _lastSwap() internal returns (uint256[5] memory parts) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = EmberPair.Swap.selector;
        for (uint256 i = logs.length; i > 0; --i) {
            if (logs[i - 1].topics[0] != topic) continue;
            (,,, uint256 lpFee, uint256 burnFee, uint256 liqFee, uint256 qyFee,) =
                abi.decode(logs[i - 1].data, (bool, uint256, uint256, uint256, uint256, uint256, uint256, uint256));
            return [lpFee, burnFee, liqFee, qyFee, lpFee + burnFee + liqFee + qyFee];
        }
        revert("no Swap event");
    }

    function _eq(uint256[5] memory a, uint256[5] memory b, string memory why) internal pure {
        for (uint256 i; i < 5; ++i) assertEq(a[i], b[i], why);
    }

    // ── construction ──────────────────────────────────────────────────────

    function test_constructorChecks() public {
        IERC20 e = IERC20(address(ember));
        IERC20 q = IERC20(address(usdc));
        vm.expectRevert(EmberPair.ZeroAddress.selector);
        new EmberPair("x", "x", IERC20(address(0)), q, router, flow, guardian, lp);
        vm.expectRevert(EmberPair.ZeroAddress.selector);
        new EmberPair("x", "x", e, q, address(0), flow, guardian, lp);
        vm.expectRevert(EmberPair.ZeroAddress.selector);
        new EmberPair("x", "x", e, q, router, flow, guardian, address(0));
        vm.expectRevert(EmberPair.SameToken.selector);
        new EmberPair("x", "x", e, e, router, flow, guardian, lp);
        MockDecimalsERC20 nineteen = new MockDecimalsERC20("x", "x", 19);
        vm.expectRevert(abi.encodeWithSelector(EmberPair.BadDecimals.selector, 19));
        new EmberPair("x", "x", e, IERC20(address(nineteen)), router, flow, guardian, lp);
        vm.expectRevert(abi.encodeWithSelector(EmberPair.BadDecimals.selector, 6));
        new EmberPair("x", "x", q, IERC20(address(nineteen)), router, flow, guardian, lp); // "EMBER" with 6 decimals
        assertEq(pair.QUOTE_SCALE(), 1e12);
        assertEq(pair.OBSERVATION_PERIOD(), 300);
    }

    // ── liquidity ─────────────────────────────────────────────────────────

    function test_firstDepositIsTheInitializersAndScalesTheQuote() public {
        vm.prank(trader);
        vm.expectRevert(EmberPair.NotInitializer.selector);
        pair.addLiquidity(E, U, 0, 0, trader);
        uint256 l = _seed(1000 * E, 1000 * U);
        // √(1000e18 · 1000e6 · 1e12) = 1000e18: one receipt per EMBER-and-USDC at parity.
        assertEq(l + pair.MINIMUM_LIQUIDITY(), 1000 * E, "the quote is scaled to 18 decimals");
        assertEq(pair.balanceOf(P.BURN_ADDRESS), pair.MINIMUM_LIQUIDITY(), "the minimum is locked at the burn address");
        assertEq(pair.balanceOf(lp), l);
        // After the first deposit anyone may add, at the current ratio.
        vm.prank(trader);
        (uint256 e, uint256 q, uint256 l2) = pair.addLiquidity(10 * E, 50 * U, 0, 0, trader);
        assertEq(e, 10 * E);
        assertEq(q, 10 * U, "takes only the quote the ratio needs");
        assertEq(l2, 10 * E);
        vm.prank(trader);
        (e, q,) = pair.addLiquidity(50 * E, 5 * U, 0, 0, trader);
        assertEq(e, 5 * E);
        assertEq(q, 5 * U);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(EmberPair.Slippage.selector, 5 * E, 6 * E));
        pair.addLiquidity(50 * E, 5 * U, 6 * E, 0, trader);
    }

    function test_firstDepositAtOrBelowTheMinimumReverts() public {
        EmberPair p = _pair(IERC20(address(new MockDecimalsERC20("W", "W", 18))), flow, guardian);
        _fund(lp, p);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(EmberPair.LiquidityTooLow.selector, 1000));
        p.addLiquidity(1000, 1000, 0, 0, lp);
        vm.prank(lp);
        p.addLiquidity(1001, 1001, 0, 0, lp);
        assertEq(p.balanceOf(lp), 1);
    }

    function test_redeemIsProRataRoundsDownAndLeavesTheMinimum() public {
        uint256 l = _seed(1000 * E + 7, 1000 * U + 3);
        vm.prank(trader);
        pair.buy(10 * U, 0, trader);
        (uint112 rE, uint112 rQ,) = pair.getReserves();
        uint256 s = pair.totalSupply();
        uint256 half = l / 2;
        vm.prank(lp);
        (uint256 e, uint256 q) = pair.redeem(half, 0, 0, lp);
        assertEq(e, half * rE / s);
        assertEq(q, half * rQ / s);
        vm.prank(lp);
        pair.redeem(l - half, 0, 0, lp);
        (rE, rQ,) = pair.getReserves();
        assertEq(pair.totalSupply(), pair.MINIMUM_LIQUIDITY());
        assertGt(rE, 0);
        assertGt(rQ, 0);
        vm.prank(lp);
        vm.expectRevert(EmberPair.ZeroAmount.selector);
        pair.redeem(0, 0, 0, lp);
    }

    function test_redeemBeforeAnyDepositReverts() public {
        vm.prank(lp);
        vm.expectRevert(EmberPair.NoLiquidity.selector);
        pair.redeem(1, 0, 0, lp);
    }

    // ── fees ──────────────────────────────────────────────────────────────

    function test_fullFeesMatchTheSpec() public {
        _seed(1_000_000 * E, 1_000_000 * U);
        vm.recordLogs();
        vm.prank(trader);
        pair.buy(U, 0, trader);
        uint256[5] memory f = _lastSwap();
        _eq(f, [uint256(2000), 250, 250, 0, 2500], "buy: 20 LP + 2.5 burn + 2.5 liquidity = 25 bps");
        // A sell's fees come from its output, in the quote: price the gross output at exactly 1 USDC.
        (uint256 out, uint256 fee) = pair.quoteSell(E, 1e6);
        vm.recordLogs();
        vm.prank(trader);
        assertEq(pair.sell(E, 0, trader), out);
        f = _lastSwap();
        uint256 gross = out + fee;
        assertEq(f[0], Math.ceilDiv(gross * 2000, 1e6));
        assertEq(f[1], Math.ceilDiv(gross * 500, 1e6));
        assertEq(f[3], Math.ceilDiv(gross * 500, 1e6), "Quote yield, in the quote asset");
        (uint256 burn, uint256 liq, uint256 qy) = pair.protocolFees();
        assertEq(burn, 250 + f[1]);
        assertEq(liq, 250 + f[2]);
        assertEq(qy, f[3]);
    }

    function test_bedrockRebateAndCompoundWaiver() public {
        _seed(1_000_000 * E, 1_000_000 * U);
        _fund(flow, pair);
        vm.startPrank(flow);
        vm.recordLogs();
        pair.flowBuy(U, 0, flow, 500_000);
        _eq(_lastSwap(), [uint256(2000), 125, 125, 0, 2250], "Bedrock buy: 22.5 bps");
        vm.recordLogs();
        pair.flowBuy(U, 0, flow, 0);
        _eq(_lastSwap(), [uint256(2000), 0, 0, 0, 2000], "the Compound waiver keeps the LP fee");
        vm.recordLogs();
        uint256 gross;
        {
            (uint256 out, uint256 fee) = pair.quoteSell(E, 500_000);
            gross = out + fee;
        }
        pair.flowSell(E, 0, flow, 500_000);
        uint256[5] memory f = _lastSwap();
        assertEq(f[0], Math.ceilDiv(gross * 2000, 1e6));
        assertEq(f[3], Math.ceilDiv(gross * 250, 1e6), "Quote yield at Bedrock: 2.5 bps");
        vm.stopPrank();
        // §14's figures on round amounts: 1 USDC of gross output at each share.
        assertEq(_feeOn(1e6, false, 500_000), 2750, "Bedrock sell: 27.5 bps");
        assertEq(_feeOn(1e6, false, 1e6), 3500);
        assertEq(_feeOn(1e6, false, 0), 2000);
    }

    /// The fee rule on a fee base `g`, independently of the pair.
    function _feeOn(uint256 g, bool isBuy, uint256 share) internal pure returns (uint256) {
        uint256 b = isBuy ? P.PAIR_BUY_BURN_PPM : P.PAIR_SELL_BURN_PPM;
        uint256 l = isBuy ? P.PAIR_BUY_LIQUIDITY_PPM : P.PAIR_SELL_LIQUIDITY_PPM;
        uint256 y = isBuy ? 0 : P.PAIR_SELL_QUOTE_YIELD_PPM;
        return Math.ceilDiv(g * P.PAIR_LP_FEE_PPM, 1e6) + Math.ceilDiv(g * b * share, 1e12)
            + Math.ceilDiv(g * l * share, 1e12) + Math.ceilDiv(g * y * share, 1e12);
    }

    function test_tinyTradesRevertRatherThanSkipFees() public {
        _seed(1_000_000 * E, 1_000_000 * U);
        vm.startPrank(trader);
        vm.expectRevert(EmberPair.TooSmall.selector);
        pair.buy(3, 0, trader); // 1 LP + 1 burn + 1 liquidity, each rounded up
        pair.buy(4, 0, trader);
        vm.expectRevert(EmberPair.TooSmall.selector);
        pair.sell(1, 0, trader); // zero gross output
        vm.expectRevert(EmberPair.ZeroAmount.selector);
        pair.buy(0, 0, trader);
        vm.stopPrank();
    }

    function test_slippageAndNoLiquidity() public {
        vm.prank(trader);
        vm.expectRevert(EmberPair.NoLiquidity.selector);
        pair.buy(U, 0, trader);
        _seed(1000 * E, 1000 * U);
        (uint256 out,) = pair.quoteBuy(U, 1e6);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(EmberPair.Slippage.selector, out, out + 1));
        pair.buy(U, out + 1, trader);
        vm.prank(trader);
        assertEq(pair.buy(U, out, trader), out);
    }

    // ── access ────────────────────────────────────────────────────────────

    function test_onlyFlowRebatesOnlyTheRouterCollectsOnlyTheGuardianPauses() public {
        _seed(1000 * E, 1000 * U);
        vm.startPrank(trader);
        vm.expectRevert(EmberPair.NotFlow.selector);
        pair.flowBuy(U, 0, trader, 0);
        vm.expectRevert(EmberPair.NotFlow.selector);
        pair.flowSell(E, 0, trader, 0);
        vm.expectRevert(EmberPair.NotFeeRouter.selector);
        pair.collectProtocolFees();
        vm.expectRevert(EmberPair.NotGuardian.selector);
        pair.setSwapsPaused(true);
        vm.stopPrank();
        _fund(flow, pair);
        vm.prank(flow);
        vm.expectRevert(abi.encodeWithSelector(EmberPair.BadShare.selector, 1e6 + 1));
        pair.flowBuy(U, 0, flow, 1e6 + 1);
    }

    function test_zeroFlowAndZeroGuardianDisableThoseCapabilities() public {
        EmberPair p = _pair(IERC20(address(usdc)), address(0), address(0));
        _fund(lp, p);
        vm.prank(lp);
        p.addLiquidity(1000 * E, 1000 * U, 0, 0, lp);
        vm.prank(address(0));
        vm.expectRevert(EmberPair.NotFlow.selector);
        p.flowBuy(U, 0, lp, 0);
        vm.prank(address(0));
        vm.expectRevert(EmberPair.NotGuardian.selector);
        p.setSwapsPaused(true);
    }

    function test_collectPaysTheRouterByLane() public {
        _seed(1_000_000 * E, 1_000_000 * U);
        vm.startPrank(trader);
        pair.buy(1000 * U, 0, trader);
        pair.sell(500 * E, 0, trader);
        vm.stopPrank();
        (uint256 burn, uint256 liq, uint256 qy) = pair.protocolFees();
        assertGt(qy, 0);
        (, uint112 rQ,) = pair.getReserves();
        assertEq(usdc.balanceOf(address(pair)), uint256(rQ) + burn + liq + qy, "booked fees sit outside the reserves");
        vm.prank(router);
        (uint256 b2, uint256 l2, uint256 q2) = pair.collectProtocolFees();
        assertEq(b2, burn);
        assertEq(l2, liq);
        assertEq(q2, qy);
        assertEq(usdc.balanceOf(router), burn + liq + qy);
        assertEq(usdc.balanceOf(address(pair)), rQ);
        (burn, liq, qy) = pair.protocolFees();
        assertEq(burn + liq + qy, 0);
        vm.prank(router);
        pair.collectProtocolFees(); // nothing left: no transfer, no revert
    }

    // ── pausing ───────────────────────────────────────────────────────────

    function test_pauseStopsSwapsNeverRedemptions() public {
        uint256 l = _seed(1000 * E, 1000 * U);
        vm.prank(trader);
        pair.buy(10 * U, 0, trader);
        vm.prank(guardian);
        pair.setSwapsPaused(true);
        assertTrue(pair.swapsPaused());
        vm.startPrank(trader);
        vm.expectRevert(EmberPair.SwapsPaused.selector);
        pair.buy(U, 0, trader);
        vm.expectRevert(EmberPair.SwapsPaused.selector);
        pair.sell(E, 0, trader);
        vm.expectRevert(EmberPair.SwapsPaused.selector);
        pair.quoteBuy(U, 1e6);
        pair.addLiquidity(E, U, 0, 0, trader); // adding liquidity is unaffected
        vm.stopPrank();
        _fund(flow, pair);
        vm.prank(flow);
        vm.expectRevert(EmberPair.SwapsPaused.selector);
        pair.flowBuy(U, 0, flow, 0);
        vm.prank(lp);
        pair.redeem(l, 0, 0, lp); // never paused
        vm.prank(router);
        pair.collectProtocolFees();
        skip(301);
        pair.checkpoint();
        vm.prank(guardian);
        pair.setSwapsPaused(false);
        vm.prank(trader);
        pair.buy(U, 0, trader);
    }

    // ── tokens ────────────────────────────────────────────────────────────

    function test_nonStandardTokensAreRefused() public {
        FeeOnTransferERC20 skim = new FeeOnTransferERC20();
        EmberPair p = _pair(IERC20(address(skim)), flow, guardian);
        _fund(lp, p);
        vm.prank(lp);
        vm.expectRevert(EmberPair.NonStandardToken.selector);
        p.addLiquidity(1000 * E, 1000 * E, 0, 0, lp);
    }

    function test_donationsChangeNothing() public {
        _seed(1000 * E, 1000 * U);
        skip(1800);
        pair.checkpoint();
        (uint112 rE, uint112 rQ,) = pair.getReserves();
        (uint256 out,) = pair.quoteBuy(U, 1e6);
        (uint256 cum,) = pair.currentCumulativePrice();
        vm.startPrank(trader);
        ember.transfer(address(pair), 500 * E);
        usdc.transfer(address(pair), 7 * U);
        vm.stopPrank();
        (uint112 rE2, uint112 rQ2,) = pair.getReserves();
        (uint256 out2,) = pair.quoteBuy(U, 1e6);
        (uint256 cum2,) = pair.currentCumulativePrice();
        assertEq(rE2, rE);
        assertEq(rQ2, rQ);
        assertEq(out2, out, "a donation does not move the price");
        assertEq(cum2, cum, "nor the oracle");
        uint256 l = pair.balanceOf(lp);
        uint256 supply = pair.totalSupply();
        vm.prank(lp);
        (uint256 e, uint256 q) = pair.redeem(l, 0, 0, lp);
        assertEq(e, l * rE / supply, "redeem pays reserves, not balances");
        assertEq(q, l * rQ / supply);
    }

    // ── oracle ────────────────────────────────────────────────────────────

    function test_oracleWindowsAndObservations() public {
        vm.expectRevert(EmberPair.NoLiquidity.selector);
        pair.checkpoint();
        _seed(1000 * E, 2000 * U); // 2 USDC per EMBER: 2e6 quote-wei per 1e18 EMBER-wei
        uint256 spot = (uint256(2000 * U) << 112) / (1000 * E);
        vm.expectRevert(EmberPair.BadWindow.selector);
        pair.consult(0);
        vm.expectRevert(EmberPair.OracleNotReady.selector);
        pair.consult(1800);
        skip(1799);
        vm.expectRevert(EmberPair.OracleNotReady.selector);
        pair.consult(1800);
        skip(1);
        (uint256 avg, uint32 elapsed) = pair.consult(1800);
        assertEq(avg, spot, "a constant price averages to itself");
        assertEq(elapsed, 1800);
        // Half the window at one price, half at another: the average is the time-weighted mean.
        vm.prank(trader);
        pair.buy(500 * U, 0, trader);
        (uint112 rE, uint112 rQ,) = pair.getReserves();
        uint256 after_ = (uint256(rQ) << 112) / rE;
        skip(1800);
        (avg, elapsed) = pair.consult(3600);
        assertEq(elapsed, 3600);
        assertEq(avg, (spot * 1800 + after_ * 1800) / 3600);
        // Observations: at most one per period, eight kept.
        (, uint8 count) = pair.observationState();
        assertEq(count, 2, "the deposit and the buy, 1800 s apart");
        pair.checkpoint();
        pair.checkpoint();
        (, count) = pair.observationState();
        assertEq(count, 3, "a second checkpoint in the same period writes nothing");
        for (uint256 i; i < 10; ++i) {
            skip(300);
            pair.checkpoint();
        }
        (uint8 latest, uint8 count2) = pair.observationState();
        assertEq(count2, 8);
        assertEq(latest, (2 + 10) % 8);
        (avg, elapsed) = pair.consult(1800);
        assertEq(elapsed, 1800, "an observation exactly a window old");
        assertEq(avg, after_);
        vm.expectRevert(EmberPair.OracleNotReady.selector);
        pair.consult(2101); // the oldest kept is 7 periods (2100 s) old
    }

    function test_sparseTradingStillAveragesExactly() public {
        _seed(1000 * E, 1000 * U);
        uint256 spot = (uint256(1000 * U) << 112) / (1000 * E);
        skip(5 hours);
        (uint256 avg, uint32 elapsed) = pair.consult(1800);
        assertEq(avg, spot, "the average is exact");
        assertEq(elapsed, 5 hours, "over a span longer than asked");
    }

    // ── properties ────────────────────────────────────────────────────────

    function testFuzz_roundTripNeverProfits(uint256 e0, uint256 q0, uint256 amountIn) public {
        e0 = bound(e0, 1e18, 1e27);
        q0 = bound(q0, 1e6, 1e15);
        _seed(e0, q0);
        amountIn = bound(amountIn, 1e3, q0);
        vm.startPrank(trader);
        try pair.buy(amountIn, 0, trader) returns (uint256 got) {
            try pair.sell(got, 0, trader) returns (uint256 back) {
                assertLt(back, amountIn, "a round trip returns less than it put in");
            } catch {}
        } catch {}
        vm.stopPrank();
    }

    function testFuzz_swapsNeverLowerK(uint256 seed, uint256 amount, bool isBuy) public {
        _seed(bound(seed, 1e20, 1e26), bound(seed >> 128, 1e8, 1e14));
        (uint112 rE, uint112 rQ,) = pair.getReserves();
        uint256 k0 = uint256(rE) * rQ;
        vm.prank(trader);
        if (isBuy) {
            try pair.buy(bound(amount, 1, 1e16), 0, trader) {} catch {}
        } else {
            try pair.sell(bound(amount, 1, 1e28), 0, trader) {} catch {}
        }
        (rE, rQ,) = pair.getReserves();
        assertGe(uint256(rE) * rQ, k0);
    }

    // ── gas (pnpm gas, isolated) ──────────────────────────────────────────

    function test_gas_pairPaths() public {
        vm.prank(lp);
        uint256 g = gasleft();
        pair.addLiquidity(1_000_000 * E, 1_000_000 * U, 0, 0, lp);
        emit log_named_uint("addLiquidity, first deposit", g - gasleft());
        skip(301);
        vm.startPrank(trader);
        g = gasleft();
        pair.buy(1000 * U, 0, trader);
        emit log_named_uint("buy, writing an observation", g - gasleft());
        g = gasleft();
        pair.buy(1000 * U, 0, trader);
        emit log_named_uint("buy, same block", g - gasleft());
        skip(12);
        g = gasleft();
        pair.sell(1000 * E, 0, trader);
        emit log_named_uint("sell", g - gasleft());
        g = gasleft();
        pair.addLiquidity(1000 * E, 1000 * U, 0, 0, trader);
        emit log_named_uint("addLiquidity", g - gasleft());
        uint256 l = pair.balanceOf(trader);
        g = gasleft();
        pair.redeem(l, 0, 0, trader);
        emit log_named_uint("redeem", g - gasleft());
        vm.stopPrank();
        g = gasleft();
        pair.consult(300);
        emit log_named_uint("consult", g - gasleft());
    }

    // ── the BigInt model's scenarios, replayed exactly ────────────────────

    function test_replaysTheModelExactly() public {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/contracts/test/fixtures/pair-vectors.json"));
        assertEq(vm.parseJsonUint(json, ".lpPpm"), P.PAIR_LP_FEE_PPM, "vectors generated from this config");
        uint256 n;
        for (; vm.keyExistsJson(json, string.concat(".scenarios[", vm.toString(n), "]")); ++n) {
            _replay(json, string.concat(".scenarios[", vm.toString(n), "]"));
        }
        assertEq(n, 8, "every scenario replayed");
    }

    struct Cols {
        uint256[] kind;
        string[] a;
        string[] b;
        string[] share;
        string[] why;
        string[][3] out;
        string[][7] state;
    }

    function _replay(string memory json, string memory base) internal {
        uint8 decimals = uint8(vm.parseJsonUint(json, string.concat(base, ".quoteDecimals")));
        MockDecimalsERC20 quote = new MockDecimalsERC20("Q", "Q", decimals);
        EmberPair p = new EmberPair("P", "P", IERC20(address(ember)), IERC20(address(quote)), router, flow, guardian, lp);
        _fund(lp, p);
        _fund(trader, p);
        _fund(flow, p);
        Cols memory c;
        c.kind = vm.parseJsonUintArray(json, string.concat(base, ".kind"));
        c.a = vm.parseJsonStringArray(json, string.concat(base, ".a"));
        c.b = vm.parseJsonStringArray(json, string.concat(base, ".b"));
        c.share = vm.parseJsonStringArray(json, string.concat(base, ".share"));
        c.why = vm.parseJsonStringArray(json, string.concat(base, ".why"));
        c.out[0] = vm.parseJsonStringArray(json, string.concat(base, ".out0"));
        c.out[1] = vm.parseJsonStringArray(json, string.concat(base, ".out1"));
        c.out[2] = vm.parseJsonStringArray(json, string.concat(base, ".out2"));
        string[7] memory keys = [".rE", ".rQ", ".supply", ".lp", ".burn", ".liquidity", ".quoteYield"];
        for (uint256 j; j < 7; ++j) c.state[j] = vm.parseJsonStringArray(json, string.concat(base, keys[j]));
        for (uint256 i; i < c.kind.length; ++i) {
            (bool ok, bytes memory ret) = _step(p, c.kind[i], vm.parseUint(c.a[i]), vm.parseUint(c.b[i]), vm.parseUint(c.share[i]));
            string memory at = string.concat(base, " step ", vm.toString(i));
            if (bytes(c.why[i]).length != 0) {
                assertFalse(ok, string.concat(at, ": expected ", c.why[i]));
                assertEq(bytes4(ret), bytes4(keccak256(bytes(string.concat(c.why[i], _args(c.why[i]))))), at);
            } else {
                assertTrue(ok, at);
                _checkOutputs(c, i, ret, at);
            }
            _checkState(p, c, i, at);
        }
    }

    function _args(string memory why) internal pure returns (string memory) {
        return keccak256(bytes(why)) == keccak256("LiquidityTooLow") ? "(uint256)" : "()";
    }

    function _step(EmberPair p, uint256 kind, uint256 a, uint256 b, uint256 share) internal returns (bool ok, bytes memory ret) {
        if (kind == 0) {
            vm.prank(lp);
            (ok, ret) = address(p).call(abi.encodeCall(EmberPair.addLiquidity, (a, b, 0, 0, lp)));
        } else if (kind == 1) {
            vm.prank(lp);
            (ok, ret) = address(p).call(abi.encodeCall(EmberPair.redeem, (a, 0, 0, lp)));
        } else if (kind == 2 || kind == 3) {
            bool isBuy = kind == 2;
            if (share == 1e6) {
                vm.prank(trader);
                (ok, ret) = address(p).call(isBuy ? abi.encodeCall(EmberPair.buy, (a, 0, trader)) : abi.encodeCall(EmberPair.sell, (a, 0, trader)));
            } else {
                vm.prank(flow);
                (ok, ret) = address(p).call(
                    isBuy ? abi.encodeCall(EmberPair.flowBuy, (a, 0, flow, share)) : abi.encodeCall(EmberPair.flowSell, (a, 0, flow, share))
                );
            }
        } else {
            vm.prank(router);
            (ok, ret) = address(p).call(abi.encodeCall(EmberPair.collectProtocolFees, ()));
        }
    }

    function _checkOutputs(Cols memory c, uint256 i, bytes memory ret, string memory at) internal pure {
        uint256 kind = c.kind[i];
        if (kind == 0) {
            (uint256 e, uint256 q, uint256 l) = abi.decode(ret, (uint256, uint256, uint256));
            assertEq(e, vm.parseUint(c.out[0][i]), at);
            assertEq(q, vm.parseUint(c.out[1][i]), at);
            assertEq(l, vm.parseUint(c.out[2][i]), at);
        } else if (kind == 1) {
            (uint256 e, uint256 q) = abi.decode(ret, (uint256, uint256));
            assertEq(e, vm.parseUint(c.out[0][i]), at);
            assertEq(q, vm.parseUint(c.out[1][i]), at);
        } else if (kind == 4) {
            (uint256 b, uint256 l, uint256 y) = abi.decode(ret, (uint256, uint256, uint256));
            assertEq(b, vm.parseUint(c.out[0][i]), at);
            assertEq(l, vm.parseUint(c.out[1][i]), at);
            assertEq(y, vm.parseUint(c.out[2][i]), at);
        } else {
            assertEq(abi.decode(ret, (uint256)), vm.parseUint(c.out[0][i]), at);
        }
    }

    function _checkState(EmberPair p, Cols memory c, uint256 i, string memory at) internal view {
        (uint112 rE, uint112 rQ,) = p.getReserves();
        (uint256 burn, uint256 liq, uint256 qy) = p.protocolFees();
        uint256[7] memory got = [uint256(rE), rQ, p.totalSupply(), p.balanceOf(lp), burn, liq, qy];
        for (uint256 j; j < 7; ++j) assertEq(got[j], vm.parseUint(c.state[j][i]), at);
    }
}
