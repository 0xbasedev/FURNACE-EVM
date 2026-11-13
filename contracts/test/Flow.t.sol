// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {EmberPair} from "../src/pairs/EmberPair.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {ForgePoolBase} from "../src/forge/ForgePoolBase.sol";
import {ForgeView} from "../src/forge/ForgeView.sol";
import {Flow, IFeeRebate} from "../src/flow/Flow.sol";
import {TestnetFeeRebate} from "../script/testnet/TestnetStandIns.sol";
import {MockERC20, MockDecimalsERC20} from "./utils/MockERC20.sol";

using ForgeView for ForgePool;

contract RevertingRebate {
    function rebatePctOf(address) external pure returns (uint256) {
        revert("down");
    }
}

contract MalformedRebate {
    fallback() external {
        assembly {
            mstore(0, 50)
            mstore(32, 50)
            return(0, 64) // two words where one is expected
        }
    }
}

/// @notice The rig both Flow suites use: two pairs, their two LP Forge pools and Flow, wired
///         through Flow's predicted address (each names the others, as CREATE3 does on chain).
abstract contract FlowRig is Test {
    uint256 constant E = 1e18;
    uint256 constant U = 1e6;
    MockERC20 ember;
    MockDecimalsERC20 usdc;
    MockDecimalsERC20 weth;
    EmberPair blast;
    EmberPair smelter;
    ForgePool pool0;
    ForgePool pool1;
    TestnetFeeRebate rebates;
    Flow flow;
    address operator = makeAddr("operator");
    address compounder = makeAddr("compounder");
    address deeds = makeAddr("deeds");

    function _rig(IFeeRebate rebateSource, address compounder_) internal {
        vm.warp(1_790_000_000);
        ember = new MockERC20("Ember", "EMBER");
        usdc = new MockDecimalsERC20("USD Coin", "USDC", 6);
        weth = new MockDecimalsERC20("Wrapped Ether", "WETH", 18);
        rebates = new TestnetFeeRebate(operator);
        uint64 n = vm.getNonce(address(this));
        address flowAt = vm.computeCreateAddress(address(this), n + 4);
        blast = new EmberPair("B", "B", IERC20(address(ember)), IERC20(address(usdc)), operator, flowAt, operator, operator);
        smelter = new EmberPair("S", "S", IERC20(address(ember)), IERC20(address(weth)), operator, flowAt, operator, operator);
        pool0 = new ForgePool(IERC20(address(blast)), true, operator, makeAddr("boost"), deeds, flowAt, address(0), address(0), address(0));
        pool1 = new ForgePool(IERC20(address(smelter)), true, operator, makeAddr("boost"), deeds, flowAt, address(0), address(0), address(0));
        IFeeRebate src = address(rebateSource) == address(1) ? IFeeRebate(address(rebates)) : rebateSource;
        flow = new Flow(IERC20(address(ember)), blast, smelter, pool0, pool1, src, compounder_);
        assertEq(address(flow), flowAt, "Flow at its predicted address");
        _seed(blast, 1_000_000 * E, 1_000_000 * U);
        _seed(smelter, 2_000_000 * E, 1_000 * E);
    }

    function _seed(EmberPair p, uint256 e, uint256 q) internal {
        _fund(operator, address(p));
        vm.prank(operator);
        p.addLiquidity(e, q, 0, 0, operator);
    }

    function _fund(address who, address spender) internal {
        ember.mint(who, 1e30);
        usdc.mint(who, 1e30);
        weth.mint(who, 1e30);
        vm.startPrank(who);
        ember.approve(spender, type(uint256).max);
        usdc.approve(spender, type(uint256).max);
        weth.approve(spender, type(uint256).max);
        blast.approve(spender, type(uint256).max);
        smelter.approve(spender, type(uint256).max);
        vm.stopPrank();
    }

    /// Flow must hold nothing between calls.
    function _flowEmpty() internal view {
        address f = address(flow);
        assertEq(ember.balanceOf(f), 0, "Flow holds no EMBER");
        assertEq(usdc.balanceOf(f), 0, "Flow holds no USDC");
        assertEq(weth.balanceOf(f), 0, "Flow holds no WETH");
        assertEq(blast.balanceOf(f), 0, "Flow holds no BlastPool LP");
        assertEq(smelter.balanceOf(f), 0, "Flow holds no SmelterPool LP");
        assertEq(ember.allowance(f, address(blast)) + usdc.allowance(f, address(blast)), 0, "no allowance left");
        assertEq(ember.allowance(f, address(smelter)) + weth.allowance(f, address(smelter)), 0, "no allowance left");
    }
}

