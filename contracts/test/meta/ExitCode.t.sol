// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice Gate self-test for scripts/check-forge-gate.mjs: fails only when
///         FURNACE_EXPECT_FAIL=1, proving a red test exits non-zero through tools/forge.mjs.
contract ExitCodeTest is Test {
    function test_failsOnlyWhenAsked() public view {
        assertFalse(vm.envOr("FURNACE_EXPECT_FAIL", false), "deliberate failure (gate self-test)");
    }
}
