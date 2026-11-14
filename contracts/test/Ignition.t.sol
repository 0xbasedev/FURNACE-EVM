// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {AshToken} from "../src/ash/AshToken.sol";
import {AshLedger, IAshMint} from "../src/ash/AshLedger.sol";
import {Ignition, IIgnitionLedger, IIgnitionKindling, IIgnitionPair} from "../src/ignition/Ignition.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {ForgePoolBase} from "../src/forge/ForgePoolBase.sol";
import {ForgeView} from "../src/forge/ForgeView.sol";
import {EmberPair} from "../src/pairs/EmberPair.sol";
import {MockDecimalsERC20, FeeOnTransferERC20} from "./utils/MockERC20.sol";
import {MockBurnableERC20} from "./utils/VentMocks.sol";
import {MockColdStorage, MockClosedAt} from "./utils/IgnitionMocks.sol";

/// @dev One Ignition on real ASH (token and ledger), mock USDC/WETH/WBTC/LP, a mock Cold Storage
///      and a mock Kindling. Every address is predicted, as the kit's CREATE3 deployment does.
abstract contract IgnitionRig is Test {
    uint256 internal constant WALLETS = 6;
    uint256 internal constant T0 = 1_800_000_000;

    address internal treasury = makeAddr("treasury");
    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");
    address internal bonusSlot = makeAddr("kindlingBonus");
    address internal forgeAsh = makeAddr("forgeAsh");

    struct World {
        MockDecimalsERC20[4] tokens; // USDC, WETH, WBTC, LP (zero when unbound)
        AshToken ash;
        AshLedger ledger;
        Ignition ig;
        MockColdStorage cold;
        MockClosedAt kindling;
    }

    function _wallet(uint256 i) internal returns (address) {
        return makeAddr(string.concat("farmer", vm.toString(i)));
    }

    function _funding(uint256 k) internal pure returns (uint256) {
        uint8[4] memory d = [6, 18, 8, 18];
        return 10_000_000 * 10 ** d[k];
    }

    function _world(uint256 start, bool lp) internal returns (World memory w) {
        w.tokens[0] = new MockDecimalsERC20("USD Coin", "USDC", 6);
        w.tokens[1] = new MockDecimalsERC20("Wrapped Ether", "WETH", 18);
        w.tokens[2] = new MockDecimalsERC20("Wrapped Bitcoin", "WBTC", 8);
        if (lp) w.tokens[3] = new MockDecimalsERC20("WETH/USDC LP", "WETH-USDC", 18);
        w.kindling = new MockClosedAt();
        uint256 n = vm.getNonce(address(this));
        address ledgerAt = vm.computeCreateAddress(address(this), n + 1);
        address igAt = vm.computeCreateAddress(address(this), n + 2);
        address coldAt = vm.computeCreateAddress(address(this), n + 3);
        w.ash = new AshToken(ledgerAt);
        w.ledger = new AshLedger(IAshMint(address(w.ash)), igAt, bonusSlot, forgeAsh, start);
        w.ig = new Ignition(_config(w, coldAt, address(0), start));
        w.cold = new MockColdStorage(IERC20(address(w.tokens[0])), igAt);
        assertEq(address(w.ledger), ledgerAt, "ledger predicted");
        assertEq(address(w.ig), igAt, "ignition predicted");
        assertEq(address(w.cold), coldAt, "cold storage predicted");
        for (uint256 i; i < WALLETS; ++i) _fund(w, _wallet(i));
    }

    function _config(World memory w, address cold, address lpPool, uint256 start)
        internal
        returns (Ignition.Config memory c)
    {
        c.usdc = IERC20(address(w.tokens[0]));
        c.weth = IERC20(address(w.tokens[1]));
        c.wbtc = IERC20(address(w.tokens[2]));
        c.lp = IERC20(address(w.tokens[3]));
        c.ash = ERC20Burnable(address(w.ash));
        c.ledger = IIgnitionLedger(address(w.ledger));
        c.treasury = treasury;
        c.coldStorage = ForgePool(cold);
        c.lpPool = ForgePool(lpPool == address(0) ? makeAddr("pool0") : lpPool);
        c.blastPool = IIgnitionPair(makeAddr("blastPool"));
        c.kindling = IIgnitionKindling(address(w.kindling));
        c.start = start;
    }

    function _fund(World memory w, address who) internal {
        vm.startPrank(who);
        for (uint256 k; k < 4; ++k) {
            if (address(w.tokens[k]) == address(0)) continue;
            w.tokens[k].mint(who, _funding(k));
            w.tokens[k].approve(address(w.ig), type(uint256).max);
        }
        vm.stopPrank();
    }

    function _deposit(World memory w, address who, uint8 pool, uint256 gross, bool optOut) internal {
        if (w.tokens[pool].balanceOf(who) < gross) w.tokens[pool].mint(who, gross);
        vm.startPrank(who);
        w.tokens[pool].approve(address(w.ig), type(uint256).max);
        w.ig.deposit(pool, gross, optOut);
        vm.stopPrank();
    }
}

