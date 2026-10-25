// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Test-only receipt token with open minting.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Test-only token that skims 1% on every transfer (must be rejected by deposits).
contract FeeOnTransferERC20 is MockERC20 {
    constructor() MockERC20("Skim", "SKIM") {}

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 skim = value / 100;
            super._update(from, address(0xdead), skim);
            value -= skim;
        }
        super._update(from, to, value);
    }
}
