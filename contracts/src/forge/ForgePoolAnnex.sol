// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";
import {Seal, SealStatus} from "./ForgeMeasures.sol";
import {ForgePoolBase} from "./ForgePoolBase.sol";

/// @title ForgePoolAnnex
/// @notice ForgePool's cold paths (ADR 0012): Seals, BOOST's bonus, Deed listing and
///         settlement, and fee collection. Each ForgePool deploys its own annex with its own
///         constructor arguments, so the annex's immutables equal the pool's, and runs these
///         functions by DELEGATECALL: in the pool's storage, as the pool, for the pool's caller.
///         No principal moves here, and no exit calls the annex.
///
///         Called directly, the annex acts on its own storage, which holds nothing.
contract ForgePoolAnnex is ForgePoolBase {
    using SafeERC20 for IERC20;

    constructor(IERC20 stakeToken, bool isLp, address feeCollector, address boost, address deeds)
        ForgePoolBase(stakeToken, isLp, feeCollector, boost, deeds)
    {}

    /// @notice Seal the position's current lots for `track`'s term (ADR 0006). Later
    ///         deposits never join; a pending cooling request pauses the Seal and extends
    ///         its term; an executed withdrawal or emergency exit forfeits its unvested
    ///         escrow, never principal. [P] A new Seal starts at least one epoch after the
    ///         previous one ended, so each epoch's bonus belongs to exactly one Seal.
    function seal(uint256 id, uint256 track) external nonReentrant returns (uint256 k) {
        Position storage p = _touchOwned(id);
        if (p.closedAt != 0) revert Closed(id);
        if (track >= P.SEAL_TRACK_COUNT) revert UnknownTrack(track);
        if (p.pendingCount != 0) revert CoolingPending(id);
        if (p.usedMask == 0) revert NothingToSeal(id);
        k = p.sealCount;
        Seal storage last = _seals[id][k];
        if (last.status == SealStatus.Active) revert SealActive(id, k);
        if (k != 0 && block.timestamp < uint256(last.endedAt) + P.EPOCH_SECONDS) {
            revert SealGap(uint256(last.endedAt) + P.EPOCH_SECONDS);
        }
        if (k == type(uint8).max) revert SealLimit(id);
        p.sealCount = uint8(++k);
        // No ticket is pending, so every used slot is an active lot: the cohort.
        _seals[id][k] = Seal(uint8(track), SealStatus.Active, uint40(block.timestamp), 0, 0, 0, p.usedMask);
        _retag(id, p, p.usedMask, block.timestamp);
        emit Sealed(id, k, track, p.usedMask);
    }

    /// @notice BOOST sets a position's ordinary bonus in units of ORDINARY_BONUS_UNIT_RAY.
    ///         The position syncs and every active lot is rewritten at now first, so each
    ///         record segment keeps one bonus. A closed position keeps its last bonus: its
    ///         measures end at the exit.
    function setOrdinaryBonus(uint256 id, uint256 units) external nonReentrant {
        if (msg.sender != BOOST) revert NotBoost();
        if (units > P.MAX_ORDINARY_BONUS_UNITS) revert BonusAboveCeiling(units);
        if (_positions[id].closedAt != 0) return;
        _setBonus(id, _touch(id), units, BOOST_RECORD_LIMIT);
    }

    // ── Deeds (ADR 0011) ──────────────────────────────────────────────────

    /// @notice DEEDS lists an open position for its owner `seller`, with no cooling ticket
    ///         pending. Until the listing ends, the owner can neither deposit, cool nor Seal;
    ///         emergency exit stays open and ends it. Returns the listing a sale must name.
    ///         The market itself checks that no Claim or Capstone withdrawal is pending.
    function list(uint256 id, address seller) external nonReentrant returns (uint32 listing) {
        if (msg.sender != DEEDS) revert NotDeeds();
        Position storage p = _touch(id);
        if (p.owner != seller) revert NotOwner(id);
        if (p.closedAt != 0) revert Closed(id);
        if (p.pendingCount != 0) revert CoolingPending(id);
        if (p.listing & 1 != 0) revert Listed(id);
        unchecked {
            listing = ++p.listing;
        }
        emit ListingChanged(id, listing);
    }

    /// @notice End a listing: DEEDS on the seller's behalf, or the owner directly, so no
    ///         market state can keep a position locked.
    function unlist(uint256 id) external nonReentrant {
        Position storage p = _positions[id];
        if (msg.sender != DEEDS && msg.sender != p.owner) revert NotOwner(id);
        if (p.listing & 1 == 0) revert NotListed(id);
        unchecked {
            ++p.listing;
        }
        emit ListingChanged(id, p.listing);
    }

    /// @notice DEEDS completes the sale of listing `listing` to `buyer` (spec §5), once.
    ///         Every active segment closes at now under the seller's anchors; the buyer's
    ///         lots carry 80% of their capped age with a new Streak and a zero bonus (Pyre
    ///         stays with the seller until BOOST refreshes). Wallet-bound terms are cleared
    ///         and the cooling plan starts afresh. Lots, records, Seals, rewards and escrow
    ///         stay with the position. No external call.
    function settle(uint256 id, address buyer, uint32 listing) external nonReentrant {
        if (msg.sender != DEEDS) revert NotDeeds();
        if (buyer == address(0)) revert ZeroAddress();
        Position storage p = _touch(id);
        if (listing & 1 == 0 || p.listing != listing) revert NotListed(id);
        // Listed ⇒ open with no ticket pending: an exit ends the listing, cooling is locked.
        address seller = p.owner;
        _owners[id][p.transfers++] = Ownership(seller, uint40(block.timestamp));
        _rewriteActive(id, p, 100 - P.DEED_HEAT_CARRY_PCT, 100, type(uint256).max);
        (p.owner, p.streakStart, p.ordinaryBonus) = (buyer, uint40(block.timestamp), 0);
        (p.founder, p.headStartActive) = (false, false);
        delete p.plan;
        unchecked {
            ++p.listing;
        }
        emit DeedSettled(id, seller, buyer);
    }

    /// @notice The fee router pulls booked fees. Exits never call it.
    function collectFees() external nonReentrant returns (uint256 dep, uint256 wd, uint256 em) {
        if (msg.sender != FEE_COLLECTOR) revert NotCollector();
        (dep, wd, em) = (feesOwed[0], feesOwed[1], feesOwed[2]);
        delete feesOwed;
        emit FeesCollected(dep, wd, em);
        STAKE_TOKEN.safeTransfer(FEE_COLLECTOR, dep + wd + em);
    }
}
