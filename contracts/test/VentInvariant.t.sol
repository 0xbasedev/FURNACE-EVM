// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {EmberPair} from "../src/pairs/EmberPair.sol";
import {Vent} from "../src/vent/Vent.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {MockBurnableERC20, MockMantle, MockFeePool} from "./utils/VentMocks.sol";
import {VentRig} from "./Vent.t.sol";

/// @notice Random trades, fees of every kind, collections, buybacks, releases, draws, Deed fees,
///         donations, pauses and time, against one Vent.
contract VentHandler is Test {
    Vent public vent;
    MockBurnableERC20 internal ember;
    MockERC20[2] internal quote;
    EmberPair[2] internal pairs;
    MockFeePool[4] internal pools;
    MockMantle internal mantle;
    address internal provider;
    address internal deeds;
    address internal compounder;
    address internal guardian;

    /// What was donated to the Vent, per token (EMBER, quote 0, quote 1): never booked.
    uint256[3] public donated;
    /// What the compounder drew, per pair.
    uint256[2] public drawn;
    uint256 public buybacks;
    uint256 public guardBroken;

    constructor(
        Vent vent_,
        MockBurnableERC20 ember_,
        MockERC20[2] memory quote_,
        MockFeePool[4] memory pools_,
        MockMantle mantle_,
        address[4] memory who // provider, deeds, compounder, guardian
    ) {
        (vent, ember, quote, pools, mantle) = (vent_, ember_, quote_, pools_, mantle_);
        pairs = [EmberPair(address(vent_.PAIR_0())), EmberPair(address(vent_.PAIR_1()))];
        (provider, deeds, compounder, guardian) = (who[0], who[1], who[2], who[3]);
    }

    /// Time passes; a keeper usually checkpoints both pairs (every fifth warp it does not).
    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 3 hours));
        if (dt % 5 != 0) {
            pairs[0].checkpoint();
            pairs[1].checkpoint();
        }
    }

    function trade(uint256 j, bool buy, uint256 amount) external {
        j %= 2;
        EmberPair p = pairs[j];
        if (p.swapsPaused()) return;
        if (buy) {
            amount = bound(amount, 1, 20_000) * (j == 0 ? 1e6 : 5e14);
            quote[j].mint(address(this), amount);
            quote[j].approve(address(p), amount);
            p.buy(amount, 0, address(this));
        } else {
            amount = bound(amount, 1, 20_000) * 1e18;
            ember.mint(address(this), amount);
            ember.approve(address(p), amount);
            p.sell(amount, 0, address(this));
        }
    }

    function bookPool(uint256 i, uint256 kind, uint256 amount) external {
        i %= 4;
        kind %= 3;
        IERC20 t = pools[i].STAKE_TOKEN();
        if (i < 2) {
            amount = bound(amount, 1, t.balanceOf(provider) / 1000 + 1);
            vm.prank(provider);
            t.transfer(address(this), amount);
        } else if (i == 2) {
            amount = bound(amount, 1, 500 * 1e18);
            ember.mint(address(this), amount);
        } else {
            amount = bound(amount, 1, 50_000 * 1e6);
            quote[0].mint(address(this), amount);
        }
        t.approve(address(pools[i]), amount);
        pools[i].book(kind, amount);
    }

    function collect(uint256 which) external {
        which %= 7;
        if (which < 4) vent.collectPool(which);
        else if (which < 6) vent.collectPair(which - 4);
        else vent.collectAll();
    }

    /// Collect everything, then try a buyback.
    function ventOnce(uint256 j) external {
        j %= 2;
        vent.collectAll();
        EmberPair p = pairs[j];
        (uint112 e0, uint112 q0,) = p.getReserves();
        Vent.Lane memory l0 = vent.lane(j);
        (Vent.Deferral r, uint256 quoteIn, uint256 out) = vent.vent(j);
        if (r != Vent.Deferral.None) {
            if (vent.lane(j).burnQuote != l0.burnQuote) ++guardBroken; // a deferral spends nothing
            return;
        }
        ++buybacks;
        (uint112 e1, uint112 q1,) = p.getReserves();
        Vent.Lane memory l1 = vent.lane(j);
        if (quoteIn > (uint256(q0) * P.VENT_CHUNK_BPS) / 10_000) ++guardBroken; // the chunk
        if (uint256(l1.windowSpent) * 10_000 > uint256(l1.windowBase) * P.VENT_WINDOW_MAX_BPS) ++guardBroken;
        uint256 before = (uint256(q0) << 112) / e0;
        uint256 afterBuy = (uint256(q1) << 112) / e1;
        if ((afterBuy - before) * 10_000 > before * P.VENT_PRICE_IMPACT_BPS) ++guardBroken; // the impact cap
        if (out == 0 || l1.burnQuote + quoteIn != l0.burnQuote) ++guardBroken;
    }

    /// What `release` paid each recipient, per token (EMBER, quote 0, quote 1).
    mapping(uint256 who => uint256[3]) internal _released;

    function released(uint256 who, uint256 t) external view returns (uint256) {
        return _released[who][t];
    }

    function release(uint256 who, uint256 t) external {
        (who, t) = (who % 4, t % 3);
        IERC20 token = t == 0 ? IERC20(address(ember)) : IERC20(address(quote[t - 1]));
        _released[who][t] += vent.release(Vent.Recipient(who), token);
    }

    function draw(uint256 j, uint256 amount, bool asCompounder) external {
        j %= 2;
        uint256 reserve = vent.lane(j).matchReserve;
        if (reserve == 0) return;
        amount = bound(amount, 1, reserve);
        if (!asCompounder) {
            vm.expectRevert(Vent.NotCompounder.selector);
            vent.drawMatchReserve(j, amount);
            return;
        }
        vm.prank(compounder);
        vent.drawMatchReserve(j, amount);
        drawn[j] += amount;
    }

    function bookDeed(uint256 t, uint256 amount) external {
        t %= 3;
        IERC20 token = t == 0 ? IERC20(address(ember)) : IERC20(address(quote[t - 1]));
        amount = bound(amount, 1, t == 1 ? 10_000 * 1e6 : 100 * 1e18);
        if (t == 0) ember.mint(deeds, amount);
        else quote[t - 1].mint(deeds, amount);
        vm.startPrank(deeds);
        token.approve(address(vent), amount);
        vent.bookDeedFee(token, amount);
        vm.stopPrank();
    }

    function donate(uint256 t, uint256 amount) external {
        t %= 3;
        amount = bound(amount, 1, 1e24);
        if (t == 0) ember.mint(address(vent), amount);
        else quote[t - 1].mint(address(vent), amount);
        donated[t] += amount;
    }

    /// Pause a pair's swaps one time in four; otherwise unpause it.
    function pause(uint256 j, uint256 r) external {
        vm.prank(guardian);
        pairs[j % 2].setSwapsPaused(r % 4 == 0);
    }
}

