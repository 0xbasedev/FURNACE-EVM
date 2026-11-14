// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";
import {EpochSplitter, IEpochMeasures} from "./EpochSplitter.sol";

/// @notice What ForgeAsh uses of the AshLedger: the vesting curve and its release.
interface IAshForgeLedger {
    function vestedAt(uint256 t) external view returns (uint256);
    function releaseForge() external returns (uint256);
}

/// @title ForgeAsh: the Forge's 28,000 ASH, streamed to Forge stakers (spec v5.5 §1, §4; ADR 0024)
/// @notice The AshLedger vests the Forge's 28,000 ASH over 730 days as V(t) (ADR 0022) and mints
///         it only to this contract. Each epoch's slice is exactly V(epoch end) − V(epoch start),
///         so the slices sum to the whole allocation with no rounding authority. The slice is
///         split over the pools by their ASH weights, 500/200/300/0, and within a pool in the
///         base's own shape, 30% by stake-seconds and 70% by Heat [P]. ASH is released from the
///         ledger on demand, never ahead of the curve. An epoch nobody earned in rolls to the
///         next. No admin, no pause, no upgrade. Not audited.
contract ForgeAsh is EpochSplitter {
    using SafeERC20 for IERC20;

    IERC20 public immutable ASH;
    IAshForgeLedger public immutable LEDGER;

    constructor(IEpochMeasures emissions, IERC20 ash, IAshForgeLedger ledger)
        EpochSplitter(emissions, Measure.Ordinary)
    {
        if (address(ash) == address(0) || address(ledger) == address(0)) revert ZeroAddress();
        (ASH, LEDGER) = (ash, ledger);
    }

    /// @notice The epoch's vested slice: V(end) − V(start), on ForgeEmissions' clock.
    function sliceOf(uint256 epoch) public view returns (uint256) {
        uint256 start = EMISSIONS.START() + epoch * P.EPOCH_SECONDS;
        return LEDGER.vestedAt(start + P.EPOCH_SECONDS) - LEDGER.vestedAt(start);
    }

    /// @notice Pool `pool`'s ASH weight.
    function pointsOf(uint256 pool) public pure returns (uint256) {
        if (pool == 0) return P.FORGE_POOL_0_ASH_POINTS;
        if (pool == 1) return P.FORGE_POOL_1_ASH_POINTS;
        if (pool == 2) return P.FORGE_POOL_2_ASH_POINTS;
        if (pool == 3) return P.FORGE_POOL_3_ASH_POINTS;
        return 0;
    }

    /// @notice The epoch's slice by the pool's ASH weight, plus anything rolled in.
    function budgetOf(uint256 epoch, uint256 pool, address token) public view override returns (uint256) {
        if (token != address(ASH)) return 0;
        return (sliceOf(epoch) * pointsOf(pool)) / P.FORGE_ASH_POINTS_TOTAL + assigned[epoch][pool][token];
    }

    /// @dev The slices are owed by the curve, not booked: there is no liability ledger to debit.
    function _debit(address, uint256) internal override {}

    /// @dev Release from the ledger what has vested, then pay. A settled epoch has ended, so its
    ///      slice is always vested by the time it is claimed.
    function _pay(address token, address to, uint256 amount) internal override {
        if (ASH.balanceOf(address(this)) < amount) LEDGER.releaseForge();
        IERC20(token).safeTransfer(to, amount);
    }
}
