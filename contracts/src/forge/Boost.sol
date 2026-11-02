// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";
import {ForgePool} from "./ForgePool.sol";
import {ForgeView} from "./ForgeView.sol";
import {ForgeEmissions} from "./ForgeEmissions.sol";

using ForgeView for ForgePool;

/// @notice [P] The protected valuation checkpoint (spec §6): EMBER-wei per stake-token-wei of
///         `pool`'s stake, RAY-scaled, so 6- and 18-decimal stakes need no other scaling.
///         `pool` is ForgeEmissions' index (0 ember-usdc-lp, 1 ember-weth-lp, 2 ember-single,
///         3 usdc-single). It must revert when its checkpoint is stale: Boost treats any value
///         it returns as current. Not built; its address is a deployment input (ADR 0009).
interface IValuation {
    function emberPerStake(uint256 pool) external view returns (uint256);
}

/// @notice [P] Cumulative registered Pyre burns of a wallet, in EMBER-wei (the Relics
///         contract; not built). Boost applies the canonical tiers itself.
interface IPyreLedger {
    function pyreBurned(address wallet) external view returns (uint256);
}

interface IMantleBurn {
    function burnRegistered(uint256 amount) external returns (uint256 credit);
    function registrarCategory(address registrar) external view returns (uint8);
}

