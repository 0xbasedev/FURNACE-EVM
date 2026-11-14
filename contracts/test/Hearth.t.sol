// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {Hearth} from "../src/hearth/Hearth.sol";
import {MockERC20, MockDecimalsERC20, FeeOnTransferERC20} from "./utils/MockERC20.sol";

/// @dev The Hearth with mock EMBER, USDC (6 decimals) and WETH as its fee assets, and a mock ASH.
abstract contract HearthRig is Test {
    uint256 internal constant T0 = 1_800_000_000;
    uint256 internal constant WALLETS = 5;
    uint256 internal constant ASSETS = 3;
    uint256 internal constant ASH_EACH = 20_000e18;

    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");

    struct World {
        MockERC20 ember;
        MockDecimalsERC20 usdc;
        MockERC20 weth;
        MockERC20 ash;
        Hearth hearth;
    }

    function _wallet(uint256 i) internal returns (address) {
        return makeAddr(string.concat("ashStaker", vm.toString(i)));
    }

    function _world() internal returns (World memory w) {
        w.ember = new MockERC20("Ember", "EMBER");
        w.usdc = new MockDecimalsERC20("USD Coin", "USDC", 6);
        w.weth = new MockERC20("Wrapped Ether", "WETH");
        w.ash = new MockERC20("Ash", "ASH");
        address[] memory assets = new address[](3);
        (assets[0], assets[1], assets[2]) = (address(w.ember), address(w.usdc), address(w.weth));
        w.hearth = new Hearth(IERC20(address(w.ash)), treasury, assets);
        for (uint256 i; i < WALLETS; ++i) {
            address who = _wallet(i);
            w.ash.mint(who, ASH_EACH);
            vm.prank(who);
            w.ash.approve(address(w.hearth), type(uint256).max);
        }
    }

    /// @dev The model's asset numbering: 0 EMBER, 1 USDC, 2 WETH, 3 ASH (never a fee asset).
    function _token(World memory w, uint256 a) internal pure returns (address) {
        return a == 0 ? address(w.ember) : a == 1 ? address(w.usdc) : a == 2 ? address(w.weth) : address(w.ash);
    }
}

