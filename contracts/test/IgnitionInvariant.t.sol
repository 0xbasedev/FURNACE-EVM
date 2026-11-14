// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {AshToken} from "../src/ash/AshToken.sol";
import {AshLedger} from "../src/ash/AshLedger.sol";
import {Ignition} from "../src/ignition/Ignition.sol";
import {MockDecimalsERC20} from "./utils/MockERC20.sol";
import {MockColdStorage} from "./utils/IgnitionMocks.sol";
import {IgnitionRig} from "./Ignition.t.sol";

/// @notice Random deposits (opted out or not), withdrawals, time, early releases, finalizes,
///         claims, auto-stakes and donations, against one Ignition farm.
contract IgnitionHandler is Test {
    Ignition public ig;
    AshLedger internal ledger;
    MockDecimalsERC20[4] internal tokens;
    address[] internal wallets;
    address internal keeper;

    /// Per wallet and pool: net principal deposited, and principal paid back or staked.
    mapping(address => mapping(uint8 => uint256)) public netIn;
    mapping(address => mapping(uint8 => uint256)) public out;
    mapping(uint8 => uint256) public donated;
    uint256 public deposits;
    uint256 public claims;
    uint256 public stakes;
    bool public depositAfterEnd;
    bool public freeAssetStuck;

    constructor(Ignition ig_, AshLedger ledger_, MockDecimalsERC20[4] memory t, address[] memory w, address keeper_) {
        (ig, ledger, tokens, wallets, keeper) = (ig_, ledger_, t, w, keeper_);
    }

    function walletCount() external view returns (uint256) {
        return wallets.length;
    }

    function walletAt(uint256 i) external view returns (address) {
        return wallets[i];
    }

    function _who(uint256 seed) internal view returns (address) {
        return wallets[seed % wallets.length];
    }

    function _pool(uint256 seed) internal pure returns (uint8) {
        // forge-lint: disable-next-line(unsafe-typecast) — below 4
        return uint8(seed % 4);
    }

    function _scale(uint8 pool) internal pure returns (uint256) {
        return pool == 0 ? 1e6 : pool == 2 ? 1e8 : 1e18;
    }

    /// @dev Long enough that most runs pass END and many pass the free-exit window.
    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 40 hours));
    }

    /// @dev A jump to somewhere in the close: from END to two days past the free-exit window.
    function leap(uint256 dt) external {
        uint256 to = ig.END() + bound(dt, 0, P.IGNITION_EXIT_WINDOW + 2 days);
        if (to > block.timestamp) vm.warp(to);
    }

    function deposit(uint256 who, uint256 pool, uint256 gross, uint256 optOutSeed) external {
        address w = _who(who);
        uint8 k = _pool(pool);
        gross = bound(gross, 1, 50_000 * _scale(k));
        // Opting out is sticky, so keep it rare enough that auto-staking is exercised.
        bool optOut = optOutSeed % 6 == 0;
        tokens[k].mint(w, gross);
        vm.prank(w);
        try ig.deposit(k, gross, optOut) returns (uint256 net, uint256) {
            netIn[w][k] += net;
            ++deposits;
            if (block.timestamp >= ig.END()) depositAfterEnd = true;
        } catch {}
    }

    function withdraw(uint256 who, uint256 pool, uint256 amount) external {
        address w = _who(who);
        uint8 k = _pool(pool);
        uint256 principal = ig.accountOf(w, k).principal;
        if (principal == 0) return;
        amount = bound(amount, 1, principal);
        (bool optedOut,,,,,) = ig.wallets(w);
        bool mustStake = k == 0 && !optedOut && block.timestamp >= ig.END() + P.IGNITION_EXIT_WINDOW;
        vm.prank(w);
        try ig.withdraw(k, amount) {
            out[w][k] += amount;
        } catch {
            // Every asset but non-opted-out USDC after the free-exit window can always leave.
            if (!mustStake) freeAssetStuck = true;
        }
    }

    function release() external {
        vm.prank(keeper);
        try ledger.releaseIgnition() {} catch {}
    }

    function finalize() external {
        vm.prank(keeper);
        try ig.finalize() {} catch {}
    }

    function claim(uint256 who) external {
        vm.prank(keeper);
        try ig.claim(_who(who)) {
            ++claims;
        } catch {}
    }

    function stakeUsdc(uint256 who) external {
        address w = _who(who);
        uint256 principal = ig.accountOf(w, 0).principal;
        vm.prank(keeper);
        try ig.stakeUsdc(w) {
            out[w][0] += principal;
            ++stakes;
        } catch {}
    }

    function donate(uint256 pool, uint256 amount) external {
        uint8 k = _pool(pool);
        amount = bound(amount, 1, 1_000 * _scale(k));
        tokens[k].mint(address(ig), amount);
        donated[k] += amount;
    }
}

