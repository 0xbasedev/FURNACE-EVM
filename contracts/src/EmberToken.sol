// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {FurnaceParams as P} from "./generated/FurnaceParams.sol";

/// @title EmberToken — home-chain (Ethereum) EMBER
/// @notice Immutable core token. No owner, no pause, no transfer tax, no upgrade path.
///  - Live-supply ceiling: totalSupply never exceeds 21,000,000 (P.EMBER_MAX_SUPPLY).
///    It is a live ceiling, not a cumulative-mint ceiling: burns reopen headroom.
///  - The Kindling seed (420,000) is minted once, in the constructor, to the Kindling
///    registry address. No other allocation is pre-minted; the team allocation is 0.
///  - Every later mint (base emissions, Ashfall, treasury vesting) comes from one
///    minter: the emission controller hosted by the Forge (P.FORGE). That contract
///    owns the epoch schedule and the shared headroom budget (EmissionMath).
///  - Argument-free constructor for CREATE3 (deployment.evm.argumentFreeConstructors).
/// @dev Omnichain: on Ethereum this token is canonical and bridges through a
///      LayerZero OFT adapter (lockbox), so totalSupply here IS the global supply,
///      in-flight transfers included. See docs/adr/0001-ember-canonical-supply.md.
contract EmberToken is ERC20, ERC20Burnable, ERC20Permit {
    uint256 public constant MAX_SUPPLY = P.EMBER_MAX_SUPPLY;
    address public constant MINTER = P.FORGE;
    bytes32 public constant CONFIG_HASH = P.CONFIG_HASH;

    error NotMinter(address caller);
    error SupplyCeilingExceeded(uint256 supplyAfter);

    constructor() ERC20(P.EMBER_NAME, P.EMBER_SYMBOL) ERC20Permit(P.EMBER_NAME) {
        _mint(P.KINDLING, P.EMBER_KINDLING_SEED);
    }

    /// @notice Remaining live-supply headroom: 21M − totalSupply.
    function headroom() external view returns (uint256) {
        return MAX_SUPPLY - totalSupply();
    }

    /// @notice Only the emission controller mints, and never past the ceiling.
    function mint(address to, uint256 amount) external {
        if (msg.sender != MINTER) revert NotMinter(msg.sender);
        _mint(to, amount);
    }

    /// @dev Single choke point for supply growth: enforces the ceiling on every mint path.
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from == address(0) && totalSupply() > MAX_SUPPLY) revert SupplyCeilingExceeded(totalSupply());
    }
}
