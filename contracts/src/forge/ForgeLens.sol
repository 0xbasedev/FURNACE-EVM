// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForgePool} from "./ForgePool.sol";
import {ForgeView} from "./ForgeView.sol";
import {Lot, Record, Seal} from "./ForgeMeasures.sol";

/// @title ForgeLens
/// @notice ForgeView as external calls, for frontends and indexers (ADR 0010). It holds no
///         state and no authority: any copy reads any pool, and replacing it changes nothing
///         on chain. Protocol contracts use the ForgeView library directly.
contract ForgeLens {
    using ForgeView for ForgePool;

    function positionOf(ForgePool pool, uint256 id) external view returns (ForgePool.Position memory) {
        return pool.positionOf(id);
    }

    function lotOf(ForgePool pool, uint256 id, uint256 slot) external view returns (Lot memory) {
        return pool.lotOf(id, slot);
    }

    function lotAt(ForgePool pool, uint256 id, uint256 slot)
        external
        view
        returns (uint256 amount, uint256 age, uint256 participated, uint256 heldBy)
    {
        return pool.lotAt(id, slot);
    }

    function historyLength(ForgePool pool, uint256 id, uint256 slot) external view returns (uint256) {
        return pool.historyLength(id, slot);
    }

    function historyAt(ForgePool pool, uint256 id, uint256 slot, uint256 i) external view returns (Record memory) {
        return pool.historyAt(id, slot, i);
    }

    function lotCount(ForgePool pool, uint256 id) external view returns (uint256) {
        return pool.lotCount(id);
    }

    function custodyOf(ForgePool pool, uint256 id) external view returns (uint256) {
        return pool.custodyOf(id);
    }

    function sealOf(ForgePool pool, uint256 id, uint256 k) external view returns (Seal memory) {
        return pool.sealOf(id, k);
    }

    function pendingTickets(ForgePool pool, uint256 id) external view returns (uint32[] memory) {
        return pool.pendingTickets(id);
    }

    function ticketOf(ForgePool pool, uint256 id, uint32 ticketId) external view returns (ForgePool.Ticket memory) {
        return pool.ticketOf(id, ticketId);
    }

    function sliceOf(ForgePool pool, uint256 id, uint32 ticketId, uint256 slot)
        external
        view
        returns (ForgePool.Slice memory)
    {
        return pool.sliceOf(id, ticketId, slot);
    }

    function dueLapses(ForgePool pool, uint256 id) external view returns (uint256) {
        return pool.dueLapses(id);
    }

    function occupancyLength(ForgePool pool) external view returns (uint256) {
        return pool.occupancyLength();
    }

    function occupancyAt(ForgePool pool, uint256 i) external view returns (ForgePool.Occupancy memory) {
        return pool.occupancyAt(i);
    }

    function lapseQueueLength(ForgePool pool) external view returns (uint256) {
        return pool.lapseQueueLength();
    }

    function listingOf(ForgePool pool, uint256 id) external view returns (uint32) {
        return pool.listingOf(id);
    }

    function ownershipAt(ForgePool pool, uint256 id, uint256 n) external view returns (ForgePool.Ownership memory) {
        return pool.ownershipAt(id, n);
    }

    function ownedSince(ForgePool pool, uint256 id) external view returns (uint256) {
        return pool.ownedSince(id);
    }
}