contract IgnitionInvariantTest is IgnitionRig {
    IgnitionHandler internal handler;
    World internal w;

    function setUp() public {
        vm.warp(T0);
        w = _world(T0, true);
        address[] memory ws = new address[](WALLETS);
        for (uint256 i; i < WALLETS; ++i) ws[i] = _wallet(i);
        handler = new IgnitionHandler(w.ig, w.ledger, w.tokens, ws, keeper);
        for (uint256 i; i < WALLETS; ++i) {
            vm.startPrank(ws[i]);
            for (uint256 k; k < 4; ++k) w.tokens[k].approve(address(w.ig), type(uint256).max);
            vm.stopPrank();
        }
        // Seed every wallet in every pool through the handler, so each run starts with principal
        // (and with USDC that will auto-stake: seeds never opt out).
        for (uint256 i; i < WALLETS; ++i) {
            for (uint256 k; k < 4; ++k) handler.deposit(i, k, (i + 1) * 1_000 * (k == 0 ? 1e6 : k == 2 ? 1e8 : 1e18), 1);
        }
        assertEq(handler.deposits(), WALLETS * 4, "seeded");
        targetContract(address(handler));
    }

    /// Each asset Ignition holds covers every wallet's principal in it, with donations owed to no one.
    function invariant_principalIsBacked() public view {
        for (uint8 k; k < 4; ++k) {
            Ignition.Pool memory p = w.ig.poolOf(k);
            uint256 sum;
            uint256 weighted;
            for (uint256 i; i < handler.walletCount(); ++i) {
                Ignition.Account memory a = w.ig.accountOf(handler.walletAt(i), k);
                sum += a.principal;
                weighted += a.weighted;
                assertLe(a.lots, w.ig.MAX_LOTS(), "lots capped");
            }
            assertEq(sum, p.principal, "pool principal is the wallets'");
            assertEq(weighted, p.weighted, "pool weight is the wallets'");
            assertEq(w.tokens[k].balanceOf(address(w.ig)), p.principal + handler.donated(k), "balance = principal + donations");
        }
    }

    /// Every wallet's principal is what it put in, net, less what left; nothing is created.
    function invariant_principalIsConserved() public view {
        for (uint256 i; i < handler.walletCount(); ++i) {
            address a = handler.walletAt(i);
            for (uint8 k; k < 4; ++k) {
                assertEq(w.ig.accountOf(a, k).principal, handler.netIn(a, k) - handler.out(a, k), "principal");
            }
        }
    }

    /// ASH: paid + owed + burned never exceeds the 41,000; the supply never passes the leaf, and
    /// no pool releases budget it has not reached.
    function invariant_theLeafIsNeverOvercommitted() public view {
        uint256 owed;
        for (uint256 i; i < handler.walletCount(); ++i) owed += w.ig.pending(handler.walletAt(i));
        assertLe(w.ig.paid() + owed + w.ig.burned(), P.ASH_IGNITION_ALLOCATION, "never more than 41,000");
        assertLe(w.ash.totalSupply(), P.ASH_IGNITION_ALLOCATION);
        for (uint8 k; k < 4; ++k) {
            assertLe(w.ig.poolOf(k).lastB, w.ig.cumulativeAt(k, block.timestamp), "never anticipated");
        }
        if (w.ig.finalized()) {
            assertEq(w.ash.balanceOf(address(w.ig)), P.ASH_IGNITION_ALLOCATION - w.ig.paid() - w.ig.burned(), "ASH held");
            assertGe(w.ash.balanceOf(address(w.ig)), owed, "every owed unit is held");
        }
    }

    /// Nothing is deposited from END, and every asset but non-opted-out USDC after the free-exit
    /// window can always leave.
    function invariant_theCloseHolds() public view {
        assertFalse(handler.depositAfterEnd(), "no deposit from END");
        assertFalse(handler.freeAssetStuck(), "free principal always leaves");
    }

    /// Cold Storage holds exactly what Ignition staked, at its fee.
    function invariant_stakesReachColdStorage() public view {
        uint256 staked;
        for (uint256 i; i < handler.walletCount(); ++i) staked += w.cold.stakedOf(handler.walletAt(i));
        assertEq(staked + w.cold.feesBooked(), w.tokens[0].balanceOf(address(w.cold)), "staked + fees = held");
    }

    function afterInvariant() external virtual {
        // Non-vacuity: every run starts from seeded principal in all four pools.
        assertGe(handler.deposits(), WALLETS * 4, "seeded deposits");
    }
}
