// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {EmberPair} from "../src/pairs/EmberPair.sol";
import {Vent, IVentFeePool, IVentPair, IVentMantle} from "../src/vent/Vent.sol";
import {MockERC20, MockDecimalsERC20} from "./utils/MockERC20.sol";
import {MockBurnableERC20, MockMantle, MockFeePool} from "./utils/VentMocks.sol";

/// @notice A Vent on two real EmberPairs, four mock fee pools and a mock Mantle.
contract VentRig is Test {
    struct World {
        MockBurnableERC20 ember;
        MockDecimalsERC20 usdc;
        MockDecimalsERC20 weth;
        MockERC20 unknown;
        MockMantle mantle;
        EmberPair[2] pairs;
        MockFeePool[4] pools;
        Vent vent;
    }

    address internal provider = makeAddr("provider");
    address internal trader = makeAddr("trader");
    address internal deeds = makeAddr("deeds");
    address internal compounder = makeAddr("compounder");
    address internal stranger = makeAddr("stranger");
    address internal guardian = makeAddr("guardian");
    address internal hearth = makeAddr("hearth");
    address internal treasury = makeAddr("treasury");
    address internal stakers = makeAddr("stakers");
    address internal quoteYield = makeAddr("quoteYield");

    uint256 internal constant E = 1e18;
    uint256 internal constant U = 1e6;

    // ── the world ─────────────────────────────────────────────────────────

    function _world() internal returns (World memory w) {
        w.ember = new MockBurnableERC20("Ember", "EMBER");
        w.usdc = new MockDecimalsERC20("USD Coin", "USDC", 6);
        w.weth = new MockDecimalsERC20("Wrapped Ether", "WETH", 18);
        w.unknown = new MockERC20("Unknown", "UNK");
        w.mantle = new MockMantle(ERC20Burnable(address(w.ember)), true);
        // The pairs and pools name the Vent before it exists, as the kit's CREATE3 plan does.
        address v = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 6);
        w.pairs[0] = new EmberPair("Blast", "BLAST", IERC20(address(w.ember)), IERC20(address(w.usdc)), v, address(0), guardian, provider);
        w.pairs[1] = new EmberPair("Smelter", "SMELT", IERC20(address(w.ember)), IERC20(address(w.weth)), v, address(0), guardian, provider);
        w.pools[0] = new MockFeePool(IERC20(address(w.pairs[0])), v);
        w.pools[1] = new MockFeePool(IERC20(address(w.pairs[1])), v);
        w.pools[2] = new MockFeePool(IERC20(address(w.ember)), v);
        w.pools[3] = new MockFeePool(IERC20(address(w.usdc)), v);
        w.vent = _deployVent(w, deeds, compounder);
        assertEq(address(w.vent), v, "the Vent lands where it was named");
    }

    function _deployVent(World memory w, address deeds_, address compounder_) internal returns (Vent) {
        IVentFeePool[4] memory pools;
        for (uint256 i; i < 4; ++i) pools[i] = IVentFeePool(address(w.pools[i]));
        IVentPair[2] memory pairs = [IVentPair(address(w.pairs[0])), IVentPair(address(w.pairs[1]))];
        return new Vent(
            IERC20(address(w.ember)), IVentMantle(address(w.mantle)), pools, pairs, hearth, treasury, stakers, quoteYield, deeds_, compounder_
        );
    }

    function _quote(World memory w, uint256 j) internal pure returns (MockERC20) {
        return j == 0 ? MockERC20(address(w.usdc)) : MockERC20(address(w.weth));
    }

    /// @dev Token by the model's index: EMBER, the two quotes, the two LPs, an unknown one.
    function _token(World memory w, uint256 t) internal pure returns (IERC20) {
        if (t == 0) return IERC20(address(w.ember));
        if (t == 1) return IERC20(address(w.usdc));
        if (t == 2) return IERC20(address(w.weth));
        if (t == 3) return IERC20(address(w.pairs[0]));
        if (t == 4) return IERC20(address(w.pairs[1]));
        return IERC20(address(w.unknown));
    }

    /// @dev Give `who` `amount` of token `t`: minted, or LP from the provider.
    function _give(World memory w, uint256 t, address who, uint256 amount) internal {
        if (t == 3 || t == 4) {
            vm.prank(provider);
            IERC20(address(w.pairs[t - 3])).transfer(who, amount);
        } else if (t == 0) {
            w.ember.mint(who, amount);
        } else {
            MockERC20(address(_token(w, t))).mint(who, amount);
        }
    }

    function _addLiquidity(World memory w, uint256 j, uint256 e, uint256 q) internal returns (bool ok, bytes memory ret) {
        w.ember.mint(provider, e);
        _quote(w, j).mint(provider, q);
        vm.startPrank(provider);
        w.ember.approve(address(w.pairs[j]), e);
        _quote(w, j).approve(address(w.pairs[j]), q);
        (ok, ret) = address(w.pairs[j]).call(abi.encodeCall(EmberPair.addLiquidity, (e, q, 0, 0, provider)));
        vm.stopPrank();
    }

    /// @dev A world with deep, matured pairs ($1 EMBER in BlastPool), at a realistic time.
    function _matured() internal returns (World memory w) {
        vm.warp(1_800_000_000);
        w = _world();
        _addLiquidity(w, 0, 1_000_000 * E, 1_000_000 * U);
        _addLiquidity(w, 1, 1_000_000 * E, 500 * E);
        for (uint256 k; k < 8; ++k) {
            vm.warp(block.timestamp + 300);
            w.pairs[0].checkpoint();
            w.pairs[1].checkpoint();
        }
    }

    function _bookPool(World memory w, uint256 i, uint256 kind, uint256 amount) internal {
        uint256 t = i == 0 ? 3 : i == 1 ? 4 : i == 2 ? 0 : 1;
        _give(w, t, provider, amount);
        vm.startPrank(provider);
        _token(w, t).approve(address(w.pools[i]), amount);
        w.pools[i].book(kind, amount);
        vm.stopPrank();
    }

    function _trade(World memory w, uint256 j, uint256 side, uint256 amount) internal returns (bool ok, bytes memory ret) {
        EmberPair p = w.pairs[j];
        if (side == 0) {
            _quote(w, j).mint(trader, amount);
            vm.startPrank(trader);
            _quote(w, j).approve(address(p), amount);
            (ok, ret) = address(p).call(abi.encodeCall(EmberPair.buy, (amount, 0, trader)));
        } else {
            w.ember.mint(trader, amount);
            vm.startPrank(trader);
            w.ember.approve(address(p), amount);
            (ok, ret) = address(p).call(abi.encodeCall(EmberPair.sell, (amount, 0, trader)));
        }
        vm.stopPrank();
    }

}

