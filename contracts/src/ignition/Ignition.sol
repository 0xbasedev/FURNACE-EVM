// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {FurnaceParams as P} from "../generated/FurnaceParams.sol";
import {ForgePool} from "../forge/ForgePool.sol";
import {ForgeView} from "../forge/ForgeView.sol";
import {Lot} from "../forge/ForgeMeasures.sol";

/// @notice What Ignition uses of the AshLedger: its one-time release, and whether it has happened.
interface IIgnitionLedger {
    function releaseIgnition() external returns (uint256);
    function ignitionReleased() external view returns (bool);
}

/// @notice What Ignition reads of Kindling: when it settled (zero until it does).
interface IIgnitionKindling {
    function closedAt() external view returns (uint256);
}

/// @notice What Ignition reads of BlastPool (the EMBER/USDC pair) to value pool-0 LP.
interface IIgnitionPair {
    function consult(uint32 window) external view returns (uint256 priceX112, uint32 elapsed);
    function getReserves() external view returns (uint112 ember, uint112 quote, uint32 updatedAt);
    function totalSupply() external view returns (uint256);
}

/// @title Ignition: the genesis farm, the founder record and the head start (spec v5.5 §2; ADR 0023)
/// @notice A 120-hour farm that pays ASH's 41,000-ASH Ignition leaf, per second, pro rata within
///         each pool: USDC, WETH, WBTC and (once one is bound) the WETH/USDC LP, weighted
///         100/100/100/150 over the bound pools [P]. Units are never added across assets.
///
///         - Deposits pay the 3% genesis fee to the Treasury at once; it is never refunded.
///           Each deposit is a lot with a fixed early-bird weight, +10% at START falling linearly
///           to +0% at END (`weightAt`, the canonical `ignitionWeight` in ppm, floored [P]).
///         - Principal may leave at any time; withdrawals take the youngest lot first [P], and
///           withdrawn principal stops earning. Time a pool sits empty accrues to nobody and is
///           burned at close [P], as is the budgets' rounding.
///         - At END deposits stop and so do rewards. `finalize` takes the 41,000 from the
///           ledger and burns what accrued to nobody; rewards are then claimable.
///         - For 24 hours after END every asset may leave fee-free. After that a wallet's USDC,
///           unless it opted out at deposit, goes only to Cold Storage (Forge pool 3), through the
///           permissionless `stakeUsdc`, at the pool's standard 1% fee [P]. WETH, WBTC, LP and
///           opted-out USDC stay withdrawable fee-free, forever.
///         - It is every pool's FOUNDERS: a wallet that kept principal through END is a founder
///           (First Flame). And it is every pool's IGNITION: within 7 days of Kindling's close a
///           wallet may date one new lot back to Ignition's start, once, if the lot is worth no
///           more than the USDC it kept through END [P].
///         No admin, no pause, no upgrade. Not audited.
contract Ignition is ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using ForgeView for ForgePool;

    /// @notice The pools, by their asset.
    uint8 public constant USDC_POOL = 0;
    uint8 public constant WETH_POOL = 1;
    uint8 public constant WBTC_POOL = 2;
    uint8 public constant LP_POOL_ID = 3;
    uint256 internal constant POOLS = 4;
    /// @notice The most lots a wallet holds in one pool [P].
    uint256 public constant MAX_LOTS = 16;
    uint256 public constant PPM = 1_000_000;
    /// @notice The accumulator's scale [P].
    uint256 public constant PREC = 1e24;
    uint256 internal constant BPS = 10_000;

    IERC20 public immutable USDC;
    IERC20 public immutable WETH;
    IERC20 public immutable WBTC;
    /// @notice The WETH/USDC LP; zero leaves its pool unbound and its weight to the others.
    IERC20 public immutable LP;
    ERC20Burnable public immutable ASH;
    IIgnitionLedger public immutable LEDGER;
    address public immutable TREASURY;
    /// @notice Forge pool 3 (USDC): where USDC auto-stakes, and one of the head start's pools.
    ForgePool public immutable COLD_STORAGE;
    /// @notice Forge pool 0 (EMBER/USDC LP): the head start's other pool.
    ForgePool public immutable LP_POOL;
    /// @notice BlastPool, whose TWAP values pool-0 LP for the head start's cap.
    IIgnitionPair public immutable BLASTPOOL;
    IIgnitionKindling public immutable KINDLING;
    uint256 public immutable START;
    uint256 public immutable END;
    uint256 internal immutable BUDGET_0;
    uint256 internal immutable BUDGET_1;
    uint256 internal immutable BUDGET_2;
    uint256 internal immutable BUDGET_3;

    struct Pool {
        uint256 lastB; // the cumulative budget accounted
        uint256 acc; // ASH per weighted unit, scaled by PREC
        uint256 unallocated; // budget that accrued while the pool was empty
        uint256 principal;
        uint256 weighted; // Σ amount · ppm
    }

    struct IgnitionLot {
        uint128 amount;
        uint32 ppm;
    }

    struct Account {
        uint256 principal;
        uint256 weighted;
        uint256 accSnap;
        uint256 earned;
        uint8 lots;
    }

    struct Wallet {
        bool optedOut;
        bool snapped;
        bool founder;
        bool headStartUsed;
        uint256 usdcKept;
        uint256 claimed;
    }

    Pool[4] internal _pools;
    mapping(address => Account[4]) internal _accounts;
    mapping(address => IgnitionLot[16][4]) internal _lots;
    mapping(address => Wallet) public wallets;
    bool public finalized;
    /// @notice ASH burned at close, and ASH paid out so far.
    uint256 public burned;
    uint256 public paid;

    struct Config {
        IERC20 usdc;
        IERC20 weth;
        IERC20 wbtc;
        IERC20 lp;
        ERC20Burnable ash;
        IIgnitionLedger ledger;
        address treasury;
        ForgePool coldStorage;
        ForgePool lpPool;
        IIgnitionPair blastPool;
        IIgnitionKindling kindling;
        uint256 start;
    }

    event Deposited(address indexed wallet, uint8 indexed pool, uint256 gross, uint256 net, uint256 ppm);
    event Withdrawn(address indexed wallet, uint8 indexed pool, uint256 amount);
    event OptedOut(address indexed wallet);
    event Finalized(uint256 burned);
    event Claimed(address indexed wallet, uint256 amount);
    event StakedUsdc(address indexed wallet, uint256 indexed positionId, uint256 amount);
    event HeadStartGranted(address indexed wallet, address indexed pool, uint256 indexed id, uint256 slot, uint256 seconds_);

    error ZeroAddress();
    error PoolDisabled(uint8 pool);
    error NotOpen();
    error BelowMinimum(uint256 gross);
    error TooManyLots();
    error BadAmount(uint256 amount, uint256 principal);
    error MustStake();
    error TooEarly();
    error AlreadyFinalized();
    error FundingMismatch(uint256 held);
    error NothingOwed(address wallet);
    error NothingToStake(address wallet);
    error NotEligiblePool(address pool);
    error NotInWindow();
    error HeadStartUsed(address wallet);
    error NotOwner(uint256 id);
    error NotNewCapital(uint256 id, uint256 slot);
    error OverCap(uint256 value, uint256 kept);
    error StaleOracle(uint32 elapsed);

    /// @dev Stores addresses only: the ledger, the pools, BlastPool and Kindling may deploy later
    ///      at their predicted CREATE3 addresses.
    constructor(Config memory c) {
        if (
            address(c.usdc) == address(0) || address(c.weth) == address(0) || address(c.wbtc) == address(0)
                || address(c.ash) == address(0) || address(c.ledger) == address(0) || c.treasury == address(0)
                || address(c.coldStorage) == address(0) || address(c.lpPool) == address(0)
                || address(c.blastPool) == address(0) || address(c.kindling) == address(0) || c.start == 0
        ) revert ZeroAddress();
        (USDC, WETH, WBTC, LP, ASH, LEDGER, TREASURY) = (c.usdc, c.weth, c.wbtc, c.lp, c.ash, c.ledger, c.treasury);
        (COLD_STORAGE, LP_POOL, BLASTPOOL, KINDLING) = (c.coldStorage, c.lpPool, c.blastPool, c.kindling);
        (START, END) = (c.start, c.start + P.IGNITION_DURATION);
        uint256 lpWeight = address(c.lp) == address(0) ? 0 : P.IGNITION_WEIGHT_LP;
        uint256 sum = P.IGNITION_WEIGHT_USDC + P.IGNITION_WEIGHT_WETH + P.IGNITION_WEIGHT_WBTC + lpWeight;
        BUDGET_0 = (P.ASH_IGNITION_ALLOCATION * P.IGNITION_WEIGHT_USDC) / sum;
        BUDGET_1 = (P.ASH_IGNITION_ALLOCATION * P.IGNITION_WEIGHT_WETH) / sum;
        BUDGET_2 = (P.ASH_IGNITION_ALLOCATION * P.IGNITION_WEIGHT_WBTC) / sum;
        BUDGET_3 = (P.ASH_IGNITION_ALLOCATION * lpWeight) / sum;
    }

    // ── the farm ──────────────────────────────────────────────────────────

    /// @notice Deposit `gross` of pool `pool`'s asset in [START, END). 3% goes to the Treasury now;
    ///         the rest is a lot at this second's early-bird weight. `optOutUsdc` on a USDC deposit
    ///         keeps the wallet's USDC out of Cold Storage at close, for good.
    function deposit(uint8 pool, uint256 gross, bool optOutUsdc)
        external
        nonReentrant
        returns (uint256 net, uint256 ppm)
    {
        IERC20 token = _live(pool);
        if (block.timestamp < START || block.timestamp >= END) revert NotOpen();
        uint256 fee = (gross * P.IGNITION_FEE_BPS) / BPS;
        if (fee == 0) revert BelowMinimum(gross);
        net = gross - fee;
        ppm = weightAt(block.timestamp);
        Account storage a = _accounts[msg.sender][pool];
        IgnitionLot[16] storage lots = _lots[msg.sender][pool];
        uint256 n = a.lots;
        bool merge = n != 0 && lots[n - 1].ppm == ppm;
        if (!merge && n == MAX_LOTS) revert TooManyLots();
        _touch(pool, a);
        _pull(token, gross);
        token.safeTransfer(TREASURY, fee);
        if (merge) {
            lots[n - 1].amount = SafeCast.toUint128(lots[n - 1].amount + net);
        } else {
            // forge-lint: disable-next-line(unsafe-typecast) — ppm is at most 1.1e6
            lots[n] = IgnitionLot(SafeCast.toUint128(net), uint32(ppm));
            // forge-lint: disable-next-line(unsafe-typecast) — n < MAX_LOTS
            a.lots = uint8(n + 1);
        }
        (a.principal, a.weighted) = (a.principal + net, a.weighted + net * ppm);
        Pool storage p = _pools[pool];
        (p.principal, p.weighted) = (p.principal + net, p.weighted + net * ppm);
        if (pool == USDC_POOL && optOutUsdc && !wallets[msg.sender].optedOut) {
            wallets[msg.sender].optedOut = true;
            emit OptedOut(msg.sender);
        }
        emit Deposited(msg.sender, pool, gross, net, ppm);
    }

    /// @notice Withdraw `amount` of principal, youngest lot first. Fee-free, at any time, except
    ///         a wallet's non-opted-out USDC once the free-exit window has passed: that goes to
    ///         Cold Storage (`stakeUsdc`). Returns the amount and how many lots it emptied.
    function withdraw(uint8 pool, uint256 amount) external nonReentrant returns (uint256, uint256 emptied) {
        IERC20 token = _live(pool);
        Account storage a = _accounts[msg.sender][pool];
        if (amount == 0 || amount > a.principal) revert BadAmount(amount, a.principal);
        if (pool == USDC_POOL && !wallets[msg.sender].optedOut && block.timestamp >= END + P.IGNITION_EXIT_WINDOW) {
            revert MustStake();
        }
        _snap(msg.sender);
        _touch(pool, a);
        IgnitionLot[16] storage lots = _lots[msg.sender][pool];
        Pool storage p = _pools[pool];
        uint256 n = a.lots;
        uint256 left = amount;
        while (left != 0) {
            IgnitionLot storage lot = lots[n - 1];
            uint256 take = Math.min(lot.amount, left);
            uint256 w = take * lot.ppm;
            // forge-lint: disable-next-line(unsafe-typecast) — take ≤ lot.amount
            lot.amount -= uint128(take);
            left -= take;
            (a.weighted, p.weighted) = (a.weighted - w, p.weighted - w);
            if (lot.amount == 0) {
                --n;
                ++emptied;
            }
        }
        // forge-lint: disable-next-line(unsafe-typecast) — n only fell
        a.lots = uint8(n);
        (a.principal, p.principal) = (a.principal - amount, p.principal - amount);
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, pool, amount);
        return (amount, emptied);
    }

    // ── the close ─────────────────────────────────────────────────────────

    /// @notice Permissionless, once, from END: brings every pool to END, takes the 41,000 from
    ///         the ledger (whoever released it) and burns what accrued to nobody.
    function finalize() external nonReentrant returns (uint256) {
        if (finalized) revert AlreadyFinalized();
        _finalize();
        return burned;
    }

    /// @notice Pay `wallet` its ASH. Permissionless; ASH only goes to the wallet.
    function claim(address wallet) external nonReentrant returns (uint256 amount) {
        _finalize();
        amount = _claim(wallet);
        if (amount == 0) revert NothingOwed(wallet);
    }

    /// @notice A caller-sized page of `claim`; wallets owed nothing are skipped.
    function claimMany(address[] calldata wallets_) external nonReentrant returns (uint256 total) {
        _finalize();
        for (uint256 i; i < wallets_.length; ++i) total += _claim(wallets_[i]);
    }

    /// @notice After the free-exit window: stake `wallet`'s USDC into Cold Storage as its own
    ///         position, unless it opted out. Permissionless. Returns the position and the amount.
    function stakeUsdc(address wallet) external nonReentrant returns (uint256 id, uint256 amount) {
        if (block.timestamp < END + P.IGNITION_EXIT_WINDOW) revert TooEarly();
        bool ok;
        (ok, id, amount) = _stake(wallet);
        if (!ok) revert NothingToStake(wallet);
    }

    /// @notice A caller-sized page of `stakeUsdc`; wallets with nothing to stake are skipped.
    function stakeUsdcMany(address[] calldata wallets_) external nonReentrant returns (uint256 count, uint256 total) {
        if (block.timestamp < END + P.IGNITION_EXIT_WINDOW) revert TooEarly();
        for (uint256 i; i < wallets_.length; ++i) {
            (bool ok,, uint256 amount) = _stake(wallets_[i]);
            if (ok) (count, total) = (count + 1, total + amount);
        }
    }

    // ── First Flame and the head start ────────────────────────────────────

    /// @notice The pools' FOUNDERS source: a wallet that kept principal in Ignition through END.
    function isFounder(address wallet) external view returns (bool) {
        if (block.timestamp < END) return false;
        Wallet storage x = wallets[wallet];
        return x.snapped ? x.founder : _anyPrincipal(wallet);
    }

    /// @notice The USDC `wallet` kept in Ignition through END: the head start's cap.
    function usdcKeptOf(address wallet) public view returns (uint256) {
        if (block.timestamp < END) return 0;
        Wallet storage x = wallets[wallet];
        return x.snapped ? x.usdcKept : _accounts[wallet][USDC_POOL].principal;
    }

    /// @notice Within 7 days of Kindling's close, date lot `slot` of the caller's position `id`
    ///         in Cold Storage or pool 0 back to Ignition's start: once per wallet, for a lot
    ///         opened after END and worth at most the USDC the caller kept through END [P].
    ///         Cold Storage's USDC counts at $1; pool-0 LP at its fair value on BlastPool's TWAP.
    function grantHeadStart(ForgePool pool, uint256 id, uint256 slot) external nonReentrant returns (uint256 seconds_) {
        if (pool != COLD_STORAGE && pool != LP_POOL) revert NotEligiblePool(address(pool));
        uint256 closed = KINDLING.closedAt();
        if (closed == 0 || block.timestamp > closed + P.IGNITION_HEAD_START_WINDOW) revert NotInWindow();
        Wallet storage x = wallets[msg.sender];
        if (x.headStartUsed) revert HeadStartUsed(msg.sender);
        if (pool.positionOf(id).owner != msg.sender) revert NotOwner(id);
        if (slot >= 32) revert NotNewCapital(id, slot);
        Lot memory lot = pool.lotOf(id, slot);
        // The lot's age-zero time: its deposit, or later if it has cooled.
        uint256 openedAt = uint256(lot.since) - lot.age;
        if (lot.amount == 0 || openedAt < END) revert NotNewCapital(id, slot);
        uint256 value = pool == COLD_STORAGE ? lot.amount : _lpValue(lot.amount);
        uint256 kept = usdcKeptOf(msg.sender);
        if (value > kept) revert OverCap(value, kept);
        _snap(msg.sender);
        x.headStartUsed = true;
        seconds_ = openedAt - START;
        pool.grantHeadStart(id, slot, seconds_);
        emit HeadStartGranted(msg.sender, address(pool), id, slot, seconds_);
    }

    // ── views ─────────────────────────────────────────────────────────────

    /// @notice The early-bird weight, in ppm, of a deposit at `t`: 1.1e6 at START falling linearly
    ///         to 1e6 at END (the canonical `ignitionWeight`, floored) [P].
    function weightAt(uint256 t) public view returns (uint256) {
        if (t >= END) return PPM;
        if (t < START) t = START;
        return PPM + (P.IGNITION_EARLY_BIRD_PPM * (END - t)) / P.IGNITION_DURATION;
    }

    /// @notice Pool `pool`'s share of the 41,000.
    function budgetOf(uint8 pool) public view returns (uint256) {
        if (pool == 0) return BUDGET_0;
        if (pool == 1) return BUDGET_1;
        if (pool == 2) return BUDGET_2;
        if (pool == 3) return BUDGET_3;
        return 0;
    }

    /// @notice Pool `pool`'s budget released by `t`: floor(budget · elapsed / duration).
    function cumulativeAt(uint8 pool, uint256 t) public view returns (uint256) {
        t = Math.min(Math.max(t, START), END);
        return (budgetOf(pool) * (t - START)) / P.IGNITION_DURATION;
    }

    function poolOf(uint8 pool) external view returns (Pool memory) {
        return _pools[pool];
    }

    function accountOf(address wallet, uint8 pool) external view returns (Account memory) {
        return _accounts[wallet][pool];
    }

    function lotOf(address wallet, uint8 pool, uint256 i) external view returns (IgnitionLot memory) {
        return _lots[wallet][pool][i];
    }

    /// @notice `wallet`'s unclaimed ASH, accrued to now (to END after the close).
    function pending(address wallet) external view returns (uint256 total) {
        for (uint8 k; k < POOLS; ++k) {
            if (budgetOf(k) == 0) continue;
            Pool storage p = _pools[k];
            Account storage a = _accounts[wallet][k];
            uint256 acc = p.acc;
            uint256 delta = cumulativeAt(k, block.timestamp) - p.lastB;
            if (delta != 0 && p.weighted != 0) acc += (delta * PREC) / p.weighted;
            total += a.earned + (a.weighted * (acc - a.accSnap)) / PREC;
        }
    }

    // ── internals ─────────────────────────────────────────────────────────

    function _live(uint8 pool) internal view returns (IERC20 token) {
        if (pool == USDC_POOL) return USDC;
        if (pool == WETH_POOL) return WETH;
        if (pool == WBTC_POOL) return WBTC;
        if (pool == LP_POOL_ID && address(LP) != address(0)) return LP;
        revert PoolDisabled(pool);
    }

    function _update(uint8 pool) internal {
        Pool storage p = _pools[pool];
        uint256 b = cumulativeAt(pool, block.timestamp);
        uint256 delta = b - p.lastB;
        if (delta == 0) return;
        if (p.weighted == 0) p.unallocated += delta;
        else p.acc += (delta * PREC) / p.weighted;
        p.lastB = b;
    }

    function _touch(uint8 pool, Account storage a) internal {
        _update(pool);
        uint256 acc = _pools[pool].acc;
        a.earned += (a.weighted * (acc - a.accSnap)) / PREC;
        a.accSnap = acc;
    }

    /// @dev At a wallet's first action from END: record whether it kept principal and how much
    ///      USDC. Nothing can be deposited from END, so its live principal until then is its
    ///      principal at END.
    function _snap(address wallet) internal {
        Wallet storage x = wallets[wallet];
        if (block.timestamp < END || x.snapped) return;
        (x.snapped, x.founder, x.usdcKept) = (true, _anyPrincipal(wallet), _accounts[wallet][USDC_POOL].principal);
    }

    function _anyPrincipal(address wallet) internal view returns (bool) {
        Account[4] storage a = _accounts[wallet];
        return a[0].principal != 0 || a[1].principal != 0 || a[2].principal != 0 || a[3].principal != 0;
    }

    function _finalize() internal {
        if (finalized) return;
        if (block.timestamp < END) revert TooEarly();
        finalized = true;
        uint256 burn = P.ASH_IGNITION_ALLOCATION - BUDGET_0 - BUDGET_1 - BUDGET_2 - BUDGET_3;
        for (uint8 k; k < POOLS; ++k) {
            _update(k);
            burn += _pools[k].unallocated;
        }
        if (!LEDGER.ignitionReleased()) LEDGER.releaseIgnition();
        uint256 held = IERC20(address(ASH)).balanceOf(address(this));
        if (held < P.ASH_IGNITION_ALLOCATION) revert FundingMismatch(held);
        burned = burn;
        if (burn != 0) ASH.burn(burn);
        emit Finalized(burn);
    }

    function _claim(address wallet) internal returns (uint256 amount) {
        for (uint8 k; k < POOLS; ++k) {
            if (budgetOf(k) == 0) continue;
            Account storage a = _accounts[wallet][k];
            _touch(k, a);
            (amount, a.earned) = (amount + a.earned, 0);
        }
        if (amount == 0) return 0;
        wallets[wallet].claimed += amount;
        paid += amount;
        IERC20(address(ASH)).safeTransfer(wallet, amount);
        emit Claimed(wallet, amount);
    }

    function _stake(address wallet) internal returns (bool, uint256 id, uint256 amount) {
        Account storage a = _accounts[wallet][USDC_POOL];
        if (wallets[wallet].optedOut || a.principal == 0) return (false, 0, 0);
        _snap(wallet);
        _touch(USDC_POOL, a);
        amount = a.principal;
        Pool storage p = _pools[USDC_POOL];
        (p.principal, p.weighted) = (p.principal - amount, p.weighted - a.weighted);
        (a.principal, a.weighted, a.lots) = (0, 0, 0);
        USDC.forceApprove(address(COLD_STORAGE), amount);
        id = COLD_STORAGE.openIgnition(wallet, amount);
        emit StakedUsdc(wallet, id, amount);
        return (true, id, amount);
    }

    /// @dev Pool-0 LP at its fair value in USDC: 2·sqrt(k · P_twap) per supply, from BlastPool's
    ///      reserves and TWAP, so neither a skewed pool nor a donation can raise it.
    function _lpValue(uint256 amount) internal view returns (uint256) {
        (uint256 priceX112, uint32 elapsed) = BLASTPOOL.consult(uint32(P.IGNITION_TWAP_SECONDS));
        if (elapsed > P.IGNITION_ORACLE_MAX_AGE) revert StaleOracle(elapsed);
        (uint112 e, uint112 q,) = BLASTPOOL.getReserves();
        uint256 root = 2 * Math.sqrt(uint256(e) * q) * Math.sqrt(priceX112);
        return Math.mulDiv(root, amount, BLASTPOOL.totalSupply() << 56);
    }

    /// @dev Pull exactly `amount`; a token that delivers anything else is refused.
    function _pull(IERC20 token, uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        if (token.balanceOf(address(this)) - before != amount) revert NonStandardToken();
    }

    error NonStandardToken();
}
