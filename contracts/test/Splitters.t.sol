// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {ForgeView} from "../src/forge/ForgeView.sol";
import {ForgeEmissions} from "../src/forge/ForgeEmissions.sol";
import {AshToken} from "../src/ash/AshToken.sol";
import {AshLedger, IAshMint} from "../src/ash/AshLedger.sol";
import {EpochSplitter, IEpochMeasures} from "../src/yield/EpochSplitter.sol";
import {BookedSplitter} from "../src/yield/BookedSplitter.sol";
import {ForgeAsh, IAshForgeLedger} from "../src/yield/ForgeAsh.sol";
import {SealedPotStream} from "../src/yield/SealedPotStream.sol";
import {MockERC20, MockDecimalsERC20} from "./utils/MockERC20.sol";
import {MockMeasures, SeedMeasures} from "./utils/SplitterMocks.sol";

/// @dev The four splitters on real Forge pools (owners and listings), real ASH (token and ledger)
///      and a mock measures source standing in for ForgeEmissions' settled epochs.
abstract contract SplitterRig is Test {
    using ForgeView for ForgePool;

    uint256 internal constant T0 = 1_800_000_000;
    uint256 internal constant IDS = 3;
    uint256 internal constant WALLETS = 6;
    uint256 internal constant EPOCHS = 6;

    address internal keeper = makeAddr("keeper");
    address internal stranger = makeAddr("stranger");

    struct World {
        MockERC20 ember;
        MockDecimalsERC20 usdc;
        AshToken ash;
        AshLedger ledger;
        ForgePool[4] pools;
        MockMeasures measures;
        EpochSplitter[4] s; // ForgeAsh, stayers, Quote yield, Sealed pot
    }

    function _wallet(uint256 i) internal returns (address) {
        return makeAddr(string.concat("staker", vm.toString(i)));
    }

    function _ownerOf(uint256 pool, uint256 id) internal pure returns (uint256) {
        return (pool * IDS + id - 1) % WALLETS;
    }

    function _world(uint256 start) internal returns (World memory w) {
        w.ember = new MockERC20("Ember", "EMBER");
        w.usdc = new MockDecimalsERC20("USD Coin", "USDC", 6);
        bool[4] memory isLp = [P.FORGE_POOL_0_IS_LP, P.FORGE_POOL_1_IS_LP, P.FORGE_POOL_2_IS_LP, P.FORGE_POOL_3_IS_LP];
        for (uint256 i; i < 4; ++i) {
            MockERC20 stake = new MockERC20("Stake", "STK");
            w.pools[i] = new ForgePool(IERC20(address(stake)), isLp[i], makeAddr("fees"), makeAddr("boost"), address(this), address(0), address(0), address(0), address(0), address(0));
            for (uint256 id = 1; id <= IDS; ++id) {
                address owner = _wallet(_ownerOf(i, id));
                stake.mint(owner, 10e18);
                vm.startPrank(owner);
                stake.approve(address(w.pools[i]), 10e18);
                assertEq(w.pools[i].open(10e18), id, "position ids 1..3");
                vm.stopPrank();
            }
        }
        w.measures = new MockMeasures(start, w.pools, w.ember);
        IEpochMeasures m = IEpochMeasures(address(w.measures));
        uint256 n = vm.getNonce(address(this));
        address ledgerAt = vm.computeCreateAddress(address(this), n + 1);
        address forgeAshAt = vm.computeCreateAddress(address(this), n + 2);
        w.ash = new AshToken(ledgerAt);
        w.ledger = new AshLedger(IAshMint(address(w.ash)), stranger, stranger, forgeAshAt, start);
        w.s[0] = new ForgeAsh(m, IERC20(address(w.ash)), IAshForgeLedger(address(w.ledger)));
        assertEq(address(w.s[0]), forgeAshAt, "ForgeAsh predicted");
        w.s[1] = new BookedSplitter(m, EpochSplitter.Measure.Stake);
        w.s[2] = new BookedSplitter(m, EpochSplitter.Measure.Ashfall);
        w.s[3] = new SealedPotStream(m, IERC20(address(w.ember)));
        w.measures.setSealedPot(address(w.s[3]));
    }

    function _token(World memory w, uint256 t) internal pure returns (address) {
        return t == 0 ? address(w.ember) : t == 1 ? address(w.usdc) : address(w.ash);
    }

    /// @dev The model's `measuresOf` (SeedMeasures).
    function _measuresOf(uint256 e, uint256 i, uint256 seed) internal pure returns (ForgeEmissions.Measure[] memory) {
        return SeedMeasures.measures(e, i, seed);
    }
}