/// @notice The Vent (ADR 0020): unit tests for every gate and guard, then the BigInt model's
///         scenarios replayed exactly.
contract VentTest is VentRig {
    // ── unit tests ────────────────────────────────────────────────────────

    function test_constructorRefusesZeroesAndAnUnregisteredVent() public {
        World memory w = _world();
        IVentFeePool[4] memory pools;
        for (uint256 i; i < 4; ++i) pools[i] = IVentFeePool(address(w.pools[i]));
        IVentPair[2] memory pairs = [IVentPair(address(w.pairs[0])), IVentPair(address(w.pairs[1]))];
        IERC20 ember = IERC20(address(w.ember));
        // Not registered with the Mantle: its burns would earn nothing, so it refuses to exist.
        IVentMantle closed = IVentMantle(address(new MockMantle(ERC20Burnable(address(w.ember)), false)));
        vm.expectRevert(Vent.NotRegistrar.selector);
        new Vent(ember, closed, pools, pairs, hearth, treasury, stakers, quoteYield, deeds, compounder);
        IVentMantle mantle = IVentMantle(address(w.mantle));
        vm.expectRevert(Vent.ZeroAddress.selector);
        new Vent(ember, mantle, pools, pairs, address(0), treasury, stakers, quoteYield, deeds, compounder);
        vm.expectRevert(Vent.ZeroAddress.selector);
        new Vent(ember, mantle, pools, pairs, hearth, treasury, address(0), quoteYield, deeds, compounder);
        pools[2] = IVentFeePool(address(0));
        vm.expectRevert(Vent.ZeroAddress.selector);
        new Vent(ember, mantle, pools, pairs, hearth, treasury, stakers, quoteYield, deeds, compounder);
        assertEq(w.vent.DEEDS(), deeds);
        assertEq(w.vent.COMPOUNDER(), compounder);
        assertEq(address(w.vent.PAIR_0()), address(w.pairs[0]));
        assertEq(w.vent.recipientOf(Vent.Recipient.QuoteYield), quoteYield);
    }

    function test_splitsByKindAndAsset() public {
        World memory w = _matured();
        _bookPool(w, 2, 0, 1000 * E + 9); // standard EMBER
        _bookPool(w, 2, 2, 100 * E + 3); // emergency EMBER
        _bookPool(w, 3, 1, 1000 * U + 7); // standard USDC
        _bookPool(w, 3, 2, 100 * U + 1); // emergency USDC
        w.vent.collectPool(2);
        w.vent.collectPool(3);
        IERC20 em = IERC20(address(w.ember));
        IERC20 usdc = IERC20(address(w.usdc));
        assertEq(w.vent.owed(Vent.Recipient.Hearth, em), (1000 * E + 9) / 10, "10% Hearth");
        assertEq(w.vent.owed(Vent.Recipient.Treasury, em), (1000 * E + 9) / 10, "10% Treasury");
        assertEq(w.vent.owed(Vent.Recipient.Stakers, em), (100 * E + 3) / 4, "25% stakers");
        uint256 kept = 2 * ((1000 * E + 9) / 10) + (100 * E + 3) / 4;
        assertEq(w.vent.totalBurned(), 1100 * E + 12 - kept, "EMBER's burn and liquidity shares burn now");
        assertEq(w.mantle.burned(), w.vent.totalBurned(), "every burn is registered");
        assertEq(w.vent.totalCredit(), w.mantle.credited());
        Vent.Lane memory l = w.vent.lane(0);
        assertEq(l.matchReserve, (1000 * U + 7) * 40 / 100 + (100 * U + 1) * 25 / 100, "quote liquidity waits");
        uint256 owedQ = (1000 * U + 7) / 10 * 2 + (100 * U + 1) / 4;
        assertEq(l.burnQuote, 1100 * U + 8 - owedQ - l.matchReserve, "the burn lane takes the remainder");
        assertEq(w.vent.owed(Vent.Recipient.Stakers, usdc), (100 * U + 1) / 4);
        assertEq(l.pendingSince, block.timestamp);
    }

    function test_lpFeesUnwindAtOnceAndDustStaysUnbooked() public {
        vm.warp(1_800_000_000);
        World memory w = _world();
        _addLiquidity(w, 0, 250_000 * E, 1_000_000 * U); // $4 EMBER: one LP unit is under a wei of each
        _addLiquidity(w, 1, 1_000_000 * E, 500 * E);
        _bookPool(w, 0, 0, 1);
        w.vent.collectPool(0);
        assertEq(w.pairs[0].balanceOf(address(w.vent)), 1, "1 LP unit redeems to nothing: left unbooked");
        assertEq(w.vent.totalBurned(), 0);
        _bookPool(w, 0, 0, 100 * E);
        _bookPool(w, 0, 2, 10 * E);
        uint256 supply = w.pairs[0].totalSupply();
        w.vent.collectPool(0);
        assertEq(w.pairs[0].totalSupply(), supply - 110 * E, "one redeem of the whole fee");
        assertGt(w.vent.lane(0).burnQuote, 0);
        assertGt(w.vent.totalBurned(), 0);
    }

    function test_collectAllSkipsAFailingSource() public {
        World memory w = _matured();
        // A Vent whose pool 1 stakes a token it does not know: that pool's collection reverts.
        address v = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        MockFeePool odd = new MockFeePool(IERC20(address(w.unknown)), v);
        IVentFeePool[4] memory pools;
        for (uint256 i; i < 4; ++i) pools[i] = IVentFeePool(address(w.pools[i]));
        pools[1] = IVentFeePool(address(odd));
        IVentPair[2] memory pairs = [IVentPair(address(w.pairs[0])), IVentPair(address(w.pairs[1]))];
        Vent vent2 = new Vent(
            IERC20(address(w.ember)), IVentMantle(address(w.mantle)), pools, pairs, hearth, treasury, stakers, quoteYield, deeds, compounder
        );
        w.unknown.mint(address(this), 5);
        w.unknown.approve(address(odd), 5);
        odd.book(0, 5);
        vm.expectRevert(abi.encodeWithSelector(Vent.UnknownAsset.selector, address(w.unknown)));
        vent2.collectPool(1);
        vent2.collectAll();
        assertEq(odd.fees(0), 5, "the failing source keeps its fees");
    }

    function test_deedFeesOnlyFromDeeds() public {
        World memory w = _matured();
        w.usdc.mint(stranger, 10 * U);
        vm.startPrank(stranger);
        w.usdc.approve(address(w.vent), 10 * U);
        vm.expectRevert(Vent.NotDeeds.selector);
        w.vent.bookDeedFee(IERC20(address(w.usdc)), 10 * U);
        vm.stopPrank();
        // With no market, nobody can book one.
        Vent none = _deployVent(w, address(0), compounder);
        vm.prank(deeds);
        vm.expectRevert(Vent.NotDeeds.selector);
        none.bookDeedFee(IERC20(address(w.usdc)), 1);
        // A token that delivers less than it claims is refused.
        w.usdc.mint(deeds, 1);
        vm.startPrank(deeds);
        w.usdc.approve(address(w.vent), 1);
        vm.mockCall(address(w.usdc), abi.encodeCall(IERC20.balanceOf, (address(w.vent))), abi.encode(uint256(0)));
        vm.expectRevert(Vent.NonStandardToken.selector);
        w.vent.bookDeedFee(IERC20(address(w.usdc)), 1);
        vm.clearMockedCalls();
        vm.stopPrank();
        // DEEDS books at 50/50.
        w.usdc.mint(deeds, 10 * U + 1);
        vm.startPrank(deeds);
        w.usdc.approve(address(w.vent), 10 * U + 1);
        w.vent.bookDeedFee(IERC20(address(w.usdc)), 10 * U + 1);
        vm.stopPrank();
        assertEq(w.vent.lane(0).matchReserve, 5 * U, "50% liquidity, floored");
        assertEq(w.vent.lane(0).burnQuote, 5 * U + 1, "50% burn takes the remainder");
    }

    function test_drawsOnlyByTheCompounder() public {
        World memory w = _matured();
        _bookPool(w, 3, 0, 1000 * U);
        w.vent.collectPool(3);
        uint256 reserve = w.vent.lane(0).matchReserve;
        vm.prank(stranger);
        vm.expectRevert(Vent.NotCompounder.selector);
        w.vent.drawMatchReserve(0, 1);
        vm.prank(treasury);
        vm.expectRevert(Vent.NotCompounder.selector);
        w.vent.drawMatchReserve(0, 1); // reserve quote is never Treasury-spendable
        vm.prank(compounder);
        vm.expectRevert(abi.encodeWithSelector(Vent.ExceedsReserve.selector, reserve + 1, reserve));
        w.vent.drawMatchReserve(0, reserve + 1);
        vm.prank(compounder);
        w.vent.drawMatchReserve(0, reserve);
        assertEq(w.usdc.balanceOf(compounder), reserve);
        Vent none = _deployVent(w, deeds, address(0));
        vm.prank(address(0));
        vm.expectRevert(Vent.NotCompounder.selector);
        none.drawMatchReserve(0, 1);
    }

    function test_aRefusingRecipientBlocksNoOther() public {
        World memory w = _matured();
        _bookPool(w, 3, 0, 1000 * U);
        w.vent.collectPool(3);
        assertEq(w.vent.release(Vent.Recipient.Hearth, IERC20(address(w.usdc))), 100 * U);
        assertEq(w.vent.release(Vent.Recipient.Hearth, IERC20(address(w.usdc))), 0, "nothing twice");
        assertEq(w.usdc.balanceOf(hearth), 100 * U);
        assertEq(w.vent.release(Vent.Recipient.Treasury, IERC20(address(w.unknown))), 0, "an unknown token owes nothing");
        // A recipient whose transfer reverts: the call fails and its ledger stays; others pay.
        vm.mockCallRevert(address(w.usdc), abi.encodeCall(IERC20.transfer, (treasury, 100 * U)), "refused");
        vm.expectRevert(bytes("refused"));
        w.vent.release(Vent.Recipient.Treasury, IERC20(address(w.usdc)));
        assertEq(w.vent.owed(Vent.Recipient.Treasury, IERC20(address(w.usdc))), 100 * U);
        vm.clearMockedCalls();
        w.vent.release(Vent.Recipient.Treasury, IERC20(address(w.usdc)));
        assertEq(w.usdc.balanceOf(treasury), 100 * U);
    }

    function test_ventDefersThenBuysWithinTheWindow() public {
        World memory w = _matured();
        _bookPool(w, 3, 0, 50_000 * U);
        w.vent.collectPool(3);
        (Vent.Deferral r, uint256 q, uint256 out) = w.vent.vent(0);
        assertEq(uint256(r), uint256(Vent.Deferral.None));
        (, uint112 rQ,) = w.pairs[0].getReserves();
        Vent.Lane memory l = w.vent.lane(0);
        assertEq(q, (uint256(l.windowBase) * P.VENT_CHUNK_BPS) / 10_000, "a 0.5% chunk of the base reserve");
        assertEq(w.mantle.burned(), out, "the bought EMBER burns");
        assertEq(w.ember.balanceOf(address(w.vent)), 0);
        // The window's 0.5% is spent: further calls defer until the next window.
        (r,,) = w.vent.vent(0);
        assertEq(uint256(r), uint256(Vent.Deferral.Window));
        assertTrue(l.draining);
        assertGt(rQ, l.windowBase);
        // At the next window the TWAP still lags the buyback's own move: the floor defers it.
        vm.warp((block.timestamp / P.VENT_WINDOW_SECONDS + 1) * P.VENT_WINDOW_SECONDS);
        (r,,) = w.vent.vent(0);
        assertEq(uint256(r), uint256(Vent.Deferral.Unsafe), "the TWAP has not caught up");
        for (uint256 k; k < 7; ++k) {
            vm.warp(block.timestamp + 300);
            w.pairs[0].checkpoint();
        }
        (r,,) = w.vent.vent(0);
        assertEq(uint256(r), uint256(Vent.Deferral.None), "a new window, the TWAP caught up");
    }

    function test_donationsMoveNothing() public {
        World memory w = _matured();
        _bookPool(w, 3, 0, 50_000 * U);
        w.vent.collectPool(3);
        Vent.Lane memory before = w.vent.lane(0);
        w.usdc.mint(address(w.vent), 1_000_000 * U);
        w.usdc.mint(address(w.pairs[0]), 1_000_000 * U); // the pair's reserves are internal
        w.ember.mint(address(w.vent), 1000 * E);
        w.vent.collectAll();
        Vent.Lane memory l = w.vent.lane(0);
        assertEq(l.burnQuote, before.burnQuote);
        assertEq(l.matchReserve, before.matchReserve);
        assertEq(w.vent.totalBurned(), 0, "donated EMBER is never burned for credit");
        (, uint256 q,) = w.vent.vent(0);
        (, uint112 rQ,) = w.pairs[0].getReserves();
        assertLe(q, (uint256(rQ) * P.VENT_WINDOW_MAX_BPS) / 10_000, "the base is the internal reserve");
    }

    /// @notice Every executed buyback stays inside the 3% price-impact cap the config pins.
    function testFuzz_impactIsImpliedByTheChunkAndTheFloor(uint256 fee, uint256 push) public {
        World memory w = _matured();
        fee = bound(fee, 10_000 * U, 5_000_000 * U);
        push = bound(push, 0, 15_000) * U;
        if (push != 0) {
            (bool ok,) = _trade(w, 0, 0, push); // move spot up to ~3% (outside the band past ~2%)
            assertTrue(ok);
        }
        _bookPool(w, 3, 0, fee);
        w.vent.collectPool(3);
        (uint112 e0, uint112 q0,) = w.pairs[0].getReserves();
        (Vent.Deferral r,,) = w.vent.vent(0);
        if (r != Vent.Deferral.None) return;
        (uint112 e1, uint112 q1,) = w.pairs[0].getReserves();
        uint256 before = (uint256(q0) << 112) / e0;
        uint256 afterBuy = (uint256(q1) << 112) / e1;
        assertLe((afterBuy - before) * 10_000, before * P.VENT_PRICE_IMPACT_BPS, "within the impact cap");
    }

    function test_smelterWaitsForItsClockAndBlastForItsBatch() public {
        World memory w = _matured();
        _bookPool(w, 3, 0, 5_000 * U); // 2,000 USDC to the burn lane: under $5,000
        w.vent.collectPool(3);
        (Vent.Deferral r,,) = w.vent.vent(0);
        assertEq(uint256(r), uint256(Vent.Deferral.NotEligible));
        assertEq(w.vent.minBatch(0), 5_000 * U);
        assertEq(w.vent.minBatch(1), type(uint256).max, "no USD threshold for a non-USD quote");
        _bookPool(w, 1, 0, 100 * E);
        w.vent.collectPool(1);
        (r,,) = w.vent.vent(1);
        assertEq(uint256(r), uint256(Vent.Deferral.NotEligible));
        vm.warp(block.timestamp + P.VENT_MAX_WAIT);
        w.pairs[1].checkpoint();
        vm.warp(block.timestamp + 1800);
        w.pairs[1].checkpoint();
        (r,,) = w.vent.vent(1);
        assertEq(uint256(r), uint256(Vent.Deferral.None), "24 h on");
    }

    function test_overdueIsAnAlertNeverAWeakerGuard() public {
        World memory w = _matured();
        _bookPool(w, 3, 0, 50_000 * U);
        w.vent.collectPool(3);
        vm.prank(guardian);
        w.pairs[0].setSwapsPaused(true);
        uint256 since = w.vent.lane(0).pendingSince;
        vm.warp(block.timestamp + P.VENT_ALERT_AFTER);
        vm.expectEmit(true, false, false, true, address(w.vent));
        emit Vent.VentOverdue(0, since);
        (Vent.Deferral r,,) = w.vent.vent(0);
        assertEq(uint256(r), uint256(Vent.Deferral.Paused), "still deferred");
    }

    function test_gas() public {
        World memory w = _matured();
        _bookPool(w, 0, 0, 100 * E);
        _bookPool(w, 3, 0, 50_000 * U);
        uint256 g = gasleft();
        w.vent.collectPool(0);
        emit log_named_uint("collectPool (LP: redeem, burn)", g - gasleft());
        g = gasleft();
        w.vent.collectPool(3);
        emit log_named_uint("collectPool (USDC)", g - gasleft());
        g = gasleft();
        w.vent.vent(0);
        emit log_named_uint("vent (buyback and burn)", g - gasleft());
        g = gasleft();
        w.vent.vent(0);
        emit log_named_uint("vent (deferred)", g - gasleft());
        g = gasleft();
        w.vent.release(Vent.Recipient.Hearth, IERC20(address(w.usdc)));
        emit log_named_uint("release", g - gasleft());
    }

    // ── the BigInt model's scenarios, replayed exactly ────────────────────

    function test_replaysTheModelExactly() public {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/contracts/test/fixtures/vent-vectors.json"));
        assertEq(vm.parseJsonUint(json, ".creditPct"), P.RECYCLE_PROTOCOL_BURN_PCT, "vectors generated from this config");
        uint256 n;
        for (; vm.keyExistsJson(json, string.concat(".scenarios[", vm.toString(n), "]")); ++n) {
            _replay(json, string.concat(".scenarios[", vm.toString(n), "]"));
        }
        assertEq(n, 10, "every scenario replayed");
    }

    struct Cols {
        uint256[] kind;
        string[] a;
        string[] b;
        string[] c;
        string[] why;
        string[][3] out;
        string[] hash;
    }

    function _replay(string memory json, string memory base) internal {
        vm.warp(vm.parseUint(vm.parseJsonString(json, string.concat(base, ".start"))));
        World memory w = _world();
        string[] memory seed = vm.parseJsonStringArray(json, string.concat(base, ".seed"));
        (bool ok,) = _addLiquidity(w, 0, vm.parseUint(seed[0]), vm.parseUint(seed[1]));
        assertTrue(ok, "seed BlastPool");
        (ok,) = _addLiquidity(w, 1, vm.parseUint(seed[2]), vm.parseUint(seed[3]));
        assertTrue(ok, "seed SmelterPool");
        Cols memory c;
        c.kind = vm.parseJsonUintArray(json, string.concat(base, ".kind"));
        c.a = vm.parseJsonStringArray(json, string.concat(base, ".a"));
        c.b = vm.parseJsonStringArray(json, string.concat(base, ".b"));
        c.c = vm.parseJsonStringArray(json, string.concat(base, ".c"));
        c.why = vm.parseJsonStringArray(json, string.concat(base, ".why"));
        c.out[0] = vm.parseJsonStringArray(json, string.concat(base, ".out0"));
        c.out[1] = vm.parseJsonStringArray(json, string.concat(base, ".out1"));
        c.out[2] = vm.parseJsonStringArray(json, string.concat(base, ".out2"));
        c.hash = vm.parseJsonStringArray(json, string.concat(base, ".hash"));
        string memory name = vm.parseJsonString(json, string.concat(base, ".name"));
        for (uint256 i; i < c.kind.length; ++i) {
            string memory at = string.concat(name, " step ", vm.toString(i));
            (bool okStep, uint256[3] memory out, bytes memory ret) =
                _act(w, c.kind[i], vm.parseUint(c.a[i]), vm.parseUint(c.b[i]), vm.parseUint(c.c[i]));
            if (bytes(c.why[i]).length != 0) {
                assertFalse(okStep, string.concat(at, ": expected ", c.why[i]));
                assertEq(bytes4(ret), bytes4(keccak256(bytes(string.concat(c.why[i], _args(c.why[i]))))), at);
            } else {
                if (!okStep) emit log_named_bytes("revert", ret);
                assertTrue(okStep, string.concat(at, ": reverted"));
                for (uint256 k; k < 3; ++k) assertEq(out[k], vm.parseUint(c.out[k][i]), string.concat(at, ": output ", vm.toString(k)));
            }
            assertEq(keccak256(abi.encodePacked(_words(w))), vm.parseBytes32(c.hash[i]), string.concat(at, ": state"));
        }
    }

    function _args(string memory why) internal pure returns (string memory) {
        bytes32 h = keccak256(bytes(why));
        if (h == keccak256("BadPool") || h == keccak256("BadPair") || h == keccak256("LiquidityTooLow")) return "(uint256)";
        if (h == keccak256("UnknownAsset")) return "(address)";
        if (h == keccak256("ExceedsReserve") || h == keccak256("Slippage")) return "(uint256,uint256)";
        return "()";
    }

    /// @dev One model action. Outputs are decoded per kind; actions without a call output zeros.
    function _act(World memory w, uint256 kind, uint256 a, uint256 b, uint256 c)
        internal
        returns (bool ok, uint256[3] memory out, bytes memory ret)
    {
        ok = true;
        if (kind == 0) {
            vm.warp(block.timestamp + a);
        } else if (kind == 1) {
            (ok, ret) = _trade(w, a, b, c);
            if (ok) out[0] = abi.decode(ret, (uint256));
        } else if (kind == 2) {
            uint256 t = a == 0 ? 3 : a == 1 ? 4 : a == 2 ? 0 : 1;
            _give(w, t, provider, c);
            vm.startPrank(provider);
            _token(w, t).approve(address(w.pools[a]), c);
            w.pools[a].book(b, c);
            vm.stopPrank();
        } else if (kind == 3) {
            vm.prank(stranger);
            (ok, ret) = address(w.vent).call(abi.encodeCall(Vent.collectPool, (a)));
            if (ok) (out[0], out[1]) = abi.decode(ret, (uint256, uint256));
        } else if (kind == 4) {
            vm.prank(stranger);
            (ok, ret) = address(w.vent).call(abi.encodeCall(Vent.collectPair, (a)));
            if (ok) (out[0], out[1], out[2]) = abi.decode(ret, (uint256, uint256, uint256));
        } else if (kind == 5) {
            vm.prank(stranger);
            (ok, ret) = address(w.vent).call(abi.encodeCall(Vent.collectAll, ()));
        } else if (kind == 6) {
            vm.prank(stranger);
            (ok, ret) = address(w.vent).call(abi.encodeCall(Vent.vent, (a)));
            if (ok) (out[0], out[1], out[2]) = abi.decode(ret, (uint256, uint256, uint256));
        } else if (kind == 7) {
            vm.prank(stranger);
            (ok, ret) = address(w.vent).call(abi.encodeCall(Vent.release, (Vent.Recipient(a), _token(w, b))));
            if (ok) out[0] = abi.decode(ret, (uint256));
        } else if (kind == 8) {
            vm.prank(c == 0 ? compounder : stranger);
            (ok, ret) = address(w.vent).call(abi.encodeCall(Vent.drawMatchReserve, (a, b)));
        } else if (kind == 9) {
            address giver = c == 0 ? deeds : stranger;
            _give(w, a, giver, b);
            vm.startPrank(giver);
            _token(w, a).approve(address(w.vent), b);
            (ok, ret) = address(w.vent).call(abi.encodeCall(Vent.bookDeedFee, (_token(w, a), b)));
            vm.stopPrank();
        } else if (kind == 10) {
            _give(w, a, stranger, b);
            vm.prank(stranger);
            _token(w, a).transfer(address(w.vent), b);
        } else if (kind == 11) {
            vm.prank(guardian);
            w.pairs[a].setSwapsPaused(b != 0);
        } else if (kind == 12) {
            (ok, ret) = address(w.pairs[a]).call(abi.encodeCall(EmberPair.checkpoint, ()));
        } else {
            (ok, ret) = _addLiquidity(w, a, b, c);
            if (ok) (out[0], out[1], out[2]) = abi.decode(ret, (uint256, uint256, uint256));
        }
    }

    /// @dev The model's `words()`, in its exact order.
    function _words(World memory w) internal view returns (uint256[] memory x) {
        x = new uint256[](77);
        uint256 n;
        for (uint256 j; j < 2; ++j) n = _pairWords(w, j, x, n);
        for (uint256 who; who < 4; ++who) {
            for (uint256 t; t < 3; ++t) x[n++] = w.vent.owed(Vent.Recipient(who), _token(w, t));
        }
        address[4] memory to = [hearth, treasury, stakers, quoteYield];
        for (uint256 who; who < 4; ++who) {
            for (uint256 t; t < 3; ++t) x[n++] = _token(w, t).balanceOf(to[who]);
        }
        for (uint256 t; t < 5; ++t) x[n++] = _token(w, t).balanceOf(address(w.vent));
        for (uint256 i; i < 4; ++i) {
            for (uint256 k; k < 3; ++k) x[n++] = w.pools[i].fees(k);
        }
        x[n++] = w.vent.totalBurned();
        x[n++] = w.vent.totalCredit();
        assert(n == 77);
    }

    function _pairWords(World memory w, uint256 j, uint256[] memory x, uint256 n) internal view returns (uint256) {
        Vent.Lane memory l = w.vent.lane(j);
        x[n++] = l.burnQuote;
        x[n++] = l.matchReserve;
        x[n++] = l.pendingSince;
        x[n++] = l.draining ? 1 : 0;
        x[n++] = l.windowId;
        x[n++] = l.windowBase;
        x[n++] = l.windowSpent;
        EmberPair p = w.pairs[j];
        (uint112 rE, uint112 rQ,) = p.getReserves();
        x[n++] = rE;
        x[n++] = rQ;
        x[n++] = p.totalSupply();
        (uint256 fb, uint256 fl, uint256 fq) = p.protocolFees();
        x[n++] = fb;
        x[n++] = fl;
        x[n++] = fq;
        x[n++] = p.swapsPaused() ? 1 : 0;
        try p.consult(uint32(P.PAIR_TWAP_SECONDS)) returns (uint256 px, uint32 el) {
            (x[n], x[n + 1]) = (px, el);
        } catch {}
        n += 2;
        x[n++] = _quote(w, j).balanceOf(compounder);
        return n;
    }
}
