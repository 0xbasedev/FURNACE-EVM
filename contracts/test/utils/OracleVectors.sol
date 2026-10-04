// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice Loads reference values generated from furnace.config.ts by `pnpm gen`.
abstract contract OracleVectors is Test {
    string internal json;

    function _loadVectors() internal {
        json = vm.readFile(string.concat(vm.projectRoot(), "/contracts/test/fixtures/oracle-vectors.json"));
    }

    function _uints(string memory key) internal view returns (uint256[] memory) {
        string[] memory raw = vm.parseJsonStringArray(json, key);
        uint256[] memory out = new uint256[](raw.length);
        for (uint256 i; i < raw.length; ++i) out[i] = vm.parseUint(raw[i]);
        return out;
    }

    /// @dev The TS oracle uses IEEE-754 doubles (~1e-16 relative); allow 1e-12 relative.
    function _assertNear(uint256 actual, uint256 expected, string memory what) internal pure {
        uint256 tol = expected / 1e12 + 1e3;
        assertApproxEqAbs(actual, expected, tol, what);
    }
}