contract SplittersTest is SplitterRig {
    using ForgeView for ForgePool;

    // ── the BigInt model's scenarios, replayed exactly ────────────────────

    function test_scenario_forgeAsh() public {
        _replayAt(0);
    }

    function test_scenario_rolls() public {
        _replayAt(1);
    }

    function test_scenario_stayers() public {
        _replayAt(2);
    }

    function test_scenario_quoteYield() public {
        _replayAt(3);
    }

    function test_scenario_sealedPot() public {
        _replayAt(4);
    }

    function test_scenario_listed() public {
        _replayAt(5);
    }

    function test_scenario_walk0() public {
        _replayAt(6);
    }

    function test_scenario_walk1() public {
        _replayAt(7);
    }

    function test_scenario_walk2() public {
        _replayAt(8);
    }

    function test_scenario_walk3() public {
        _replayAt(9);
    }

    function test_everyScenarioHasATest() public view {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/contracts/test/fixtures/splitter-vectors.json"));
        assertEq(vm.parseUint(vm.parseJsonString(json, ".epoch")), P.EPOCH_SECONDS, "vectors from this config");
        assertEq(vm.parseUint(vm.parseJsonString(json, ".stream")), P.SEALED_POT_STREAM_EPOCHS, "vectors from this config");
        assertTrue(vm.keyExistsJson(json, ".scenarios[9]"));
        assertFalse(vm.keyExistsJson(json, ".scenarios[10]"), "a scenario without a test");
    }

    struct Cols {
        uint256[] kind;
        string[] a;
        string[] b;
        string[] c;
        string[] why;
        string[] out0;
        string[] hash;
    }

    function _replayAt(uint256 n) internal {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/contracts/test/fixtures/splitter-vectors.json"));
        string memory base = string.concat(".scenarios[", vm.toString(n), "]");
        uint256 start = vm.parseUint(vm.parseJsonString(json, string.concat(base, ".start")));
        vm.warp(start - 3600);
        World memory w = _world(start);
        Cols memory c;
        c.kind = vm.parseJsonUintArray(json, string.concat(base, ".kind"));
        c.a = vm.parseJsonStringArray(json, string.concat(base, ".a"));
        c.b = vm.parseJsonStringArray(json, string.concat(base, ".b"));
        c.c = vm.parseJsonStringArray(json, string.concat(base, ".c"));
        c.why = vm.parseJsonStringArray(json, string.concat(base, ".why"));
        c.out0 = vm.parseJsonStringArray(json, string.concat(base, ".out0"));
        c.hash = vm.parseJsonStringArray(json, string.concat(base, ".hash"));
        string memory name = vm.parseJsonString(json, string.concat(base, ".name"));
        for (uint256 i; i < c.kind.length; ++i) {
            string memory at = string.concat(name, " step ", vm.toString(i));
            (bool ok, uint256 out, bytes memory ret) =
                _act(w, c.kind[i], vm.parseUint(c.a[i]), vm.parseUint(c.b[i]), vm.parseUint(c.c[i]));
            if (bytes(c.why[i]).length != 0) {
                assertFalse(ok, string.concat(at, ": expected ", c.why[i]));
                assertEq(bytes4(ret), bytes4(keccak256(bytes(string.concat(c.why[i], _args(c.why[i]))))), at);
            } else {
                if (!ok) emit log_named_bytes("revert", ret);
                assertTrue(ok, string.concat(at, ": reverted"));
                assertEq(out, vm.parseUint(c.out0[i]), string.concat(at, ": output"));
            }
            assertEq(keccak256(abi.encodePacked(_words(w))), vm.parseBytes32(c.hash[i]), string.concat(at, ": state"));
        }
    }

    function _args(string memory why) internal pure returns (string memory) {
        bytes32 h = keccak256(bytes(why));
        if (h == keccak256("NotSettled") || h == keccak256("NotEmpty") || h == keccak256("Listed")) return "(uint256,uint256)";
        if (h == keccak256("AlreadyRolled")) return "(uint256,uint256,address)";
        if (h == keccak256("NothingOwed")) return "(uint256,uint256,uint256,address)";
        if (h == keccak256("NothingToBook")) return "(address)";
        if (h == keccak256("NothingToPull")) return "(uint256)";
        return "()";
    }

    /// @dev One model action: 0 warp, 1 settle, 2 gift, 3 book, 4 claim, 5 claimMany, 6 roll,
    ///      7 fund a pot, 8 pull, 9 list, 10 unlist, 11 the ledger's release.
    function _act(World memory w, uint256 kind, uint256 a, uint256 b, uint256 cc)
        internal
        returns (bool ok, uint256 out, bytes memory ret)
    {
        ok = true;
        if (kind >= 4 && kind <= 6) return _splitterAct(w, kind, a, b);
        if (kind == 0) {
            vm.warp(block.timestamp + a);
        } else if (kind == 1) {
            w.measures.settle(a, b, _measuresOf(a, b, cc));
        } else if (kind == 2) {
            MockERC20(_token(w, b)).mint(address(w.s[a]), cc);
        } else if (kind == 3) {
            vm.prank(keeper);
            (ok, ret) = address(w.s[a]).call(abi.encodeCall(BookedSplitter.book, (_token(w, b))));
            if (ok) out = abi.decode(ret, (uint256));
        } else if (kind == 7) {
            w.measures.fundPot(a, b);
        } else if (kind == 8) {
            vm.prank(keeper);
            (ok, ret) = address(w.s[3]).call(abi.encodeCall(SealedPotStream.pull, (a)));
            if (ok) out = abi.decode(ret, (uint256));
        } else if (kind == 9) {
            if (w.pools[a].listingOf(b) & 1 == 0) w.pools[a].list(b, w.pools[a].ownerOf(b));
        } else if (kind == 10) {
            if (w.pools[a].listingOf(b) & 1 == 1) w.pools[a].unlist(b);
        } else {
            vm.prank(keeper);
            (ok, ret) = address(w.ledger).call(abi.encodeCall(AshLedger.releaseForge, ()));
            if (ok) out = abi.decode(ret, (uint256));
        }
    }

    /// @dev Claims, pages and rolls: `a` packs splitter | token << 4 | pool << 8 | id << 12.
    function _splitterAct(World memory w, uint256 kind, uint256 a, uint256 b)
        internal
        returns (bool ok, uint256 out, bytes memory ret)
    {
        address sp = address(w.s[a & 0xf]);
        address tok = _token(w, (a >> 4) & 0xf);
        bytes memory data;
        if (kind == 4) {
            data = abi.encodeCall(EpochSplitter.claim, (b, (a >> 8) & 0xf, (a >> 12) & 0xf, tok));
        } else if (kind == 5) {
            data = abi.encodeCall(EpochSplitter.claimMany, (_epochs(b), (a >> 8) & 0xf, (a >> 12) & 0xf, tok));
        } else {
            data = abi.encodeCall(EpochSplitter.roll, (b, (a >> 8) & 0xf, tok));
        }
        vm.prank(keeper);
        (ok, ret) = sp.call(data);
        if (ok) out = abi.decode(ret, (uint256));
    }

    function _epochs(uint256 mask) internal pure returns (uint256[] memory epochs) {
        uint256 count;
        for (uint256 e; e < 8; ++e) if ((mask >> e) & 1 == 1) ++count;
        epochs = new uint256[](count);
        count = 0;
        for (uint256 e; e < 8; ++e) if ((mask >> e) & 1 == 1) epochs[count++] = e;
    }

    /// @dev The model's `words()`, in its exact order.
    function _words(World memory w) internal returns (uint256[] memory x) {
        x = new uint256[](4 * (6 + EPOCHS * 4 * 3 * 3) + WALLETS * 3 + 6);
        uint256 n;
        for (uint256 k; k < 4; ++k) {
            EpochSplitter sp = w.s[k];
            for (uint256 t; t < 3; ++t) x[n++] = sp.liability(_token(w, t));
            for (uint256 t; t < 3; ++t) x[n++] = IERC20(_token(w, t)).balanceOf(address(sp));
            for (uint256 e; e < EPOCHS; ++e) {
                for (uint256 i; i < 4; ++i) {
                    for (uint256 t; t < 3; ++t) {
                        address tok = _token(w, t);
                        x[n++] = sp.budgetOf(e, i, tok);
                        x[n++] = sp.paidOut(e, i, tok);
                        x[n++] = sp.rolled(e, i, tok) ? 1 : 0;
                    }
                }
            }
        }
        for (uint256 j; j < WALLETS; ++j) {
            for (uint256 t; t < 3; ++t) x[n++] = IERC20(_token(w, t)).balanceOf(_wallet(j));
        }
        x[n++] = w.ledger.forgeReleased();
        x[n++] = w.ash.totalSupply();
        for (uint256 i; i < 4; ++i) x[n++] = w.measures.pot(i);
        assertEq(n, x.length, "words");
    }

    // ── unit tests ────────────────────────────────────────────────────────

    function test_forgeAshSlicesSumToExactlyTheForgeAllocation() public {
        World memory w = _world(T0);
        ForgeAsh fa = ForgeAsh(address(w.s[0]));
        uint256 days_ = P.ASH_FORGE_VESTING / P.EPOCH_SECONDS;
        uint256 sum;
        for (uint256 e; e <= days_; ++e) sum += fa.sliceOf(e);
        assertEq(sum, P.ASH_FORGE_ALLOCATION, "730 slices are the whole 28,000, to the wei");
        assertEq(fa.sliceOf(days_ + 1), 0, "nothing after the vesting");
        // By pool: 500/200/300/0 of each slice, floored.
        assertEq(fa.budgetOf(0, 0, address(w.ash)), (fa.sliceOf(0) * 500) / 1000);
        assertEq(fa.budgetOf(0, 2, address(w.ash)), (fa.sliceOf(0) * 300) / 1000);
        assertEq(fa.budgetOf(0, 3, address(w.ash)), 0, "Cold Storage earns no ASH");
        assertEq(fa.budgetOf(0, 0, address(w.ember)), 0, "ForgeAsh pays only ASH");
    }

    function test_forgeAshReleasesOnlyWhatHasVested() public {
        World memory w = _world(T0);
        vm.warp(T0 + P.EPOCH_SECONDS);
        w.measures.settle(0, 0, _measuresOf(0, 0, 1));
        uint256 share = w.s[0].shareOf(0, 0, 1, address(w.ash));
        vm.prank(stranger);
        uint256 paid = w.s[0].claim(0, 0, 1, address(w.ash));
        assertEq(paid, share, "the view showed exactly what the claim paid");
        assertEq(w.s[0].shareOf(0, 0, 1, address(w.ash)), 0, "nothing left to show once claimed");
        assertEq(IERC20(address(w.ash)).balanceOf(_wallet(_ownerOf(0, 1))), paid, "paid to the owner, not the caller");
        assertEq(IERC20(address(w.ash)).balanceOf(stranger), 0);
        assertEq(w.ledger.forgeReleased(), w.ledger.vestedAt(block.timestamp), "released exactly V(now)");
        assertLe(w.ledger.forgeReleased(), P.ASH_FORGE_ALLOCATION);
    }

    function test_aBookingSplitsByTheBaseWeights() public {
        World memory w = _world(T0);
        vm.warp(T0 + 3 * P.EPOCH_SECONDS + 5);
        w.ember.mint(address(w.s[1]), 2_000);
        assertEq(BookedSplitter(address(w.s[1])).book(address(w.ember)), 2_000);
        address e = address(w.ember);
        (uint256 b0, uint256 b1, uint256 b2, uint256 b3) =
            (w.s[1].budgetOf(3, 0, e), w.s[1].budgetOf(3, 1, e), w.s[1].budgetOf(3, 2, e), w.s[1].budgetOf(3, 3, e));
        assertEq(b0, 1_000);
        assertEq(b1, 400);
        assertEq(b2, 400);
        assertEq(b3, 200, "1000/400/400/200, into the epoch now running");
        assertEq(w.s[1].liability(e), 2_000);
        vm.expectRevert(abi.encodeWithSelector(BookedSplitter.NothingToBook.selector, e));
        BookedSplitter(address(w.s[1])).book(e);
    }

    function test_theSealedPotStreamsEvenlyOverThirtyEpochs() public {
        World memory w = _world(T0);
        vm.warp(T0 + 2 * P.EPOCH_SECONDS);
        w.measures.fundPot(1, 30_029);
        assertEq(SealedPotStream(address(w.s[3])).pull(1), 30_029);
        address e = address(w.ember);
        for (uint256 k; k < 29; ++k) assertEq(w.s[3].budgetOf(2 + k, 1, e), 1_000);
        assertEq(w.s[3].budgetOf(31, 1, e), 1_029, "the floor's remainder on the last");
        assertEq(w.s[3].budgetOf(32, 1, e), 0);
        assertEq(w.s[3].budgetOf(1, 1, e), 0, "nothing before the pull");
    }

    /// A rolled budget is spent: it pays nobody in its own epoch, even if its source later reports
    /// measures there. ForgeEmissions never changes a settled epoch; the guard holds without it.
    function test_aRolledBudgetIsNeverAlsoPaid() public {
        World memory w = _world(T0);
        address e = address(w.ember);
        vm.warp(T0 + 1);
        w.ember.mint(address(w.s[1]), 2_000);
        BookedSplitter(address(w.s[1])).book(e);
        vm.warp(T0 + P.EPOCH_SECONDS);
        w.measures.settle(0, 0, _measuresOf(0, 0, 1 << 16)); // nobody earned in pool 0
        assertEq(w.s[1].roll(0, 0, e), 1_000);
        assertEq(w.s[1].budgetOf(1, 0, e), 1_000, "the next epoch carries it");
        w.measures.settle(0, 0, _measuresOf(0, 0, 1)); // a source that rewrites a settled epoch
        assertEq(w.s[1].shareOf(0, 0, 1, e), 0, "no share of a rolled budget");
        vm.expectRevert(abi.encodeWithSelector(EpochSplitter.NothingOwed.selector, 0, 0, 1, e));
        w.s[1].claim(0, 0, 1, e);
        uint256[] memory epochs = new uint256[](1);
        assertEq(w.s[1].claimMany(epochs, 0, 1, e), 0);
        assertEq(IERC20(e).balanceOf(address(w.s[1])), 2_000, "nothing left the splitter");
        assertEq(w.s[1].liability(e), 2_000);
    }

    function test_constructorsRefuseZeroInputs() public {
        World memory w = _world(T0);
        IEpochMeasures m = IEpochMeasures(address(w.measures));
        vm.expectRevert(EpochSplitter.ZeroAddress.selector);
        new BookedSplitter(IEpochMeasures(address(0)), EpochSplitter.Measure.Stake);
        vm.expectRevert(EpochSplitter.ZeroAddress.selector);
        new ForgeAsh(m, IERC20(address(0)), IAshForgeLedger(address(w.ledger)));
        vm.expectRevert(EpochSplitter.ZeroAddress.selector);
        new ForgeAsh(m, IERC20(address(w.ash)), IAshForgeLedger(address(0)));
        vm.expectRevert(EpochSplitter.ZeroAddress.selector);
        new SealedPotStream(m, IERC20(address(0)));
        vm.expectRevert(EpochSplitter.ZeroAddress.selector);
        BookedSplitter(address(w.s[1])).book(address(0));
    }

    function test_sharesSumToAtMostTheBudget(uint256 seed, uint96 amount) public {
        World memory w = _world(T0);
        vm.warp(T0 + 1);
        w.usdc.mint(address(w.s[2]), uint256(amount) + 1);
        BookedSplitter(address(w.s[2])).book(address(w.usdc));
        vm.warp(T0 + P.EPOCH_SECONDS);
        for (uint256 i; i < 4; ++i) w.measures.settle(0, i, _measuresOf(0, i, seed % (1 << 16)));
        for (uint256 i; i < 4; ++i) {
            uint256 paid;
            for (uint256 id = 1; id <= IDS; ++id) paid += w.s[2].shareOf(0, i, id, address(w.usdc));
            assertLe(paid, w.s[2].budgetOf(0, i, address(w.usdc)), "never more than the budget");
            assertGe(paid + IDS, w.s[2].budgetOf(0, i, address(w.usdc)), "less only by the floors");
        }
    }

    // ── gas (pnpm gas, isolated) ──────────────────────────────────────────

    function test_gas_splitters() public {
        World memory w = _world(T0);
        vm.warp(T0 + 1);
        w.usdc.mint(address(w.s[1]), 1e12);
        uint256 g = gasleft();
        BookedSplitter(address(w.s[1])).book(address(w.usdc));
        emit log_named_uint("book (four pools)", g - gasleft());
        w.measures.fundPot(0, 3e21);
        g = gasleft();
        SealedPotStream(address(w.s[3])).pull(0);
        emit log_named_uint("pull (a 30-epoch stream)", g - gasleft());
        vm.warp(T0 + P.EPOCH_SECONDS);
        for (uint256 i; i < 4; ++i) w.measures.settle(0, i, _measuresOf(0, i, 7));
        g = gasleft();
        w.s[0].claim(0, 0, 1, address(w.ash));
        emit log_named_uint("ForgeAsh claim (releases from the ledger)", g - gasleft());
        g = gasleft();
        w.s[0].claim(0, 0, 2, address(w.ash));
        emit log_named_uint("ForgeAsh claim", g - gasleft());
        g = gasleft();
        w.s[1].claim(0, 0, 1, address(w.usdc));
        emit log_named_uint("stayers claim", g - gasleft());
    }
}
