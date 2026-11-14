// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hearth} from "../src/hearth/Hearth.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {HearthRig} from "./Hearth.t.sol";

/// @notice Random fees, stakes, exits, cancels, withdrawals, claims and time against the Hearth.
contract HearthHandler is Test {
    Hearth internal hearth;
    MockERC20 internal ashToken;
    address[3] internal assets;
    address[5] internal wallets;
    uint256 public claims;
    uint256 public withdrawals;
    uint256 public freshStakes;

    constructor(Hearth h, MockERC20 ash, address[3] memory a, address[5] memory w) {
        (hearth, ashToken, assets, wallets) = (h, ash, a, w);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 2 days));
    }

    function fee(uint256 asset, uint256 amount) external {
        MockERC20(assets[bound(asset, 0, 2)]).mint(address(hearth), bound(amount, 1, 1e27));
    }

    function book(uint256 asset) external {
        try hearth.book(assets[bound(asset, 0, 2)]) {} catch {}
    }

    /// A wallet with nothing staked that stakes gets none of what arrived before it.
    function stake(uint256 who, uint256 amount) external {
        address w = wallets[bound(who, 0, 4)];
        uint256 have = ashToken.balanceOf(w);
        if (have == 0) return;
        amount = bound(amount, 1, have);
        bool fresh = hearth.stakeOf(w) == 0;
        uint256[3] memory before;
        for (uint256 k; k < 3; ++k) before[k] = hearth.pending(w, assets[k]);
        vm.prank(w);
        hearth.stake(amount);
        if (fresh) {
            ++freshStakes;
            for (uint256 k; k < 3; ++k) assertEq(hearth.pending(w, assets[k]), before[k], "a newcomer captured an old batch");
        }
    }

    function requestExit(uint256 who, uint256 amount) external {
        address w = wallets[bound(who, 0, 4)];
        uint256 staked = hearth.stakeOf(w);
        if (staked == 0) return;
        vm.prank(w);
        hearth.requestExit(bound(amount, 1, staked));
    }

    function cancelExit(uint256 who) external {
        vm.prank(wallets[bound(who, 0, 4)]);
        try hearth.cancelExit() {} catch {}
    }

    /// A matured exit always pays out, in full.
    function withdraw(uint256 who) external {
        address w = wallets[bound(who, 0, 4)];
        (uint256 amount, uint256 unlockAt) = hearth.exitOf(w);
        if (amount == 0 || block.timestamp < unlockAt) return;
        uint256 before = ashToken.balanceOf(w);
        vm.prank(w);
        assertEq(hearth.withdraw(), amount, "a matured exit pays in full");
        assertEq(ashToken.balanceOf(w), before + amount);
        ++withdrawals;
    }

    function claim(uint256 who, uint256 asset) external {
        vm.prank(wallets[bound(who, 0, 4)]);
        try hearth.claim(assets[bound(asset, 0, 2)]) {
            ++claims;
        } catch {}
    }

    function claimAll(uint256 who) external {
        vm.prank(wallets[bound(who, 0, 4)]);
        hearth.claimAll();
        ++claims;
    }

    function release(uint256 asset) external {
        try hearth.releaseToTreasury(assets[bound(asset, 0, 2)]) {} catch {}
    }
}

contract HearthInvariantTest is HearthRig {
    HearthHandler internal handler;
    World internal w;
    address[5] internal wallets;

    function setUp() public {
        vm.warp(T0);
        w = _world();
        for (uint256 i; i < WALLETS; ++i) wallets[i] = _wallet(i);
        handler = new HearthHandler(w.hearth, w.ash, [address(w.ember), address(w.usdc), address(w.weth)], wallets);
        targetContract(address(handler));
        // Start with stake, a waiting batch and a pending exit, so every run has something to pay.
        vm.prank(wallets[0]);
        w.hearth.stake(1_000e18);
        vm.prank(wallets[1]);
        w.hearth.stake(500e18);
        w.ember.mint(address(w.hearth), 100e18);
        vm.prank(wallets[1]);
        w.hearth.requestExit(200e18);
    }

    /// Every fee asset's balance covers what is booked and unpaid; and what stakers could claim,
    /// plus the Treasury's share, never exceeds it.
    function invariant_feesAreFundedAndNeverOverPromised() public {
        for (uint256 a; a < ASSETS; ++a) {
            address t = _token(w, a);
            uint256 owed = w.hearth.liability(t);
            assertGe(IERC20(t).balanceOf(address(w.hearth)), owed, "owed is held");
            uint256 promised = w.hearth.treasuryOwed(t);
            for (uint256 i; i < WALLETS; ++i) promised += w.hearth.pending(wallets[i], t);
            assertLe(promised, owed, "never promised past the booked");
        }
    }

    /// ASH held is the stake plus the exits, and the totals are the wallets' sums.
    function invariant_ashIsBackedAndTotalsAreSums() public {
        uint256 staked;
        uint256 exiting;
        for (uint256 i; i < WALLETS; ++i) {
            staked += w.hearth.stakeOf(wallets[i]);
            (uint256 amount,) = w.hearth.exitOf(wallets[i]);
            exiting += amount;
        }
        assertEq(staked, w.hearth.totalStaked(), "staked sums");
        assertEq(exiting, w.hearth.totalExiting(), "exiting sums");
        assertEq(w.ash.balanceOf(address(w.hearth)), staked + exiting, "ASH held is stake plus exits");
    }

    /// No exit waits more than the cooldown from its last request.
    function invariant_exitsUnlockWithinTheCooldown() public {
        for (uint256 i; i < WALLETS; ++i) {
            (uint256 amount, uint256 unlockAt) = w.hearth.exitOf(wallets[i]);
            if (amount != 0) assertLe(unlockAt, block.timestamp + 24 hours, "unlocks within 24 h");
            else assertEq(unlockAt, 0);
        }
    }
}
