// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {EpochSplitter} from "../src/yield/EpochSplitter.sol";
import {BookedSplitter} from "../src/yield/BookedSplitter.sol";
import {SealedPotStream} from "../src/yield/SealedPotStream.sol";
import {AshLedger} from "../src/ash/AshLedger.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {MockMeasures, SeedMeasures} from "./utils/SplitterMocks.sol";
import {SplitterRig} from "./Splitters.t.sol";

/// @notice Random settlements, bookings, pulls, claims, rolls and time against the four splitters.
contract SplitterHandler is Test {
    EpochSplitter[4] internal s;
    MockMeasures internal measures;
    AshLedger internal ledger;
    address[3] internal tokens;
    uint256[4] public settledUpTo; // next epoch to settle, per pool
    uint256 public claims;
    uint256 public rolls;

    constructor(EpochSplitter[4] memory s_, MockMeasures m, AshLedger l, address[3] memory t) {
        (s, measures, ledger, tokens) = (s_, m, l, t);
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 2 days));
    }

    /// @dev Settle the next epoch of `pool` that has ended, as ForgeEmissions would.
    function settle(uint256 pool, uint256 seed) external {
        pool = bound(pool, 0, 3);
        uint256 e = settledUpTo[pool];
        if (block.timestamp < measures.START() + (e + 1) * P.EPOCH_SECONDS) return;
        measures.settle(e, pool, SeedMeasures.measures(e, pool, seed));
        settledUpTo[pool] = e + 1;
    }

    function gift(uint256 which, uint256 token, uint256 amount) external {
        which = bound(which, 1, 2);
        MockERC20(tokens[bound(token, 0, 1)]).mint(address(s[which]), bound(amount, 1, 1e24));
    }

    function book(uint256 which, uint256 token) external {
        which = bound(which, 1, 2);
        try BookedSplitter(address(s[which])).book(tokens[bound(token, 0, 1)]) {} catch {}
    }

    function fundAndPull(uint256 pool, uint256 amount) external {
        pool = bound(pool, 0, 3);
        measures.fundPot(pool, bound(amount, 0, 1e24));
        try SealedPotStream(address(s[3])).pull(pool) {} catch {}
    }

    function claim(uint256 which, uint256 epoch, uint256 pool, uint256 id, uint256 token) external {
        which = bound(which, 0, 3);
        pool = bound(pool, 0, 3);
        if (settledUpTo[pool] == 0) return;
        epoch = bound(epoch, 0, settledUpTo[pool] - 1);
        address t = which == 0 ? tokens[2] : which == 3 ? tokens[0] : tokens[bound(token, 0, 1)];
        try s[which].claim(epoch, pool, bound(id, 1, 3), t) {
            ++claims;
        } catch {}
    }

    function roll(uint256 which, uint256 epoch, uint256 pool, uint256 token) external {
        which = bound(which, 0, 3);
        pool = bound(pool, 0, 3);
        if (settledUpTo[pool] == 0) return;
        epoch = bound(epoch, 0, settledUpTo[pool] - 1);
        address t = which == 0 ? tokens[2] : which == 3 ? tokens[0] : tokens[bound(token, 0, 1)];
        try s[which].roll(epoch, pool, t) {
            ++rolls;
        } catch {}
    }

    function release() external {
        ledger.releaseForge();
    }
}

contract SplittersInvariantTest is SplitterRig {
    SplitterHandler internal handler;
    World internal w;
    uint256 internal constant WATCHED = 12;

    function setUp() public {
        vm.warp(T0);
        w = _world(T0);
        handler = new SplitterHandler(w.s, w.measures, w.ledger, [address(w.ember), address(w.usdc), address(w.ash)]);
        targetContract(address(handler));
    }

    /// A booked or streamed splitter holds at least what it owes, in every token.
    function invariant_balancesCoverWhatIsOwed() public view {
        for (uint256 k = 1; k < 4; ++k) {
            for (uint256 t; t < 3; ++t) {
                address tok = _token(w, t);
                assertGe(IERC20(tok).balanceOf(address(w.s[k])), w.s[k].liability(tok), "owed is held");
            }
        }
    }

    /// Nothing is ever paid past an (epoch, pool, token) budget.
    function invariant_noBudgetIsOverpaid() public view {
        for (uint256 k; k < 4; ++k) {
            for (uint256 e; e < WATCHED; ++e) {
                for (uint256 i; i < 4; ++i) {
                    for (uint256 t; t < 3; ++t) {
                        address tok = _token(w, t);
                        assertLe(w.s[k].paidOut(e, i, tok), w.s[k].budgetOf(e, i, tok), "paid within budget");
                    }
                }
            }
        }
    }

    /// ForgeAsh never runs ahead of the vesting curve, and pays only what was released.
    function invariant_forgeAshFollowsTheCurve() public view {
        assertLe(w.ledger.forgeReleased(), w.ledger.vestedAt(block.timestamp), "never anticipated");
        assertLe(w.ledger.forgeReleased(), P.ASH_FORGE_ALLOCATION);
        assertEq(w.ash.totalSupply(), w.ledger.forgeReleased(), "ASH minted only as the curve releases it");
    }
}
