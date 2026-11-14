// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";

/// @title Hearth: staked ASH earns the Vent's fee share (spec v5.5 §15; ADR 0025)
/// @notice The Vent pushes the Hearth's 10% of Forge fees here in kind (ADR 0020). This pays only
///         what has actually arrived (realized, funded fee-asset liabilities) to staked ASH, through a
///         global index per fee asset with checkpointed stake changes:
///         - `book(asset)` adds whatever this holds of an asset beyond what it owes to that asset's
///           index, pro rata to the ASH staked at that moment. Every stake change books every asset
///           first, so new stake never meets an unbooked batch and cannot capture an old one.
///         - A batch booked while nothing is staked had no stakeholder when it was realized; it is
///           owed to the Treasury, released by anyone [P].
///         - `requestExit` stops ASH earning at once and unlocks it 24 hours later (the retained ASH
///           exit cooldown); `withdraw` then returns it to its owner, needing nobody's approval.
///           A pending exit can be cancelled back into stake until it is withdrawn [P].
///         Fees are chain-local: this pays the fee assets this chain's Vent funds, and promises no
///         cross-chain aggregation (config `hearth.feeScope`). It carries no governance weight: the
///         spec builds no tokenholder voting (§20). No admin, no pause, no upgrade. Not audited.
contract Hearth is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @notice The index scale.
    uint256 public constant PREC = 1e36;
    /// @notice The most fee assets a Hearth pays (EMBER and each pair's quote asset).
    uint256 public constant MAX_ASSETS = 4;

    IERC20 public immutable ASH;
    /// @notice Receives batches booked while nothing is staked [P].
    address public immutable TREASURY;
    uint256 public immutable ASSET_COUNT;
    address internal immutable ASSET_0;
    address internal immutable ASSET_1;
    address internal immutable ASSET_2;
    address internal immutable ASSET_3;

    struct Exit {
        uint128 amount;
        uint64 unlockAt;
    }

    uint256 public totalStaked;
    /// @notice ASH requested out and not yet withdrawn; it earns nothing.
    uint256 public totalExiting;
    mapping(address => uint256) public stakeOf;
    mapping(address => Exit) internal _exits;
    /// @notice Each asset's cumulative fee per staked ASH, scaled by PREC.
    mapping(address => uint256) public indexOf;
    /// @notice The index a wallet last settled at, per asset.
    mapping(address => mapping(address => uint256)) public paidIndexOf;
    /// @notice Settled and unclaimed, per wallet and asset.
    mapping(address => mapping(address => uint256)) public owedOf;
    /// @notice Booked and not yet paid, per asset: what this owes stakers and the Treasury.
    mapping(address => uint256) public liability;
    /// @notice Batches booked while nothing was staked, owed to the Treasury.
    mapping(address => uint256) public treasuryOwed;

    event Booked(address indexed asset, uint256 amount, uint256 totalStaked, uint256 index);
    event BookedToTreasury(address indexed asset, uint256 amount);
    event Staked(address indexed wallet, uint256 amount);
    event ExitRequested(address indexed wallet, uint256 amount, uint256 pending, uint256 unlockAt);
    event ExitCancelled(address indexed wallet, uint256 amount);
    event Withdrawn(address indexed wallet, uint256 amount);
    event Claimed(address indexed wallet, address indexed asset, uint256 amount);
    event ReleasedToTreasury(address indexed asset, uint256 amount);

    error ZeroAddress();
    error BadAssets();
    error ZeroAmount();
    error UnknownAsset(address token);
    error NothingToBook(address asset);
    error NothingOwed(address wallet, address asset);
    error OverStake(uint256 amount, uint256 staked);
    error NoExit(address wallet);
    error TooEarly(uint256 unlockAt);
    error NonStandardToken();

    /// @param assets The fee assets, fixed: EMBER and each pair's quote asset, distinct, never ASH.
    constructor(IERC20 ash, address treasury, address[] memory assets) {
        if (address(ash) == address(0) || treasury == address(0)) revert ZeroAddress();
        uint256 n = assets.length;
        if (n == 0 || n > MAX_ASSETS) revert BadAssets();
        for (uint256 k; k < n; ++k) {
            if (assets[k] == address(0)) revert ZeroAddress();
            if (assets[k] == address(ash)) revert BadAssets();
            for (uint256 j; j < k; ++j) if (assets[j] == assets[k]) revert BadAssets();
        }
        (ASH, TREASURY, ASSET_COUNT) = (ash, treasury, n);
        ASSET_0 = assets[0];
        ASSET_1 = n > 1 ? assets[1] : address(0);
        ASSET_2 = n > 2 ? assets[2] : address(0);
        ASSET_3 = n > 3 ? assets[3] : address(0);
    }

    // ── fees ──────────────────────────────────────────────────────────────

    /// @notice Permissionless: book this contract's unowed balance of `asset` into its index.
    function book(address asset) external nonReentrant returns (uint256 amount) {
        _asset(asset);
        amount = _unbooked(asset);
        if (amount == 0) revert NothingToBook(asset);
        _book(asset, amount);
    }

    /// @notice Pay the caller what it has earned of `asset`, after booking every asset.
    function claim(address asset) external nonReentrant returns (uint256 amount) {
        _asset(asset);
        _bookAll();
        _settle(msg.sender);
        amount = _pay(msg.sender, asset);
        if (amount == 0) revert NothingOwed(msg.sender, asset);
    }

    /// @notice Pay the caller every asset it has earned; returns the amounts in asset order.
    function claimAll() external nonReentrant returns (uint256[] memory amounts) {
        _bookAll();
        _settle(msg.sender);
        amounts = new uint256[](ASSET_COUNT);
        for (uint256 k; k < ASSET_COUNT; ++k) amounts[k] = _pay(msg.sender, assetAt(k));
    }

    /// @notice Permissionless: push the Treasury the batches booked while nothing was staked.
    function releaseToTreasury(address asset) external nonReentrant returns (uint256 amount) {
        _asset(asset);
        amount = treasuryOwed[asset];
        if (amount == 0) revert NothingOwed(TREASURY, asset);
        treasuryOwed[asset] = 0;
        liability[asset] -= amount;
        IERC20(asset).safeTransfer(TREASURY, amount);
        emit ReleasedToTreasury(asset, amount);
    }

    // ── stake ─────────────────────────────────────────────────────────────

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _bookAll();
        _settle(msg.sender);
        uint256 before = ASH.balanceOf(address(this));
        ASH.safeTransferFrom(msg.sender, address(this), amount);
        if (ASH.balanceOf(address(this)) - before != amount) revert NonStandardToken();
        stakeOf[msg.sender] += amount;
        totalStaked += amount;
        emit Staked(msg.sender, amount);
    }

    /// @notice Stop `amount` of the caller's ASH earning now; it unlocks after the exit cooldown.
    ///         A second request adds to the pending exit and restarts its clock [P].
    function requestExit(uint256 amount) external nonReentrant returns (uint256 unlockAt) {
        if (amount == 0) revert ZeroAmount();
        uint256 staked = stakeOf[msg.sender];
        if (amount > staked) revert OverStake(amount, staked);
        _bookAll();
        _settle(msg.sender);
        stakeOf[msg.sender] = staked - amount;
        totalStaked -= amount;
        totalExiting += amount;
        Exit storage e = _exits[msg.sender];
        e.amount = SafeCast.toUint128(uint256(e.amount) + amount);
        unlockAt = block.timestamp + P.HEARTH_EXIT_COOLDOWN;
        e.unlockAt = SafeCast.toUint64(unlockAt);
        emit ExitRequested(msg.sender, amount, e.amount, unlockAt);
    }

    /// @notice Return the caller's whole pending exit to stake [P].
    function cancelExit() external nonReentrant returns (uint256 amount) {
        amount = _exits[msg.sender].amount;
        if (amount == 0) revert NoExit(msg.sender);
        _bookAll();
        _settle(msg.sender);
        delete _exits[msg.sender];
        totalExiting -= amount;
        stakeOf[msg.sender] += amount;
        totalStaked += amount;
        emit ExitCancelled(msg.sender, amount);
    }

    /// @notice Once the cooldown has passed, return the caller's pending exit. Never paused, never
    ///         gated by anyone.
    function withdraw() external nonReentrant returns (uint256 amount) {
        Exit memory e = _exits[msg.sender];
        if (e.amount == 0) revert NoExit(msg.sender);
        if (block.timestamp < e.unlockAt) revert TooEarly(e.unlockAt);
        amount = e.amount;
        delete _exits[msg.sender];
        totalExiting -= amount;
        ASH.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ── views ─────────────────────────────────────────────────────────────

    function assetAt(uint256 k) public view returns (address) {
        if (k >= ASSET_COUNT) revert BadAssets();
        return k == 0 ? ASSET_0 : k == 1 ? ASSET_1 : k == 2 ? ASSET_2 : ASSET_3;
    }

    function isAsset(address token) public view returns (bool) {
        if (token == address(0)) return false;
        for (uint256 k; k < ASSET_COUNT; ++k) if (assetAt(k) == token) return true;
        return false;
    }

    function exitOf(address wallet) external view returns (uint256 amount, uint256 unlockAt) {
        Exit memory e = _exits[wallet];
        return (e.amount, e.unlockAt);
    }

    /// @notice What `wallet` could claim of `asset` from what is already booked.
    function pending(address wallet, address asset) external view returns (uint256) {
        return owedOf[wallet][asset]
            + Math.mulDiv(stakeOf[wallet], indexOf[asset] - paidIndexOf[wallet][asset], PREC);
    }

    /// @notice What this holds of `asset` beyond what it owes: the next batch to book.
    function unbooked(address asset) external view returns (uint256) {
        return _unbooked(asset);
    }

    // ── internals ─────────────────────────────────────────────────────────

    function _asset(address token) internal view {
        if (!isAsset(token)) revert UnknownAsset(token);
    }

    function _unbooked(address asset) internal view returns (uint256) {
        uint256 held = IERC20(asset).balanceOf(address(this));
        uint256 owed = liability[asset];
        return held > owed ? held - owed : 0;
    }

    function _bookAll() internal {
        for (uint256 k; k < ASSET_COUNT; ++k) {
            address asset = assetAt(k);
            uint256 amount = _unbooked(asset);
            if (amount != 0) _book(asset, amount);
        }
    }

    function _book(address asset, uint256 amount) internal {
        liability[asset] += amount;
        uint256 total = totalStaked;
        if (total == 0) {
            treasuryOwed[asset] += amount;
            emit BookedToTreasury(asset, amount);
        } else {
            uint256 index = indexOf[asset] + Math.mulDiv(amount, PREC, total);
            indexOf[asset] = index;
            emit Booked(asset, amount, total, index);
        }
    }

    /// @dev Move what `wallet`'s stake earned since its last checkpoint into what it is owed.
    function _settle(address wallet) internal {
        uint256 staked = stakeOf[wallet];
        for (uint256 k; k < ASSET_COUNT; ++k) {
            address asset = assetAt(k);
            uint256 index = indexOf[asset];
            uint256 paid = paidIndexOf[wallet][asset];
            if (index == paid) continue;
            if (staked != 0) owedOf[wallet][asset] += Math.mulDiv(staked, index - paid, PREC);
            paidIndexOf[wallet][asset] = index;
        }
    }

    function _pay(address wallet, address asset) internal returns (uint256 amount) {
        amount = owedOf[wallet][asset];
        if (amount == 0) return 0;
        owedOf[wallet][asset] = 0;
        liability[asset] -= amount;
        IERC20(asset).safeTransfer(wallet, amount);
        emit Claimed(wallet, asset, amount);
    }
}
