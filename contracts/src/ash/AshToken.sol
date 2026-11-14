// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";

/// @title AshToken: home-chain ASH (spec v5.5 §1; ADR 0022)
/// @notice Immutable: no owner, no pause, no transfer tax, no upgrade path.
///  - ASH has a CUMULATIVE issuance budget of 70,000: 41,000 for Ignition, 1,000 for the
///    Kindling bonus and 28,000 vesting to the Forge. Burning never makes room for more, so the
///    token counts every unit ever minted (`totalMinted`) and refuses a mint past the budget,
///    whatever the live supply.
///  - The only minter is the AshLedger, which holds the three allocations and their release
///    rules. Nothing is pre-minted; there is no team allocation.
///  - Transport (OFT) is not built; it would be transport, never another allocation.
///  Not audited.
contract AshToken is ERC20, ERC20Burnable, ERC20Permit {
    uint256 public constant MAX_SUPPLY = P.ASH_MAX_SUPPLY;
    bytes32 public constant CONFIG_HASH = P.CONFIG_HASH;
    address public immutable LEDGER;
    /// @notice Every unit ever minted, burns included: the cumulative issuance the budget caps.
    uint256 public totalMinted;

    error ZeroLedger();
    error NotLedger(address caller);
    error IssuanceExceeded(uint256 mintedAfter);

    constructor(address ledger) ERC20(P.ASH_NAME, P.ASH_SYMBOL) ERC20Permit(P.ASH_NAME) {
        if (ledger == address(0)) revert ZeroLedger();
        LEDGER = ledger;
    }

    /// @notice Only the ledger mints, and never past the cumulative budget.
    function mint(address to, uint256 amount) external {
        if (msg.sender != LEDGER) revert NotLedger(msg.sender);
        uint256 after_ = totalMinted + amount;
        if (after_ > MAX_SUPPLY) revert IssuanceExceeded(after_);
        totalMinted = after_;
        _mint(to, amount);
    }

    /// @notice What can still ever be minted.
    function unissued() external view returns (uint256) {
        return MAX_SUPPLY - totalMinted;
    }
}