contract IgnitionTest is IgnitionRig {
    using ForgeView for ForgePool;

    // ── the BigInt model's scenarios, replayed exactly ────────────────────

    function test_replaysTheModelExactly() public {
        string memory json =
            vm.readFile(string.concat(vm.projectRoot(), "/contracts/test/fixtures/ignition-vectors.json"));
        assertEq(vm.parseUint(vm.parseJsonString(json, ".total")), P.ASH_IGNITION_ALLOCATION, "vectors from this config");
        assertEq(vm.parseUint(vm.parseJsonString(json, ".feeBps")), P.IGNITION_FEE_BPS, "vectors from this config");
        assertEq(vm.parseUint(vm.parseJsonString(json, ".duration")), P.IGNITION_DURATION, "vectors from this config");
        uint256 n;
        for (; vm.keyExistsJson(json, string.concat(".scenarios[", vm.toString(n), "]")); ++n) {
            _replay(json, string.concat(".scenarios[", vm.toString(n), "]"));
        }
        assertEq(n, 15, "every scenario replayed");
    }

    function test_theEntryWeightIsTheCanonicalCurve() public {
        World memory w = _world(T0, true);
        string memory json =
            vm.readFile(string.concat(vm.projectRoot(), "/contracts/test/fixtures/ignition-vectors.json"));
        string[] memory e = vm.parseJsonStringArray(json, ".weightElapsed");
        string[] memory want = vm.parseJsonStringArray(json, ".weightPpm");
        for (uint256 i; i < e.length; ++i) {
            assertEq(w.ig.weightAt(T0 + vm.parseUint(e[i])), vm.parseUint(want[i]), e[i]);
        }
        assertEq(w.ig.weightAt(T0 - 1), 1_100_000, "before START: the full bonus");
        assertEq(w.ig.weightAt(type(uint256).max), 1_000_000);
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
        bool lp = vm.parseJsonBool(json, string.concat(base, ".lp"));
        vm.warp(start - 3600);
        World memory w = _world(start, lp);
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
        if (h == keccak256("PoolDisabled")) return "(uint8)";
        if (h == keccak256("BelowMinimum") || h == keccak256("FundingMismatch")) return "(uint256)";
        if (h == keccak256("BadAmount")) return "(uint256,uint256)";
        if (h == keccak256("NothingOwed") || h == keccak256("NothingToStake")) return "(address)";
        return "()";
    }

    function _page(uint256 mask) internal returns (address[] memory page) {
        uint256 count;
        for (uint256 i; i < WALLETS; ++i) if ((mask >> i) & 1 == 1) ++count;
        page = new address[](count);
        count = 0;
        for (uint256 i; i < WALLETS; ++i) if ((mask >> i) & 1 == 1) page[count++] = _wallet(i);
    }

    /// @dev One model action: 0 warp, 1 deposit, 2 withdraw, 3 finalize, 4 claim, 5 claimMany,
    ///      6 stakeUsdc, 7 stakeUsdcMany, 8 the ledger's release, 9 donate, 10 warp to.
    function _act(World memory w, uint256 kind, uint256 a, uint256 b)
        internal
        returns (bool ok, uint256[2] memory out, bytes memory ret)
    {
        ok = true;
        // forge-lint: disable-next-line(unsafe-typecast) — the model packs the pool in byte 1
        uint8 pool = uint8(a >> 8);
        if (kind == 0) {
            vm.warp(block.timestamp + a);
        } else if (kind == 1) {
            vm.prank(_wallet(a & 0xff));
            (ok, ret) = address(w.ig).call(abi.encodeCall(Ignition.deposit, (pool, b, (a >> 16) & 1 == 1)));
            if (ok) (out[0], out[1]) = abi.decode(ret, (uint256, uint256));
        } else if (kind == 2) {
            vm.prank(_wallet(a & 0xff));
            (ok, ret) = address(w.ig).call(abi.encodeCall(Ignition.withdraw, (pool, b)));
            if (ok) (out[0], out[1]) = abi.decode(ret, (uint256, uint256));
        } else if (kind == 3) {
            vm.prank(keeper);
            (ok, ret) = address(w.ig).call(abi.encodeCall(Ignition.finalize, ()));
            if (ok) out[0] = abi.decode(ret, (uint256));
        } else if (kind == 4) {
            vm.prank(keeper);
            (ok, ret) = address(w.ig).call(abi.encodeCall(Ignition.claim, (_wallet(a))));
            if (ok) out[0] = abi.decode(ret, (uint256));
        } else if (kind == 5) {
            address[] memory page = _page(a);
            vm.prank(keeper);
            (ok, ret) = address(w.ig).call(abi.encodeCall(Ignition.claimMany, (page)));
            if (ok) out[0] = abi.decode(ret, (uint256));
        } else if (kind == 6) {
            vm.prank(keeper);
            (ok, ret) = address(w.ig).call(abi.encodeCall(Ignition.stakeUsdc, (_wallet(a))));
            if (ok) (out[0], out[1]) = abi.decode(ret, (uint256, uint256));
        } else if (kind == 7) {
            address[] memory page = _page(a);
            vm.prank(keeper);
            (ok, ret) = address(w.ig).call(abi.encodeCall(Ignition.stakeUsdcMany, (page)));
            if (ok) (out[0], out[1]) = abi.decode(ret, (uint256, uint256));
        } else if (kind == 8) {
            vm.prank(keeper);
            (ok, ret) = address(w.ledger).call(abi.encodeCall(AshLedger.releaseIgnition, ()));
            if (ok) out[0] = abi.decode(ret, (uint256));
        } else if (kind == 9) {
            w.tokens[a].mint(address(w.ig), b);
        } else {
            vm.warp(a);
        }
    }

    /// @dev The model's `words()`, in its exact order.
    function _words(World memory w) internal returns (uint256[] memory x) {
        Ignition ig = w.ig;
        // Exactly sized: memory is never freed, and the replay takes hundreds of steps.
        uint256 size = 3 + 4 * 6 + 4 + 1 + 4 + 1 + 3;
        for (uint256 i; i < WALLETS; ++i) {
            size += 5 + 4 * 5 + 3 + 7;
            for (uint8 k; k < 4; ++k) size += 2 * uint256(ig.accountOf(_wallet(i), k).lots);
        }
        x = new uint256[](size);
        x[0] = ig.finalized() ? 1 : 0;
        x[1] = ig.burned();
        x[2] = ig.paid();
        uint256 n = 3;
        for (uint8 k; k < 4; ++k) {
            Ignition.Pool memory p = ig.poolOf(k);
            x[n++] = ig.budgetOf(k);
            x[n++] = p.lastB;
            x[n++] = p.acc;
            x[n++] = p.unallocated;
            x[n++] = p.principal;
            x[n++] = p.weighted;
        }
        for (uint256 i; i < WALLETS; ++i) n = _walletWords(w, _wallet(i), x, n);
        for (uint256 k; k < 4; ++k) x[n++] = _bal(w, k, address(ig));
        x[n++] = w.ash.balanceOf(address(ig));
        for (uint256 k; k < 4; ++k) x[n++] = _bal(w, k, treasury);
        x[n++] = w.ash.totalSupply();
        x[n++] = w.tokens[0].balanceOf(address(w.cold));
        x[n++] = w.cold.feesBooked();
        x[n++] = w.cold.positionCount();
        assertEq(n, size, "words");
    }

    function _bal(World memory w, uint256 k, address who) internal view returns (uint256) {
        return address(w.tokens[k]) == address(0) ? 0 : w.tokens[k].balanceOf(who);
    }

    function _flags(Ignition ig, address who, uint256[] memory x, uint256 n) internal view returns (uint256) {
        (bool optedOut, bool snapped, bool founder,, uint256 kept, uint256 claimed) = ig.wallets(who);
        x[n++] = optedOut ? 1 : 0;
        x[n++] = snapped ? 1 : 0;
        x[n++] = founder ? 1 : 0;
        x[n++] = kept;
        x[n++] = claimed;
        return n;
    }

    function _walletWords(World memory w, address who, uint256[] memory x, uint256 n) internal view returns (uint256) {
        Ignition ig = w.ig;
        n = _flags(ig, who, x, n);
        for (uint8 k; k < 4; ++k) {
            Ignition.Account memory a = ig.accountOf(who, k);
            x[n++] = a.principal;
            x[n++] = a.weighted;
            x[n++] = a.accSnap;
            x[n++] = a.earned;
            x[n++] = a.lots;
            for (uint256 j; j < a.lots; ++j) {
                Ignition.IgnitionLot memory l = ig.lotOf(who, k, j);
                x[n++] = l.amount;
                x[n++] = l.ppm;
            }
        }
        x[n++] = ig.isFounder(who) ? 1 : 0;
        x[n++] = ig.usdcKeptOf(who);
        x[n++] = ig.pending(who);
        for (uint256 k; k < 4; ++k) x[n++] = _bal(w, k, who);
        x[n++] = w.ash.balanceOf(who);
        x[n++] = w.cold.stakedOf(who);
        x[n++] = w.cold.positionsOf(who);
        return n;
    }

    // ── construction and budgets ──────────────────────────────────────────

    function test_constructorRefusesZeroInputs() public {
        World memory w = _world(T0, true);
        Ignition.Config memory c = _config(w, address(w.cold), address(0), T0);
        Ignition.Config memory bad = c;
        bad.usdc = IERC20(address(0));
        vm.expectRevert(Ignition.ZeroAddress.selector);
        new Ignition(bad);
        bad = _config(w, address(w.cold), address(0), T0);
        bad.coldStorage = ForgePool(address(0));
        vm.expectRevert(Ignition.ZeroAddress.selector);
        new Ignition(bad);
        bad = _config(w, address(w.cold), address(0), T0);
        bad.kindling = IIgnitionKindling(address(0));
        vm.expectRevert(Ignition.ZeroAddress.selector);
        new Ignition(bad);
        bad = _config(w, address(w.cold), address(0), T0);
        bad.start = 0;
        vm.expectRevert(Ignition.ZeroAddress.selector);
        new Ignition(bad);
        // The LP is the one optional asset.
        bad = _config(w, address(w.cold), address(0), T0);
        bad.lp = IERC20(address(0));
        Ignition noLp = new Ignition(bad);
        assertEq(noLp.budgetOf(3), 0);
    }

    function test_theBudgetsSplitByWeightOverTheBoundPools() public {
        World memory w = _world(T0, true);
        assertEq(w.ig.END(), T0 + 120 hours, "120 h");
        uint256 total = P.ASH_IGNITION_ALLOCATION;
        assertEq(w.ig.budgetOf(0), (total * 100) / 450);
        assertEq(w.ig.budgetOf(1), (total * 100) / 450);
        assertEq(w.ig.budgetOf(2), (total * 100) / 450);
        assertEq(w.ig.budgetOf(3), (total * 150) / 450);
        assertEq(w.ig.budgetOf(4), 0);
        World memory v = _world(T0, false);
        assertEq(v.ig.budgetOf(0), total / 3, "the LP's weight goes to the bound pools");
        assertEq(v.ig.budgetOf(3), 0);
        assertLe(v.ig.budgetOf(0) * 3, total);
    }

    // ── deposits and withdrawals ──────────────────────────────────────────

    function test_theFeeGoesToTheTreasuryAtOnceAndIsNeverRefunded() public {
        vm.warp(T0);
        World memory w = _world(T0, true);
        address a = _wallet(0);
        vm.prank(a);
        (uint256 net, uint256 ppm) = w.ig.deposit(0, 10_000e6, false);
        assertEq(net, 9_700e6);
        assertEq(ppm, 1_100_000, "the full early bird at START");
        assertEq(w.tokens[0].balanceOf(treasury), 300e6, "3% to the Treasury, now");
        vm.prank(a);
        w.ig.withdraw(0, 9_700e6);
        assertEq(w.tokens[0].balanceOf(a), _funding(0) - 300e6, "the fee stays with the Treasury");
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(Ignition.BadAmount.selector, 1, 0));
        w.ig.withdraw(0, 1);
    }

    function test_aNonStandardTokenIsRefused() public {
        vm.warp(T0);
        World memory w = _world(T0, true);
        FeeOnTransferERC20 skim = new FeeOnTransferERC20();
        Ignition.Config memory c = _config(w, address(w.cold), address(0), T0);
        c.weth = IERC20(address(skim));
        Ignition ig = new Ignition(c);
        skim.mint(stranger, 1e18);
        vm.startPrank(stranger);
        skim.approve(address(ig), type(uint256).max);
        vm.expectRevert(Ignition.NonStandardToken.selector);
        ig.deposit(1, 1e18, false);
        vm.stopPrank();
    }

    // ── the close ─────────────────────────────────────────────────────────

    function test_finalizeRefusesALedgerThatPaysElsewhere() public {
        vm.warp(T0);
        World memory w = _world(T0, true);
        // A ledger whose Ignition is another address: its release never reaches this farm.
        uint256 n = vm.getNonce(address(this));
        AshToken t = new AshToken(vm.computeCreateAddress(address(this), n + 1));
        AshLedger other = new AshLedger(IAshMint(address(t)), stranger, bonusSlot, forgeAsh, T0);
        Ignition.Config memory c = _config(w, address(w.cold), address(0), T0);
        (c.ash, c.ledger) = (ERC20Burnable(address(t)), IIgnitionLedger(address(other)));
        Ignition ig = new Ignition(c);
        vm.warp(ig.END());
        vm.expectRevert(abi.encodeWithSelector(Ignition.FundingMismatch.selector, 0));
        ig.finalize();
    }

    function test_theWholeLeafIsPaidOrBurnedAndNeverMore(uint256 seed) public {
        vm.warp(T0);
        World memory w = _world(T0, true);
        for (uint256 i; i < 12; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint8 pool = uint8(seed % 4);
            uint256 gross = 1e3 + (seed >> 8) % (10 ** (pool == 2 ? 8 : pool == 0 ? 10 : 21));
            _deposit(w, _wallet(i % WALLETS), pool, gross, false);
            vm.warp(block.timestamp + (seed >> 128) % 20 hours);
            if (block.timestamp >= w.ig.END()) break;
        }
        vm.warp(w.ig.END() + 1);
        address[] memory everyone = _page(0x3f);
        w.ig.claimMany(everyone);
        uint256 dust = P.ASH_IGNITION_ALLOCATION - w.ig.paid() - w.ig.burned();
        assertEq(w.ash.balanceOf(address(w.ig)), dust, "only rounding dust stays");
        assertLt(dust, 1e9, "dust below a billionth of an ASH");
        assertEq(w.ash.totalSupply(), P.ASH_IGNITION_ALLOCATION - w.ig.burned());
        for (uint256 i; i < WALLETS; ++i) assertEq(w.ig.pending(_wallet(i)), 0);
    }

    // ── First Flame and the head start, on real Forge pools ──────────────

    struct Real {
        World w;
        ForgePool cold;
        ForgePool pool0;
        EmberPair blast;
        MockBurnableERC20 ember;
        Ignition ig;
    }

    /// @dev Ignition over a real Cold Storage (USDC) and a real pool 0 on a real BlastPool, both
    ///      naming Ignition as their IGNITION and FOUNDERS.
    function _real() internal returns (Real memory r) {
        vm.warp(T0 - 1 hours);
        r.w = _world(T0, true);
        r.ember = new MockBurnableERC20("Ember", "EMBER");
        // A pool deploys its annex from its own nonce, so each deployment here takes one.
        uint256 n = vm.getNonce(address(this));
        address coldAt = vm.computeCreateAddress(address(this), n);
        address blastAt = vm.computeCreateAddress(address(this), n + 1);
        address pool0At = vm.computeCreateAddress(address(this), n + 2);
        address igAt = vm.computeCreateAddress(address(this), n + 4);
        address ledgerAt = vm.computeCreateAddress(address(this), n + 5);
        address fees = makeAddr("feeRouter");
        r.cold = new ForgePool(IERC20(address(r.w.tokens[0])), false, fees, makeAddr("boost"), makeAddr("deeds"), address(0), address(0), address(0), igAt, igAt);
        r.blast = new EmberPair("Blast", "BLAST", IERC20(address(r.ember)), IERC20(address(r.w.tokens[0])), fees, address(0), makeAddr("guardian"), address(this));
        r.pool0 = new ForgePool(IERC20(address(r.blast)), true, fees, makeAddr("boost"), makeAddr("deeds"), address(0), address(0), address(0), igAt, igAt);
        // The rig's ledger names its own Ignition; this farm gets its own ASH and ledger.
        AshToken t = new AshToken(ledgerAt);
        Ignition.Config memory c = _config(r.w, coldAt, pool0At, T0);
        (c.blastPool, c.ash, c.ledger) = (IIgnitionPair(blastAt), ERC20Burnable(address(t)), IIgnitionLedger(ledgerAt));
        r.ig = new Ignition(c);
        AshLedger l = new AshLedger(IAshMint(address(t)), igAt, bonusSlot, forgeAsh, T0);
        assertEq(address(r.cold), coldAt);
        assertEq(address(r.blast), blastAt);
        assertEq(address(r.pool0), pool0At);
        assertEq(address(r.ig), igAt, "ignition predicted");
        assertEq(address(l), ledgerAt, "ledger predicted");
        r.w.ig = r.ig;
        for (uint256 i; i < WALLETS; ++i) _fund(r.w, _wallet(i));
    }

    function test_usdcAutoStakesIntoARealColdStoragePosition() public {
        Real memory r = _real();
        address a = _wallet(0);
        vm.warp(T0);
        _deposit(r.w, a, 0, 10_000e6, false);
        vm.warp(r.ig.END() + P.IGNITION_EXIT_WINDOW);
        (uint256 id, uint256 amount) = r.ig.stakeUsdc(a);
        assertEq(amount, 9_700e6);
        ForgePoolBase.Position memory p = r.cold.positionOf(id);
        assertEq(p.owner, a, "the wallet's own position");
        assertEq(r.cold.custodyOf(id), 9_700e6 - 97e6, "at the standard 1% fee");
        assertTrue(r.ig.isFounder(a), "it kept principal through close");
        assertEq(r.ig.usdcKeptOf(a), 9_700e6, "recorded at its first post-close action");
        // The pool reads the founder record through FOUNDERS.
        assertTrue(r.cold.refreshFounder(id));
    }

    function test_onlyIgnitionOpensIgnitionPositions() public {
        Real memory r = _real();
        r.w.tokens[0].mint(stranger, 1e6);
        vm.startPrank(stranger);
        r.w.tokens[0].approve(address(r.cold), 1e6);
        vm.expectRevert(ForgePoolBase.NotIgnition.selector);
        r.cold.openIgnition(stranger, 1e6);
        vm.stopPrank();
        ForgePool none = new ForgePool(IERC20(address(r.w.tokens[0])), false, stranger, stranger, stranger, address(0), address(0), address(0), address(0), address(0));
        vm.prank(address(0));
        vm.expectRevert(ForgePoolBase.NotIgnition.selector);
        none.openIgnition(stranger, 1e6);
    }

    function test_theHeadStartDatesTheAutoStakedLotToIgnitionsStart() public {
        Real memory r = _real();
        address a = _wallet(0);
        vm.warp(T0 + 3 hours);
        _deposit(r.w, a, 0, 10_000e6, false);
        uint256 end = r.ig.END();
        vm.warp(end + P.IGNITION_EXIT_WINDOW);
        (uint256 id,) = r.ig.stakeUsdc(a);
        uint256 stakedAt = block.timestamp;
        // Not before Kindling closes.
        vm.prank(a);
        vm.expectRevert(Ignition.NotInWindow.selector);
        r.ig.grantHeadStart(r.cold, id, 0);
        vm.warp(stakedAt + 2 days);
        r.w.kindling.setClosedAt(block.timestamp - 1 days);
        // Only the position's owner, only an eligible pool.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ignition.NotOwner.selector, id));
        r.ig.grantHeadStart(r.cold, id, 0);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(Ignition.NotEligiblePool.selector, stranger));
        r.ig.grantHeadStart(ForgePool(stranger), id, 0);
        vm.prank(a);
        uint256 s = r.ig.grantHeadStart(r.cold, id, 0);
        assertEq(s, stakedAt - T0, "the lot's open time less Ignition's start");
        ForgePoolBase.Position memory p = r.cold.positionOf(id);
        assertEq(p.headStart, s);
        assertTrue(p.headStartActive);
        // Once per wallet.
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(Ignition.HeadStartUsed.selector, a));
        r.ig.grantHeadStart(r.cold, id, 0);
    }

    function test_theHeadStartWindowIsSevenDaysFromKindlingsClose() public {
        Real memory r = _real();
        address a = _wallet(1);
        vm.warp(T0);
        _deposit(r.w, a, 0, 1_000e6, false);
        vm.warp(r.ig.END() + P.IGNITION_EXIT_WINDOW);
        (uint256 id,) = r.ig.stakeUsdc(a);
        r.w.kindling.setClosedAt(block.timestamp);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(a);
        vm.expectRevert(Ignition.NotInWindow.selector);
        r.ig.grantHeadStart(r.cold, id, 0);
        vm.warp(block.timestamp - 1);
        vm.prank(a);
        r.ig.grantHeadStart(r.cold, id, 0);
    }

    function test_theHeadStartIsCappedToTheUsdcKeptAndOnlyForNewCapital() public {
        Real memory r = _real();
        address a = _wallet(2);
        vm.warp(T0);
        // A Cold Storage position opened during Ignition is not new capital.
        r.w.tokens[0].mint(a, 5_000e6);
        vm.startPrank(a);
        r.w.tokens[0].approve(address(r.cold), type(uint256).max);
        uint256 early = r.cold.open(1_000e6);
        vm.stopPrank();
        _deposit(r.w, a, 0, 1_000e6, true); // opted out: it keeps 970 USDC through close
        vm.warp(r.ig.END() + 1);
        vm.prank(a);
        uint256 big = r.cold.open(980e6); // 970.2 after the pool's fee: over the cap
        vm.prank(a);
        uint256 small = r.cold.open(979e6); // 969.21 after the fee: within it
        r.w.kindling.setClosedAt(block.timestamp);
        vm.startPrank(a);
        vm.expectRevert(abi.encodeWithSelector(Ignition.NotNewCapital.selector, early, 0));
        r.ig.grantHeadStart(r.cold, early, 0);
        vm.expectRevert(abi.encodeWithSelector(Ignition.OverCap.selector, 980e6 - 9.8e6, 970e6));
        r.ig.grantHeadStart(r.cold, big, 0);
        vm.expectRevert(abi.encodeWithSelector(Ignition.NotNewCapital.selector, small, 1));
        r.ig.grantHeadStart(r.cold, small, 1);
        r.ig.grantHeadStart(r.cold, small, 0);
        vm.stopPrank();
        assertEq(r.cold.positionOf(small).headStart, (r.ig.END() + 1) - T0);
        // A wallet that kept no USDC has no room: WETH is not valued [P].
        address b = _wallet(3);
        vm.warp(r.ig.END() + 2);
        r.w.tokens[0].mint(b, 10e6);
        vm.startPrank(b);
        r.w.tokens[0].approve(address(r.cold), type(uint256).max);
        uint256 id = r.cold.open(10e6);
        vm.expectRevert(abi.encodeWithSelector(Ignition.OverCap.selector, 10e6 - 0.1e6, 0));
        r.ig.grantHeadStart(r.cold, id, 0);
        vm.stopPrank();
    }

    function test_poolZeroLpIsValuedAtItsFairTwapValue() public {
        Real memory r = _real();
        address a = _wallet(4);
        vm.warp(T0);
        _deposit(r.w, a, 0, 1_000_000e6, true);
        // BlastPool opens at $0.50 per EMBER: 1,000,000 EMBER against 500,000 USDC.
        r.ember.mint(address(this), 1_000_000e18);
        r.w.tokens[0].mint(address(this), 500_000e6);
        r.ember.approve(address(r.blast), type(uint256).max);
        r.w.tokens[0].approve(address(r.blast), type(uint256).max);
        (,, uint256 lp) = r.blast.addLiquidity(1_000_000e18, 500_000e6, 0, 0, address(this));
        vm.warp(r.ig.END() + 1);
        r.blast.checkpoint();
        vm.warp(block.timestamp + P.IGNITION_TWAP_SECONDS);
        r.blast.checkpoint();
        // The wallet opens a pool-0 position with 10% of the LP: about $100,000 of value.
        uint256 stake = lp / 10;
        r.blast.transfer(a, stake);
        vm.startPrank(a);
        r.blast.approve(address(r.pool0), type(uint256).max);
        uint256 id = r.pool0.open(stake);
        vm.stopPrank();
        r.w.kindling.setClosedAt(block.timestamp);
        // A large buy skews the spot price inside this block: the TWAP value does not follow it.
        r.w.tokens[0].mint(address(this), 2_000_000e6);
        r.w.tokens[0].approve(address(r.blast), type(uint256).max);
        r.blast.buy(2_000_000e6, 0, address(this));
        vm.prank(a);
        uint256 s = r.ig.grantHeadStart(r.pool0, id, 0);
        assertEq(s, block.timestamp - T0);
        // A stale TWAP refuses: no observation newer than the maximum age.
        Real memory q = _real();
        vm.warp(T0);
        _deposit(q.w, a, 0, 1_000_000e6, true);
        q.ember.mint(address(this), 1_000_000e18);
        q.w.tokens[0].mint(address(this), 500_000e6);
        q.ember.approve(address(q.blast), type(uint256).max);
        q.w.tokens[0].approve(address(q.blast), type(uint256).max);
        (,, lp) = q.blast.addLiquidity(1_000_000e18, 500_000e6, 0, 0, address(this));
        vm.warp(q.ig.END() + 3 hours);
        q.blast.transfer(a, lp / 10);
        vm.startPrank(a);
        q.blast.approve(address(q.pool0), type(uint256).max);
        id = q.pool0.open(lp / 10);
        vm.stopPrank();
        q.w.kindling.setClosedAt(block.timestamp);
        vm.prank(a);
        vm.expectPartialRevert(Ignition.StaleOracle.selector);
        q.ig.grantHeadStart(q.pool0, id, 0);
    }

    function test_theLpCapReadsTheFairValue() public {
        Real memory r = _real();
        address a = _wallet(5);
        vm.warp(T0);
        // Keep exactly $1,000 of USDC through close.
        _deposit(r.w, a, 0, uint256(1_000e6) * 100 / 97 + 1, true);
        r.ember.mint(address(this), 1_000_000e18);
        r.w.tokens[0].mint(address(this), 500_000e6);
        r.ember.approve(address(r.blast), type(uint256).max);
        r.w.tokens[0].approve(address(r.blast), type(uint256).max);
        (,, uint256 lp) = r.blast.addLiquidity(1_000_000e18, 500_000e6, 0, 0, address(this));
        vm.warp(r.ig.END() + 1);
        r.blast.checkpoint();
        vm.warp(block.timestamp + P.IGNITION_TWAP_SECONDS);
        r.blast.checkpoint();
        uint256 supply = r.blast.totalSupply();
        // $1,000,000 of pool value: $1,000 is supply / 1000; just over it, after the pool's 1% fee.
        uint256 over = (supply / 1000) * 100 / 99 + 1e15;
        r.blast.transfer(a, over);
        vm.startPrank(a);
        r.blast.approve(address(r.pool0), type(uint256).max);
        uint256 id = r.pool0.open(over);
        r.w.kindling.setClosedAt(block.timestamp);
        vm.expectPartialRevert(Ignition.OverCap.selector);
        r.ig.grantHeadStart(r.pool0, id, 0);
        vm.stopPrank();
        assertGt(lp, over);
    }

    // ── gas (pnpm gas, isolated) ──────────────────────────────────────────

    function test_gas_ignition() public {
        Real memory r = _real();
        (address a, address b) = (_wallet(0), _wallet(1));
        vm.warp(T0);
        vm.prank(b);
        r.ig.deposit(1, 1e18, false);
        vm.prank(a);
        uint256 gas = gasleft();
        r.ig.deposit(0, 10_000e6, false);
        emit log_named_uint("deposit (first lot)", gas - gasleft());
        vm.warp(T0 + 1 hours);
        vm.prank(a);
        gas = gasleft();
        r.ig.deposit(0, 1_000e6, false);
        emit log_named_uint("deposit (a second lot)", gas - gasleft());
        vm.prank(a);
        gas = gasleft();
        r.ig.withdraw(0, 1_500e6);
        emit log_named_uint("withdraw (across two lots)", gas - gasleft());
        vm.warp(r.ig.END());
        gas = gasleft();
        r.ig.finalize();
        emit log_named_uint("finalize (releases and burns)", gas - gasleft());
        gas = gasleft();
        r.ig.claim(a);
        emit log_named_uint("claim", gas - gasleft());
        vm.warp(r.ig.END() + P.IGNITION_EXIT_WINDOW);
        gas = gasleft();
        (uint256 id,) = r.ig.stakeUsdc(a);
        emit log_named_uint("stakeUsdc (into the real Cold Storage)", gas - gasleft());
        r.w.kindling.setClosedAt(block.timestamp);
        vm.prank(a);
        gas = gasleft();
        r.ig.grantHeadStart(r.cold, id, 0);
        emit log_named_uint("grantHeadStart (Cold Storage)", gas - gasleft());
    }
}
