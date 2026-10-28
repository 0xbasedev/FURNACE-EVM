// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForgeEmissions} from "../src/forge/ForgeEmissions.sol";
import {SettlementFixture} from "./ForgeEmissions.t.sol";

/// @notice Record spam: one owner stacks many records in one slot within one epoch
///         (request 1 wei, cancel; a capped lot merges back each time). Resumable pages
///         keep every page bounded and the epoch settles for everyone.
contract SettlementGriefTest is SettlementFixture {
    function setUp() public {
        vm.warp(1_800_000_000);
        _deploySettlement(block.timestamp);
    }

    function test_gas_recordSpam() public {
        address attacker = _user(1);
        address honest = _user(2);
        _fund(attacker);
        _fund(honest);
        vm.prank(honest);
        pools[0].open(100e18);
        vm.startPrank(attacker);
        uint256 id = pools[0].open(100e18);
        pools[0].deposit(id, 100e18); // a second lot so a 1-wei request splits one lot
        vm.stopPrank();
        // Age everything past the cap, then settle the idle epochs up to here.
        vm.warp(block.timestamp + 400 days);
        uint256 epoch = (block.timestamp - start) / 1 days;
        vm.warp(start + epoch * 1 days + 1);
        uint256 cycles = 600;
        uint256 g0 = gasleft();
        vm.startPrank(attacker);
        for (uint256 k; k < cycles; ++k) {
            uint32 t = pools[0].requestCooling(id, 1);
            vm.warp(block.timestamp + 1);
            pools[0].cancelCooling(id, t);
            vm.warp(block.timestamp + 1);
        }
        vm.stopPrank();
        uint256 attackGas = g0 - gasleft();
        emit log_named_uint("attacker gas per record", attackGas / (2 * cycles));
        emit log_named_uint("records in slot 0", pools[0].historyLength(id, 0));
        vm.warp(start + (epoch + 1) * 1 days + 1);
        for (uint256 e; e <= epoch; ++e) mantle.finalizeEpoch();
        for (uint256 e; e <= epoch; ++e) emissions.openEpoch();
        uint256 maxPage;
        uint256 pages;
        while (emissions.poolEpoch(epoch, 0).phase == ForgeEmissions.Phase.Measuring) {
            uint256 g = gasleft();
            emissions.advance(epoch, 0);
            uint256 used = g - gasleft();
            if (used > maxPage) maxPage = used;
            ++pages;
        }
        emit log_named_uint("measure pages for the spammed epoch", pages);
        emit log_named_uint("heaviest measure page", maxPage);
        assertGt(pages, 1, "the spammed position spans pages");
        assertLt(maxPage, 6_000_000, "every page stays bounded");
        while (emissions.poolEpoch(epoch, 0).phase == ForgeEmissions.Phase.Crediting) emissions.advance(epoch, 0);
        assertGt(emissions.unclaimed(0, 1), 0, "the honest staker is paid despite the spam");
    }
}
