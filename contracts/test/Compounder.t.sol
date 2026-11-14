// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {EmberPair} from "../src/pairs/EmberPair.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {ForgeView} from "../src/forge/ForgeView.sol";
import {Lot} from "../src/forge/ForgeMeasures.sol";
import {Compounder, ICastLedger, IMatchVent} from "../src/match/Compounder.sol";
import {MockERC20, MockDecimalsERC20} from "./utils/MockERC20.sol";
import {MockCastLedger, MockMatchVent} from "./utils/CompounderMocks.sol";

using ForgeView for ForgePool;

/// @dev The Compounder's world: mock EMBER, 6-decimal USDC and WETH; two real EmberPairs this
///      contract initializes (and whose LP it hands to wallets); two real LP Forge pools whose
///      COMPOUNDER is the Compounder and whose DEEDS is this contract; a mock cast ledger and a mock
///      Vent lane; a plain address as the permanent sink.
abstract contract CompounderRig is Test {
    uint256 internal constant T0 = 1_800_000_000;
    uint256 internal constant WALLETS = 4;
    uint256 internal constant MAX_POSITIONS = 4;
    uint256 internal constant EPOCHS = 12;

    struct World {
        MockERC20 ember;
        MockERC20 usdc;
        MockERC20 weth;
        EmberPair[2] pairs;
        ForgePool[2] pools;
        MockCastLedger ledger;
        MockMatchVent vent;
        Compounder c;
        address sink;
    }

    address internal trader = makeAddr("trader");

    function _wallet(uint256 w) internal pure returns (address) {
        return address(uint160(0x5000 + w));
    }

    function _world() internal returns (World memory w) {
        w.ember = new MockERC20("Ember", "EMBER");
        w.usdc = new MockDecimalsERC20("USD Coin", "USDC", 6);
        w.weth = new MockERC20("Wrapped Ether", "WETH");
        w.sink = makeAddr("sink");
        w.ledger = new MockCastLedger(w.ember, T0);
        w.vent = new MockMatchVent(w.usdc, w.weth);
        address fees = makeAddr("fees");
        w.pairs[0] = new EmberPair("BlastPool LP", "BLP", w.ember, w.usdc, fees, address(0), address(0), address(this));
        w.pairs[1] = new EmberPair("SmelterPool LP", "SLP", w.ember, w.weth, fees, address(0), address(0), address(this));
        address at = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        for (uint256 j; j < 2; ++j) {
            w.pools[j] = new ForgePool(
                IERC20(address(w.pairs[j])), true, fees, makeAddr("boost"), address(this), address(0), at, address(0), address(0), address(0)
            );
        }
        w.c = new Compounder(
            IERC20(address(w.ember)), ICastLedger(address(w.ledger)), IMatchVent(address(w.vent)), w.sink, w.pairs, w.pools, T0
        );
        require(address(w.c) == at, "prediction");
        w.ledger.setConsumer(at);
        w.vent.setConsumer(at);
        _init(w, 0, 100_000e18, 50_000e6);
        _init(w, 1, 100_000e18, 25e18);
    }

    function _init(World memory w, uint256 j, uint256 e, uint256 q) internal {
        w.ember.mint(address(this), e);
        MockERC20(address(w.pairs[j].QUOTE())).mint(address(this), q);
        w.ember.approve(address(w.pairs[j]), e);
        w.pairs[j].QUOTE().approve(address(w.pairs[j]), q);
        w.pairs[j].addLiquidity(e, q, 0, 0, address(this));
    }
}

