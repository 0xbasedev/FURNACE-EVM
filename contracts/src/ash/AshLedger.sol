// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FurnaceParams as P} from "../generated/FurnaceParams.sol";

/// @notice What the ledger uses of AshToken: its only mint path.
interface IAshMint {
    function mint(address to, uint256 amount) external;
}

/// @title AshLedger: ASH's home-chain issuance authority (spec v5.5 §1; ADR 0022)
/// @notice Holds the three ASH allocations and the only rules that ever release them. Every
///         recipient is immutable, every release is a fixed amount or a fixed curve, and
///         together they are exactly the 70,000 cumulative budget the token also enforces.
///
///         - Ignition: 41,000, released once, to IGNITION.
///         - The Kindling bonus: 1,000, released once and only when KINDLING_BONUS asks, which it
///           does only after Kindling settles. A failed Kindling never mints it [P].
///         - The Forge: 28,000, vesting to FORGE as
///           V(t) = floor(28,000 · min(t − START, 730 days) / 730 days), released permissionlessly as
///           V(now) − released. Never anticipatory.
///
///         No admin, no pause, no upgrade, no other mint path. Not audited.
contract AshLedger {
    IAshMint public immutable TOKEN;
    /// @notice Ignition: the bootstrap farm that distributes the 41,000.
    address public immutable IGNITION;
    /// @notice The Kindling bonus distributor (KindlingAshBonus).
    address public immutable KINDLING_BONUS;
    /// @notice The Forge's ASH recipient: the distributor that streams the 28,000 to Forge stakers.
    address public immutable FORGE;
    /// @notice When the Forge allocation starts vesting (the Mantle's START, epoch 0) [P].
    uint256 public immutable START;

    bool public ignitionReleased;
    bool public bonusReleased;
    uint256 public forgeReleased;

    event IgnitionReleased(address indexed to, uint256 amount);
    event KindlingBonusReleased(address indexed to, uint256 amount);
    event ForgeReleased(address indexed to, uint256 amount, uint256 released);

    error ZeroAddress();
    error AlreadyReleased();
    error NotKindlingBonus(address caller);

    /// @dev Stores addresses only: the token and every recipient may deploy later at their
    ///      predicted CREATE3 addresses.
    constructor(IAshMint token, address ignition, address kindlingBonus, address forge, uint256 start) {
        if (
            address(token) == address(0) || ignition == address(0) || kindlingBonus == address(0) || forge == address(0)
                || start == 0
        ) revert ZeroAddress();
        (TOKEN, IGNITION, KINDLING_BONUS, FORGE, START) = (token, ignition, kindlingBonus, forge, start);
    }

    /// @notice Permissionless, once: mints Ignition's 41,000 to IGNITION.
    function releaseIgnition() external returns (uint256 amount) {
        if (ignitionReleased) revert AlreadyReleased();
        ignitionReleased = true;
        amount = P.ASH_IGNITION_ALLOCATION;
        TOKEN.mint(IGNITION, amount);
        emit IgnitionReleased(IGNITION, amount);
    }

    /// @notice KINDLING_BONUS only, once: mints the 1,000 bonus to it.
    function releaseKindlingBonus() external returns (uint256 amount) {
        if (msg.sender != KINDLING_BONUS) revert NotKindlingBonus(msg.sender);
        if (bonusReleased) revert AlreadyReleased();
        bonusReleased = true;
        amount = P.ASH_KINDLING_BONUS;
        TOKEN.mint(KINDLING_BONUS, amount);
        emit KindlingBonusReleased(KINDLING_BONUS, amount);
    }

    /// @notice Permissionless: mints V(now) − released to FORGE.
    function releaseForge() external returns (uint256 amount) {
        amount = vestedAt(block.timestamp) - forgeReleased;
        if (amount == 0) return 0;
        forgeReleased += amount;
        TOKEN.mint(FORGE, amount);
        emit ForgeReleased(FORGE, amount, forgeReleased);
    }

    /// @notice The Forge allocation vested at `t`: the canonical V(t) (accounting.ts `vested`).
    function vestedAt(uint256 t) public view returns (uint256) {
        if (t <= START) return 0;
        uint256 elapsed = t - START;
        if (elapsed > P.ASH_FORGE_VESTING) elapsed = P.ASH_FORGE_VESTING;
        return (P.ASH_FORGE_ALLOCATION * elapsed) / P.ASH_FORGE_VESTING;
    }

    /// @notice Every unit this ledger has minted so far.
    function issued() external view returns (uint256) {
        return (ignitionReleased ? P.ASH_IGNITION_ALLOCATION : 0) + (bonusReleased ? P.ASH_KINDLING_BONUS : 0)
            + forgeReleased;
    }
}
