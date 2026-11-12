// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {EmberPair} from "../src/pairs/EmberPair.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {Flow, IFeeRebate} from "../src/flow/Flow.sol";
import {TestnetFeeRebate} from "../script/testnet/TestnetStandIns.sol";
import {FlowRig} from "./Flow.t.sol";

contract FlowHandler is Test {
    Flow public flow;
    EmberPair[2] internal pairs;
    ForgePool[2] internal pools;
    TestnetFeeRebate internal rebates;
    address internal operator;
    address internal compounder;
    address[3] internal users;
    mapping(address user => uint256[2]) internal positionOf;

    /// Receipts staked into each pool through Flow; the pools take no other deposits here.
    uint256[2] public staked;
    /// Protocol fees each pair should have booked: the fee rule on every swap leg's base, at
    /// the share that leg ran at, computed before the call from the reserves it saw.
    uint256[2] public expectedFees;
    uint256 public maxDustPpm;
    bool public dustTooLarge;
    uint256 public zaps;

    constructor(Flow flow_, TestnetFeeRebate rebates_, address operator_, address compounder_) {
        (flow, rebates, operator, compounder) = (flow_, rebates_, operator_, compounder_);
        pairs = [flow_.PAIR0(), flow_.PAIR1()];
        pools = [flow_.POOL0(), flow_.POOL1()];
        for (uint256 i; i < 3; ++i) users[i] = address(uint160(0x4000 + i));
        users[2] = compounder_;
        for (uint256 i; i < 3; ++i) {
            address u = users[i];
            for (uint256 k; k < 2; ++k) {
                MockMint(address(pairs[k].EMBER())).mint(u, 1e32);
                MockMint(address(pairs[k].QUOTE())).mint(u, 1e32);
                vm.startPrank(u);
                pairs[k].EMBER().approve(address(flow_), type(uint256).max);
                pairs[k].QUOTE().approve(address(flow_), type(uint256).max);
                IERC20(address(pairs[k])).approve(address(flow_), type(uint256).max);
                vm.stopPrank();
            }
        }
    }

    // ── the expected-fee model (independent of Flow and the pair) ─────────

    function _protocolFee(uint256 g, bool isBuy, uint256 share) internal pure returns (uint256) {
        uint256 b = isBuy ? P.PAIR_BUY_BURN_PPM : P.PAIR_SELL_BURN_PPM;
        uint256 l = isBuy ? P.PAIR_BUY_LIQUIDITY_PPM : P.PAIR_SELL_LIQUIDITY_PPM;
        uint256 y = isBuy ? 0 : P.PAIR_SELL_QUOTE_YIELD_PPM;
        return Math.ceilDiv(g * b * share, 1e12) + Math.ceilDiv(g * l * share, 1e12) + Math.ceilDiv(g * y * share, 1e12);
    }

    /// The protocol fee of a swap of `amountIn` at reserves (rE, rQ).
    function _legFee(uint256 rE, uint256 rQ, bool isBuy, uint256 amountIn, uint256 share) internal pure returns (uint256) {
        uint256 base = isBuy ? amountIn : (rQ * amountIn) / (rE + amountIn);
        return _protocolFee(base, isBuy, share);
    }

    function _reserves(uint256 k) internal view returns (uint256 rE, uint256 rQ) {
        (uint112 e, uint112 q,) = pairs[k].getReserves();
        return (e, q);
    }

    function _booked(uint256 k) internal view returns (uint256) {
        (uint256 b, uint256 l, uint256 y) = pairs[k].protocolFees();
        return b + l + y;
    }

    function _amount(uint256 seed, bool emberSide, uint256 k) internal pure returns (uint256) {
        uint256 unit = emberSide || k == 1 ? 1e18 : 1e6;
        return bound(seed >> 8, 1, 10 ** (seed % 6) * 10 * unit / (k == 1 && !emberSide ? 1000 : 1));
    }

    // ── actions ───────────────────────────────────────────────────────────

    function setRebate(uint256 who, uint256 pct) external {
        vm.prank(operator);
        rebates.setRebate(users[who % 2], bound(pct, 0, 100));
    }

    function swap(uint256 who, uint256 k, bool buy, uint256 seed) external {
        address u = users[who % 2];
        k %= 2;
        uint256 amount = _amount(seed, !buy, k);
        uint256 share = flow.rebateShareOf(u);
        (uint256 rE, uint256 rQ) = _reserves(k);
        uint256 fee = _legFee(rE, rQ, buy, amount, share);
        vm.prank(u);
        try flow.swap(k, buy, amount, 0, u, block.timestamp) {
            expectedFees[k] += fee;
        } catch {}
    }

    function compoundSwap(uint256 k, bool buy, uint256 seed) external {
        k %= 2;
        vm.prank(compounder);
        try flow.compoundSwap(k, buy, _amount(seed, !buy, k), 0, compounder, block.timestamp) {} catch {}
        // share 0: no protocol fee expected
    }

    struct Z {
        address u;
        uint256 k;
        uint256 amount;
        uint256 fee;
        IERC20 tokenIn;
        uint256 before;
        uint256 slack;
        uint256 mode;
    }

    function zap(uint256 who, uint256 k, bool fromQuote, uint256 seed, uint256 stakeMode) external {
        Z memory z;
        (z.u, z.k) = (users[who % 2], k % 2);
        z.amount = _amount(seed, !fromQuote, z.k);
        bool priced;
        (priced, z.fee) = _zapFee(z.u, z.k, fromQuote, z.amount);
        if (!priced) return;
        z.tokenIn = fromQuote ? pairs[z.k].QUOTE() : pairs[z.k].EMBER();
        z.before = z.tokenIn.balanceOf(z.u);
        z.mode = stakeMode % 3; // 0 keep the LP, 1 stake into a new position, 2 add to one
        // Rounding slack: each fee component rounds up by under one quote unit, and the swap's
        // output and the add's amounts round down by one more, so a zap from EMBER can strand
        // up to ~10 quote units' worth of EMBER at the pool's price.
        (uint256 rE, uint256 rQ) = _reserves(z.k);
        z.slack = fromQuote ? 10 : 10 * rE / rQ + 10;
        try this.zapAs(z.u, z.k, fromQuote, z.amount, z.mode, z.mode == 2 ? positionOf[z.u][z.k] : 0) returns (
            uint256 l, uint256 id
        ) {
            expectedFees[z.k] += z.fee;
            _afterZap(z.u, z.k, z.mode, l, id);
            _checkDust(z.amount, z.before - z.tokenIn.balanceOf(z.u), z.slack);
        } catch {}
    }

    /// The protocol fee of a zap's swap leg, priced before the call at the caller's share.
    function _zapFee(address u, uint256 k, bool fromQuote, uint256 amount) internal view returns (bool, uint256) {
        uint256 share = flow.rebateShareOf(u);
        (uint256 rE, uint256 rQ) = _reserves(k);
        try flow.splitOf(k, fromQuote, amount, share) returns (uint256 s) {
            return (true, _legFee(rE, rQ, fromQuote, s, share));
        } catch {
            return (false, 0);
        }
    }

    function _afterZap(address u, uint256 k, uint256 mode, uint256 l, uint256 id) internal {
        ++zaps;
        if (mode != 0) {
            staked[k] += l;
            positionOf[u][k] = id;
        }
    }

    function _checkDust(uint256 amount, uint256 spent, uint256 slack) internal {
        uint256 refunded = amount - spent;
        uint256 ppm = refunded * 1e6 / amount;
        if (ppm > maxDustPpm) maxDustPpm = ppm;
        if (refunded > amount / 1e4 + slack) dustTooLarge = true;
    }

    /// External so `zap` can `try` it; only the handler itself may call it.
    function zapAs(address u, uint256 k, bool fromQuote, uint256 amount, uint256 mode, uint256 pos)
        external
        returns (uint256 l, uint256 id)
    {
        require(msg.sender == address(this), "handler only");
        vm.prank(u);
        if (mode == 0) return (flow.zapIn(k, fromQuote, amount, 0, block.timestamp), 0);
        return flow.zapAndStake(k, fromQuote, amount, 0, mode == 2 ? pos : 0, block.timestamp);
    }

    function zapOut(uint256 who, uint256 k, bool toQuote, uint256 fraction) external {
        address u = users[who % 2];
        k %= 2;
        uint256 held = pairs[k].balanceOf(u);
        if (held == 0) return;
        uint256 l = bound(fraction, 1, held);
        uint256 share = flow.rebateShareOf(u);
        (uint256 rE, uint256 rQ) = _reserves(k);
        uint256 supply = pairs[k].totalSupply();
        (uint256 e, uint256 q) = (l * rE / supply, l * rQ / supply);
        (rE, rQ) = (rE - e, rQ - q);
        uint256 fee = toQuote ? (e == 0 ? 0 : _legFee(rE, rQ, false, e, share)) : (q == 0 ? 0 : _legFee(rE, rQ, true, q, share));
        vm.prank(u);
        try flow.zapOut(k, l, toQuote, 0, block.timestamp) {
            expectedFees[k] += fee;
        } catch {}
    }

    function warp(uint256 dt) external {
        skip(bound(dt, 1, 1 days));
    }

    function bookedFees(uint256 k) external view returns (uint256) {
        return _booked(k);
    }
}

