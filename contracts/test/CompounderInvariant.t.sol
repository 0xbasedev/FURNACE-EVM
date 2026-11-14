// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {EmberPair} from "../src/pairs/EmberPair.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {ForgeView} from "../src/forge/ForgeView.sol";
import {Compounder} from "../src/match/Compounder.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {MockCastLedger, MockMatchVent} from "./utils/CompounderMocks.sol";
import {CompounderRig} from "./Compounder.t.sol";

using ForgeView for ForgePool;

/// @notice Random time, swaps, positions, credits, settlements, funding, forfeits, seed, freezes,
///         casts, closes and auto-pairs against the Compounder.
contract CompounderHandler is Test {
    Compounder internal c;
    MockCastLedger internal ledger;
    MockMatchVent internal vent;
    MockERC20 internal ember;
    EmberPair[2] internal pairs;
    ForgePool[2] internal pools;
    address internal bank;
    address internal sink;
    uint256 internal constant T0 = 1_800_000_000;

    /// Shares credited, and the pool-epochs they fall in (`epoch << 8 | pool`), for the actions
    /// to aim at.
    uint256[3][] internal shares;
    uint256[] internal poolEpochs;
    mapping(uint256 => bool) internal knownPoolEpoch;

    uint256 public casts;
    uint256 public releases;
    uint256 public dryReleases;
    uint256 public autoPairs;
    uint256 public maxEpoch;

    constructor(Compounder c_, MockCastLedger l, MockMatchVent v, MockERC20 e, EmberPair[2] memory ps, ForgePool[2] memory pl, address s) {
        (c, ledger, vent, ember, bank, sink) = (c_, l, v, e, msg.sender, s);
        (pairs[0], pairs[1], pools[0], pools[1]) = (ps[0], ps[1], pl[0], pl[1]);
    }

    function _epoch() internal view returns (uint256) {
        return block.timestamp <= T0 ? 0 : (block.timestamp - T0) / 1 days;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1 hours, 36 hours));
        if (_epoch() > maxEpoch) maxEpoch = _epoch();
    }

    /// Both pairs observe now and 30 minutes later, so the next calls see a fresh TWAP.
    function freshen() public {
        pairs[0].checkpoint();
        pairs[1].checkpoint();
        vm.warp(block.timestamp + P.PAIR_TWAP_SECONDS);
        pairs[0].checkpoint();
        pairs[1].checkpoint();
        if (_epoch() > maxEpoch) maxEpoch = _epoch();
    }

    function swap(uint256 j, bool buy, uint256 amount) external {
        j = bound(j, 0, 1);
        EmberPair pair = pairs[j];
        IERC20 tokenIn = buy ? pair.QUOTE() : pair.EMBER();
        amount = buy ? bound(amount, 1, j == 0 ? 500e6 : 0.2e18) : bound(amount, 1, 800e18);
        MockERC20(address(tokenIn)).mint(address(this), amount);
        tokenIn.approve(address(pair), amount);
        if (buy) {
            try pair.buy(amount, 0, address(this)) {} catch {}
        } else {
            try pair.sell(amount, 0, address(this)) {} catch {}
        }
    }

    function open(uint256 i, uint256 lp) external {
        i = bound(i, 0, 1);
        if (pools[i].positionCount() >= 6) return;
        lp = bound(lp, 50e18, 600e18);
        address who = address(uint160(0x7000 + pools[i].positionCount()));
        vm.prank(bank);
        IERC20(address(pairs[i])).transfer(who, lp);
        vm.prank(who);
        IERC20(address(pairs[i])).approve(address(pools[i]), lp);
        vm.prank(who);
        pools[i].open(lp);
    }

    function request(uint256 i, uint256 id, uint256 amount) external {
        i = bound(i, 0, 1);
        uint256 n = pools[i].positionCount();
        if (n == 0) return;
        id = bound(id, 1, n);
        vm.prank(pools[i].positionOf(id).owner);
        try pools[i].requestCooling(id, bound(amount, 1, 200e18)) {} catch {}
    }

    function credit(uint256 i, uint256 id, uint256 amount) external {
        i = bound(i, 0, 1);
        uint256 n = pools[i].positionCount();
        if (n == 0) return;
        (uint256 e, uint256 k) = (_epoch(), bound(id, 1, n));
        try ledger.credit(e, i, k, bound(amount, 1, 60e18)) {
            shares.push([e, i, k]);
            uint256 pe = e << 8 | i;
            if (!knownPoolEpoch[pe]) {
                knownPoolEpoch[pe] = true;
                poolEpochs.push(pe);
            }
        } catch {}
    }

    /// Settle a credited pool-epoch once its epoch has ended.
    function settle(uint256 pick) external {
        if (poolEpochs.length == 0) return;
        uint256 pe = poolEpochs[bound(pick, 0, poolEpochs.length - 1)];
        try ledger.settle(pe >> 8, pe & 0xff) {} catch {}
    }

    function fund(uint256 j, uint256 amount) external {
        j = bound(j, 0, 1);
        vent.fund(j, j == 0 ? bound(amount, 1, 300e6) : bound(amount, 1, 0.1e18));
    }

    function forfeit(uint256 amount) external {
        ledger.forfeit(bound(amount, 1, 50e18));
        c.pullForfeits();
    }

    function fundSeed(uint256 amount) external {
        amount = bound(amount, 1, 200e18);
        ember.mint(address(this), amount);
        ember.approve(address(c), amount);
        c.fundSeed(amount);
    }

    /// Freeze a credited pool-epoch, usually on a fresh TWAP.
    function freeze(uint256 pick, bool fresh) external {
        if (poolEpochs.length == 0) return;
        uint256 pe = poolEpochs[bound(pick, 0, poolEpochs.length - 1)];
        if (fresh) freshen();
        try c.freeze(pe >> 8, pe & 0xff) {} catch {}
    }

    /// Every consumed share is accounted exactly: what was paired plus what returned liquid is the
    /// share; a share its budget does not cover returns whole.
    function cast(uint256 pick, bool fresh) external {
        if (shares.length == 0) return;
        (uint256 e, uint256 i, uint256 id) = (0, 0, 0);
        {
            uint256[3] memory s = shares[bound(pick, 0, shares.length - 1)];
            (e, i, id) = (s[0], s[1], s[2]);
        }
        if (fresh) freshen();
        uint256 share = ledger.castOf(e, i, id);
        (, uint256 covered,) = c.reservationOf(e, i, id);
        uint256 held = ember.balanceOf(address(ledger));
        uint256 owed = ledger.unclaimed(i, id);
        try c.cast(e, i, id) returns (uint256 lp) {
            uint256 used = held - ember.balanceOf(address(ledger));
            assertEq(used + (ledger.unclaimed(i, id) - owed), share, "a share is paired or returned, exactly");
            assertLe(used, covered, "never more than its budget covers");
            if (lp == 0) {
                assertEq(used, 0);
                ++releases;
                if (covered == 0) ++dryReleases;
            } else {
                ++casts;
            }
        } catch {}
    }

    /// A whole epoch: each pool's positions earn a share, the epoch ends, the pool-epochs settle,
    /// and on a fresh TWAP they freeze and some shares are cast through `cast`'s own checks.
    function cycle(uint256 seed) external {
        uint256 e = _epoch();
        for (uint256 i; i < 2; ++i) {
            for (uint256 id = 1; id <= pools[i].positionCount(); ++id) {
                uint256 amount = bound(uint256(keccak256(abi.encode(seed, i, id))), 1e18, 50e18);
                try ledger.credit(e, i, id, amount) {
                    shares.push([e, i, id]);
                } catch {}
            }
            uint256 pe = e << 8 | i;
            if (!knownPoolEpoch[pe]) {
                knownPoolEpoch[pe] = true;
                poolEpochs.push(pe);
            }
        }
        vm.warp(T0 + (e + 1) * 1 days + 1);
        for (uint256 i; i < 2; ++i) ledger.settle(e, i);
        freshen();
        for (uint256 i; i < 2; ++i) try c.freeze(e, i) {} catch {}
        uint256 n = shares.length;
        for (uint256 k = n > 8 ? n - 8 : 0; k < n; ++k) if (uint256(keccak256(abi.encode(seed, k))) % 3 != 0) this.cast(k, false);
    }

    /// Seven epochs and more with no Cast: the pair is idle, the seed is funded, and the idle
    /// auto-pair runs through `autoPair`'s own checks.
    function idle(uint256 j, uint256 amount) external {
        vm.warp(block.timestamp + (P.IDLE_EPOCHS_BEFORE_AUTO_PAIR + 1) * 1 days);
        this.fundSeed(amount);
        this.autoPair(j, true);
    }

    /// A share's window passes, and it is cast: it must return to its owner whole.
    function expire(uint256 pick) external {
        if (shares.length == 0) return;
        uint256 k = bound(pick, 0, shares.length - 1);
        uint256 at = c.expiresAt(shares[k][0]);
        if (block.timestamp < at) vm.warp(at);
        if (_epoch() > maxEpoch) maxEpoch = _epoch();
        this.cast(k, false);
    }

    function close(uint256 pick) external {
        if (poolEpochs.length == 0) return;
        uint256 pe = poolEpochs[bound(pick, 0, poolEpochs.length - 1)];
        try c.close(pe >> 8, pe & 0xff) {} catch {}
    }

    /// The idle auto-pair never spends reserved quote, and runs only when the pair is idle.
    function autoPair(uint256 j, bool fresh) external {
        j = bound(j, 0, 1);
        if (fresh) freshen();
        Compounder.Reserve memory r = c.reserveOf(j);
        uint256 sunk = pairs[j].balanceOf(sink);
        try c.autoPair(j) returns (uint256 lp) {
            assertEq(c.reserveOf(j).reserved, r.reserved, "reserved quote is never paired");
            assertGe(_epoch(), uint256(r.lastActiveEpoch) + P.IDLE_EPOCHS_BEFORE_AUTO_PAIR, "only when idle");
            assertEq(pairs[j].balanceOf(sink), sunk + lp, "its LP is permanent");
            ++autoPairs;
        } catch {}
    }
}

