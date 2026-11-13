// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title GenesisFeeEscrow
/// @notice The dedicated immutable custody of one Kindling event's quote (spec v5.5 §3; DECISIONS
///         A3; `CONTRACTS.md` row 11; ADR 0021). It holds two liabilities in one asset: the
///         contributors' net principal and the 3% fee.
///
///         - Only EVENT (that event's Kindling) books, returns principal, settles or fails it.
///         - It moves Open → Settled or Open → Failed, once. The two are exclusive.
///         - Principal leaves only as a cancellation while Open, as the pool's quote on Settled, or
///           as a refund after Failed. Fees leave only on Settled (the close bounty and the
///           Treasury, after the pool is initialized) or as refunds after Failed. Each outflow is
///           capped by its own ledger, so the Treasury can never take refund backing.
///         - No rescue, approval, upgrade or administrative withdrawal. Quote sent here outside a
///           booking (a donation) is never anyone's liability and stays here.
///         Not audited.
contract GenesisFeeEscrow {
    using SafeERC20 for IERC20;

    enum State {
        Open,
        Settled,
        Failed
    }

    /// @notice The one asset this escrow holds (Kindling's USDC).
    IERC20 public immutable QUOTE;
    /// @notice The event: the only caller of every mutating function.
    address public immutable EVENT;
    /// @notice The success beneficiary of the fees, less the close bounty.
    address public immutable TREASURY;

    State public state;
    /// @notice Net principal owed to contributors (or to the pool on success).
    uint256 public principal;
    /// @notice Fees held: refundable on failure, earned on success.
    uint256 public fees;
    /// @notice Set once the fees are released on success.
    bool public feesReleased;

    event Booked(uint256 net, uint256 fee);
    event PrincipalReturned(address indexed to, uint256 amount);
    event LiquidityFunded(uint256 amount);
    event FeesReleased(address indexed bountyTo, uint256 bounty, uint256 treasury);
    event EventFailed();
    event Refunded(address indexed to, uint256 net, uint256 fee);

    error ZeroAddress();
    error NotEvent();
    error WrongState(State state);
    error ExceedsLiability(uint256 amount, uint256 liability);
    error AlreadyReleased();

    constructor(IERC20 quote, address event_, address treasury) {
        if (address(quote) == address(0) || event_ == address(0) || treasury == address(0)) revert ZeroAddress();
        (QUOTE, EVENT, TREASURY) = (quote, event_, treasury);
    }

    modifier onlyEvent() {
        if (msg.sender != EVENT) revert NotEvent();
        _;
    }

    modifier inState(State s) {
        if (state != s) revert WrongState(state);
        _;
    }

    /// @notice Book a contribution the event has already transferred here, exactly.
    function book(uint256 net, uint256 fee) external onlyEvent inState(State.Open) {
        (principal, fees) = (principal + net, fees + fee);
        emit Booked(net, fee);
    }

    /// @notice A cancellation: return `amount` of net principal at once. Its fee stays.
    function returnPrincipal(address to, uint256 amount) external onlyEvent inState(State.Open) {
        if (amount > principal) revert ExceedsLiability(amount, principal);
        principal -= amount;
        QUOTE.safeTransfer(to, amount);
        emit PrincipalReturned(to, amount);
    }

    /// @notice Success, step one: pay all net principal to the event to initialize the pool.
    function fundLiquidity() external onlyEvent inState(State.Open) returns (uint256 amount) {
        state = State.Settled;
        (amount, principal) = (principal, 0);
        QUOTE.safeTransfer(EVENT, amount);
        emit LiquidityFunded(amount);
    }

    /// @notice Success, step two, after the pool is initialized: the close bounty to `bountyTo`,
    ///         the rest of the fees to the Treasury. Once.
    function releaseFees(address bountyTo, uint256 bounty)
        external
        onlyEvent
        inState(State.Settled)
        returns (uint256 treasury)
    {
        if (feesReleased) revert AlreadyReleased();
        if (bounty > fees) revert ExceedsLiability(bounty, fees);
        feesReleased = true;
        treasury = fees - bounty;
        fees = 0;
        if (bounty != 0) QUOTE.safeTransfer(bountyTo, bounty);
        if (treasury != 0) QUOTE.safeTransfer(TREASURY, treasury);
        emit FeesReleased(bountyTo, bounty, treasury);
    }

    /// @notice Failure: from now on both ledgers are refund backing only.
    function fail() external onlyEvent inState(State.Open) {
        state = State.Failed;
        emit EventFailed();
    }

    /// @notice A refund after failure: remaining net principal plus every fee the contributor paid.
    function refund(address to, uint256 net, uint256 fee) external onlyEvent inState(State.Failed) {
        if (net > principal) revert ExceedsLiability(net, principal);
        if (fee > fees) revert ExceedsLiability(fee, fees);
        (principal, fees) = (principal - net, fees - fee);
        QUOTE.safeTransfer(to, net + fee);
        emit Refunded(to, net, fee);
    }
}
