// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";

/// @notice What the bonus reads of Kindling: its ending and each wallet's net principal.
interface IKindlingBonusView {
    function status() external view returns (uint8);
    function totalNet() external view returns (uint256);
    function contributions(address wallet) external view returns (uint128 gross, uint128 net, uint128 fee, bool done);
}

/// @notice The ledger's bonus release.
interface IAshBonusLedger {
    function releaseKindlingBonus() external returns (uint256);
}

/// @title KindlingAshBonus: Kindling's 1,000-ASH bonus leaf (spec v5.5 §3; ADR 0022)
/// @notice Pays the 1,000 ASH pro rata to Kindling contributors once Kindling has settled, on the
///         same basis as their LP: `floor(1,000 · net / totalNet)` [P]. It reads only Kindling's
///         public views, so Kindling needs no change.
///
///         - Funded on the first claim: it asks the AshLedger for the 1,000. A Kindling that fails
///           never settles, so the bonus is never minted [P].
///         - Permissionless, per wallet or in caller-sized pages; ASH only ever goes to the wallet.
///         - The claim that places the last net principal burns the rounding remainder [P]: ASH is
///           cumulative, so nothing ever re-issues it.
///         No admin, no pause, no upgrade. Not audited.
contract KindlingAshBonus is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    uint8 internal constant SETTLED = 1; // Kindling.Status.Settled

    IKindlingBonusView public immutable KINDLING;
    ERC20Burnable public immutable ASH;
    IAshBonusLedger public immutable LEDGER;

    bool public funded;
    mapping(address => bool) public claimed;
    /// @notice Net principal paid against, and ASH paid, so far.
    uint256 public netClaimed;
    uint256 public paid;

    event Claimed(address indexed wallet, uint256 amount);
    event RemainderBurned(uint256 amount);

    error ZeroAddress();
    error NotSettled();
    error NothingOwed(address wallet);
    error FundingMismatch(uint256 received);

    constructor(IKindlingBonusView kindling, ERC20Burnable ash, IAshBonusLedger ledger) {
        if (address(kindling) == address(0) || address(ash) == address(0) || address(ledger) == address(0)) {
            revert ZeroAddress();
        }
        (KINDLING, ASH, LEDGER) = (kindling, ash, ledger);
    }

    /// @notice Pay `wallet` its share of the bonus. Permissionless.
    function claim(address wallet) external nonReentrant returns (uint256 amount) {
        _fund();
        amount = _claim(wallet);
        if (amount == 0) revert NothingOwed(wallet);
    }

    /// @notice A caller-sized page of `claim`; wallets with nothing owed are skipped.
    function claimMany(address[] calldata wallets) external nonReentrant returns (uint256 total) {
        _fund();
        for (uint256 i; i < wallets.length; ++i) total += _claim(wallets[i]);
    }

    /// @notice `wallet`'s unclaimed bonus, once Kindling has settled; zero otherwise.
    function bonusOf(address wallet) public view returns (uint256) {
        if (KINDLING.status() != SETTLED || claimed[wallet]) return 0;
        (, uint128 net,,) = KINDLING.contributions(wallet);
        uint256 total = KINDLING.totalNet();
        return total == 0 ? 0 : (P.ASH_KINDLING_BONUS * net) / total;
    }

    function _fund() internal {
        if (KINDLING.status() != SETTLED) revert NotSettled();
        if (funded) return;
        funded = true;
        uint256 before = ASH.balanceOf(address(this));
        LEDGER.releaseKindlingBonus();
        uint256 received = ASH.balanceOf(address(this)) - before;
        if (received != P.ASH_KINDLING_BONUS) revert FundingMismatch(received);
    }

    function _claim(address wallet) internal returns (uint256 amount) {
        if (claimed[wallet]) return 0;
        (, uint128 net,,) = KINDLING.contributions(wallet);
        if (net == 0) return 0;
        claimed[wallet] = true;
        uint256 total = KINDLING.totalNet();
        amount = (P.ASH_KINDLING_BONUS * net) / total;
        (netClaimed, paid) = (netClaimed + net, paid + amount);
        if (amount != 0) IERC20(address(ASH)).safeTransfer(wallet, amount);
        emit Claimed(wallet, amount);
        if (netClaimed == total) {
            uint256 rest = P.ASH_KINDLING_BONUS - paid;
            paid = P.ASH_KINDLING_BONUS;
            if (rest != 0) {
                ASH.burn(rest);
                emit RemainderBurned(rest);
            }
        }
    }
}