contract CompounderInvariantTest is CompounderRig {
    CompounderHandler internal handler;
    World internal w;

    function setUp() public {
        vm.warp(T0);
        w = _world();
        handler = new CompounderHandler(w.c, w.ledger, w.vent, w.ember, w.pairs, w.pools, w.sink);
        // The handler hands out this contract's LP, as the bank, by pranked transfers.
        targetContract(address(handler));
        // Start with a position in each pool, a funded lane and a fresh TWAP.
        for (uint256 j; j < 2; ++j) {
            address who = address(uint160(0x7000 + j));
            IERC20(address(w.pairs[j])).transfer(who, 400e18);
            vm.prank(who);
            IERC20(address(w.pairs[j])).approve(address(w.pools[j]), 400e18);
            vm.prank(who);
            w.pools[j].open(400e18);
        }
        w.vent.fund(0, 500e6);
        w.vent.fund(1, 0.2e18);
    }

    /// The matching quote held is exactly the unreserved plus the reserved inventory, and the
    /// reserved inventory is exactly what the frozen budgets still hold.
    function invariant_quoteIsFreePlusReserved() public view {
        uint256 last = handler.maxEpoch();
        for (uint256 j; j < 2; ++j) {
            Compounder.Reserve memory r = w.c.reserveOf(j);
            assertEq(w.pairs[j].QUOTE().balanceOf(address(w.c)), uint256(r.free) + r.reserved, "quote held");
            uint256 outstanding;
            for (uint256 e; e <= last; ++e) {
                Compounder.Budget memory b = w.c.budgetOf(e, j);
                assertLe(b.remaining, b.budget, "a budget holds no more than it reserved");
                assertLe(b.budget, b.need, "and reserved no more than its demand needed");
                outstanding += b.remaining;
            }
            assertEq(outstanding, r.reserved, "reserved is the budgets' remainder");
        }
    }

    /// The Compounder holds seed EMBER and nothing else of EMBER, and never keeps LP.
    function invariant_emberIsTheSeedAndNoLpStays() public view {
        assertEq(w.ember.balanceOf(address(w.c)), w.c.seed(), "EMBER held is the seed");
        for (uint256 j; j < 2; ++j) assertEq(w.pairs[j].balanceOf(address(w.c)), 0, "no LP stays");
    }
}