/// @notice Flow (ADR 0016): routes, the rebate, the waiver, zaps, the pool's fee-free hooks, and an
///         exact replay of the BigInt model's zap scenarios (scripts/flow-model.ts).
contract FlowTest is FlowRig {
    address user = makeAddr("user");

    function setUp() public {
        _rig(IFeeRebate(address(1)), compounder);
        _fund(user, address(flow));
    }

    function _protocolFees(EmberPair p) internal view returns (uint256) {
        (uint256 b, uint256 l, uint256 y) = p.protocolFees();
        return b + l + y;
    }

    // ── construction ──────────────────────────────────────────────────────

    function test_constructionAndThePoolsFlowRule() public {
        vm.expectRevert(Flow.ZeroAddress.selector);
        new Flow(IERC20(address(0)), blast, smelter, pool0, pool1, rebates, compounder);
        vm.expectRevert(Flow.ZeroAddress.selector);
        new Flow(IERC20(address(ember)), blast, smelter, ForgePool(address(0)), pool1, rebates, compounder);
        // Only an LP pool may name a Flow: the exemption is for LP formation.
        vm.expectRevert(ForgePoolBase.FlowNeedsLp.selector);
        new ForgePool(IERC20(address(ember)), false, operator, makeAddr("boost"), deeds, address(flow), address(0), address(0), address(0));
        assertEq(pool0.FLOW(), address(flow));
    }

    // ── the rebate ────────────────────────────────────────────────────────

    function test_rebateSnapsDownToATier() public {
        uint256[7] memory pct = [uint256(0), 24, 25, 49, 50, 51, 100];
        uint256[7] memory share = [uint256(1e6), 1e6, 750_000, 750_000, 500_000, 500_000, 500_000];
        for (uint256 i; i < 7; ++i) {
            vm.prank(operator);
            rebates.setRebate(user, pct[i]);
            assertEq(flow.rebateShareOf(user), share[i]);
        }
    }

    function test_aBrokenRebateSourceGivesNoRebate() public {
        address[3] memory sources = [address(new RevertingRebate()), makeAddr("no code"), address(new MalformedRebate())];
        for (uint256 i; i < 3; ++i) {
            Flow f = new Flow(IERC20(address(ember)), blast, smelter, pool0, pool1, IFeeRebate(sources[i]), compounder);
            assertEq(f.rebateShareOf(user), 1e6, "full fee, and no revert");
        }
        Flow none = new Flow(IERC20(address(ember)), blast, smelter, pool0, pool1, IFeeRebate(address(0)), compounder);
        assertEq(none.rebateShareOf(user), 1e6);
    }

    function test_swapAtBedrockBooksHalfTheProtocolShare() public {
        vm.prank(operator);
        rebates.setRebate(user, 50);
        uint256 before = _protocolFees(blast);
        vm.prank(user);
        flow.swap(0, true, U, 0, user, block.timestamp);
        assertEq(_protocolFees(blast) - before, 250, "2.5 of the 5 bps protocol share on a 1 USDC buy");
        _flowEmpty();
    }

    // ── the waiver ────────────────────────────────────────────────────────

    function test_onlyTheCompounderSwapsWithTheWaiver() public {
        vm.prank(user);
        vm.expectRevert(Flow.NotCompounder.selector);
        flow.compoundSwap(0, false, E, 0, user, block.timestamp);
        _fund(compounder, address(flow));
        uint256 before = _protocolFees(blast);
        vm.prank(compounder);
        flow.compoundSwap(0, false, 1000 * E, 0, compounder, block.timestamp);
        assertEq(_protocolFees(blast), before, "no protocol share on a Compound");
        Flow noCompounder = new Flow(IERC20(address(ember)), blast, smelter, pool0, pool1, rebates, address(0));
        vm.prank(address(0));
        vm.expectRevert(Flow.NotCompounder.selector);
        noCompounder.compoundSwap(0, false, E, 0, user, block.timestamp);
        _flowEmpty();
    }

    // ── deadlines, minimums, pairs ────────────────────────────────────────

    function test_deadlinesMinimumsAndUnknownPairs() public {
        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(Flow.Expired.selector, block.timestamp - 1));
        flow.swap(0, true, U, 0, user, block.timestamp - 1);
        vm.expectRevert(abi.encodeWithSelector(Flow.UnknownPair.selector, 2));
        flow.swap(2, true, U, 0, user, block.timestamp);
        vm.expectPartialRevert(EmberPair.Slippage.selector);
        flow.swap(0, true, U, type(uint256).max, user, block.timestamp);
        vm.expectPartialRevert(Flow.Slippage.selector);
        flow.zapIn(0, true, 1000 * U, type(uint256).max, block.timestamp);
        uint256 l = flow.zapIn(0, true, 1000 * U, 0, block.timestamp);
        vm.expectPartialRevert(Flow.Slippage.selector);
        flow.zapOut(0, l, true, type(uint256).max, block.timestamp);
        vm.expectRevert(Flow.ZeroAmount.selector);
        flow.zapIn(0, true, 0, 0, block.timestamp);
        vm.stopPrank();
        _flowEmpty();
    }

    // ── zaps ──────────────────────────────────────────────────────────────

    function test_zapInBothSidesRefundsDustAndHoldsNothing() public {
        for (uint256 pair; pair < 2; ++pair) {
            for (uint256 side; side < 2; ++side) {
                bool fromQuote = side == 0;
                EmberPair p = pair == 0 ? blast : smelter;
                IERC20 tokenIn = fromQuote ? p.QUOTE() : IERC20(address(ember));
                uint256 amount = fromQuote ? (pair == 0 ? 5000 * U : 2 * E) : 10_000 * E;
                uint256 bal = tokenIn.balanceOf(user);
                uint256 lp0 = p.balanceOf(user);
                vm.prank(user);
                uint256 l = flow.zapIn(pair, fromQuote, amount, 0, block.timestamp);
                assertEq(p.balanceOf(user) - lp0, l, "the receipts go to the caller");
                uint256 spent = bal - tokenIn.balanceOf(user);
                assertLe(amount - spent, amount / 1e6 + 10, "only dust comes back");
                _flowEmpty();
            }
        }
    }

    function test_zapOutToEitherToken() public {
        vm.startPrank(user);
        uint256 l = flow.zapIn(0, true, 10_000 * U, 0, block.timestamp);
        uint256 q0 = usdc.balanceOf(user);
        uint256 out = flow.zapOut(0, l / 2, true, 0, block.timestamp);
        assertEq(usdc.balanceOf(user) - q0, out);
        assertApproxEqRel(out, 5000 * U, 0.01e18, "about half back, less fees and impact");
        uint256 e0 = ember.balanceOf(user);
        out = flow.zapOut(0, blast.balanceOf(user), false, 0, block.timestamp);
        assertEq(ember.balanceOf(user) - e0, out);
        vm.stopPrank();
        _flowEmpty();
    }

    // ── fee-free same-route staking ───────────────────────────────────────

    function test_zapAndStakeOpensAndAddsWithoutTheDepositFee() public {
        uint256[3] memory fees0 = [pool0.feesOwed(0), pool0.feesOwed(1), pool0.feesOwed(2)];
        vm.prank(user);
        (uint256 l, uint256 id) = flow.zapAndStake(0, true, 10_000 * U, 0, 0, block.timestamp);
        assertEq(pool0.positionOf(id).owner, user, "opened for the caller");
        assertEq(pool0.custodyOf(id), l, "every receipt staked: no 1% fee");
        assertEq(blast.balanceOf(address(pool0)), l);
        vm.prank(user);
        (uint256 l2, uint256 id2) = flow.zapAndStake(0, false, 5000 * E, 0, id, block.timestamp);
        assertEq(id2, id);
        assertEq(pool0.custodyOf(id), l + l2, "added to the same position, fee-free");
        for (uint256 k; k < 3; ++k) assertEq(pool0.feesOwed(k), fees0[k], "no fee booked");
        // A direct deposit of the same LP still pays 1%.
        vm.startPrank(user);
        uint256 own = flow.zapIn(0, true, 10_000 * U, 0, block.timestamp);
        blast.approve(address(pool0), own);
        pool0.deposit(id, own);
        vm.stopPrank();
        assertEq(pool0.feesOwed(0), own / 100, "the ordinary path keeps its fee");
        _flowEmpty();
    }

    function test_zapAndStakeRespectsOwnershipListingAndClosure() public {
        vm.prank(user);
        (, uint256 id) = flow.zapAndStake(1, true, E, 0, 0, block.timestamp);
        address other = makeAddr("other");
        _fund(other, address(flow));
        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.NotOwner.selector, id));
        flow.zapAndStake(1, true, E, 0, id, block.timestamp); // nobody adds to another's position
        vm.prank(deeds);
        pool1.list(id, user);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.Listed.selector, id));
        flow.zapAndStake(1, true, E, 0, id, block.timestamp);
        vm.prank(user);
        pool1.unlist(id);
        vm.prank(user);
        pool1.emergencyExit(id);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ForgePoolBase.Closed.selector, id));
        flow.zapAndStake(1, true, E, 0, id, block.timestamp);
        _flowEmpty();
    }

    function test_onlyFlowCallsThePoolsFeeFreeHooks() public {
        vm.startPrank(user);
        blast.approve(address(pool0), type(uint256).max);
        vm.expectRevert(ForgePoolBase.NotFlow.selector);
        pool0.openFor(user, 1e18);
        vm.expectRevert(ForgePoolBase.NotFlow.selector);
        pool0.depositFor(1, user, 1e18);
        vm.stopPrank();
        ForgePool noFlow = new ForgePool(IERC20(address(blast)), true, operator, makeAddr("boost"), deeds, address(0), address(0), address(0), address(0));
        vm.prank(address(0));
        vm.expectRevert(ForgePoolBase.NotFlow.selector);
        noFlow.openFor(user, 1e18);
    }

    // ── gas (pnpm gas, isolated) ──────────────────────────────────────────

    function test_gas_flowRoutes() public {
        vm.startPrank(user);
        uint256 g = gasleft();
        flow.swap(0, true, 100 * U, 0, user, block.timestamp);
        emit log_named_uint("swap (buy)", g - gasleft());
        g = gasleft();
        uint256 l = flow.zapIn(0, true, 1000 * U, 0, block.timestamp);
        emit log_named_uint("zapIn", g - gasleft());
        g = gasleft();
        (, uint256 id) = flow.zapAndStake(0, true, 1000 * U, 0, 0, block.timestamp);
        emit log_named_uint("zapAndStake, opening", g - gasleft());
        g = gasleft();
        flow.zapAndStake(0, false, 1000 * E, 0, id, block.timestamp);
        emit log_named_uint("zapAndStake, adding", g - gasleft());
        g = gasleft();
        flow.zapOut(0, l, true, 0, block.timestamp);
        emit log_named_uint("zapOut", g - gasleft());
        vm.stopPrank();
    }

    // ── the BigInt model's scenarios, replayed exactly ────────────────────

    function test_replaysTheModelExactly() public {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/contracts/test/fixtures/flow-vectors.json"));
        string[] memory tiers = vm.parseJsonStringArray(json, ".rebateTiers");
        assertEq(vm.parseUint(tiers[0]), P.FLOW_REBATE_TIER_0_PCT);
        assertEq(vm.parseUint(tiers[1]), P.FLOW_REBATE_TIER_1_PCT);
        uint256 n;
        for (; vm.keyExistsJson(json, string.concat(".scenarios[", vm.toString(n), "]")); ++n) {
            _replay(json, string.concat(".scenarios[", vm.toString(n), "]"));
        }
        assertEq(n, 4, "every scenario replayed");
    }

    struct Cols {
        uint256[] kind;
        bool[] fromQuote;
        string[] a;
        string[] share;
        string[] why;
        string[][4] out;
        string[][5] state;
    }

    struct Ctx {
        EmberPair p;
        MockDecimalsERC20 q;
        Flow f;
        address z;
        string base;
    }

    function _replay(string memory json, string memory base) internal {
        Ctx memory x = _scenarioRig(json, base);
        Cols memory c = _cols(json, base);
        for (uint256 i; i < c.kind.length; ++i) _replayStep(x, c, i);
    }

    /// A fresh BlastPool-shaped pair with the scenario's quote, behind its own Flow, seeded by
    /// the initializer; the zapper starts with no receipts.
    function _scenarioRig(string memory json, string memory base) internal returns (Ctx memory x) {
        x.base = base;
        x.q = new MockDecimalsERC20("Q", "Q", uint8(vm.parseJsonUint(json, string.concat(base, ".quoteDecimals"))));
        address flowAt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        x.p = new EmberPair("P", "P", IERC20(address(ember)), IERC20(address(x.q)), operator, flowAt, operator, operator);
        ForgePool pool = new ForgePool(IERC20(address(x.p)), true, operator, makeAddr("boost"), deeds, flowAt, address(0), address(0), address(0));
        x.f = new Flow(IERC20(address(ember)), x.p, smelter, pool, pool1, rebates, compounder);
        assertEq(address(x.f), flowAt);
        x.z = makeAddr(string.concat("zapper", base));
        address[3] memory who = [operator, x.z, compounder];
        for (uint256 k; k < 3; ++k) {
            ember.mint(who[k], 1e40);
            x.q.mint(who[k], 1e40);
            vm.startPrank(who[k]);
            ember.approve(address(x.p), type(uint256).max);
            x.q.approve(address(x.p), type(uint256).max);
            ember.approve(address(x.f), type(uint256).max);
            x.q.approve(address(x.f), type(uint256).max);
            x.p.approve(address(x.f), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(operator);
        x.p.addLiquidity(
            vm.parseUint(vm.parseJsonString(json, string.concat(base, ".seedEmber"))),
            vm.parseUint(vm.parseJsonString(json, string.concat(base, ".seedQuote"))),
            0,
            0,
            operator
        );
    }

    function _replayStep(Ctx memory x, Cols memory c, uint256 i) internal {
        uint256 share = vm.parseUint(c.share[i]);
        if (share != 0) {
            vm.prank(operator);
            rebates.setRebate(x.z, (1e6 - share) / 1e4);
        }
        uint256[2] memory b0 = [ember.balanceOf(x.z), x.q.balanceOf(x.z)];
        (bool ok, bytes memory ret) = _step(x.f, x.z, c.kind[i], c.fromQuote[i], vm.parseUint(c.a[i]), share);
        string memory at = string.concat(x.base, " step ", vm.toString(i));
        if (bytes(c.why[i]).length != 0) {
            assertFalse(ok, string.concat(at, ": expected ", c.why[i]));
            assertEq(bytes4(ret), bytes4(keccak256(bytes(string.concat(c.why[i], "()")))), at);
        } else {
            assertTrue(ok, at);
            _checkOut(c, i, ret, at);
            if (c.kind[i] == 0) _checkRefunds(c, i, b0, [ember.balanceOf(x.z), x.q.balanceOf(x.z)], at);
        }
        _checkState(x, c, i, at);
    }

    function _checkState(Ctx memory x, Cols memory c, uint256 i, string memory at) internal view {
        (uint112 rE, uint112 rQ,) = x.p.getReserves();
        (uint256 b, uint256 l, uint256 y) = x.p.protocolFees();
        uint256[5] memory got = [uint256(rE), rQ, x.p.totalSupply(), x.p.balanceOf(x.z), b + l + y];
        for (uint256 j; j < 5; ++j) assertEq(got[j], vm.parseUint(c.state[j][i]), at);
        address f = address(x.f);
        assertEq(ember.balanceOf(f) + x.q.balanceOf(f) + x.p.balanceOf(f), 0, "Flow empty");
    }

    function _cols(string memory json, string memory base) internal pure returns (Cols memory c) {
        c.kind = vm.parseJsonUintArray(json, string.concat(base, ".kind"));
        c.fromQuote = vm.parseJsonBoolArray(json, string.concat(base, ".fromQuote"));
        c.a = vm.parseJsonStringArray(json, string.concat(base, ".a"));
        c.share = vm.parseJsonStringArray(json, string.concat(base, ".share"));
        c.why = vm.parseJsonStringArray(json, string.concat(base, ".why"));
        string[4] memory outs = [".out0", ".out1", ".out2", ".out3"];
        for (uint256 j; j < 4; ++j) c.out[j] = vm.parseJsonStringArray(json, string.concat(base, outs[j]));
        string[5] memory keys = [".rE", ".rQ", ".supply", ".held", ".fees"];
        for (uint256 j; j < 5; ++j) c.state[j] = vm.parseJsonStringArray(json, string.concat(base, keys[j]));
    }

    function _step(Flow f, address z, uint256 kind, bool fromQuote, uint256 a, uint256 share)
        internal
        returns (bool ok, bytes memory ret)
    {
        if (kind == 0) {
            vm.prank(z);
            (ok, ret) = address(f).call(abi.encodeCall(Flow.zapIn, (0, fromQuote, a, 0, block.timestamp)));
        } else if (kind == 1) {
            vm.prank(z);
            (ok, ret) = address(f).call(abi.encodeCall(Flow.zapOut, (0, a, fromQuote, 0, block.timestamp)));
        } else if (share == 0) {
            vm.prank(compounder);
            (ok, ret) = address(f).call(abi.encodeCall(Flow.compoundSwap, (0, fromQuote, a, 0, z, block.timestamp)));
        } else {
            vm.prank(z);
            (ok, ret) = address(f).call(abi.encodeCall(Flow.swap, (0, fromQuote, a, 0, z, block.timestamp)));
        }
    }

    /// A zap returns its liquidity (the model's out1); an unzap or a swap its output (out0).
    function _checkOut(Cols memory c, uint256 i, bytes memory ret, string memory at) internal pure {
        if (c.kind[i] == 0) assertEq(abi.decode(ret, (uint256)), vm.parseUint(c.out[1][i]), at);
        else assertEq(abi.decode(ret, (uint256)), vm.parseUint(c.out[0][i]), at);
    }

    /// A zap's net effect on the zapper is exactly the model's: the input less its refund, and
    /// the other side's refund received. Those refunds pin the swapped amount too.
    function _checkRefunds(Cols memory c, uint256 i, uint256[2] memory b0, uint256[2] memory b1, string memory at)
        internal
        pure
    {
        uint256 a = vm.parseUint(c.a[i]);
        uint256 refundE = vm.parseUint(c.out[2][i]);
        uint256 refundQ = vm.parseUint(c.out[3][i]);
        if (c.fromQuote[i]) {
            assertEq(b0[1] - b1[1], a - refundQ, string.concat(at, ": quote spent"));
            assertEq(b1[0] - b0[0], refundE, string.concat(at, ": EMBER refunded"));
        } else {
            assertEq(b0[0] - b1[0], a - refundE, string.concat(at, ": EMBER spent"));
            assertEq(b1[1] - b0[1], refundQ, string.concat(at, ": quote refunded"));
        }
    }
}