contract HearthTest is HearthRig {
    // ── the BigInt model's scenarios, replayed exactly ────────────────────

    function test_everyScenarioHasATest() public view {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/contracts/test/fixtures/hearth-vectors.json"));
        assertEq(vm.parseUint(vm.parseJsonString(json, ".cooldown")), P.HEARTH_EXIT_COOLDOWN, "vectors from this config");
        assertEq(vm.parseUint(vm.parseJsonString(json, ".prec")), 1e36, "the model's index scale");
        assertTrue(vm.keyExistsJson(json, ".scenarios[8]"));
        assertFalse(vm.keyExistsJson(json, ".scenarios[9]"), "a scenario without a test");
    }

    function test_scenario_oldBatch() public {
        _replayAt(0);
    }

    function test_scenario_treasury() public {
        _replayAt(1);
    }

    function test_scenario_exits() public {
        _replayAt(2);
    }

    function test_scenario_decimals() public {
        _replayAt(3);
    }

    function test_scenario_notAnAsset() public {
        _replayAt(4);
    }

    function test_scenario_walk0() public {
        _replayAt(5);
    }

    function test_scenario_walk1() public {
        _replayAt(6);
    }

    function test_scenario_walk2() public {
        _replayAt(7);
    }

    function test_scenario_walk3() public {
        _replayAt(8);
    }

    struct Cols {
        uint256[] kind;
        string[] a;
        string[] b;
        string[] why;
        string[] out;
        string[] hash;
    }

    function _replayAt(uint256 n) internal {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/contracts/test/fixtures/hearth-vectors.json"));
        string memory base = string.concat(".scenarios[", vm.toString(n), "]");
        vm.warp(T0);
        World memory w = _world();
        Cols memory c;
        c.kind = vm.parseJsonUintArray(json, string.concat(base, ".kind"));
        c.a = vm.parseJsonStringArray(json, string.concat(base, ".a"));
        c.b = vm.parseJsonStringArray(json, string.concat(base, ".b"));
        c.why = vm.parseJsonStringArray(json, string.concat(base, ".why"));
        c.out = vm.parseJsonStringArray(json, string.concat(base, ".out"));
        c.hash = vm.parseJsonStringArray(json, string.concat(base, ".hash"));
        string memory name = vm.parseJsonString(json, string.concat(base, ".name"));
        for (uint256 i; i < c.kind.length; ++i) {
            string memory at = string.concat(name, " step ", vm.toString(i));
            (bool ok, uint256 out, bytes memory ret) = _act(w, c.kind[i], vm.parseUint(c.a[i]), vm.parseUint(c.b[i]));
            if (bytes(c.why[i]).length != 0) {
                assertFalse(ok, string.concat(at, ": expected ", c.why[i]));
                assertEq(bytes4(ret), bytes4(keccak256(bytes(string.concat(c.why[i], _args(c.why[i]))))), at);
            } else {
                if (!ok) emit log_named_bytes("revert", ret);
                assertTrue(ok, string.concat(at, ": reverted"));
                assertEq(out, vm.parseUint(c.out[i]), string.concat(at, ": output"));
            }
            assertEq(keccak256(abi.encodePacked(_words(w))), vm.parseBytes32(c.hash[i]), string.concat(at, ": state"));
        }
    }

    function _args(string memory why) internal pure returns (string memory) {
        bytes32 h = keccak256(bytes(why));
        if (h == keccak256("OverStake")) return "(uint256,uint256)";
        if (h == keccak256("NothingOwed")) return "(address,address)";
        if (h == keccak256("TooEarly")) return "(uint256)";
        if (h == keccak256("NoExit") || h == keccak256("NothingToBook") || h == keccak256("UnknownAsset")) return "(address)";
        return "()";
    }

    /// @dev One model action: 0 warp, 1 gift, 2 book, 3 stake, 4 request an exit, 5 cancel it,
    ///      6 withdraw, 7 claim, 8 claim all, 9 release to the Treasury.
    function _act(World memory w, uint256 kind, uint256 a, uint256 b)
        internal
        returns (bool ok, uint256 out, bytes memory ret)
    {
        ok = true;
        if (kind == 0) {
            vm.warp(block.timestamp + a);
            return (ok, out, ret);
        }
        if (kind == 1) {
            MockERC20(_token(w, a)).mint(address(w.hearth), b);
            return (ok, out, ret);
        }
        address caller = kind == 2 || kind == 9 ? keeper : _wallet(a);
        bytes memory data;
        if (kind == 2) data = abi.encodeCall(Hearth.book, (_token(w, a)));
        else if (kind == 3) data = abi.encodeCall(Hearth.stake, (b));
        else if (kind == 4) data = abi.encodeCall(Hearth.requestExit, (b));
        else if (kind == 5) data = abi.encodeCall(Hearth.cancelExit, ());
        else if (kind == 6) data = abi.encodeCall(Hearth.withdraw, ());
        else if (kind == 7) data = abi.encodeCall(Hearth.claim, (_token(w, b)));
        else if (kind == 8) data = abi.encodeCall(Hearth.claimAll, ());
        else data = abi.encodeCall(Hearth.releaseToTreasury, (_token(w, a)));
        vm.prank(caller);
        (ok, ret) = address(w.hearth).call(data);
        if (!ok || kind == 3) return (ok, 0, ret);
        if (kind == 8) {
            uint256[] memory amounts = abi.decode(ret, (uint256[]));
            for (uint256 k; k < amounts.length; ++k) out += amounts[k];
        } else {
            out = abi.decode(ret, (uint256));
        }
    }

    /// @dev The model's `words()`, in its exact order.
    function _words(World memory w) internal returns (uint256[] memory x) {
        x = new uint256[](ASSETS * 5 + 3 + WALLETS * (4 + ASSETS * 3));
        uint256 n;
        Hearth h = w.hearth;
        for (uint256 a; a < ASSETS; ++a) {
            address t = _token(w, a);
            x[n++] = IERC20(t).balanceOf(address(h));
            x[n++] = h.liability(t);
            x[n++] = h.indexOf(t);
            x[n++] = h.treasuryOwed(t);
            x[n++] = IERC20(t).balanceOf(treasury);
        }
        x[n++] = h.totalStaked();
        x[n++] = h.totalExiting();
        x[n++] = w.ash.balanceOf(address(h));
        for (uint256 i; i < WALLETS; ++i) {
            address who = _wallet(i);
            (uint256 amount, uint256 unlockAt) = h.exitOf(who);
            x[n++] = h.stakeOf(who);
            x[n++] = amount;
            x[n++] = unlockAt;
            x[n++] = w.ash.balanceOf(who);
            for (uint256 a; a < ASSETS; ++a) {
                address t = _token(w, a);
                x[n++] = h.paidIndexOf(who, t);
                x[n++] = h.owedOf(who, t);
                x[n++] = IERC20(t).balanceOf(who);
            }
        }
        assertEq(n, x.length, "words");
    }

    // ── unit and fuzz tests ───────────────────────────────────────────────

    /// A batch that arrived before a stake is booked to the stake that was there: the newcomer gets
    /// none of it, however it is timed.
    function test_aNewStakerCannotCaptureAnOldBatch(uint96 first, uint96 second, uint96 fee) public {
        vm.warp(T0);
        World memory w = _world();
        uint256 a = bound(first, 1, ASH_EACH);
        uint256 b = bound(second, 1, ASH_EACH);
        uint256 f = bound(fee, 1, 1e30);
        address old = _wallet(0);
        address newcomer = _wallet(1);
        vm.prank(old);
        w.hearth.stake(a);
        w.ember.mint(address(w.hearth), f);
        vm.prank(newcomer);
        w.hearth.stake(b);
        assertEq(w.hearth.pending(newcomer, address(w.ember)), 0, "nothing from the old batch");
        assertEq(w.hearth.pending(old, address(w.ember)), (f * 1e36 / a) * a / 1e36, "all of it, to the floor");
        assertLe(w.hearth.pending(old, address(w.ember)), f);
        assertGe(w.hearth.pending(old, address(w.ember)) + 1, f, "short by at most a wei");
    }

    function test_batchesBookedWithNobodyStakedAreTheTreasurys() public {
        vm.warp(T0);
        World memory w = _world();
        w.usdc.mint(address(w.hearth), 5e6);
        vm.prank(keeper);
        assertEq(w.hearth.book(address(w.usdc)), 5e6);
        assertEq(w.hearth.treasuryOwed(address(w.usdc)), 5e6);
        assertEq(w.hearth.indexOf(address(w.usdc)), 0, "no index moved with nobody staked");
        vm.prank(_wallet(0));
        w.hearth.stake(1e18);
        assertEq(w.hearth.pending(_wallet(0), address(w.usdc)), 0, "the first staker takes none of it");
        vm.prank(keeper);
        assertEq(w.hearth.releaseToTreasury(address(w.usdc)), 5e6);
        assertEq(w.usdc.balanceOf(treasury), 5e6);
        assertEq(w.hearth.liability(address(w.usdc)), 0);
    }

    function test_exitingAshEarnsNothingAndUnlocksAfterTheCooldown() public {
        vm.warp(T0);
        World memory w = _world();
        address a = _wallet(0);
        address b = _wallet(1);
        vm.prank(a);
        w.hearth.stake(100e18);
        vm.prank(b);
        w.hearth.stake(100e18);
        vm.prank(a);
        assertEq(w.hearth.requestExit(100e18), T0 + 24 hours);
        w.weth.mint(address(w.hearth), 3e18);
        vm.prank(keeper);
        w.hearth.book(address(w.weth));
        assertEq(w.hearth.pending(a, address(w.weth)), 0, "exiting ASH earns nothing");
        assertEq(w.hearth.pending(b, address(w.weth)), 3e18);
        vm.warp(T0 + 24 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(Hearth.TooEarly.selector, T0 + 24 hours));
        vm.prank(a);
        w.hearth.withdraw();
        vm.warp(T0 + 24 hours);
        vm.prank(a);
        assertEq(w.hearth.withdraw(), 100e18, "nobody's approval needed");
        assertEq(w.ash.balanceOf(a), ASH_EACH);
    }

    function test_aCancelledExitEarnsAgainFromItsCancel() public {
        vm.warp(T0);
        World memory w = _world();
        address a = _wallet(0);
        vm.startPrank(a);
        w.hearth.stake(10e18);
        w.hearth.requestExit(10e18);
        vm.stopPrank();
        w.ember.mint(address(w.hearth), 1e18);
        vm.prank(a);
        assertEq(w.hearth.cancelExit(), 10e18);
        assertEq(w.hearth.treasuryOwed(address(w.ember)), 1e18, "it arrived while nothing was staked");
        assertEq(w.hearth.pending(a, address(w.ember)), 0);
        w.ember.mint(address(w.hearth), 2e18);
        vm.prank(a);
        assertEq(w.hearth.claim(address(w.ember)), 2e18);
    }

    /// What a stake change settles stays visible: `pending` shows the settled amount, and the claim
    /// pays exactly that, though the ASH has left the stake.
    function test_pendingShowsWhatAStakeChangeSettled() public {
        vm.warp(T0);
        World memory w = _world();
        address a = _wallet(0);
        vm.prank(a);
        w.hearth.stake(30e18);
        vm.prank(_wallet(1));
        w.hearth.stake(10e18);
        w.weth.mint(address(w.hearth), 8e18);
        vm.prank(a);
        w.hearth.requestExit(30e18);
        uint256 settled = w.hearth.owedOf(a, address(w.weth));
        assertEq(settled, 6e18, "three quarters of the batch, settled at the request");
        assertEq(w.hearth.stakeOf(a), 0);
        assertEq(w.hearth.pending(a, address(w.weth)), settled, "the view shows what was settled");
        vm.prank(a);
        assertEq(w.hearth.claim(address(w.weth)), settled);
        assertEq(w.hearth.pending(a, address(w.weth)), 0);
    }

    function test_claimsNeverPassWhatWasBooked(uint256 seed) public {
        vm.warp(T0);
        World memory w = _world();
        for (uint256 i; i < WALLETS; ++i) {
            vm.prank(_wallet(i));
            w.hearth.stake(bound(uint256(keccak256(abi.encode(seed, i))), 1, ASH_EACH));
        }
        uint256 fee = bound(uint256(keccak256(abi.encode(seed, "fee"))), 1, 1e30);
        w.usdc.mint(address(w.hearth), fee);
        uint256 paid;
        for (uint256 i; i < WALLETS; ++i) {
            vm.prank(_wallet(i));
            uint256[] memory got = w.hearth.claimAll();
            paid += got[1];
        }
        assertLe(paid, fee, "never more than booked");
        assertGe(paid + WALLETS, fee, "short only by the floors");
        assertGe(w.usdc.balanceOf(address(w.hearth)), w.hearth.liability(address(w.usdc)), "owed is held");
    }

    function test_constructorRefusesBadInputs() public {
        MockERC20 ash = new MockERC20("Ash", "ASH");
        address[] memory one = new address[](1);
        one[0] = makeAddr("ember");
        vm.expectRevert(Hearth.ZeroAddress.selector);
        new Hearth(IERC20(address(0)), treasury, one);
        vm.expectRevert(Hearth.ZeroAddress.selector);
        new Hearth(IERC20(address(ash)), address(0), one);
        vm.expectRevert(Hearth.BadAssets.selector);
        new Hearth(IERC20(address(ash)), treasury, new address[](0));
        vm.expectRevert(Hearth.BadAssets.selector);
        new Hearth(IERC20(address(ash)), treasury, new address[](5));
        address[] memory bad = new address[](2);
        vm.expectRevert(Hearth.ZeroAddress.selector);
        new Hearth(IERC20(address(ash)), treasury, bad);
        (bad[0], bad[1]) = (one[0], one[0]);
        vm.expectRevert(Hearth.BadAssets.selector);
        new Hearth(IERC20(address(ash)), treasury, bad);
        (bad[0], bad[1]) = (one[0], address(ash));
        vm.expectRevert(Hearth.BadAssets.selector);
        new Hearth(IERC20(address(ash)), treasury, bad);
        Hearth h = new Hearth(IERC20(address(ash)), treasury, one);
        assertEq(h.ASSET_COUNT(), 1);
        assertEq(h.assetAt(0), one[0]);
        assertFalse(h.isAsset(address(ash)));
        vm.expectRevert(Hearth.BadAssets.selector);
        h.assetAt(1);
    }

    function test_aNonStandardAshIsRefused() public {
        FeeOnTransferERC20 skim = new FeeOnTransferERC20();
        address[] memory one = new address[](1);
        one[0] = address(new MockERC20("Ember", "EMBER"));
        Hearth h = new Hearth(IERC20(address(skim)), treasury, one);
        skim.mint(address(this), 100e18);
        skim.approve(address(h), 100e18);
        vm.expectRevert(Hearth.NonStandardToken.selector);
        h.stake(100e18);
    }

    // ── gas (pnpm gas, isolated) ──────────────────────────────────────────

    function test_gas_hearth() public {
        vm.warp(T0);
        World memory w = _world();
        address a = _wallet(0);
        vm.prank(_wallet(1));
        w.hearth.stake(1e18);
        w.ember.mint(address(w.hearth), 1e18);
        w.usdc.mint(address(w.hearth), 1e6);
        w.weth.mint(address(w.hearth), 1e18);
        vm.prank(a);
        uint256 g = gasleft();
        w.hearth.stake(1e18);
        emit log_named_uint("stake (books three assets)", g - gasleft());
        w.ember.mint(address(w.hearth), 1e18);
        vm.prank(keeper);
        g = gasleft();
        w.hearth.book(address(w.ember));
        emit log_named_uint("book", g - gasleft());
        vm.prank(a);
        g = gasleft();
        w.hearth.claim(address(w.ember));
        emit log_named_uint("claim", g - gasleft());
        vm.prank(a);
        g = gasleft();
        w.hearth.requestExit(1e18);
        emit log_named_uint("requestExit", g - gasleft());
        vm.warp(T0 + 24 hours);
        vm.prank(a);
        g = gasleft();
        w.hearth.withdraw();
        emit log_named_uint("withdraw", g - gasleft());
    }
}
