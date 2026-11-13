// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";
import {GenesisFeeEscrow} from "./GenesisFeeEscrow.sol";

/// @notice The Mantle's one-time seed: 420,000 EMBER minted to Kindling, once.
interface IKindlingMantle {
    function mintKindlingSeed() external;
}

/// @notice What Kindling uses of BlastPool (EmberPair), whose INITIALIZER it is.
interface IKindlingPair {
    function EMBER() external view returns (IERC20);
    function QUOTE() external view returns (IERC20);
    function INITIALIZER() external view returns (address);
    function totalSupply() external view returns (uint256);
    function getReserves() external view returns (uint112 ember, uint112 quote, uint32 updatedAt);
    function addLiquidity(uint256 emberDesired, uint256 quoteDesired, uint256 emberMin, uint256 quoteMin, address to)
        external
        returns (uint256 ember, uint256 quote, uint256 liquidity);
}

/// @notice What Kindling uses of Forge pool 0, whose KINDLING it is (ADR 0018).
interface IKindlingPool {
    function STAKE_TOKEN() external view returns (IERC20);
    function KINDLING() external view returns (address);
    function openKindling(address owner, uint256 amount) external returns (uint256 id);
}

/// @title Kindling
/// @notice The genesis event (spec v5.5 §3; `CONTRACTS.md` row 11; ADR 0021). One 24-hour USDC raise
///         that opens BlastPool at a price set by the raise itself.
///
///         - `contribute` runs from START until END exactly. 3% of each gross contribution is the
///           fee, floored; gross is pulled exactly into the GenesisFeeEscrow. Admission refuses a
///           wallet past $25,000 or the event past $5,000,000 of accepted gross, never part-fills.
///         - `cancel` returns net principal at once until settlement, the retry window included.
///           The fee stays escrowed. The cancelled share of the wallet's accepted gross leaves the
///           event's base, rounded up, so cancellations never enlarge it.
///         - `settle` is permissionless, after END and before END + 72 h, with at least $100,000 of
///           accepted gross. Atomically it mints the 420,000-EMBER seed, takes the net principal
///           from the escrow, initializes BlastPool with both, keeps 90% of the LP for contributors
///           (floored) and sends the rest to the permanent sink, then releases the fees: 5 bps of
///           accepted gross to the caller and the rest to the Treasury.
///         - `fail` is permissionless once the event cannot settle: below the minimum after END, or
///           72 h after END. Success and failure are exclusive. `refund` then pays each wallet its
///           remaining net principal plus every fee it paid, once.
///         - `materialize` turns a contributor's entitlement, floor(LP90 × net / Σnet), into a Forge
///           pool 0 position through `openKindling` (the standard 1% deposit fee, ADR 0018). It is
///           permissionless, per wallet or in caller-sized pages; nothing loops over every wallet.
///           The last materialization sends the rounding remainder to the sink.
///         No admin, no pause, no upgrade. Not audited.
contract Kindling is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant BPS = 10_000;

    enum Status {
        Live,
        Settled,
        Failed
    }

    /// @notice Why a `settle` would refuse the venue. `None` means it is safe to initialize.
    enum Venue {
        None,
        PairMissing, // BlastPool has no code yet
        PairWiring, // BlastPool's initializer, EMBER or quote is not this event's
        PairInitialized, // BlastPool already has LP or reserves
        PoolWiring // pool 0 is missing, does not stake BlastPool's LP, or names another KINDLING
    }

    enum Failure {
        BelowMinimum,
        Timeout
    }

    /// @notice One wallet's place in the event.
    struct Contribution {
        uint128 gross; // live accepted gross: each cancellation removes its share, rounded up
        uint128 net; // live net principal
        uint128 fee; // every fee paid, cancelled contributions' included
        bool done; // refunded (after failure) or materialized (after success)
    }

    IERC20 public immutable USDC;
    IERC20 public immutable EMBER;
    IKindlingMantle public immutable MANTLE;
    /// @notice BlastPool: the pair this event initializes. Its LP is pool 0's stake token.
    IKindlingPair public immutable PAIR;
    IKindlingPool public immutable POOL;
    GenesisFeeEscrow public immutable ESCROW;
    /// @notice The permanent LP sink (PermanentLiquidity).
    address public immutable SINK;
    uint256 public immutable START;
    uint256 public immutable END;
    /// @notice After this, an unsettled event can only fail.
    uint256 public immutable SETTLE_DEADLINE;
    /// @notice The limits, in USDC units (config dollars × 10^decimals, USDC valued at $1 [P]).
    uint256 public immutable MIN_CONTRIBUTION;
    uint256 public immutable WALLET_CAP;
    uint256 public immutable MIN_RAISE;
    uint256 public immutable MAX_RAISE;

    Status public status;
    mapping(address => Contribution) public contributions;
    /// @notice Accepted gross less cancellations: the minimum's, the maximum's and the bounty's base.
    uint256 public accepted;
    /// @notice Live net principal, equal to the escrow's principal ledger until settlement.
    uint256 public totalNet;
    /// @notice Every fee paid, equal to the escrow's fee ledger until settlement.
    uint256 public totalFees;

    /// @notice When the event settled; zero until then. Ignition's head-start window reads it.
    uint256 public closedAt;
    /// @notice The LP the opening deposit minted to this event (the pair's minimum liquidity is
    ///         already burned), and the contributors' 90% of it.
    uint256 public liquidity;
    uint256 public contributorLp;
    /// @notice Contributor LP paid out so far, and the net principal it was paid against.
    uint256 public lpPaid;
    uint256 public netMaterialized;

    event Contributed(address indexed wallet, uint256 gross, uint256 net, uint256 fee);
    event Cancelled(address indexed wallet, uint256 net, uint256 grossOut);
    event Settled(
        address indexed caller,
        uint256 seed,
        uint256 quote,
        uint256 liquidity,
        uint256 contributorLp,
        uint256 sinkLp,
        uint256 bounty,
        uint256 treasuryFees
    );
    event EventFailed(Failure reason);
    event Refunded(address indexed wallet, uint256 net, uint256 fee);
    event Materialized(address indexed wallet, uint256 lp, uint256 positionId);
    event RemainderSunk(uint256 lp);

    error ZeroAddress();
    error EscrowMismatch();
    error QuoteDecimals(uint8 decimals);
    error NotOpen();
    error BelowMinimumContribution(uint256 gross, uint256 minimum);
    error WalletCap(uint256 gross, uint256 cap);
    error RaiseCap(uint256 accepted, uint256 cap);
    error NonStandardToken();
    error NotLive(Status status);
    error BadCancel(uint256 amount, uint256 net);
    error TooEarly();
    error SettlementExpired();
    error BelowMinimumRaise(uint256 accepted, uint256 minimum);
    error UnsafeVenue(Venue reason);
    error SeedMismatch(uint256 received);
    error QuoteMismatch(uint256 received);
    error StillSettleable();
    error NotFailed();
    error NotSettled();
    error NothingOwed(address wallet);

    /// @dev The escrow is deployed first and names this event; nothing else is called, so the
    ///      Mantle, the pair, the pool and the sink may deploy later at their predicted addresses.
    constructor(
        IERC20 usdc,
        IERC20 ember,
        IKindlingMantle mantle,
        IKindlingPair pair,
        IKindlingPool pool,
        GenesisFeeEscrow escrow,
        address sink,
        uint256 start
    ) {
        if (
            address(usdc) == address(0) || address(ember) == address(0) || address(mantle) == address(0)
                || address(pair) == address(0) || address(pool) == address(0) || address(escrow) == address(0)
                || sink == address(0) || start == 0
        ) revert ZeroAddress();
        if (escrow.QUOTE() != usdc || escrow.EVENT() != address(this)) revert EscrowMismatch();
        uint8 decimals = IERC20Metadata(address(usdc)).decimals();
        if (decimals > 18) revert QuoteDecimals(decimals);
        (USDC, EMBER, MANTLE, PAIR, POOL, ESCROW, SINK) = (usdc, ember, mantle, pair, pool, escrow, sink);
        (START, END) = (start, start + P.KINDLING_DURATION);
        SETTLE_DEADLINE = start + P.KINDLING_DURATION + P.KINDLING_SETTLE_WINDOW;
        uint256 unit = 10 ** decimals;
        MIN_CONTRIBUTION = P.KINDLING_MIN_CONTRIBUTION_USD * unit;
        WALLET_CAP = P.KINDLING_WALLET_CAP_USD * unit;
        MIN_RAISE = P.KINDLING_MIN_RAISE_USD * unit;
        MAX_RAISE = P.KINDLING_MAX_RAISE_USD * unit;
    }

    // ── The raise ───────────────────────────────────────────────────────

    /// @notice Contribute `gross` USDC, pulled exactly into the escrow. Top-ups add to the same place.
    function contribute(uint256 gross) external nonReentrant returns (uint256 net, uint256 fee) {
        if (block.timestamp < START || block.timestamp >= END) revert NotOpen();
        if (gross < MIN_CONTRIBUTION) revert BelowMinimumContribution(gross, MIN_CONTRIBUTION);
        fee = (gross * P.KINDLING_FEE_BPS) / BPS;
        net = gross - fee;
        Contribution storage c = contributions[msg.sender];
        uint256 walletGross = c.gross + gross;
        if (walletGross > WALLET_CAP) revert WalletCap(walletGross, WALLET_CAP);
        uint256 total = accepted + gross;
        if (total > MAX_RAISE) revert RaiseCap(total, MAX_RAISE);
        c.gross = walletGross.toUint128();
        c.net = (c.net + net).toUint128();
        c.fee = (c.fee + fee).toUint128();
        (accepted, totalNet, totalFees) = (total, totalNet + net, totalFees + fee);
        uint256 before = USDC.balanceOf(address(ESCROW));
        USDC.safeTransferFrom(msg.sender, address(ESCROW), gross);
        if (USDC.balanceOf(address(ESCROW)) - before != gross) revert NonStandardToken();
        ESCROW.book(net, fee);
        emit Contributed(msg.sender, gross, net, fee);
    }

    /// @notice Take back `amount` of net principal now, until settlement. The fee stays escrowed:
    ///         the Treasury's on success, refunded on failure.
    function cancel(uint256 amount) external nonReentrant returns (uint256 grossOut) {
        if (status != Status.Live) revert NotLive(status);
        Contribution storage c = contributions[msg.sender];
        uint256 net = c.net;
        if (amount == 0 || amount > net) revert BadCancel(amount, net);
        grossOut = Math.mulDiv(c.gross, amount, net, Math.Rounding.Ceil);
        c.gross = (c.gross - grossOut).toUint128();
        c.net = (net - amount).toUint128();
        (accepted, totalNet) = (accepted - grossOut, totalNet - amount);
        ESCROW.returnPrincipal(msg.sender, amount);
        emit Cancelled(msg.sender, amount, grossOut);
    }

    // ── Settlement ──────────────────────────────────────────────────────

    /// @notice Open BlastPool with the seed and the net raise, split the LP, release the fees.
    ///         Permissionless; the caller earns the close bounty.
    function settle() external nonReentrant returns (uint256 minted) {
        if (status != Status.Live) revert NotLive(status);
        if (block.timestamp < END) revert TooEarly();
        if (block.timestamp >= SETTLE_DEADLINE) revert SettlementExpired();
        uint256 base = accepted;
        if (base < MIN_RAISE) revert BelowMinimumRaise(base, MIN_RAISE);
        Venue venue = venueCheck();
        if (venue != Venue.None) revert UnsafeVenue(venue);
        (status, closedAt) = (Status.Settled, block.timestamp);

        uint256 seed = EMBER.balanceOf(address(this));
        MANTLE.mintKindlingSeed();
        seed = EMBER.balanceOf(address(this)) - seed;
        if (seed != P.EMBER_KINDLING_SEED) revert SeedMismatch(seed);
        uint256 quote = USDC.balanceOf(address(this));
        uint256 funded = ESCROW.fundLiquidity();
        quote = USDC.balanceOf(address(this)) - quote;
        if (quote != funded || quote != totalNet) revert QuoteMismatch(quote);

        EMBER.forceApprove(address(PAIR), seed);
        USDC.forceApprove(address(PAIR), quote);
        (,, minted) = PAIR.addLiquidity(seed, quote, seed, quote, address(this));
        uint256 kept = (minted * P.KINDLING_CONTRIBUTOR_LP_PCT) / 100;
        (liquidity, contributorLp) = (minted, kept);
        IERC20(address(PAIR)).safeTransfer(SINK, minted - kept);

        uint256 bounty = (base * P.KINDLING_CLOSE_BOUNTY_BPS) / BPS;
        uint256 treasury = ESCROW.releaseFees(msg.sender, bounty);
        emit Settled(msg.sender, seed, quote, minted, kept, minted - kept, bounty, treasury);
    }

    /// @notice End an event that cannot settle: below the minimum after END, or unsettled 72 h
    ///         after END. Permissionless. Refunds open at once.
    function fail() external returns (Failure reason) {
        if (status != Status.Live) revert NotLive(status);
        if (block.timestamp < END) revert TooEarly();
        bool below = accepted < MIN_RAISE;
        if (!below && block.timestamp < SETTLE_DEADLINE) revert StillSettleable();
        status = Status.Failed;
        reason = below ? Failure.BelowMinimum : Failure.Timeout;
        ESCROW.fail();
        emit EventFailed(reason);
    }

    /// @notice After failure: pay `wallet` its remaining net principal plus every fee it paid. Once.
    ///         Permissionless; the quote only ever goes to the wallet.
    function refund(address wallet) external nonReentrant returns (uint256 amount) {
        if (status != Status.Failed) revert NotFailed();
        Contribution storage c = contributions[wallet];
        (uint256 net, uint256 fee) = (c.net, c.fee);
        if (c.done || net + fee == 0) revert NothingOwed(wallet);
        c.done = true;
        ESCROW.refund(wallet, net, fee);
        emit Refunded(wallet, net, fee);
        return net + fee;
    }

    // ── Entitlements ────────────────────────────────────────────────────

    /// @notice Turn `wallet`'s entitlement into its pool 0 position. Permissionless.
    function materialize(address wallet) external nonReentrant returns (uint256 positionId) {
        bool paid;
        (paid, positionId) = _materialize(wallet);
        if (!paid) revert NothingOwed(wallet);
    }

    /// @notice A caller-sized page of `materialize`; wallets with nothing owed are skipped.
    function materializeMany(address[] calldata wallets) external nonReentrant returns (uint256 paid) {
        for (uint256 i; i < wallets.length; ++i) {
            (bool ok,) = _materialize(wallets[i]);
            if (ok) ++paid;
        }
    }

    function _materialize(address wallet) internal returns (bool paid, uint256 positionId) {
        if (status != Status.Settled) revert NotSettled();
        Contribution storage c = contributions[wallet];
        uint256 net = c.net;
        if (c.done || net == 0) return (false, 0);
        c.done = true;
        uint256 lp = (contributorLp * net) / totalNet;
        (lpPaid, netMaterialized) = (lpPaid + lp, netMaterialized + net);
        IERC20(address(PAIR)).forceApprove(address(POOL), lp);
        positionId = POOL.openKindling(wallet, lp);
        emit Materialized(wallet, lp, positionId);
        if (netMaterialized == totalNet) {
            uint256 rest = contributorLp - lpPaid;
            lpPaid = contributorLp;
            if (rest != 0) {
                IERC20(address(PAIR)).safeTransfer(SINK, rest);
                emit RemainderSunk(rest);
            }
        }
        return (true, positionId);
    }

    // ── Views ───────────────────────────────────────────────────────────

    /// @notice Whether BlastPool and pool 0 are this event's and untouched; `None` means safe.
    function venueCheck() public view returns (Venue) {
        if (address(PAIR).code.length == 0) return Venue.PairMissing;
        if (PAIR.INITIALIZER() != address(this) || PAIR.EMBER() != EMBER || PAIR.QUOTE() != USDC) {
            return Venue.PairWiring;
        }
        (uint112 e, uint112 q,) = PAIR.getReserves();
        if (PAIR.totalSupply() != 0 || e != 0 || q != 0) return Venue.PairInitialized;
        if (
            address(POOL).code.length == 0 || POOL.KINDLING() != address(this)
                || POOL.STAKE_TOKEN() != IERC20(address(PAIR))
        ) return Venue.PoolWiring;
        return Venue.None;
    }

    /// @notice `wallet`'s LP entitlement once settled and not yet materialized; zero otherwise.
    function entitlementOf(address wallet) external view returns (uint256) {
        Contribution memory c = contributions[wallet];
        if (status != Status.Settled || c.done || totalNet == 0) return 0;
        return (contributorLp * c.net) / totalNet;
    }

    /// @notice What `wallet` would be refunded if the event failed now (or is owed, after failure).
    function refundableOf(address wallet) external view returns (uint256) {
        Contribution memory c = contributions[wallet];
        if (status == Status.Settled || c.done) return 0;
        return c.net + c.fee;
    }
}