/// @title Boost
/// @notice The Capstone (spec v5.5 §6) and the ordinary Heat bonus of every Forge position
///         (ADR 0008, ADR 0009). One contract holds three fixed roles: every pool's `BOOST`,
///         ForgeEmissions' `CAPSTONE` consumer, and a Protocol-category burn registrar.
///
///         A position's owner keeps EMBER in its Capstone. It earns no emissions; it raises the
///         position's bonus by +0.5 at most, linearly up to a Capstone value of half the stake's
///         custody value. Pyre adds up to +0.15 from its owner's registered burns. Fees of 1% on
///         Capstone deposits and withdrawals are burned.
///
///         Raising a bonus reads the valuation; nothing else does. A withdrawal lowers the bonus
///         by the remaining Capstone fraction and pays out without any price, so an unavailable
///         valuation can never hold Capstone EMBER. The pools never call Boost.
///
///         Deeds (ADR 0011): the Capstone travels with its position. While the position is listed
///         its owner can neither deposit nor request a withdrawal. After a sale the new owner
///         starts with a fresh raise allowance and a fresh withdrawal plan; the pool has zeroed
///         the bonus, and the first raise restores it with the new owner's Pyre.
///
///         Stoke (ADR 0013): the owner compounds the position's unclaimed rewards into its Capstone,
///         with no fee (the protocol Compound fee is zero), no timer and no sale. Keepers may Stoke
///         only a position whose owner opted in, within the canonical tip, interval and size limits;
///         the settings lapse at a sale. A Stoke's raise spends the caller side's raise allowance.
contract Boost is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    struct Ticket {
        uint128 amount;
        uint40 maturity;
    }

    /// @dev The owner's keeper settings (spec §210); `tipBps == 0` means off. `last` is the time
    ///      of the last keeper Stoke, which the interval counts from; the owner's own Stokes and
    ///      changes of settings leave it as it is.
    struct Keeper {
        uint16 tipBps;
        uint32 interval;
        uint40 last;
        uint128 minSize;
    }

    /// @dev One position's Capstone. `capstone` counts toward the bonus; a pending withdrawal
    ///      (one at a time) is held outside it. The plan mirrors ForgePool's cooling plan: a
    ///      frozen reference, cumulative requests over the horizon, quota kept on cancel.
    struct Account {
        uint128 capstone;
        uint40 ownerRaiseAt;
        uint40 publicRaiseAt;
        uint32 transfers; // the pool's sale count when this owner's allowance and plan began
        uint40 planStart;
        uint128 planReference;
        uint128 planRequested;
        Ticket pending;
        Keeper keeper;
    }

    ForgeEmissions public immutable EMISSIONS;
    IERC20 public immutable EMBER;
    IMantleBurn public immutable MANTLE;
    IValuation public immutable VALUATION;
    IPyreLedger public immutable PYRE;
    ForgePool internal immutable POOL_0;
    ForgePool internal immutable POOL_1;
    ForgePool internal immutable POOL_2;
    ForgePool internal immutable POOL_3;
    /// @dev Bit i set: pool i stakes EMBER itself, so its value needs no valuation.
    uint256 internal immutable EMBER_POOLS;

    mapping(uint256 pool => mapping(uint256 id => Account)) internal _accounts;
    /// @notice Booked Capstone fees, burned by anyone through `burnFees`.
    uint256 public feesToBurn;

    event CapstoneDeposited(uint256 indexed pool, uint256 indexed id, uint256 net, uint256 fee);
    event EscrowClaimed(uint256 indexed pool, uint256 indexed id, uint256 amount);
    event WithdrawRequested(uint256 indexed pool, uint256 indexed id, uint256 amount, uint256 maturity);
    event WithdrawExecuted(uint256 indexed pool, uint256 indexed id, uint256 net, uint256 fee);
    event WithdrawResumed(uint256 indexed pool, uint256 indexed id, uint256 amount, bool lapsed);
    event BonusSet(uint256 indexed pool, uint256 indexed id, uint256 units);
    event BonusUnavailable(uint256 indexed pool, uint256 indexed id);
    event BonusUnsynced(uint256 indexed pool, uint256 indexed id, uint256 units);
    event FeesBurned(uint256 amount);
    event Stoked(uint256 indexed pool, uint256 indexed id, address indexed by, uint256 amount, uint256 tip);
    event KeeperSet(uint256 indexed pool, uint256 indexed id, uint256 tipBps, uint256 interval, uint256 minSize);
    event RaiseDeferred(uint256 indexed pool, uint256 indexed id, uint256 units);

    error ZeroAddress();
    error Miswired();
    error UnknownPool(uint256 pool);
    error NotOwner(uint256 pool, uint256 id);
    error Closed(uint256 pool, uint256 id);
    error ZeroAmount();
    error ExceedsCapstone(uint256 amount, uint256 capstone);
    error PlanQuotaExceeded(uint256 requested, uint256 referenceBalance);
    error WithdrawPending(uint256 pool, uint256 id);
    error NotPending(uint256 pool, uint256 id);
    error NotMatured(uint256 maturity);
    error RaiseTooSoon(uint256 readyAt);
    error BelowMinimum(uint256 amount);
    error Listed(uint256 pool, uint256 id);
    error NothingToStoke(uint256 pool, uint256 id);
    error KeeperOff(uint256 pool, uint256 id);
    error StokeTooSoon(uint256 readyAt);
    error BelowStokeMinimum(uint256 amount, uint256 minimum);
    error BadKeeperSettings();

    /// @dev Deployed after the pools, the Mantle and ForgeEmissions, at the address each of
    ///      them was given; the constructor checks every wire.
    constructor(ForgeEmissions emissions, IValuation valuation, IPyreLedger pyre) {
        if (address(emissions) == address(0) || address(valuation) == address(0) || address(pyre) == address(0)) {
            revert ZeroAddress();
        }
        (EMISSIONS, VALUATION, PYRE) = (emissions, valuation, pyre);
        EMBER = emissions.EMBER();
        MANTLE = IMantleBurn(address(emissions.MANTLE()));
        if (emissions.CAPSTONE() != address(this) || MANTLE.registrarCategory(address(this)) != 1) revert Miswired();
        uint256 emberPools;
        ForgePool[4] memory ps;
        for (uint256 i; i < 4; ++i) {
            ps[i] = emissions.poolAt(i);
            if (ps[i].BOOST() != address(this)) revert Miswired();
            if (address(ps[i].STAKE_TOKEN()) == address(EMBER)) emberPools |= 1 << i;
        }
        (POOL_0, POOL_1, POOL_2, POOL_3, EMBER_POOLS) = (ps[0], ps[1], ps[2], ps[3], emberPools);
    }

    // ── Capstone ──────────────────────────────────────────────────────────

    /// @notice The owner adds EMBER to an open position's Capstone (1% fee, burned). The bonus
    ///         is then raised from the valuation if it is available; the deposit stands either way.
    function deposit(uint256 pool, uint256 id, uint256 amount) external nonReentrant {
        (ForgePool p, uint256 closedAt,, uint256 transfers) = _owned(pool, id, true);
        if (closedAt != 0) revert Closed(pool, id);
        if (amount == 0) revert ZeroAmount();
        EMBER.safeTransferFrom(msg.sender, address(this), amount);
        uint256 fee = (amount * P.CAPSTONE_DEPOSIT_FEE_PCT) / 100;
        if (fee == 0) revert BelowMinimum(amount); // every raise by deposit pays a burned fee
        feesToBurn += fee;
        Account storage a = _accounts[pool][id];
        _settle(pool, id, a, transfers);
        a.capstone += uint128(amount - fee);
        emit CapstoneDeposited(pool, id, amount - fee, fee);
        _tryRaise(pool, id, p, a, msg.sender);
    }

    /// @notice Anyone moves a position's vested Seal escrow into its Capstone (no fee: the
    ///         escrow was minted for it), then the bonus is raised as for a deposit.
    function claimEscrow(uint256 pool, uint256 id) external nonReentrant returns (uint256 amount) {
        ForgePool p = _pool(pool);
        amount = EMISSIONS.takeCapstone(pool, id);
        if (amount == 0) return 0;
        (address owner, uint256 closedAt,,, uint256 transfers) = p.briefOf(id);
        Account storage a = _accounts[pool][id];
        _settle(pool, id, a, transfers);
        a.capstone += uint128(amount);
        emit EscrowClaimed(pool, id, amount);
        if (closedAt == 0) _tryRaise(pool, id, p, a, owner);
    }

    /// @notice The owner starts a Capstone withdrawal on the Forge tier timers (cooldown
    ///         `sameAsWithdraw`). The amount stops counting at once: the bonus is scaled by the
    ///         remaining Capstone fraction, without any price.
    function requestWithdraw(uint256 pool, uint256 id, uint256 amount) external nonReentrant returns (uint256 maturity) {
        (ForgePool p,, uint256 current, uint256 transfers) = _owned(pool, id, true);
        Account storage a = _accounts[pool][id];
        _settle(pool, id, a, transfers);
        if (a.pending.amount != 0) revert WithdrawPending(pool, id);
        if (amount == 0) revert ZeroAmount();
        uint256 before = a.capstone;
        if (amount > before) revert ExceedsCapstone(amount, before);
        maturity = block.timestamp + _chargePlan(a, amount, before);
        a.capstone = uint128(before - amount);
        a.pending = Ticket(uint128(amount), uint40(maturity));
        emit WithdrawRequested(pool, id, amount, maturity);
        if (current != 0) _push(pool, id, p, Math.mulDiv(current, before - amount, before), false);
    }

    /// @notice The owner takes a matured withdrawal inside its 24h window (1% fee, burned).
    function executeWithdraw(uint256 pool, uint256 id) external nonReentrant returns (uint256 net) {
        (,,, uint256 transfers) = _owned(pool, id, false);
        Account storage a = _accounts[pool][id];
        _settle(pool, id, a, transfers);
        Ticket memory t = a.pending;
        if (t.amount == 0) revert NotPending(pool, id);
        if (block.timestamp < t.maturity) revert NotMatured(t.maturity);
        delete a.pending;
        uint256 fee = (uint256(t.amount) * P.CAPSTONE_WITHDRAW_FEE_PCT) / 100;
        feesToBurn += fee;
        net = t.amount - fee;
        emit WithdrawExecuted(pool, id, net, fee);
        EMBER.safeTransfer(msg.sender, net); // the owner: _owned checked it
    }

    /// @notice The owner cancels a pending withdrawal: the amount counts again (the bonus
    ///         returns on the next raise); the plan's quota stays consumed.
    function cancelWithdraw(uint256 pool, uint256 id) external nonReentrant {
        (,,, uint256 transfers) = _owned(pool, id, false);
        Account storage a = _accounts[pool][id];
        _settle(pool, id, a, transfers);
        uint256 amount = a.pending.amount;
        if (amount == 0) revert NotPending(pool, id);
        delete a.pending;
        a.capstone += uint128(amount);
        emit WithdrawResumed(pool, id, amount, false);
    }

    /// @notice Raise or lower a position's bonus to its value now. Lowering is open to anyone at
    ///         any time; raising is open to the owner and, separately, to anyone else, each at
    ///         most once per epoch, so neither can use up the other's allowance.
    function refresh(uint256 pool, uint256 id) external nonReentrant returns (uint256 units) {
        ForgePool p = _pool(pool);
        (address owner_, uint256 closedAt, uint256 current,, uint256 transfers) = p.briefOf(id);
        if (closedAt != 0 || owner_ == address(0)) return current;
        Account storage a = _accounts[pool][id];
        _settle(pool, id, a, transfers);
        units = bonusTarget(pool, id);
        if (units > current) {
            bool owner = msg.sender == owner_;
            uint256 last = owner ? a.ownerRaiseAt : a.publicRaiseAt;
            if (last != 0 && block.timestamp < last + P.EPOCH_SECONDS) revert RaiseTooSoon(last + P.EPOCH_SECONDS);
            if (owner) a.ownerRaiseAt = uint40(block.timestamp);
            else a.publicRaiseAt = uint40(block.timestamp);
        }
        if (units != current) _push(pool, id, p, units, true);
    }

    // ── Stoke (ADR 0013) ──────────────────────────────────────────────────

    /// @notice The owner compounds the position's unclaimed rewards into its Capstone (spec §6):
    ///         no fee, no timer, no sale. A pending Claim keeps its snapshot. The bonus rises now
    ///         if the owner's raise allowance is unspent this epoch; otherwise a later raise picks
    ///         it up. A listing locks it (ADR 0011).
    function stoke(uint256 pool, uint256 id) external nonReentrant returns (uint256 amount) {
        (ForgePool p, uint256 closedAt, uint256 current, uint256 transfers) = _owned(pool, id, true);
        if (closedAt != 0) revert Closed(pool, id);
        Account storage a = _accounts[pool][id];
        _settle(pool, id, a, transfers);
        amount = EMISSIONS.takeUnclaimed(pool, id);
        if (amount == 0) revert NothingToStoke(pool, id);
        a.capstone += uint128(amount);
        emit Stoked(pool, id, msg.sender, amount, 0);
        _rationedRaise(pool, id, p, a, msg.sender, current, true);
    }

    /// @notice The owner opts the position into keeper Stokes, or out with `tipBps == 0`. A tip
    ///         is 0.1–1% of each keeper Stoke; keepers wait at least 24h between Stokes and
    ///         compound at least the owner's minimum, itself at least 100 EMBER [P]. The UI
    ///         suggests 0.5%, 7 days and 100 EMBER. The settings end at a sale.
    function setKeeper(uint256 pool, uint256 id, uint256 tipBps, uint256 interval, uint256 minSize)
        external
        nonReentrant
    {
        (,,, uint256 transfers) = _owned(pool, id, false); // opting out stays open while listed
        if (tipBps == 0) {
            (interval, minSize) = (0, 0);
        } else if (
            tipBps < P.AUTO_STOKE_TIP_MIN_BPS || tipBps > P.AUTO_STOKE_TIP_MAX_BPS
                || interval < P.AUTO_STOKE_MIN_INTERVAL || interval > type(uint32).max
                || minSize < P.AUTO_STOKE_MIN_SIZE || minSize > type(uint128).max
        ) {
            revert BadKeeperSettings();
        }
        Account storage a = _accounts[pool][id];
        _settle(pool, id, a, transfers); // first, so a new owner's settings are not cleared after
        Keeper storage k = a.keeper;
        (k.tipBps, k.interval, k.minSize) = (uint16(tipBps), uint32(interval), uint128(minSize));
        emit KeeperSet(pool, id, tipBps, interval, minSize);
    }

    /// @notice Anyone Stokes a position whose owner opted in, once its interval has passed and its
    ///         unclaimed rewards reach the owner's minimum; the caller receives the tip. The owner
    ///         calling it earns none. The raise spends the public allowance (the owner's, if the
    ///         owner calls).
    function keeperStoke(uint256 pool, uint256 id) external nonReentrant returns (uint256 amount, uint256 tip) {
        ForgePool p = _pool(pool);
        (address owner, uint256 current, uint256 tipBps) = _keeperReady(pool, id, p);
        Account storage a = _accounts[pool][id];
        amount = EMISSIONS.takeUnclaimed(pool, id);
        bool byOwner = msg.sender == owner;
        if (!byOwner) tip = (amount * tipBps) / 10_000;
        a.capstone += uint128(amount - tip);
        emit Stoked(pool, id, msg.sender, amount - tip, tip);
        if (tip != 0) EMBER.safeTransfer(msg.sender, tip);
        _rationedRaise(pool, id, p, a, owner, current, byOwner);
    }

    /// @dev A keeper Stoke's checks: open, not listed, opted in under this owner, the interval
    ///      passed and the minimum reached. Starts the next interval now.
    function _keeperReady(uint256 pool, uint256 id, ForgePool p)
        internal
        returns (address owner, uint256 current, uint256 tipBps)
    {
        uint256 closedAt;
        uint256 listing;
        uint256 transfers;
        (owner, closedAt, current, listing, transfers) = p.briefOf(id);
        if (closedAt != 0) revert Closed(pool, id);
        if (listing & 1 != 0) revert Listed(pool, id);
        Account storage a = _accounts[pool][id];
        _settle(pool, id, a, transfers);
        Keeper storage k = a.keeper;
        tipBps = k.tipBps;
        if (tipBps == 0) revert KeeperOff(pool, id);
        uint256 readyAt = uint256(k.last) + k.interval;
        if (block.timestamp < readyAt) revert StokeTooSoon(readyAt);
        uint256 owed = EMISSIONS.unclaimed(pool, id);
        if (owed < k.minSize) revert BelowStokeMinimum(owed, k.minSize);
        k.last = uint40(block.timestamp);
    }

    /// @notice Burn the booked Capstone fees through the Mantle (Protocol category).
    function burnFees() external nonReentrant returns (uint256 amount) {
        amount = feesToBurn;
        if (amount == 0) return 0;
        feesToBurn = 0;
        EMBER.forceApprove(address(MANTLE), amount);
        MANTLE.burnRegistered(amount);
        emit FeesBurned(amount);
    }

    // ── views ─────────────────────────────────────────────────────────────

    function accountOf(uint256 pool, uint256 id) external view returns (Account memory) {
        return _accounts[pool][id];
    }

    /// @notice The bonus a position earns now (units of ORDINARY_BONUS_UNIT_RAY): Capstone
    ///         against its custody value, plus its owner's Pyre. Reads the valuation unless
    ///         the pool stakes EMBER; reverts if a source does.
    function bonusTarget(uint256 pool, uint256 id) public view returns (uint256) {
        ForgePool p = _pool(pool);
        uint256 rate = EMBER_POOLS & (1 << pool) != 0 ? P.RAY : VALUATION.emberPerStake(pool);
        return capstoneUnits(_accounts[pool][id].capstone, p.custodyOf(id), rate)
            + pyreUnits(PYRE.pyreBurned(p.ownerOf(id)));
    }

    /// @notice The Capstone part: +0.5 × min(ratio, 0.5) / 0.5, ratio = Capstone EMBER ÷ the
    ///         custody's EMBER value (custody · rate / RAY). Both roundings err against the
    ///         holder; zero custody or a zero rate gives zero.
    function capstoneUnits(uint256 capstone, uint256 custody, uint256 rate) public pure returns (uint256) {
        uint256 value = Math.mulDiv(custody, rate, P.RAY, Math.Rounding.Ceil);
        if (capstone == 0 || value == 0) return 0;
        uint256 forMax = Math.mulDiv(value, P.CAPSTONE_RATIO_FOR_MAX_RAY, P.RAY, Math.Rounding.Ceil);
        if (capstone >= forMax) return P.CAPSTONE_MAX_BONUS_UNITS;
        return Math.mulDiv(capstone, P.CAPSTONE_MAX_BONUS_UNITS, forMax);
    }

    /// @notice The Pyre part: the canonical tiers by cumulative registered burn, capped.
    function pyreUnits(uint256 burned) public pure returns (uint256 units) {
        if (burned >= P.PYRE_TIER_0_BURN) units += P.PYRE_TIER_0_UNITS;
        if (burned >= P.PYRE_TIER_1_BURN) units += P.PYRE_TIER_1_UNITS;
        if (burned >= P.PYRE_TIER_2_BURN) units += P.PYRE_TIER_2_UNITS;
        return Math.min(units, P.PYRE_MAX_BOOST_UNITS);
    }

    // ── internals ─────────────────────────────────────────────────────────

    function _pool(uint256 i) internal view returns (ForgePool) {
        if (i == 0) return POOL_0;
        if (i == 1) return POOL_1;
        if (i == 2) return POOL_2;
        if (i == 3) return POOL_3;
        revert UnknownPool(i);
    }

    /// @dev The caller must own the position; returns its closure time, current bonus and sales.
    ///      A listing locks the owner's mutations (`locked`; ADR 0011).
    function _owned(uint256 pool, uint256 id, bool locked)
        internal
        view
        returns (ForgePool p, uint256 closedAt, uint256 bonus, uint256 transfers)
    {
        p = _pool(pool);
        (address owner, uint256 c, uint256 b, uint256 listing, uint256 t) = p.briefOf(id);
        if (owner != msg.sender) revert NotOwner(pool, id);
        if (locked && listing & 1 != 0) revert Listed(pool, id);
        return (p, c, b, t);
    }

    /// @dev A new owner (the pool counted a sale since this account last looked) starts with an
    ///      unused raise allowance, no withdrawal plan and no keeper settings. A withdrawal not
    ///      executed by the end of its window returns to the Capstone.
    function _settle(uint256 pool, uint256 id, Account storage a, uint256 transfers) internal {
        if (transfers != a.transfers) {
            (a.transfers, a.ownerRaiseAt, a.planStart) = (uint32(transfers), 0, 0);
            delete a.keeper;
        }
        Ticket memory t = a.pending;
        if (t.amount == 0 || block.timestamp < uint256(t.maturity) + P.WITHDRAW_EXECUTION_WINDOW) return;
        delete a.pending;
        a.capstone += t.amount;
        emit WithdrawResumed(pool, id, t.amount, true);
    }

    /// @dev ForgePool._chargePlan for the Capstone: a new plan once the horizon has passed
    ///      (nothing is pending here), cumulative requests against its frozen reference.
    function _chargePlan(Account storage a, uint256 amount, uint256 balance) internal returns (uint256) {
        if (a.planStart == 0 || block.timestamp >= uint256(a.planStart) + P.COOLING_PLAN_HORIZON) {
            (a.planStart, a.planReference, a.planRequested) = (uint40(block.timestamp), uint128(balance), 0);
        }
        uint256 requested = a.planRequested + amount;
        if (requested > a.planReference) revert PlanQuotaExceeded(requested, a.planReference);
        a.planRequested = uint128(requested);
        uint256 ref = a.planReference;
        if (requested * 100 <= ref * P.WITHDRAW_TIER_0_MAX_PCT) return P.WITHDRAW_TIER_0_SECONDS;
        if (requested * 100 <= ref * P.WITHDRAW_TIER_1_MAX_PCT) return P.WITHDRAW_TIER_1_SECONDS;
        if (requested * 100 <= ref * P.WITHDRAW_TIER_2_MAX_PCT) return P.WITHDRAW_TIER_2_SECONDS;
        if (requested * 100 <= ref * P.WITHDRAW_TIER_3_MAX_PCT) return P.WITHDRAW_TIER_3_SECONDS;
        return P.WITHDRAW_TIER_4_SECONDS;
    }

    /// @dev Raise after a deposit or escrow: skipped (the deposit stands) if a source fails. A
    ///      deposit pays a burned fee and escrow arrives once per Seal, so neither is rationed.
    function _tryRaise(uint256 pool, uint256 id, ForgePool p, Account storage a, address owner) internal {
        (bool ok, uint256 units) = _target(pool, id, p, a, owner);
        if (ok) _push(pool, id, p, units, false);
    }

    /// @dev A Stoke's raise: fee-free, so it spends the caller side's once-per-epoch allowance, like
    ///      `refresh`. Spent, the Capstone still grows and the raise waits for a later one. Lowering
    ///      needs no allowance.
    function _rationedRaise(
        uint256 pool,
        uint256 id,
        ForgePool p,
        Account storage a,
        address owner,
        uint256 current,
        bool byOwner
    ) internal {
        (bool ok, uint256 units) = _target(pool, id, p, a, owner);
        if (!ok || units == current) return;
        if (units > current) {
            uint256 last = byOwner ? a.ownerRaiseAt : a.publicRaiseAt;
            if (last != 0 && block.timestamp < last + P.EPOCH_SECONDS) {
                emit RaiseDeferred(pool, id, units);
                return;
            }
            if (byOwner) a.ownerRaiseAt = uint40(block.timestamp);
            else a.publicRaiseAt = uint40(block.timestamp);
        }
        _push(pool, id, p, units, false);
    }

    /// @dev The bonus the position earns now, or ok = false (reported) if a source fails.
    function _target(uint256 pool, uint256 id, ForgePool p, Account storage a, address owner)
        internal
        returns (bool ok, uint256 units)
    {
        uint256 rate = P.RAY;
        if (EMBER_POOLS & (1 << pool) == 0) {
            try VALUATION.emberPerStake(pool) returns (uint256 r) {
                rate = r;
            } catch {
                emit BonusUnavailable(pool, id);
                return (false, 0);
            }
            // Custody is below 2^106, so a rate below 2^160 cannot overflow the units (a
            // 6-decimal stake's RAY rate is already ~1e39); a larger one counts as unavailable.
            if (rate > type(uint160).max) {
                emit BonusUnavailable(pool, id);
                return (false, 0);
            }
        }
        uint256 burned;
        try PYRE.pyreBurned(owner) returns (uint256 b) {
            burned = b;
        } catch {
            emit BonusUnavailable(pool, id);
            return (false, 0);
        }
        return (true, capstoneUnits(a.capstone, p.custodyOf(id), rate) + pyreUnits(burned));
    }

    /// @dev Set the pool's bonus. Only `refresh` lets a pool failure revert; elsewhere it is
    ///      reported, so no Capstone action depends on the pool accepting the write.
    function _push(uint256 pool, uint256 id, ForgePool p, uint256 units, bool strict) internal {
        if (strict) {
            p.setOrdinaryBonus(id, units);
        } else {
            try p.setOrdinaryBonus(id, units) {}
            catch {
                emit BonusUnsynced(pool, id, units);
                return;
            }
        }
        emit BonusSet(pool, id, units);
    }
}
