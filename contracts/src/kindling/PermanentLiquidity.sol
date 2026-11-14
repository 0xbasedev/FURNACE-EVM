// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title PermanentLiquidity
/// @notice The irretrievable LP sink (spec v5.5 §3; `CONTRACTS.md` row 13; ADR 0021). Kindling
///         sends it 10% of the opening LP; the later idle auto-pairing will send it its LP too.
///
///         It has no function that moves a token, approves, redeems, migrates, delegates, calls
///         out with value or upgrades, and it accepts no native currency. Anything sent to it stays
///         here for good, so the liquidity it holds can never be withdrawn from the pair. Its one
///         function is a view. Not audited.
contract PermanentLiquidity {
    /// @notice What this contract holds of `token`, forever.
    function held(IERC20 token) external view returns (uint256) {
        return token.balanceOf(address(this));
    }
}
