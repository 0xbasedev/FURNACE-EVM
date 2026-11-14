// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";
import {EpochSplitter, IEpochMeasures} from "./EpochSplitter.sol";

/// @title BookedSplitter: the Vent's stayers' share and Quote yield (spec v5.5 §11, §12; ADR 0024)
/// @notice The Vent releases what it owes a fixed recipient by pushing tokens to it (ADR 0020).
///         `book(token)` assigns whatever this holds beyond what it already owes to the current
///         epoch, split over the four pools by their base weights (1000/400/400/200) [P]. Once
///         each pool's epoch settles, its positions claim by this deployment's measure:
///         - **Stayers** (`Measure.Stake`): the 25% of emergency-exit fees owed to everyone who
///           stayed, by stake-seconds [P].
///         - **Quote yield** (`Measure.Ashfall`): the sell side's 5 bps in the pairs' quote
///           assets, by the Heat² weight of Ashfall-eligible lots (spec v5.5 §12).
///         A token sent here unasked is booked the same way: it can only ever reach stakers.
///         No admin, no pause, no upgrade. Not audited.
contract BookedSplitter is EpochSplitter {
    error NothingToBook(address token);

    constructor(IEpochMeasures emissions, Measure measure) EpochSplitter(emissions, measure) {}

    /// @notice Permissionless: assign this contract's unowed balance of `token` to the epoch now
    ///         running, by the pools' base weights.
    function book(address token) external nonReentrant returns (uint256 amount) {
        if (token == address(0)) revert ZeroAddress();
        amount = IERC20(token).balanceOf(address(this)) - liability[token];
        if (amount == 0) revert NothingToBook(token);
        uint256[4] memory points = [
            P.FORGE_POOL_0_ALLOC_POINTS,
            P.FORGE_POOL_1_ALLOC_POINTS,
            P.FORGE_POOL_2_ALLOC_POINTS,
            P.FORGE_POOL_3_ALLOC_POINTS
        ];
        _assignByPoints(epochAt(block.timestamp), token, amount, points, P.FORGE_ALLOC_POINTS_TOTAL);
    }
}
