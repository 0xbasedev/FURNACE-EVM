// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev A founder record the tests set by hand (ADR 0018).
contract MockFounders {
    mapping(address wallet => bool) public isFounder;

    function set(address wallet, bool founder) external {
        isFounder[wallet] = founder;
    }
}