/// @notice Vent invariants (ADR 0020).
contract VentInvariantTest is VentRig {
    VentHandler handler;
    World w;

    function setUp() public {
        World memory m = _matured();
        w = m;
        MockERC20[2] memory q = [MockERC20(address(m.usdc)), MockERC20(address(m.weth))];
        handler = new VentHandler(m.vent, m.ember, q, m.pools, m.mantle, [provider, deeds, compounder, guardian]);
        // Fees waiting in every pool, uncollected, so that buybacks are reachable from the start.
        _bookPool(m, 3, 0, 250_000 * U);
        _bookPool(m, 0, 1, 5_000 * E);
        _bookPool(m, 1, 2, 500 * E);
        _bookPool(m, 2, 0, 1_000 * E);
        targetContract(address(handler));
    }

    function _owedSum(IERC20 token) internal view returns (uint256 s) {
        for (uint256 who; who < 4; ++who) s += w.vent.owed(Vent.Recipient(who), token);
    }

    /// Every token the Vent holds is exactly its ledgers plus what was donated: nothing is lost,
    /// and a donation is never booked. EMBER is never held once burned.
    function invariant_ledgersAreTheBalances() public view {
        IERC20 em = IERC20(address(w.ember));
        assertEq(em.balanceOf(address(w.vent)), _owedSum(em) + handler.donated(0), "EMBER");
        for (uint256 j; j < 2; ++j) {
            IERC20 q = j == 0 ? IERC20(address(w.usdc)) : IERC20(address(w.weth));
            Vent.Lane memory l = w.vent.lane(j);
            assertEq(q.balanceOf(address(w.vent)), l.burnQuote + l.matchReserve + _owedSum(q) + handler.donated(j + 1), "quote");
        }
    }

    /// No window spends more than its share of its fixed starting reserve.
    function invariant_windowCap() public view {
        for (uint256 j; j < 2; ++j) {
            Vent.Lane memory l = w.vent.lane(j);
            assertLe(uint256(l.windowSpent) * 10_000, uint256(l.windowBase) * P.VENT_WINDOW_MAX_BPS);
        }
    }

    /// Every burn went through the Mantle's registered burn, credit and all.
    function invariant_burnsAreRegistered() public view {
        assertEq(w.vent.totalBurned(), w.mantle.burned());
        assertEq(w.vent.totalCredit(), w.mantle.credited());
        assertLe(w.vent.totalCredit() * 100, w.vent.totalBurned() * P.RECYCLE_PROTOCOL_BURN_PCT);
    }

    /// Every buyback kept its chunk, window and impact cap; every deferral spent nothing.
    function invariant_guardsHeld() public view {
        assertEq(handler.guardBroken(), 0);
    }

    /// Match-reserve quote reached only the compounder, and owed shares only their recipients,
    ///  exactly what each release paid.
    function invariant_onlyTheirRecipientsAreReached() public view {
        assertEq(w.usdc.balanceOf(compounder), handler.drawn(0));
        assertEq(w.weth.balanceOf(compounder), handler.drawn(1));
        address[4] memory to = [hearth, treasury, stakers, quoteYield];
        IERC20[3] memory tokens = [IERC20(address(w.ember)), IERC20(address(w.usdc)), IERC20(address(w.weth))];
        for (uint256 who; who < 4; ++who) {
            for (uint256 t; t < 3; ++t) assertEq(tokens[t].balanceOf(to[who]), handler.released(who, t));
        }
    }
}
