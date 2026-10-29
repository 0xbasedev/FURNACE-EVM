// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FurnaceParams as P} from "./generated/FurnaceParams.sol";
import {EmissionMath} from "./libraries/EmissionMath.sol";

interface IEmberMintBurn {
    function mint(address to, uint256 amount) external;
    function burnFrom(address account, uint256 value) external;
    function totalSupply() external view returns (uint256);
}

/// @title Mantle — home-chain EMBER issuance ledger (spec v5.5 §1, CONTRACTS.md)
/// @notice The only economic mint authority for EMBER. Immutable: no owner, no pause, no upgrade.
///
/// Ledger (all in EMBER wei):
///   accounted = everything this contract minted − burns it recognized
///   reserved  = Kindling seed (until minted) + unreleased Treasury vesting
///             + finalized-but-unminted epoch budgets
///   headroom  = max(0, 21M − accounted − reserved)          (spec: globallyAccountedSupply)
/// Invariant: accounted + reserved ≤ 21M. Bridging is disabled at launch (v5.5 staging), so no
/// transport claims exist yet; a later release must add them to `accounted` before enabling it.
///
/// Burns reopen headroom only through `burnRegistered`, where the Mantle performs the burn
/// itself, so recognition and burn are one atomic act and every burn has exactly one category.
/// Raw `burn()` calls and dead-address transfers are never recognized: their headroom stays
/// stranded (conservative by design; see ADR 0003).
///
/// Epochs (daily, from START) are finalized in order, one per call, by anyone. Finalizing
/// reserves the epoch's full GLOBAL base target plus authorized Ashfall credits from the
/// previous epoch's registered burns, scaled pro-rata if headroom is short. The DISTRIBUTOR
/// (the Forge's emission controller) then pulls mints from those budgets. Chain emission shares
/// are routed out of that budget by the distributor, never applied here: v5.5 makes the Mantle the
/// global issuance authority, and satellites receive funded budgets without mint rights.
contract Mantle {
    // ── Immutable wiring ────────────────────────────────────────────────
    IEmberMintBurn public immutable EMBER;
    /// Pulls epoch budgets (the Forge's emission controller).
    address public immutable DISTRIBUTOR;
    /// Receives the one-time 420,000 seed on successful Kindling settlement.
    address public immutable KINDLING;
    /// Receives Treasury vesting releases.
    address public immutable TREASURY;
    /// Epoch 0 start and vesting start.
    uint256 public immutable START;

    enum BurnCategory {
        None,
        Protocol, // Vent burn lane, emergency-exit burns, Deed/Capstone fee burns: 50% recycled
        Pyre // registered voluntary Pyre burns: 25% recycled
    }

    /// Fixed at construction: a registrar can never relabel its burns.
    mapping(address registrar => BurnCategory) public registrarCategory;

    // ── Ledger ──────────────────────────────────────────────────────────
    uint256 public accounted;
    uint256 public seedReserved;
    uint256 public vestingReleased;
    uint256 public epochReserved;

    // ── Epochs ──────────────────────────────────────────────────────────
    struct EpochBudget {
        uint128 base;
        uint128 ashfall;
        uint128 baseMinted;
        uint128 ashfallMinted;
        uint128 baseReleased;
        uint128 ashfallRolled;
    }

    uint256 public nextEpoch;
    mapping(uint256 epoch => EpochBudget) public budgets;
    mapping(uint256 epoch => uint256) public residueOf; // floor-rounding residue, never minted
    /// Ashfall credits recognized during each epoch (consumed by the following epoch).
    mapping(uint256 epoch => uint256) public creditsOf;
    /// Authorized credits not yet granted (cap-constrained or rolled over).
    uint256 public queuedAshfall;

    // ── Errors / events ─────────────────────────────────────────────────
    error ZeroAddress();
    error LengthMismatch();
    error DuplicateRegistrar(address registrar);
    error NotDistributor();
    error NotKindling();
    error NotRegistrar();
    error SeedAlreadyMinted();
    error EpochNotOver(uint256 epoch, uint256 endsAt);
    error EpochNotFinalized(uint256 epoch);
    error ExceedsBudget(uint256 requested, uint256 available);

    event SeedMinted(address indexed to, uint256 amount);
    event VestingReleased(address indexed to, uint256 amount, uint256 totalReleased);
    event EpochFinalized(uint256 indexed epoch, uint256 base, uint256 ashfall, uint256 residue, uint256 queuedAshfall);
    event BaseMinted(uint256 indexed epoch, address indexed to, uint256 amount);
    event AshfallMinted(uint256 indexed epoch, address indexed to, uint256 amount);
    event BaseReleased(uint256 indexed epoch, uint256 amount);
    event AshfallRolled(uint256 indexed epoch, uint256 amount);
    event BurnRecognized(address indexed registrar, BurnCategory indexed category, uint256 amount, uint256 credit, uint256 indexed epoch);
    event ForfeitBurned(uint256 amount, uint256 indexed epoch);

    constructor(
        IEmberMintBurn ember,
        address distributor,
        address kindling,
        address treasury,
        uint256 start,
        address[] memory registrars,
        BurnCategory[] memory categories
    ) {
        if (address(ember) == address(0) || distributor == address(0) || kindling == address(0) || treasury == address(0)) {
            revert ZeroAddress();
        }
        if (registrars.length != categories.length) revert LengthMismatch();
        EMBER = ember;
        DISTRIBUTOR = distributor;
        KINDLING = kindling;
        TREASURY = treasury;
        START = start;
        for (uint256 i; i < registrars.length; ++i) {
            if (registrars[i] == address(0) || categories[i] == BurnCategory.None) revert ZeroAddress();
            if (registrarCategory[registrars[i]] != BurnCategory.None) revert DuplicateRegistrar(registrars[i]);
            registrarCategory[registrars[i]] = categories[i];
        }
        // Allocations are reserved from day 0 so base emissions can never consume them.
        seedReserved = P.EMBER_KINDLING_SEED;
    }

    // ── Views ───────────────────────────────────────────────────────────
    function vestingReserved() public view returns (uint256) {
        return P.EMBER_TREASURY_ALLOCATION - vestingReleased;
    }

    function reserved() public view returns (uint256) {
        return seedReserved + vestingReserved() + epochReserved;
    }

    function headroom() public view returns (uint256) {
        uint256 used = accounted + reserved();
        return P.EMBER_MAX_SUPPLY > used ? P.EMBER_MAX_SUPPLY - used : 0;
    }

    /// @notice Epoch containing `timestamp` (0 before START).
    function epochAt(uint256 timestamp) public view returns (uint256) {
        return timestamp <= START ? 0 : (timestamp - START) / P.EPOCH_SECONDS;
    }

    /// @notice Exact cumulative entitlement V(t) = floor(total · min(elapsed, D) / D)  (accounting.ts `vested`).
    function vestedAt(uint256 timestamp) public view returns (uint256) {
        uint256 elapsed = timestamp <= START ? 0 : timestamp - START;
        if (elapsed > P.EMBER_TREASURY_VESTING) elapsed = P.EMBER_TREASURY_VESTING;
        return Math.mulDiv(P.EMBER_TREASURY_ALLOCATION, elapsed, P.EMBER_TREASURY_VESTING);
    }

    // ── Genesis seed ────────────────────────────────────────────────────
    /// @notice Kindling calls this inside its atomic successful settlement. Exactly once, exactly 420,000.
    ///         On failure Kindling never calls it and the reservation stays (ADR 0003).
    function mintKindlingSeed() external {
        if (msg.sender != KINDLING) revert NotKindling();
        uint256 amount = seedReserved;
        if (amount == 0) revert SeedAlreadyMinted();
        seedReserved = 0;
        _mint(KINDLING, amount);
        emit SeedMinted(KINDLING, amount);
    }

    // ── Treasury vesting ────────────────────────────────────────────────
    /// @notice Permissionless: mints V(now) − released to the Treasury. Never anticipatory.
    function releaseVesting() external returns (uint256 amount) {
        amount = vestedAt(block.timestamp) - vestingReleased;
        if (amount == 0) return 0;
        vestingReleased += amount;
        _mint(TREASURY, amount);
        emit VestingReleased(TREASURY, amount, vestingReleased);
    }

    // ── Epoch finalization ──────────────────────────────────────────────
    /// @notice Permissionless; finalizes exactly one epoch (the next unfinalized one) once it has ended.
    function finalizeEpoch() external returns (uint256 epoch) {
        epoch = nextEpoch;
        uint256 endsAt = START + (epoch + 1) * P.EPOCH_SECONDS;
        if (block.timestamp < endsAt) revert EpochNotOver(epoch, endsAt);

        uint256 baseTarget = EmissionMath.baseEmissionPerDay(epoch); // global target
        uint256 ashfallTarget = queuedAshfall;
        if (epoch >= P.ASHFALL_LAG_EPOCHS) ashfallTarget += creditsOf[epoch - P.ASHFALL_LAG_EPOCHS];

        (uint256 base, uint256 ashfall, uint256 residue) =
            EmissionMath.allocateMint(accounted, reserved(), baseTarget, ashfallTarget);

        // Cap-constrained Ashfall stays queued for a later epoch; base shortfall is simply not issued.
        queuedAshfall = ashfallTarget - ashfall;
        epochReserved += base + ashfall;
        budgets[epoch] = EpochBudget(uint128(base), uint128(ashfall), 0, 0, 0, 0);
        residueOf[epoch] = residue;
        nextEpoch = epoch + 1;
        emit EpochFinalized(epoch, base, ashfall, residue, queuedAshfall);
    }

    // ── Distributor pulls ───────────────────────────────────────────────
    function mintBase(uint256 epoch, address to, uint256 amount) external onlyDistributor {
        EpochBudget storage b = _finalized(epoch);
        uint256 available = b.base - b.baseMinted - b.baseReleased;
        if (amount > available) revert ExceedsBudget(amount, available);
        b.baseMinted += uint128(amount);
        epochReserved -= amount;
        _mint(to, amount);
        emit BaseMinted(epoch, to, amount);
    }

    function mintAshfall(uint256 epoch, address to, uint256 amount) external onlyDistributor {
        EpochBudget storage b = _finalized(epoch);
        uint256 available = b.ashfall - b.ashfallMinted - b.ashfallRolled;
        if (amount > available) revert ExceedsBudget(amount, available);
        b.ashfallMinted += uint128(amount);
        epochReserved -= amount;
        _mint(to, amount);
        emit AshfallMinted(epoch, to, amount);
    }

    /// @notice Base budget the distributor will never pay (e.g. empty-pool time) leaves the
    ///         reservation. It is not re-issued to anyone later (no retroactive windfall).
    function releaseBase(uint256 epoch, uint256 amount) external onlyDistributor {
        EpochBudget storage b = _finalized(epoch);
        uint256 available = b.base - b.baseMinted - b.baseReleased;
        if (amount > available) revert ExceedsBudget(amount, available);
        b.baseReleased += uint128(amount);
        epochReserved -= amount;
        emit BaseReleased(epoch, amount);
    }

    /// @notice Ashfall nobody was eligible for rolls forward into the queue (spec: roll forward).
    function rollAshfall(uint256 epoch, uint256 amount) external onlyDistributor {
        EpochBudget storage b = _finalized(epoch);
        uint256 available = b.ashfall - b.ashfallMinted - b.ashfallRolled;
        if (amount > available) revert ExceedsBudget(amount, available);
        b.ashfallRolled += uint128(amount);
        epochReserved -= amount;
        queuedAshfall += amount;
        emit AshfallRolled(epoch, amount);
    }

    // ── Registered burns ────────────────────────────────────────────────
    /// @notice A registrar burns `amount` of ITS OWN EMBER through the Mantle (it must have approved
    ///         the Mantle). Burn and recognition are one act; the category is fixed per registrar.
    function burnRegistered(uint256 amount) external returns (uint256 credit) {
        BurnCategory category = registrarCategory[msg.sender];
        if (category == BurnCategory.None) revert NotRegistrar();
        EMBER.burnFrom(msg.sender, amount);
        accounted -= amount;
        uint256 rate = category == BurnCategory.Protocol ? P.RECYCLE_PROTOCOL_BURN_PCT : P.RECYCLE_PYRE_BURN_PCT;
        credit = (amount * rate) / 100;
        uint256 epoch = epochAt(block.timestamp);
        creditsOf[epoch] += credit;
        emit BurnRecognized(msg.sender, category, amount, credit, epoch);
    }

    /// @notice The distributor burns forfeited Seal escrow (its own EMBER, approved to the
    ///         Mantle). A recognized burn: the ledger shrinks. It earns NO Ashfall credit:
    ///         Seal forfeits are not among the config's Ashfall sources (ADR 0007).
    function burnForfeited(uint256 amount) external onlyDistributor {
        EMBER.burnFrom(msg.sender, amount);
        accounted -= amount;
        emit ForfeitBurned(amount, epochAt(block.timestamp));
    }

    // ── Internals ───────────────────────────────────────────────────────
    modifier onlyDistributor() {
        if (msg.sender != DISTRIBUTOR) revert NotDistributor();
        _;
    }

    function _finalized(uint256 epoch) private view returns (EpochBudget storage) {
        if (epoch >= nextEpoch) revert EpochNotFinalized(epoch);
        return budgets[epoch];
    }

    function _mint(address to, uint256 amount) private {
        accounted += amount;
        EMBER.mint(to, amount);
    }
}
