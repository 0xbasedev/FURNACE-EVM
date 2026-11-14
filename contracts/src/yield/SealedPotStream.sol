// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";
import {EpochSplitter, IEpochMeasures} from "./EpochSplitter.sol";

/// @notice What the stream uses of ForgeEmissions: its pull of a pool's Sealed pot.
interface ISealedPotSource {
    function takeSealedPot(uint256 pool) external returns (uint256);
}

/// @title SealedPotStream: forfeited Seal escrow, streamed to running Seals (spec v5.5 §10, §12; ADR 0024)
/// @notice ForgeEmissions keeps 25% of every forfeited Seal escrow in a per-pool Sealed pot and
///         lets only this contract take it (ADR 0007). `pull(pool)` takes the pot and streams it
///         over the next 30 epochs of that pool [P], in equal parts with the floor's remainder on
///         the last, to positions with a running Seal, by the Conviction measure C. It is never a
///         new mint and never cast. An epoch with no running Seal rolls to the next. No admin, no
///         pause, no upgrade. Not audited.
contract SealedPotStream is EpochSplitter {
    IERC20 public immutable EMBER;

    error NothingToPull(uint256 pool);

    constructor(IEpochMeasures emissions, IERC20 ember) EpochSplitter(emissions, Measure.Conviction) {
        if (address(ember) == address(0)) revert ZeroAddress();
        EMBER = ember;
    }

    /// @notice Permissionless: take pool `pool`'s Sealed pot and stream it over the next 30 epochs,
    ///         starting with the one now running.
    function pull(uint256 pool) external nonReentrant returns (uint256 amount) {
        amount = ISealedPotSource(address(EMISSIONS)).takeSealedPot(pool);
        if (amount == 0) revert NothingToPull(pool);
        uint256 epoch = epochAt(block.timestamp);
        uint256 part = amount / P.SEALED_POT_STREAM_EPOCHS;
        for (uint256 k; k < P.SEALED_POT_STREAM_EPOCHS - 1; ++k) _assign(epoch + k, pool, address(EMBER), part);
        _assign(epoch + P.SEALED_POT_STREAM_EPOCHS - 1, pool, address(EMBER), amount - part * (P.SEALED_POT_STREAM_EPOCHS - 1));
    }
}
