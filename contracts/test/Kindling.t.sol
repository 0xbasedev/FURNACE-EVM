// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {EmberPair} from "../src/pairs/EmberPair.sol";
import {GenesisFeeEscrow} from "../src/kindling/GenesisFeeEscrow.sol";
import {PermanentLiquidity} from "../src/kindling/PermanentLiquidity.sol";
import {Kindling, IKindlingMantle, IKindlingPair, IKindlingPool} from "../src/kindling/Kindling.sol";
import {MockBurnableERC20} from "./utils/VentMocks.sol";
import {
    MockQuote,
    MockFeeOnTransferQuote,
    MockCallbackQuote,
    MockKindlingMantle,
    MockKindlingPool,
    MockVenuePair,
    MockVenuePool
} from "./utils/KindlingMocks.sol";

/// @dev One Kindling event on a real EmberPair (BlastPool), a mock Mantle and a mock Forge pool 0.
abstract contract KindlingRig is Test {
    uint256 internal constant WALLETS = 8;
    uint256 internal constant FUNDING = 40_000e6;
    uint256 internal constant T0 = 1_800_000_000;

    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");
    address internal vent = makeAddr("vent");
    address internal guardian = makeAddr("guardian");

    struct World {
        MockQuote usdc;
        MockBurnableERC20 ember;
        PermanentLiquidity sink;
        GenesisFeeEscrow escrow;
        Kindling k;
        MockKindlingMantle mantle;
        EmberPair pair;
        MockKindlingPool pool;
    }

    function _wallet(uint256 i) internal returns (address) {
        return makeAddr(string.concat("contributor", vm.toString(i)));
    }

    /// @dev A world on a 6-decimal USDC that starts at `start`.
    function _world(uint256 start) internal returns (World memory w) {
        return _worldWith(new MockQuote("USD Coin", "USDC", 6), start, P.EMBER_KINDLING_SEED, true);
    }

    /// @dev `seed` is what the Mantle mints; `mantleNamesEvent` false gives a Mantle naming another
    ///      KINDLING. Every address is predicted, as the kit's CREATE3 deployment does.
    function _worldWith(MockQuote usdc, uint256 start, uint256 seed, bool mantleNamesEvent)
        internal
        returns (World memory w)
    {
        w.usdc = usdc;
        w.ember = new MockBurnableERC20("Ember", "EMBER");
        w.sink = new PermanentLiquidity();
        uint256 n = vm.getNonce(address(this));
        address kAt = vm.computeCreateAddress(address(this), n + 1);
        address mantleAt = vm.computeCreateAddress(address(this), n + 2);
        address pairAt = vm.computeCreateAddress(address(this), n + 3);
        address poolAt = vm.computeCreateAddress(address(this), n + 4);
        w.escrow = new GenesisFeeEscrow(IERC20(address(usdc)), kAt, treasury);
        w.k = new Kindling(
            IERC20(address(usdc)),
            IERC20(address(w.ember)),
            IKindlingMantle(mantleAt),
            IKindlingPair(pairAt),
            IKindlingPool(poolAt),
            w.escrow,
            address(w.sink),
            start
        );
        w.mantle = new MockKindlingMantle(w.ember, mantleNamesEvent ? address(w.k) : stranger, seed);
        w.pair = new EmberPair(
            "Blast", "BLAST", IERC20(address(w.ember)), IERC20(address(usdc)), vent, address(0), guardian, address(w.k)
        );
        w.pool = new MockKindlingPool(IERC20(address(w.pair)), address(w.k));
        assertEq(address(w.k), kAt, "kindling predicted");
        assertEq(address(w.mantle), mantleAt, "mantle predicted");
        assertEq(address(w.pair), pairAt, "pair predicted");
        assertEq(address(w.pool), poolAt, "pool predicted");
        for (uint256 i; i < WALLETS; ++i) _fund(w, _wallet(i), FUNDING);
    }

    function _fund(World memory w, address who, uint256 amount) internal {
        w.usdc.mint(who, amount);
        vm.prank(who);
        w.usdc.approve(address(w.k), type(uint256).max);
    }

    function _contribute(World memory w, address who, uint256 gross) internal {
        vm.prank(who);
        w.k.contribute(gross);
    }

    /// @dev Contribute `count` wallets of `each` from a fresh set, funded on the way.
    function _crowd(World memory w, string memory tag, uint256 count, uint256 each) internal {
        for (uint256 i; i < count; ++i) {
            address who = makeAddr(string.concat(tag, vm.toString(i)));
            _fund(w, who, each);
            _contribute(w, who, each);
        }
    }
}