interface MockMint {
    function mint(address, uint256) external;
}

/// @notice Flow invariants (ADR 0016) over random swaps, Compound swaps, zaps in and out,
///         fee-free stakes and rebate changes.
contract FlowInvariantTest is FlowRig {
    FlowHandler handler;

    function setUp() public {
        _rig(IFeeRebate(address(1)), compounder);
        handler = new FlowHandler(flow, rebates, operator, compounder);
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = FlowHandler.setRebate.selector;
        selectors[1] = FlowHandler.swap.selector;
        selectors[2] = FlowHandler.compoundSwap.selector;
        selectors[3] = FlowHandler.zap.selector;
        selectors[4] = FlowHandler.zapOut.selector;
        selectors[5] = FlowHandler.warp.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// Flow holds no token, receipt or allowance between calls.
    function invariant_flowHoldsNothing() public view {
        _flowEmpty();
    }

    /// Every receipt a zap staked is in custody, whole: the same-route stake pays no deposit fee.
    function invariant_stakesAreWholeAndFeeFree() public view {
        assertEq(blast.balanceOf(address(pool0)), handler.staked(0));
        assertEq(smelter.balanceOf(address(pool1)), handler.staked(1));
        assertEq(pool0.feesOwed(0) + pool1.feesOwed(0), 0, "no deposit fee booked");
    }

    /// The pairs booked exactly the protocol fees the share rule charges on every swap leg.
    function invariant_feesFollowTheShareRule() public view {
        assertEq(handler.bookedFees(0), handler.expectedFees(0), "BlastPool");
        assertEq(handler.bookedFees(1), handler.expectedFees(1), "SmelterPool");
    }

    /// A zap returns at most dust: 0.01% of its input, plus ten quote units of rounding valued
    /// at the pool's price.
    function invariant_zapDustIsDust() public view {
        assertFalse(handler.dustTooLarge());
    }
}
