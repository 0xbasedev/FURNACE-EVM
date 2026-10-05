// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {FurnaceParams as P} from "./generated/FurnaceParams.sol";

/// @title EmberToken — home-chain (Ethereum) EMBER, spec v5.5
/// @notice Immutable core token: no owner, no pause, no transfer tax, no upgrade path.
///  - Local backstop for the live-supply ceiling: totalSupply never exceeds 21,000,000.
///    The ECONOMIC ceiling is enforced by the Mantle's global ledger (reservations,
///    transport claims, burn credits); this check only guarantees the token can never
///    be the component that breaks it.
///  - The only minter is the Mantle (the home-chain issuance authority). It reserves the
///    Kindling seed, Treasury vesting, base and Ashfall budgets before minting. Nothing is
///    pre-minted here; the team allocation is zero.
///  - The Mantle address is a constructor argument: v5.5 allows constructor arguments
///    under CREATE3 (the address does not depend on init code), and the Mantle's own
///    registry entry is not mined yet.
contract EmberToken is ERC20, ERC20Burnable, ERC20Permit {
    uint256 public constant MAX_SUPPLY = P.EMBER_MAX_SUPPLY;
    bytes32 public constant CONFIG_HASH = P.CONFIG_HASH;
    address public immutable MANTLE;

    error ZeroMantle();
    error NotMantle(address caller);
    error SupplyCeilingExceeded(uint256 supplyAfter);

    constructor(address mantle) ERC20(P.EMBER_NAME, P.EMBER_SYMBOL) ERC20Permit(P.EMBER_NAME) {
        if (mantle == address(0)) revert ZeroMantle();
        MANTLE = mantle;
    }

    /// @notice Local view of 21M − totalSupply. Not the economic headroom (see Mantle).
    function localHeadroom() external view returns (uint256) {
        return MAX_SUPPLY - totalSupply();
    }

    /// @notice Only the Mantle mints, and never past the ceiling.
    function mint(address to, uint256 amount) external {
        if (msg.sender != MANTLE) revert NotMantle(msg.sender);
        _mint(to, amount);
    }

    /// @dev Single choke point for supply growth: enforces the ceiling on every mint path.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from == address(0) && totalSupply() > MAX_SUPPLY) revert SupplyCeilingExceeded(totalSupply());
    }
}