/// @notice Exact replay of scripts/compounder-model.ts: every output, every revert selector and a
///         hash of the whole state after every step.
contract CompounderTest is CompounderRig {
    enum K {
        Warp,
        Checkpoint,
        Swap,
        Open,
        Deposit,
        Request,
        Emergency,
        List,
        Unlist,
        Credit,
        Settle,
        Forfeit,
        Fund,
        Refill,
        PullForfeits,
        FundSeed,
        Freeze,
        Cast,
        Close,
        AutoPair
    }

    string internal json;
    World internal w;

    function setUp() public {
        json = vm.readFile(string.concat(vm.projectRoot(), "/contracts/test/fixtures/compounder-vectors.json"));
    }

    function test_everyScenarioHasATest() public view {
        assertEq(vm.parseUint(vm.parseJsonString(json, ".t0")), T0, "the model's start");
        assertEq(vm.parseUint(vm.parseJsonString(json, ".castPct")), P.CASTING_LP_SHARE_PCT);
        assertEq(vm.parseUint(vm.parseJsonString(json, ".reservationEpochs")), P.MATCH_RESERVATION_EPOCHS);
        assertEq(vm.parseUint(vm.parseJsonString(json, ".idleEpochs")), P.IDLE_EPOCHS_BEFORE_AUTO_PAIR);
        assertTrue(vm.keyExistsJson(json, ".scenarios[9]"));
        assertFalse(vm.keyExistsJson(json, ".scenarios[10]"), "a scenario without a test");
    }

    function test_scenario_covered() public {
        _replayAt(0);
    }

    function test_scenario_partial() public {
        _replayAt(1);
    }

    function test_scenario_drift() public {
        _replayAt(2);
    }

    function test_scenario_lots() public {
        _replayAt(3);
    }

    function test_scenario_expiry() public {
        _replayAt(4);
    }

    function test_scenario_idle() public {
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

    struct Cols {
        uint256[] kind;
        string[] a;
        string[] b;
        string[] c;
        string[] d;
        string[] why;
        string[] out;
        string[] hash;
    }

    function _replayAt(uint256 n) internal {
        string memory base = string.concat(".scenarios[", vm.toString(n), "]");
        vm.warp(T0);
        w = _world();
        Cols memory c;
        c.kind = vm.parseJsonUintArray(json, string.concat(base, ".kind"));
        c.a = vm.parseJsonStringArray(json, string.concat(base, ".a"));
        c.b = vm.parseJsonStringArray(json, string.concat(base, ".b"));
        c.c = vm.parseJsonStringArray(json, string.concat(base, ".c"));
        c.d = vm.parseJsonStringArray(json, string.concat(base, ".d"));
        c.why = vm.parseJsonStringArray(json, string.concat(base, ".why"));
        c.out = vm.parseJsonStringArray(json, string.concat(base, ".out"));
        c.hash = vm.parseJsonStringArray(json, string.concat(base, ".hash"));
        string memory name = vm.parseJsonString(json, string.concat(base, ".name"));
        for (uint256 i; i < c.kind.length; ++i) {
            string memory at = string.concat(name, " step ", vm.toString(i));
            uint256[4] memory x = [vm.parseUint(c.a[i]), vm.parseUint(c.b[i]), vm.parseUint(c.c[i]), vm.parseUint(c.d[i])];
            (bool ok, bytes memory ret) = address(this).call(abi.encodeCall(this.step, (K(c.kind[i]), x)));
            if (bytes(c.why[i]).length != 0) {
                assertFalse(ok, string.concat(at, ": expected ", c.why[i]));
                assertEq(bytes4(ret), _selector(K(c.kind[i]), c.why[i]), string.concat(at, ": ", c.why[i]));
            } else {
                if (!ok) emit log_named_bytes("revert", ret);
                assertTrue(ok, string.concat(at, ": reverted"));
                assertEq(abi.decode(ret, (uint256)), vm.parseUint(c.out[i]), string.concat(at, ": output"));
            }
            assertEq(this.stateHash(), vm.parseBytes32(c.hash[i]), string.concat(at, ": state"));
        }
    }

    /// @dev One scenario action, as one external call so a revert undoes all of it.
    function step(K k, uint256[4] memory x) external returns (uint256 out) {
        require(msg.sender == address(this));
        if (k == K.Warp) vm.warp(block.timestamp + x[0]);
        else if (k == K.Checkpoint) w.pairs[x[0]].checkpoint();
        else if (k == K.Swap) out = _swap(x[0], x[1] == 1, x[2]);
        else if (k == K.Open) out = _open(x[0], x[1], x[2]);
        else if (k == K.Deposit) _deposit(x[0], x[1], x[2]);
        else if (k == K.Request) {
            vm.prank(w.pools[x[0]].positionOf(x[1]).owner);
            out = w.pools[x[0]].requestCooling(x[1], x[2]);
        } else if (k == K.Emergency) {
            vm.prank(w.pools[x[0]].positionOf(x[1]).owner);
            out = w.pools[x[0]].emergencyExit(x[1]);
        } else if (k == K.List) {
            out = w.pools[x[0]].list(x[1], w.pools[x[0]].positionOf(x[1]).owner);
        } else if (k == K.Unlist) {
            w.pools[x[0]].unlist(x[1]);
        } else if (k == K.Credit) {
            w.ledger.credit(x[0], x[1], x[2], x[3]);
        } else if (k == K.Settle) {
            w.ledger.settle(x[0], x[1]);
        } else if (k == K.Forfeit) {
            w.ledger.forfeit(x[0]);
        } else if (k == K.Fund) {
            w.vent.fund(x[0], x[1]);
        } else if (k == K.Refill) {
            out = w.c.refill(x[0]);
        } else if (k == K.PullForfeits) {
            out = w.c.pullForfeits();
        } else if (k == K.FundSeed) {
            w.ember.mint(address(this), x[0]);
            w.ember.approve(address(w.c), x[0]);
            w.c.fundSeed(x[0]);
        } else if (k == K.Freeze) {
            out = w.c.freeze(x[0], x[1]);
        } else if (k == K.Cast) {
            out = w.c.cast(x[0], x[1], x[2]);
        } else if (k == K.Close) {
            out = w.c.close(x[0], x[1]);
        } else {
            out = w.c.autoPair(x[0]);
        }
    }

    function _swap(uint256 j, bool buy, uint256 amount) internal returns (uint256) {
        EmberPair pair = w.pairs[j];
        IERC20 tokenIn = buy ? pair.QUOTE() : pair.EMBER();
        MockERC20(address(tokenIn)).mint(trader, amount);
        vm.prank(trader);
        tokenIn.approve(address(pair), amount);
        // One-call pranks only: a prank that a reverting call leaves set would outlive the step.
        vm.prank(trader);
        return buy ? pair.buy(amount, 0, trader) : pair.sell(amount, 0, trader);
    }

    function _open(uint256 i, uint256 wallet, uint256 lp) internal returns (uint256 id) {
        address who = _wallet(wallet);
        IERC20(address(w.pairs[i])).transfer(who, lp);
        vm.prank(who);
        IERC20(address(w.pairs[i])).approve(address(w.pools[i]), lp);
        vm.prank(who);
        id = w.pools[i].open(lp);
    }

    function _deposit(uint256 i, uint256 id, uint256 lp) internal {
        address who = w.pools[i].positionOf(id).owner;
        IERC20(address(w.pairs[i])).transfer(who, lp);
        vm.prank(who);
        IERC20(address(w.pairs[i])).approve(address(w.pools[i]), lp);
        vm.prank(who);
        w.pools[i].deposit(id, lp);
    }

    /// @dev The selector each model reason names, by where the action reverts.
    function _selector(K k, string memory why) internal pure returns (bytes4) {
        bytes32 h = keccak256(bytes(why));
        if (k == K.Swap) return bytes4(keccak256(bytes(string.concat(why, "()"))));
        if (k == K.Credit || k == K.Settle) return bytes4(keccak256(bytes(string.concat(why, "()"))));
        if (k >= K.Open && k <= K.Unlist) {
            if (h == keccak256("BelowMinimum")) return bytes4(keccak256("BelowMinimum(uint256)"));
            return bytes4(keccak256(bytes(string.concat(why, "(uint256)"))));
        }
        string memory args;
        if (h == keccak256("ZeroAmount")) args = "()";
        else if (h == keccak256("UnknownPool") || h == keccak256("Expired") || h == keccak256("NoOracle")) args = "(uint256)";
        else if (h == keccak256("NothingToPair")) args = "(uint256)";
        else if (h == keccak256("NothingToCast") || h == keccak256("AlreadyCast") || h == keccak256("OutOfBand")) {
            args = "(uint256,uint256,uint256)";
        } else {
            args = "(uint256,uint256)"; // NotSettled, AlreadyFrozen, NotFrozen, NotExpired, Listed, StaleOracle, NotIdle
        }
        return bytes4(keccak256(bytes(string.concat(why, args))));
    }

    /// @dev External, so each step's words get fresh memory.
    function stateHash() external view returns (bytes32) {
        return keccak256(abi.encodePacked(_words()));
    }

    /// @dev Mirror of CompounderModel.words().
    function _words() internal view returns (uint256[] memory out) {
        out = new uint256[](4096);
        uint256 n;
        for (uint256 j; j < 2; ++j) {
            EmberPair pair = w.pairs[j];
            (uint112 rE, uint112 rQ,) = pair.getReserves();
            Compounder.Reserve memory r = w.c.reserveOf(j);
            (out[n], out[n + 1], out[n + 2], out[n + 3], out[n + 4]) = (rE, rQ, pair.totalSupply(), r.free, r.reserved);
            (out[n + 5], out[n + 6], out[n + 7]) = (r.lastActiveEpoch, w.vent.lanes(j), pair.QUOTE().balanceOf(address(w.c)));
            (out[n + 8], out[n + 9]) = (pair.balanceOf(w.sink), pair.balanceOf(address(this)));
            n += 10;
        }
        (out[n], out[n + 1], out[n + 2], out[n + 3]) =
            (w.c.seed(), w.ember.balanceOf(address(w.c)), w.ember.balanceOf(address(w.ledger)), w.ledger.forfeits());
        n += 4;
        for (uint256 e; e < EPOCHS; ++e) {
            for (uint256 i; i < 2; ++i) n = _budgetWords(out, n, e, i);
        }
        for (uint256 i; i < 2; ++i) n = _poolWords(out, n, i);
        assembly ("memory-safe") {
            mstore(out, n)
        }
    }

    function _budgetWords(uint256[] memory out, uint256 n, uint256 e, uint256 i) internal view returns (uint256) {
        Compounder.Budget memory b = w.c.budgetOf(e, i);
        (out[n], out[n + 1], out[n + 2], out[n + 3]) = (w.ledger.demand(e, i), w.ledger.done(e, i) ? 1 : 0, b.need, b.budget);
        (out[n + 4], out[n + 5], out[n + 6]) = (b.remaining, b.frozen ? 1 : 0, b.closed ? 1 : 0);
        n += 7;
        for (uint256 id = 1; id <= MAX_POSITIONS; ++id) {
            (out[n], out[n + 1]) = (w.ledger.share(e, i, id), w.ledger.castTaken(e, i, id) ? 1 : 0);
            n += 2;
        }
        return n;
    }

    function _poolWords(uint256[] memory out, uint256 n, uint256 i) internal view returns (uint256) {
        ForgePool pool = w.pools[i];
        uint256 count = pool.positionCount();
        (out[n], out[n + 1], out[n + 2]) = (pool.activePrincipal(), pool.frozenPrincipal(), count);
        n += 3;
        for (uint256 id = 1; id <= MAX_POSITIONS; ++id) {
            out[n++] = w.ledger.unclaimed(i, id);
            if (id > count) {
                (out[n], out[n + 1]) = (0, 0);
                n += 2;
                continue;
            }
            bool closed = pool.positionOf(id).closedAt != 0;
            (out[n], out[n + 1]) = (closed ? 1 : 0, pool.positionOf(id).listing % 2);
            n += 2;
            if (closed) continue;
            for (uint256 s; s < 32; ++s) {
                Lot memory l = pool.lotOf(id, s);
                out[n] = l.amount;
                out[n + 1] = l.amount == 0 ? 0 : Math.min(l.age + (block.timestamp - l.since), P.HEAT_AGE_CAP);
                n += 2;
            }
        }
        return n;
    }
}

/// @notice The Compounder's properties, one at a time.
contract CompounderUnitTest is CompounderRig {
    World internal w;
    address internal alice = _wallet(0);
    address internal bob = _wallet(1);

    function setUp() public {
        vm.warp(T0);
        w = _world();
    }

    function _open(uint256 i, address who, uint256 lp) internal returns (uint256 id) {
        IERC20(address(w.pairs[i])).transfer(who, lp);
        vm.prank(who);
        IERC20(address(w.pairs[i])).approve(address(w.pools[i]), lp);
        vm.prank(who);
        id = w.pools[i].open(lp);
    }

    /// Both pairs observe now and again 30 minutes later: a fresh TWAP.
    function _twap() internal {
        w.pairs[0].checkpoint();
        w.pairs[1].checkpoint();
        vm.warp(block.timestamp + P.PAIR_TWAP_SECONDS);
        w.pairs[0].checkpoint();
        w.pairs[1].checkpoint();
    }

    /// Epoch 0 earns `share` for position `id` of pool 0, settles, and is frozen against `funding`.
    function _frozen(uint256 id, uint256 share, uint256 funding) internal {
        w.ledger.credit(0, 0, id, share);
        vm.warp(T0 + 1 days);
        w.ledger.settle(0, 0);
        if (funding != 0) w.vent.fund(0, funding);
        _twap();
        w.c.freeze(0, 0);
    }

    function test_constructorRefusesZeroAddresses() public {
        IERC20 e = IERC20(address(w.ember));
        ICastLedger l = ICastLedger(address(w.ledger));
        IMatchVent v = IMatchVent(address(w.vent));
        EmberPair[2] memory noPair;
        ForgePool[2] memory noPool;
        vm.expectRevert(Compounder.ZeroAddress.selector);
        new Compounder(IERC20(address(0)), l, v, w.sink, w.pairs, w.pools, T0);
        vm.expectRevert(Compounder.ZeroAddress.selector);
        new Compounder(e, ICastLedger(address(0)), v, w.sink, w.pairs, w.pools, T0);
        vm.expectRevert(Compounder.ZeroAddress.selector);
        new Compounder(e, l, IMatchVent(address(0)), w.sink, w.pairs, w.pools, T0);
        vm.expectRevert(Compounder.ZeroAddress.selector);
        new Compounder(e, l, v, address(0), w.pairs, w.pools, T0);
        vm.expectRevert(Compounder.ZeroAddress.selector);
        new Compounder(e, l, v, w.sink, noPair, w.pools, T0);
        vm.expectRevert(Compounder.ZeroAddress.selector);
        new Compounder(e, l, v, w.sink, w.pairs, noPool, T0);
    }

    /// A covered share becomes LP in the lot that earned it, at that lot's age; the owner owns the
    /// LP, and only the rounding returns liquid.
    function test_aCoveredCastLandsInTheSourceLotAtItsAge() public {
        uint256 id = _open(0, alice, 1000e18);
        _frozen(id, 40e18, 1_000e6);
        Lot memory before = w.pools[0].lotOf(id, 0);
        uint256 ageBefore = before.age + (block.timestamp - before.since);
        uint256 lp = w.c.cast(0, 0, id);
        assertGt(lp, 0);
        Lot memory l = w.pools[0].lotOf(id, 0);
        assertEq(l.amount, before.amount + lp, "the LP is in the source lot");
        assertEq(l.age, ageBefore, "at the lot's own age");
        assertEq(w.pools[0].positionOf(id).owner, alice, "and the owner's");
        assertEq(IERC20(address(w.pairs[0])).balanceOf(address(w.c)), 0, "the Compounder keeps no LP");
        (uint112 rE, uint112 rQ,) = w.pairs[0].getReserves();
        assertLe(w.ledger.unclaimed(0, id), 2 * uint256(rE) / rQ, "only rounding returns liquid: a quote wei's worth");
        assertEq(w.c.reserveOf(0).reserved, 0, "the reservation is spent");
    }

    /// With nothing in the lane the budget is zero, and the whole share returns liquid: nothing is
    /// sold and no LP is formed.
    function test_aDryReserveReturnsTheWholeShare() public {
        uint256 id = _open(0, alice, 1000e18);
        _frozen(id, 40e18, 0);
        assertEq(w.c.budgetOf(0, 0).budget, 0);
        (uint112 rE, uint112 rQ,) = w.pairs[0].getReserves();
        assertEq(w.c.cast(0, 0, id), 0);
        assertEq(w.ledger.unclaimed(0, id), 40e18, "all of it, liquid");
        (uint112 rE2, uint112 rQ2,) = w.pairs[0].getReserves();
        assertEq(uint256(rE2), rE, "nothing was paired or sold");
        assertEq(uint256(rQ2), rQ);
    }

    /// Budgets are pro-rata: two shares of a short budget are covered in the same proportion.
    function test_aShortBudgetCoversEachShareProRata() public {
        uint256 a = _open(0, alice, 1000e18);
        uint256 b = _open(0, bob, 1000e18);
        w.ledger.credit(0, 0, a, 300e18);
        w.ledger.credit(0, 0, b, 100e18);
        vm.warp(T0 + 1 days);
        w.ledger.settle(0, 0);
        w.vent.fund(0, 40e6);
        _twap();
        w.c.freeze(0, 0);
        (, uint256 ea, uint256 qa) = w.c.reservationOf(0, 0, a);
        (, uint256 eb, uint256 qb) = w.c.reservationOf(0, 0, b);
        assertApproxEqAbs(ea, 3 * eb, 3, "EMBER covered pro-rata");
        assertApproxEqAbs(qa, 3 * qb, 3, "quote reserved pro-rata");
        assertLe(qa + qb, 40e6, "never more than the budget");
    }

    /// The source lot is the youngest active lot already open when the epoch ended; a deposit
    /// made after it is not one.
    function test_theSourceLotIsTheYoungestOpenAtTheEpochsEnd() public {
        uint256 id = _open(0, alice, 500e18);
        vm.warp(T0 + 6 hours);
        IERC20(address(w.pairs[0])).transfer(alice, 600e18);
        vm.prank(alice);
        IERC20(address(w.pairs[0])).approve(address(w.pools[0]), type(uint256).max);
        vm.prank(alice);
        w.pools[0].deposit(id, 300e18); // slot 1: younger, open at the epoch's end
        w.ledger.credit(0, 0, id, 20e18);
        vm.warp(T0 + 1 days + 1);
        vm.prank(alice);
        w.pools[0].deposit(id, 300e18); // slot 2: after the epoch ended
        w.ledger.settle(0, 0);
        w.vent.fund(0, 1_000e6);
        _twap();
        w.c.freeze(0, 0);
        uint256[3] memory before = [uint256(w.pools[0].lotOf(id, 0).amount), w.pools[0].lotOf(id, 1).amount, w.pools[0].lotOf(id, 2).amount];
        uint256 lp = w.c.cast(0, 0, id);
        assertEq(w.pools[0].lotOf(id, 0).amount, before[0]);
        assertEq(w.pools[0].lotOf(id, 1).amount, before[1] + lp, "the youngest source");
        assertEq(w.pools[0].lotOf(id, 2).amount, before[2], "not a lot opened after the epoch");
    }

    /// A stale oracle or a spot outside the band reverts the cast: nothing is released to anyone.
    function test_anUnsafeMarketReleasesNothing() public {
        uint256 id = _open(0, alice, 1000e18);
        _frozen(id, 40e18, 1_000e6);
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(abi.encodeWithSelector(Compounder.StaleOracle.selector, 0, 2 hours));
        w.c.cast(0, 0, id);
        _twap();
        MockERC20(address(w.usdc)).mint(address(this), 5_000e6);
        w.usdc.approve(address(w.pairs[0]), 5_000e6);
        w.pairs[0].buy(5_000e6, 0, address(this));
        vm.expectPartialRevert(Compounder.OutOfBand.selector);
        w.c.cast(0, 0, id);
        assertFalse(w.ledger.castTaken(0, 0, id), "the share waits");
        assertEq(w.ledger.unclaimed(0, id), 0);
        assertGt(w.c.reserveOf(0).reserved, 0, "and so does its quote");
    }

    /// After the window the share returns liquid and the budget's quote returns to the
    /// unreserved inventory, once.
    function test_expiryReturnsTheShareAndTheQuote() public {
        uint256 id = _open(0, alice, 1000e18);
        _frozen(id, 40e18, 1_000e6);
        uint256 reserved = w.c.reserveOf(0).reserved;
        uint256 free = w.c.reserveOf(0).free;
        vm.warp(w.c.expiresAt(0) - 1);
        vm.expectRevert(abi.encodeWithSelector(Compounder.NotExpired.selector, 0, w.c.expiresAt(0)));
        w.c.close(0, 0);
        vm.warp(w.c.expiresAt(0));
        assertEq(w.c.cast(0, 0, id), 0);
        assertEq(w.ledger.unclaimed(0, id), 40e18, "the reward is never confiscated");
        assertEq(w.c.reserveOf(0).reserved, 0);
        assertEq(w.c.reserveOf(0).free, free + reserved, "the quote is unreserved again");
        assertEq(w.c.close(0, 0), 0, "once");
    }

    /// The idle auto-pair spends only unreserved quote and funded seed EMBER; its LP is the sink's.
    function test_theIdleAutoPairNeverSpendsReservedQuote() public {
        uint256 id = _open(0, alice, 1000e18);
        _frozen(id, 40e18, 1_000e6);
        uint256 reserved = w.c.reserveOf(0).reserved;
        assertGt(reserved, 0);
        w.ember.mint(address(this), 100e18);
        w.ember.approve(address(w.c), 100e18);
        w.c.fundSeed(100e18);
        vm.expectRevert(abi.encodeWithSelector(Compounder.NotIdle.selector, 0, P.IDLE_EPOCHS_BEFORE_AUTO_PAIR));
        w.c.autoPair(0);
        vm.warp(T0 + P.IDLE_EPOCHS_BEFORE_AUTO_PAIR * 1 days);
        _twap();
        uint256 lp = w.c.autoPair(0);
        assertEq(IERC20(address(w.pairs[0])).balanceOf(w.sink), lp, "the LP is permanent");
        assertEq(w.c.reserveOf(0).reserved, reserved, "reserved quote untouched");
        assertEq(w.c.seed(), 0, "a short seed pairs what it covers");
        assertGt(w.c.reserveOf(0).free, 0, "and the rest of the quote waits");
        assertGt(w.c.cast(0, 0, id), 0, "the reservation still casts");
    }

    function test_gas_compounder() public {
        uint256 id = _open(0, alice, 1000e18);
        w.ledger.credit(0, 0, id, 40e18);
        vm.warp(T0 + 1 days);
        w.ledger.settle(0, 0);
        w.vent.fund(0, 1_000e6);
        _twap();
        uint256 g = gasleft();
        w.c.freeze(0, 0);
        emit log_named_uint("freeze (with refill)", g - gasleft());
        g = gasleft();
        w.c.cast(0, 0, id);
        emit log_named_uint("cast", g - gasleft());
        w.ember.mint(address(this), 100e18);
        w.ember.approve(address(w.c), 100e18);
        w.c.fundSeed(100e18);
        vm.warp(T0 + 9 days);
        _twap();
        g = gasleft();
        w.c.autoPair(0);
        emit log_named_uint("autoPair", g - gasleft());
    }
}