contract KindlingTest is KindlingRig {
    // ── the BigInt model's scenarios, replayed exactly ────────────────────

    function test_replaysTheModelExactly() public {
        string memory json =
            vm.readFile(string.concat(vm.projectRoot(), "/contracts/test/fixtures/kindling-vectors.json"));
        assertEq(vm.parseUint(vm.parseJsonString(json, ".seed")), P.EMBER_KINDLING_SEED, "vectors from this config");
        assertEq(vm.parseUint(vm.parseJsonString(json, ".feeBps")), P.KINDLING_FEE_BPS, "vectors from this config");
        uint256 n;
        for (; vm.keyExistsJson(json, string.concat(".scenarios[", vm.toString(n), "]")); ++n) {
            _replay(json, string.concat(".scenarios[", vm.toString(n), "]"));
        }
        assertEq(n, 15, "every scenario replayed");
    }

    struct Cols {
        uint256[] kind;
        string[] a;
        string[] b;
        string[] why;
        string[] out0;
        string[] out1;
        string[] hash;
    }

    function _replay(string memory json, string memory base) internal {
        uint256 start = vm.parseUint(vm.parseJsonString(json, string.concat(base, ".start")));
        vm.warp(start - 3600);
        World memory w = _world(start);
        Cols memory c;
        c.kind = vm.parseJsonUintArray(json, string.concat(base, ".kind"));
        c.a = vm.parseJsonStringArray(json, string.concat(base, ".a"));
        c.b = vm.parseJsonStringArray(json, string.concat(base, ".b"));
        c.why = vm.parseJsonStringArray(json, string.concat(base, ".why"));
        c.out0 = vm.parseJsonStringArray(json, string.concat(base, ".out0"));
        c.out1 = vm.parseJsonStringArray(json, string.concat(base, ".out1"));
        c.hash = vm.parseJsonStringArray(json, string.concat(base, ".hash"));
        string memory name = vm.parseJsonString(json, string.concat(base, ".name"));
        for (uint256 i; i < c.kind.length; ++i) {
            string memory at = string.concat(name, " step ", vm.toString(i));
            (bool ok, uint256[2] memory out, bytes memory ret) =
                _act(w, c.kind[i], vm.parseUint(c.a[i]), vm.parseUint(c.b[i]));
            if (bytes(c.why[i]).length != 0) {
                assertFalse(ok, string.concat(at, ": expected ", c.why[i]));
                assertEq(bytes4(ret), bytes4(keccak256(bytes(string.concat(c.why[i], _args(c.why[i]))))), at);
            } else {
                if (!ok) emit log_named_bytes("revert", ret);
                assertTrue(ok, string.concat(at, ": reverted"));
                assertEq(out[0], vm.parseUint(c.out0[i]), string.concat(at, ": output 0"));
                assertEq(out[1], vm.parseUint(c.out1[i]), string.concat(at, ": output 1"));
            }
            assertEq(keccak256(abi.encodePacked(_words(w))), vm.parseBytes32(c.hash[i]), string.concat(at, ": state"));
        }
    }

    function _args(string memory why) internal pure returns (string memory) {
        bytes32 h = keccak256(bytes(why));
        if (h == keccak256("NotLive")) return "(uint8)";
        if (h == keccak256("NothingOwed")) return "(address)";
        if (h == keccak256("BelowMinimum")) return "(uint256)";
        if (
            h == keccak256("BelowMinimumContribution") || h == keccak256("WalletCap") || h == keccak256("RaiseCap")
                || h == keccak256("BadCancel") || h == keccak256("BelowMinimumRaise")
        ) return "(uint256,uint256)";
        return "()";
    }

    /// @dev One model action: 0 warp, 1 contribute, 2 cancel, 3 settle, 4 fail, 5 refund,
    ///      6 materialize, 7 materializeMany (a wallet bitmask), 8 donate.
    function _act(World memory w, uint256 kind, uint256 a, uint256 b)
        internal
        returns (bool ok, uint256[2] memory out, bytes memory ret)
    {
        ok = true;
        if (kind == 0) {
            vm.warp(block.timestamp + a);
        } else if (kind == 1) {
            vm.prank(_wallet(a));
            (ok, ret) = address(w.k).call(abi.encodeCall(Kindling.contribute, (b)));
            if (ok) (out[0], out[1]) = abi.decode(ret, (uint256, uint256));
        } else if (kind == 2) {
            vm.prank(_wallet(a));
            (ok, ret) = address(w.k).call(abi.encodeCall(Kindling.cancel, (b)));
            if (ok) out[0] = abi.decode(ret, (uint256));
        } else if (kind == 3) {
            vm.prank(keeper);
            (ok, ret) = address(w.k).call(abi.encodeCall(Kindling.settle, ()));
            if (ok) out[0] = abi.decode(ret, (uint256));
        } else if (kind == 4) {
            vm.prank(keeper);
            (ok, ret) = address(w.k).call(abi.encodeCall(Kindling.fail, ()));
            if (ok) out[0] = abi.decode(ret, (uint256));
        } else if (kind == 5) {
            vm.prank(keeper);
            (ok, ret) = address(w.k).call(abi.encodeCall(Kindling.refund, (_wallet(a))));
            if (ok) out[0] = abi.decode(ret, (uint256));
        } else if (kind == 6) {
            vm.prank(keeper);
            (ok, ret) = address(w.k).call(abi.encodeCall(Kindling.materialize, (_wallet(a))));
            if (ok) out[0] = abi.decode(ret, (uint256));
        } else if (kind == 7) {
            uint256 count;
            for (uint256 i; i < WALLETS; ++i) if ((a >> i) & 1 == 1) ++count;
            address[] memory page = new address[](count);
            count = 0;
            for (uint256 i; i < WALLETS; ++i) if ((a >> i) & 1 == 1) page[count++] = _wallet(i);
            vm.prank(keeper);
            (ok, ret) = address(w.k).call(abi.encodeCall(Kindling.materializeMany, (page)));
            if (ok) out[0] = abi.decode(ret, (uint256));
        } else {
            if (a == 0) w.usdc.mint(address(w.escrow), b);
            else if (a == 1) w.usdc.mint(address(w.k), b);
            else if (a == 2) w.ember.mint(address(w.k), b);
            else if (a == 3) w.usdc.mint(address(w.pair), b);
            else w.ember.mint(address(w.pair), b);
        }
    }

    /// @dev The model's `words()`, in its exact order.
    function _words(World memory w) internal returns (uint256[] memory x) {
        x = new uint256[](102);
        Kindling k = w.k;
        x[0] = uint256(k.status());
        x[1] = k.accepted();
        x[2] = k.totalNet();
        x[3] = k.totalFees();
        x[4] = k.closedAt();
        x[5] = k.liquidity();
        x[6] = k.contributorLp();
        x[7] = k.lpPaid();
        x[8] = k.netMaterialized();
        x[9] = uint256(w.escrow.state());
        x[10] = w.escrow.principal();
        x[11] = w.escrow.fees();
        x[12] = w.escrow.feesReleased() ? 1 : 0;
        x[13] = w.usdc.balanceOf(address(w.escrow));
        uint256 n = 14;
        for (uint256 i; i < WALLETS; ++i) n = _walletWords(w, _wallet(i), x, n);
        x[n++] = w.usdc.balanceOf(address(k));
        x[n++] = w.ember.balanceOf(address(k));
        x[n++] = w.pair.balanceOf(address(k));
        (uint112 rE, uint112 rQ,) = w.pair.getReserves();
        x[n++] = rE;
        x[n++] = rQ;
        x[n++] = w.pair.totalSupply();
        x[n++] = w.pair.balanceOf(P.BURN_ADDRESS);
        x[n++] = w.usdc.balanceOf(address(w.pair)) - rQ;
        x[n++] = w.ember.balanceOf(address(w.pair)) - rE;
        x[n++] = w.pair.balanceOf(address(w.sink));
        x[n++] = w.usdc.balanceOf(treasury);
        x[n++] = w.usdc.balanceOf(keeper);
        x[n++] = w.mantle.seedMinted() ? 1 : 0;
        x[n++] = w.pair.balanceOf(address(w.pool));
        x[n++] = w.pool.feesBooked();
        x[n++] = w.pool.positionCount();
        assertEq(n, 102, "words");
    }

    function _walletWords(World memory w, address who, uint256[] memory x, uint256 n) internal view returns (uint256) {
        (uint128 gross, uint128 net, uint128 fee, bool done) = w.k.contributions(who);
        x[n++] = gross;
        x[n++] = net;
        x[n++] = fee;
        x[n++] = done ? 1 : 0;
        x[n++] = w.usdc.balanceOf(who);
        x[n++] = w.pool.stakedOf(who);
        x[n++] = w.pair.balanceOf(who);
        x[n++] = w.k.entitlementOf(who);
        x[n++] = w.k.refundableOf(who);
        return n;
    }

    // ── construction ──────────────────────────────────────────────────────

    function test_constructorRefusesZeroAddressesAndAMismatchedEscrow() public {
        MockQuote usdc = new MockQuote("USD Coin", "USDC", 6);
        IERC20 q = IERC20(address(usdc));
        address kAt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        GenesisFeeEscrow escrow = new GenesisFeeEscrow(q, kAt, treasury);
        address s = address(new PermanentLiquidity());
        address any = makeAddr("any");
        // The escrow names the address the next deployment would take, so only zero inputs fail.
        vm.expectRevert(Kindling.ZeroAddress.selector);
        new Kindling(IERC20(address(0)), q, IKindlingMantle(any), IKindlingPair(any), IKindlingPool(any), escrow, s, T0);
        vm.expectRevert(Kindling.ZeroAddress.selector);
        new Kindling(q, q, IKindlingMantle(any), IKindlingPair(any), IKindlingPool(any), escrow, address(0), T0);
        vm.expectRevert(Kindling.ZeroAddress.selector);
        new Kindling(q, q, IKindlingMantle(any), IKindlingPair(any), IKindlingPool(any), escrow, s, 0);
        // An escrow for another event, or another asset.
        GenesisFeeEscrow other = new GenesisFeeEscrow(q, stranger, treasury);
        vm.expectRevert(Kindling.EscrowMismatch.selector);
        new Kindling(q, q, IKindlingMantle(any), IKindlingPair(any), IKindlingPool(any), other, s, T0);
        MockQuote dai = new MockQuote("Dai", "DAI", 18);
        kAt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        GenesisFeeEscrow wrongAsset = new GenesisFeeEscrow(IERC20(address(dai)), kAt, treasury);
        vm.expectRevert(Kindling.EscrowMismatch.selector);
        new Kindling(q, q, IKindlingMantle(any), IKindlingPair(any), IKindlingPool(any), wrongAsset, s, T0);
        // The escrow refuses zero addresses too.
        vm.expectRevert(GenesisFeeEscrow.ZeroAddress.selector);
        new GenesisFeeEscrow(q, address(0), treasury);
        vm.expectRevert(GenesisFeeEscrow.ZeroAddress.selector);
        new GenesisFeeEscrow(q, stranger, address(0));
    }

    function test_theLimitsScaleWithTheQuoteDecimals() public {
        World memory w = _world(T0);
        assertEq(w.k.END(), T0 + 24 hours, "24 h");
        assertEq(w.k.SETTLE_DEADLINE(), T0 + 24 hours + 72 hours, "72 h after the deadline");
        assertEq(w.k.MIN_CONTRIBUTION(), 1e6);
        assertEq(w.k.WALLET_CAP(), 25_000e6);
        assertEq(w.k.MIN_RAISE(), 100_000e6);
        assertEq(w.k.MAX_RAISE(), 5_000_000e6);
        World memory d = _worldWith(new MockQuote("Dai", "DAI", 18), T0, P.EMBER_KINDLING_SEED, true);
        assertEq(d.k.WALLET_CAP(), 25_000e18);
        assertEq(d.k.MAX_RAISE(), 5_000_000e18);
        MockQuote odd = new MockQuote("Odd", "ODD", 19);
        address kAt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        GenesisFeeEscrow escrow = new GenesisFeeEscrow(IERC20(address(odd)), kAt, treasury);
        address any = makeAddr("any");
        vm.expectRevert(abi.encodeWithSelector(Kindling.QuoteDecimals.selector, uint8(19)));
        new Kindling(
            IERC20(address(odd)),
            IERC20(any),
            IKindlingMantle(any),
            IKindlingPair(any),
            IKindlingPool(any),
            escrow,
            any,
            T0
        );
    }

    // ── the escrow on its own ─────────────────────────────────────────────

    function test_onlyTheEventMovesTheEscrow() public {
        MockQuote usdc = new MockQuote("USD Coin", "USDC", 6);
        GenesisFeeEscrow e = new GenesisFeeEscrow(IERC20(address(usdc)), address(this), treasury);
        vm.startPrank(stranger);
        vm.expectRevert(GenesisFeeEscrow.NotEvent.selector);
        e.book(1, 1);
        vm.expectRevert(GenesisFeeEscrow.NotEvent.selector);
        e.returnPrincipal(stranger, 0);
        vm.expectRevert(GenesisFeeEscrow.NotEvent.selector);
        e.fundLiquidity();
        vm.expectRevert(GenesisFeeEscrow.NotEvent.selector);
        e.releaseFees(stranger, 0);
        vm.expectRevert(GenesisFeeEscrow.NotEvent.selector);
        e.fail();
        vm.expectRevert(GenesisFeeEscrow.NotEvent.selector);
        e.refund(stranger, 0, 0);
        vm.stopPrank();
    }

    function test_theEscrowsLedgersCapEveryOutflow() public {
        MockQuote usdc = new MockQuote("USD Coin", "USDC", 6);
        GenesisFeeEscrow e = new GenesisFeeEscrow(IERC20(address(usdc)), address(this), treasury);
        usdc.mint(address(e), 10_000e6 + 777); // 777 is a donation: nobody's liability
        e.book(9_700e6, 300e6);
        // Refunds and fee releases are not possible while Open.
        vm.expectRevert(abi.encodeWithSelector(GenesisFeeEscrow.WrongState.selector, GenesisFeeEscrow.State.Open));
        e.refund(stranger, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(GenesisFeeEscrow.WrongState.selector, GenesisFeeEscrow.State.Open));
        e.releaseFees(stranger, 0);
        vm.expectRevert(abi.encodeWithSelector(GenesisFeeEscrow.ExceedsLiability.selector, 9_700e6 + 1, 9_700e6));
        e.returnPrincipal(stranger, 9_700e6 + 1);
        e.returnPrincipal(stranger, 4_000e6);
        e.fail();
        // Failed: nothing books, funds or fails again; refunds are capped by each ledger.
        vm.expectRevert(abi.encodeWithSelector(GenesisFeeEscrow.WrongState.selector, GenesisFeeEscrow.State.Failed));
        e.book(1, 1);
        vm.expectRevert(abi.encodeWithSelector(GenesisFeeEscrow.WrongState.selector, GenesisFeeEscrow.State.Failed));
        e.fundLiquidity();
        vm.expectRevert(abi.encodeWithSelector(GenesisFeeEscrow.WrongState.selector, GenesisFeeEscrow.State.Failed));
        e.fail();
        vm.expectRevert(abi.encodeWithSelector(GenesisFeeEscrow.WrongState.selector, GenesisFeeEscrow.State.Failed));
        e.returnPrincipal(stranger, 1);
        vm.expectRevert(abi.encodeWithSelector(GenesisFeeEscrow.ExceedsLiability.selector, 5_700e6 + 1, 5_700e6));
        e.refund(stranger, 5_700e6 + 1, 0);
        vm.expectRevert(abi.encodeWithSelector(GenesisFeeEscrow.ExceedsLiability.selector, 300e6 + 1, 300e6));
        e.refund(stranger, 0, 300e6 + 1);
        e.refund(stranger, 5_700e6, 300e6);
        assertEq(usdc.balanceOf(stranger), 10_000e6, "every unit back, nothing twice");
        assertEq(usdc.balanceOf(address(e)), 777, "the donation stays");
        assertEq(usdc.balanceOf(treasury), 0, "the Treasury never touches refund backing");

        GenesisFeeEscrow s = new GenesisFeeEscrow(IERC20(address(usdc)), address(this), treasury);
        usdc.mint(address(s), 1_000e6);
        s.book(970e6, 30e6);
        vm.expectRevert(abi.encodeWithSelector(GenesisFeeEscrow.WrongState.selector, GenesisFeeEscrow.State.Open));
        s.releaseFees(keeper, 1);
        assertEq(s.fundLiquidity(), 970e6);
        vm.expectRevert(abi.encodeWithSelector(GenesisFeeEscrow.WrongState.selector, GenesisFeeEscrow.State.Settled));
        s.fail();
        vm.expectRevert(abi.encodeWithSelector(GenesisFeeEscrow.WrongState.selector, GenesisFeeEscrow.State.Settled));
        s.refund(stranger, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(GenesisFeeEscrow.ExceedsLiability.selector, 30e6 + 1, 30e6));
        s.releaseFees(keeper, 30e6 + 1);
        assertEq(s.releaseFees(keeper, 1e6), 29e6);
        vm.expectRevert(GenesisFeeEscrow.AlreadyReleased.selector);
        s.releaseFees(keeper, 0);
        assertEq(usdc.balanceOf(treasury), 29e6);
        assertEq(usdc.balanceOf(keeper), 1e6);
        assertEq(usdc.balanceOf(address(s)), 0);
    }

    // ── assets and callbacks ──────────────────────────────────────────────

    function test_aFeeOnTransferQuoteIsRefused() public {
        vm.warp(T0);
        World memory w = _worldWith(new MockFeeOnTransferQuote(), T0, P.EMBER_KINDLING_SEED, true);
        vm.prank(_wallet(0));
        vm.expectRevert(Kindling.NonStandardToken.selector);
        w.k.contribute(1_000e6);
    }

    function test_aCallbackCannotReenterOrEndTheEvent() public {
        vm.warp(T0);
        MockCallbackQuote hook = new MockCallbackQuote();
        World memory w = _worldWith(hook, T0, P.EMBER_KINDLING_SEED, true);
        _contribute(w, _wallet(0), 1_000e6);
        // During a contribution's pull, a hook tries to cancel: the guard refuses it.
        hook.arm(address(w.k), abi.encodeCall(Kindling.cancel, (1e6)));
        _contribute(w, _wallet(1), 1_000e6);
        assertFalse(hook.lastOk(), "no reentry");
        assertEq(bytes4(hook.lastRet()), ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        _crowd(w, "crowd", 4, 25_000e6);
        vm.warp(T0 + 1 days);
        // During settlement's pull into the pair, a hook tries to fail the event: it is already settled.
        hook.arm(address(w.k), abi.encodeCall(Kindling.fail, ()));
        vm.prank(keeper);
        w.k.settle();
        assertFalse(hook.lastOk(), "settlement cannot be failed from inside");
        assertEq(bytes4(hook.lastRet()), Kindling.NotLive.selector);
        assertEq(uint256(w.k.status()), uint256(Kindling.Status.Settled));
    }

    // ── the limits ────────────────────────────────────────────────────────

    function test_theMaximumRaiseIsExactAndEveryEntitlementClearsThePoolMinimum() public {
        vm.warp(T0);
        World memory w = _world(T0);
        _crowd(w, "whale", 199, 25_000e6);
        _contribute(w, _wallet(0), 24_999e6);
        _contribute(w, _wallet(1), 1e6);
        assertEq(w.k.accepted(), 5_000_000e6, "exactly the maximum");
        vm.prank(_wallet(2));
        vm.expectRevert(abi.encodeWithSelector(Kindling.RaiseCap.selector, 5_000_001e6, 5_000_000e6));
        w.k.contribute(1e6);
        vm.warp(T0 + 1 days);
        vm.prank(keeper);
        w.k.settle();
        assertEq(w.usdc.balanceOf(keeper), 2_500e6, "5 bps of $5M");
        assertEq(w.usdc.balanceOf(treasury), 150_000e6 - 2_500e6, "the rest of the fees");
        // The smallest possible entitlement in the largest raise still opens a position.
        vm.prank(keeper);
        uint256 id = w.k.materialize(_wallet(1));
        assertEq(w.pool.ownerOf(id), _wallet(1));
        assertGe(w.pool.stakedOf(_wallet(1)), P.MIN_STAKE_LP, "clears the pool minimum");
    }

    // ── the venue ─────────────────────────────────────────────────────────

    function test_anUnsafeVenueRefusesSettlementAndTheEventStillRefunds() public {
        vm.warp(T0);
        MockQuote usdc = new MockQuote("USD Coin", "USDC", 6);
        MockBurnableERC20 ember = new MockBurnableERC20("Ember", "EMBER");
        address sink = address(new PermanentLiquidity());
        uint256 n = vm.getNonce(address(this));
        address kAt = vm.computeCreateAddress(address(this), n + 3);
        MockVenuePair vp = new MockVenuePair(IERC20(address(ember)), IERC20(address(usdc)), kAt);
        MockVenuePool vpool = new MockVenuePool(IERC20(address(vp)), kAt);
        GenesisFeeEscrow escrow = new GenesisFeeEscrow(IERC20(address(usdc)), kAt, treasury);
        Kindling k = new Kindling(
            IERC20(address(usdc)),
            IERC20(address(ember)),
            IKindlingMantle(makeAddr("mantle")),
            IKindlingPair(address(vp)),
            IKindlingPool(address(vpool)),
            escrow,
            sink,
            T0
        );
        assertEq(address(k), kAt);
        assertEq(uint256(k.venueCheck()), uint256(Kindling.Venue.None));
        // Every way the venue can be wrong, each reported by name.
        vp.wire(IERC20(address(usdc)), IERC20(address(usdc)), kAt);
        assertEq(uint256(k.venueCheck()), uint256(Kindling.Venue.PairWiring), "EMBER");
        vp.wire(IERC20(address(ember)), IERC20(address(ember)), kAt);
        assertEq(uint256(k.venueCheck()), uint256(Kindling.Venue.PairWiring), "quote");
        vp.wire(IERC20(address(ember)), IERC20(address(usdc)), stranger);
        assertEq(uint256(k.venueCheck()), uint256(Kindling.Venue.PairWiring), "initializer");
        vp.wire(IERC20(address(ember)), IERC20(address(usdc)), kAt);
        vp.set(1, 0, 0);
        assertEq(uint256(k.venueCheck()), uint256(Kindling.Venue.PairInitialized), "supply");
        vp.set(0, 1, 0);
        assertEq(uint256(k.venueCheck()), uint256(Kindling.Venue.PairInitialized), "EMBER reserve");
        vp.set(0, 0, 1);
        assertEq(uint256(k.venueCheck()), uint256(Kindling.Venue.PairInitialized), "quote reserve");
        vp.set(0, 0, 0);
        vpool.wire(IERC20(address(usdc)), kAt);
        assertEq(uint256(k.venueCheck()), uint256(Kindling.Venue.PoolWiring), "stake token");
        vpool.wire(IERC20(address(vp)), stranger);
        assertEq(uint256(k.venueCheck()), uint256(Kindling.Venue.PoolWiring), "pool's KINDLING");
        // A funded event whose pair is already initialized cannot settle; time alone never makes
        // it look settled, and after 72 h it refunds in full.
        vp.set(1, 0, 0);
        for (uint256 i; i < 4; ++i) {
            address who = _wallet(i);
            usdc.mint(who, 25_000e6);
            vm.startPrank(who);
            usdc.approve(address(k), type(uint256).max);
            k.contribute(25_000e6);
            vm.stopPrank();
        }
        vm.warp(T0 + 1 days);
        vm.expectRevert(abi.encodeWithSelector(Kindling.UnsafeVenue.selector, Kindling.Venue.PairInitialized));
        k.settle();
        vm.expectRevert(Kindling.StillSettleable.selector);
        k.fail();
        vm.warp(T0 + 4 days);
        vm.expectRevert(Kindling.SettlementExpired.selector);
        k.settle();
        assertEq(uint256(k.fail()), uint256(Kindling.Failure.Timeout));
        for (uint256 i; i < 4; ++i) assertEq(k.refund(_wallet(i)), 25_000e6, "gross back in full");
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(treasury), 0);
        // A pair or pool with no code at all.
        Kindling bare = _bareEvent(usdc, ember, makeAddr("noPair"), address(vpool));
        assertEq(uint256(bare.venueCheck()), uint256(Kindling.Venue.PairMissing));
        bare = _bareEvent(usdc, ember, address(vp), makeAddr("noPool"));
        vp.set(0, 0, 0);
        vp.wire(IERC20(address(ember)), IERC20(address(usdc)), address(bare));
        assertEq(uint256(bare.venueCheck()), uint256(Kindling.Venue.PoolWiring));
    }

    function _bareEvent(MockQuote usdc, MockBurnableERC20 ember, address pair, address pool)
        internal
        returns (Kindling k)
    {
        address kAt = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        GenesisFeeEscrow escrow = new GenesisFeeEscrow(IERC20(address(usdc)), kAt, treasury);
        k = new Kindling(
            IERC20(address(usdc)),
            IERC20(address(ember)),
            IKindlingMantle(makeAddr("mantle")),
            IKindlingPair(pair),
            IKindlingPool(pool),
            escrow,
            makeAddr("sink"),
            T0
        );
    }

    // ── the seed ──────────────────────────────────────────────────────────

    function test_aWrongSeedOrARefusingMantleRevertsTheWholeSettlement() public {
        vm.warp(T0);
        World memory w = _worldWith(new MockQuote("USD Coin", "USDC", 6), T0, P.EMBER_KINDLING_SEED - 1, true);
        _crowd(w, "crowd", 4, 25_000e6);
        vm.warp(T0 + 1 days);
        vm.expectRevert(abi.encodeWithSelector(Kindling.SeedMismatch.selector, P.EMBER_KINDLING_SEED - 1));
        w.k.settle();
        assertEq(uint256(w.k.status()), uint256(Kindling.Status.Live), "nothing changed");
        assertEq(w.escrow.principal(), 97_000e6);
        assertEq(w.pair.totalSupply(), 0);

        World memory r =
            _worldWith(new MockQuote("USD Coin", "USDC", 6), T0 + 1 days, P.EMBER_KINDLING_SEED, false);
        _crowd(r, "crowd", 4, 25_000e6);
        vm.warp(T0 + 2 days);
        vm.expectRevert(MockKindlingMantle.NotKindling.selector);
        r.k.settle();
        vm.warp(T0 + 5 days);
        assertEq(uint256(r.k.fail()), uint256(Kindling.Failure.Timeout));
        assertEq(r.k.refund(makeAddr("crowd0")), 25_000e6);
    }

    // ── the opening ───────────────────────────────────────────────────────

    /// @dev Spec v5.5 §3: "A $100 gross contribution leaves $97 of net quote. A 90% contributor LP
    ///      share corresponds approximately to $87.30 of quote-side reserves plus its token-side
    ///      claim. Marking that token claim at the opening ratio produces a combined $174.60."
    function test_theOpeningMatchesTheSpecsExample() public {
        vm.warp(T0);
        World memory w = _world(T0);
        _contribute(w, _wallet(0), 100e6);
        _crowd(w, "crowd", 4, 25_000e6);
        vm.warp(T0 + 1 days);
        vm.prank(keeper);
        uint256 minted = w.k.settle();
        (uint112 rE, uint112 rQ,) = w.pair.getReserves();
        assertEq(rE, P.EMBER_KINDLING_SEED, "the seed, all of it");
        assertEq(rQ, w.k.totalNet(), "the net raise, all of it");
        assertEq(w.pair.balanceOf(P.BURN_ADDRESS), 1000, "the minimum liquidity, accounted for separately");
        assertEq(w.k.contributorLp(), (minted * 90) / 100);
        assertEq(w.pair.balanceOf(address(w.sink)), minted - (minted * 90) / 100, "10% to the sink");
        uint256 lp = w.k.entitlementOf(_wallet(0));
        uint256 supply = w.pair.totalSupply();
        uint256 quoteSide = (lp * rQ) / supply;
        uint256 emberSide = (lp * rE) / supply;
        assertApproxEqAbs(quoteSide, 87_300_000, 2, "$87.30 of quote-side reserves");
        assertApproxEqAbs((emberSide * rQ) / rE, 87_300_000, 2, "its token claim, at the opening ratio");
    }

    function test_refundPaysTheWalletNotTheCaller() public {
        vm.warp(T0);
        World memory w = _world(T0);
        _contribute(w, _wallet(0), 10_000e6);
        vm.warp(T0 + 1 days);
        w.k.fail();
        vm.prank(stranger);
        assertEq(w.k.refund(_wallet(0)), 10_000e6);
        assertEq(w.usdc.balanceOf(_wallet(0)), FUNDING);
        assertEq(w.usdc.balanceOf(stranger), 0);
    }

    // ── the sink ──────────────────────────────────────────────────────────

    /// @dev The sink's runtime has no opcode that could move value out or change code: no CALL,
    ///      CALLCODE, DELEGATECALL, CREATE, CREATE2, SELFDESTRUCT, and no SSTORE either. Its one
    ///      external read is a STATICCALL. It refuses native currency.
    function test_theSinkHasNoWayOut() public {
        PermanentLiquidity sink = new PermanentLiquidity();
        bytes memory code = address(sink).code;
        uint256 end = code.length;
        // Skip the CBOR metadata, whose length is its last two bytes (if the compiler appended it).
        uint256 meta = (uint256(uint8(code[end - 2])) << 8) | uint8(code[end - 1]);
        if (meta + 2 < end) {
            uint8 head = uint8(code[end - meta - 2]);
            if (head == 0xa1 || head == 0xa2) end -= meta + 2;
        }
        bool staticCall;
        for (uint256 i; i < end; ++i) {
            uint8 op = uint8(code[i]);
            assertTrue(
                op != 0xf0 && op != 0xf1 && op != 0xf2 && op != 0xf4 && op != 0xf5 && op != 0xff && op != 0x55,
                string.concat("forbidden opcode at ", vm.toString(i))
            );
            if (op == 0xfa) staticCall = true;
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f; // PUSH data
        }
        assertTrue(staticCall, "the scan read real code");
        (bool ok,) = address(sink).call{value: 1}("");
        assertFalse(ok, "no native currency");
        MockQuote lp = new MockQuote("LP", "LP", 18);
        lp.mint(address(sink), 5e18);
        assertEq(sink.held(IERC20(address(lp))), 5e18);
    }

    // ── gas (pnpm gas, isolated) ──────────────────────────────────────────

    function test_gas_kindling() public {
        vm.warp(T0);
        World memory w = _world(T0);
        _crowd(w, "crowd", 3, 25_000e6);
        uint256 g = gasleft();
        _contribute(w, _wallet(0), 25_000e6);
        emit log_named_uint("contribute (first)", g - gasleft());
        _contribute(w, _wallet(1), 1_000e6);
        g = gasleft();
        _contribute(w, _wallet(1), 1_000e6);
        emit log_named_uint("contribute (top-up)", g - gasleft());
        vm.prank(_wallet(1));
        g = gasleft();
        w.k.cancel(500e6);
        emit log_named_uint("cancel", g - gasleft());
        for (uint256 i = 2; i < WALLETS; ++i) _contribute(w, _wallet(i), 1_000e6);
        vm.warp(T0 + 1 days);
        g = gasleft();
        w.k.settle();
        emit log_named_uint("settle (seed, pool init, LP split, fees)", g - gasleft());
        g = gasleft();
        w.k.materialize(_wallet(0));
        emit log_named_uint("materialize", g - gasleft());
        address[] memory page = new address[](WALLETS - 1);
        for (uint256 i = 1; i < WALLETS; ++i) page[i - 1] = _wallet(i);
        g = gasleft();
        w.k.materializeMany(page);
        emit log_named_uint("materializeMany (7 wallets)", g - gasleft());

        World memory f = _world(T0 + 2 days);
        vm.warp(T0 + 2 days);
        _contribute(f, _wallet(0), 1_000e6);
        vm.warp(T0 + 3 days);
        g = gasleft();
        f.k.fail();
        emit log_named_uint("fail", g - gasleft());
        g = gasleft();
        f.k.refund(_wallet(0));
        emit log_named_uint("refund", g - gasleft());
    }
}
