// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EmberToken} from "../src/EmberToken.sol";
import {Mantle, IEmberMintBurn} from "../src/Mantle.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {ForgeView} from "../src/forge/ForgeView.sol";
import {ForgeEmissions, IMantleDistribution} from "../src/forge/ForgeEmissions.sol";
import {Boost, IValuation, IPyreLedger} from "../src/forge/Boost.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {MockERC20} from "./utils/MockERC20.sol";
import {OracleVectors} from "./utils/OracleVectors.sol";

using ForgeView for ForgePool;

/// @dev Test valuation: a settable RAY rate per pool, or a revert.
contract MockValuation is IValuation {
    mapping(uint256 pool => uint256) public rate;
    bool public down;

    function set(uint256 pool, uint256 r) external {
        rate[pool] = r;
    }

    function setDown(bool d) external {
        down = d;
    }

    function emberPerStake(uint256 pool) external view returns (uint256) {
        require(!down, "valuation down");
        return rate[pool];
    }
}

/// @dev Test Pyre ledger: settable cumulative burns per wallet.
contract MockPyre is IPyreLedger {
    mapping(address wallet => uint256) public pyreBurned;

    function set(address wallet, uint256 burned) external {
        pyreBurned[wallet] = burned;
    }
}

/// @dev The whole wiring with Boost at its predicted address: pools 0, 1 and 3 stake mock
///      tokens (pool 3 with 6 decimals in value terms), pool 2 stakes EMBER itself. Users get
///      EMBER from the Kindling seed, so every burn stays inside the Mantle's ledger.
abstract contract BoostFixture is OracleVectors {
    using stdStorage for StdStorage;

    MockERC20[4] stake;
    ForgePool[4] public pools;
    EmberToken public ember;
    Mantle mantle;
    ForgeEmissions emissions;
    Boost public boost;
    MockValuation valuation;
    MockPyre pyre;
    address kindling = makeAddr("kindling");
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function _deployBoost() internal {
        vm.warp(1_800_000_000);
        valuation = new MockValuation();
        pyre = new MockPyre();
        for (uint256 i; i < 4; ++i) {
            if (i != 2) stake[i] = new MockERC20("Stake", "STK");
        }
        uint256 n = vm.getNonce(address(this));
        address emberAt = vm.computeCreateAddress(address(this), n);
        address mantleAt = vm.computeCreateAddress(address(this), n + 5);
        address emissionsAt = vm.computeCreateAddress(address(this), n + 6);
        address boostAt = vm.computeCreateAddress(address(this), n + 7);
        ember = new EmberToken(mantleAt);
        bool[4] memory lp = [true, true, false, false];
        for (uint256 i; i < 4; ++i) {
            IERC20 token = i == 2 ? IERC20(address(ember)) : IERC20(address(stake[i]));
            pools[i] = new ForgePool(token, lp[i], makeAddr("feeRouter"), boostAt, makeAddr("deeds"), address(0));
        }
        address[] memory registrars = new address[](1);
        Mantle.BurnCategory[] memory categories = new Mantle.BurnCategory[](1);
        (registrars[0], categories[0]) = (boostAt, Mantle.BurnCategory.Protocol);
        mantle = new Mantle(
            IEmberMintBurn(address(ember)), emissionsAt, kindling, makeAddr("treasury"), block.timestamp, registrars, categories
        );
        emissions = new ForgeEmissions(
            IMantleDistribution(address(mantle)), IERC20(address(ember)), pools, boostAt, makeAddr("match"), makeAddr("pot")
        );
        boost = new Boost(emissions, valuation, pyre);
        require(address(boost) == boostAt && address(emissions) == emissionsAt, "prediction");

        vm.prank(kindling);
        mantle.mintKindlingSeed();
        for (uint256 u; u < 2; ++u) {
            address who = u == 0 ? alice : bob;
            vm.prank(kindling);
            ember.transfer(who, 100_000e18);
            vm.startPrank(who);
            ember.approve(address(boost), type(uint256).max);
            for (uint256 i; i < 4; ++i) {
                if (i != 2) {
                    stake[i].mint(who, 1e30);
                    stake[i].approve(address(pools[i]), type(uint256).max);
                } else {
                    ember.approve(address(pools[i]), type(uint256).max);
                }
            }
            vm.stopPrank();
        }
    }

    function _open(address who, uint256 pool, uint256 amount) internal returns (uint256 id) {
        vm.prank(who);
        id = pools[pool].open(amount);
    }

    function _bonus(uint256 pool, uint256 id) internal view returns (uint256) {
        return pools[pool].positionOf(id).ordinaryBonus;
    }

    /// @dev Credits `amount` of unclaimed rewards as a settled epoch would, backed by EMBER in
    ///      ForgeEmissions (from the Kindling seed, so supply stays the Mantle's).
    function _credit(uint256 pool, uint256 id, uint256 amount) internal {
        uint256 owed = emissions.unclaimed(pool, id);
        stdstore.target(address(emissions)).sig("unclaimed(uint256,uint256)").with_key(pool).with_key(id)
            .checked_write(owed + amount);
        vm.prank(kindling);
        ember.transfer(address(emissions), amount);
    }
}

contract BoostTest is BoostFixture {
    using stdStorage for StdStorage;

    function setUp() public {
        _deployBoost();
        _loadVectors();
    }

    // ── formula ───────────────────────────────────────────────────────────

    function test_capstoneUnitsMatchReference() public view {
        uint256[] memory c = _uints(".capstoneUnits.capstone");
        uint256[] memory k = _uints(".capstoneUnits.custody");
        uint256[] memory r = _uints(".capstoneUnits.rate");
        uint256[] memory want = _uints(".capstoneUnits.out");
        assertGt(want.length, 40);
        for (uint256 i; i < want.length; ++i) assertEq(boost.capstoneUnits(c[i], k[i], r[i]), want[i]);
    }

    function test_pyreUnitsMatchReference() public view {
        uint256[] memory b = _uints(".pyreUnits.burned");
        uint256[] memory want = _uints(".pyreUnits.out");
        for (uint256 i; i < want.length; ++i) assertEq(boost.pyreUnits(b[i]), want[i]);
    }

    function test_constructorChecksEveryWire() public {
        vm.expectRevert(Boost.Miswired.selector); // ForgeEmissions names another CAPSTONE
        new Boost(emissions, valuation, pyre);
        vm.expectRevert(Boost.ZeroAddress.selector);
        new Boost(emissions, IValuation(address(0)), pyre);
    }

    // ── bonus by pool: decimals and the EMBER pool ───────────────────────

    function test_emberPoolNeedsNoValuation() public {
        valuation.setDown(true);
        uint256 id = _open(alice, 2, 1000e18); // net 990 EMBER staked
        vm.prank(alice);
        boost.deposit(2, id, 100e18); // net 99: ratio 0.1 → +0.1
        assertEq(_bonus(2, id), 10_000);
        assertEq(boost.accountOf(2, id).capstone, 99e18);
    }

    function test_sixDecimalStake() public {
        valuation.set(3, 2e12 * P.RAY); // 1 USDC = 2 EMBER: 2e12 EMBER-wei per USDC-wei
        uint256 id = _open(alice, 3, 1000e6); // net 990 USDC = 1,980 EMBER
        vm.prank(alice);
        boost.deposit(3, id, 500e18); // net 495 EMBER: half the maximum ratio
        assertEq(_bonus(3, id), 25_000);
    }

    function test_lpStakeAndPyre() public {
        valuation.set(0, 3 * P.RAY); // 1 LP = 3 EMBER
        pyre.set(alice, 1250e18); // two tiers: +0.1
        uint256 id = _open(alice, 0, 100e18); // net 99 LP = 297 EMBER
        vm.prank(alice);
        boost.deposit(0, id, 1000e18); // far past the maximum ratio
        assertEq(_bonus(0, id), 50_000 + 10_000);
    }

    // ── withdrawals never read the valuation ─────────────────────────────

    function test_withdrawalsNeverReadTheValuation() public {
        valuation.set(0, P.RAY);
        uint256 id = _open(alice, 0, 1000e18); // 990 LP = 990 EMBER
        vm.prank(alice);
        boost.deposit(0, id, 200e18); // net 198: ratio 0.2 → +0.2
        assertEq(_bonus(0, id), 20_000);
        valuation.setDown(true);
        pyre.set(alice, 0);

        vm.startPrank(alice);
        boost.requestWithdraw(0, id, 99e18); // half: the bonus halves, no price read
        assertEq(_bonus(0, id), 10_000);
        boost.cancelWithdraw(0, id); // counts again; the bonus returns on the next raise
        assertEq(boost.accountOf(0, id).capstone, 198e18);
        skip(4 days); // past the plan horizon
        uint256 maturity = boost.requestWithdraw(0, id, 198e18);
        assertEq(_bonus(0, id), 0);
        vm.warp(maturity);
        uint256 before = ember.balanceOf(alice);
        uint256 net = boost.executeWithdraw(0, id);
        vm.stopPrank();
        assertEq(net, 198e18 - 198e18 / 100);
        assertEq(ember.balanceOf(alice) - before, net);

        vm.expectRevert(bytes("valuation down")); // only raising needs the price
        boost.refresh(0, id);
    }

    function test_depositStandsWhenTheValuationIsDown() public {
        valuation.setDown(true);
        uint256 id = _open(alice, 0, 1000e18);
        vm.expectEmit(address(boost));
        emit Boost.BonusUnavailable(0, id);
        vm.prank(alice);
        boost.deposit(0, id, 100e18);
        assertEq(boost.accountOf(0, id).capstone, 99e18);
        assertEq(_bonus(0, id), 0);
        valuation.setDown(false);
        valuation.set(0, P.RAY);
        boost.refresh(0, id); // anyone raises it once the valuation is back
        assertEq(_bonus(0, id), 10_000);
    }

    function test_absurdRateCountsAsUnavailable() public {
        valuation.set(0, type(uint256).max);
        uint256 id = _open(alice, 0, 1e28); // custody · rate / RAY would overflow 256 bits
        vm.prank(alice);
        boost.deposit(0, id, 100e18); // stands
        assertEq(_bonus(0, id), 0);
        assertEq(boost.accountOf(0, id).capstone, 99e18);
    }

    // ── the withdrawal timer: Forge's cumulative plan ─────────────────────

    function test_splittingDoesNotBuyShortTimers() public {
        uint256 id = _open(alice, 2, 1000e18);
        vm.startPrank(alice);
        boost.deposit(2, id, 1010e18); // net 999.9
        uint256 cap = boost.accountOf(2, id).capstone;
        uint256 t0 = block.timestamp;
        assertEq(boost.requestWithdraw(2, id, cap / 10) - t0, P.WITHDRAW_TIER_0_SECONDS); // 10%
        vm.warp(t0 + P.WITHDRAW_TIER_0_SECONDS - 1);
        vm.expectRevert(abi.encodeWithSelector(Boost.NotMatured.selector, t0 + P.WITHDRAW_TIER_0_SECONDS));
        boost.executeWithdraw(2, id);
        vm.warp(t0 + P.WITHDRAW_TIER_0_SECONDS);
        boost.executeWithdraw(2, id);
        uint256 t1 = block.timestamp; // cumulative 20% of the frozen reference: tier 1
        assertEq(boost.requestWithdraw(2, id, cap / 10) - t1, P.WITHDRAW_TIER_1_SECONDS);
        boost.cancelWithdraw(2, id); // the quota stays consumed
        assertEq(boost.requestWithdraw(2, id, cap / 10) - t1, P.WITHDRAW_TIER_2_SECONDS); // 30%
        vm.expectRevert(abi.encodeWithSelector(Boost.WithdrawPending.selector, 2, id));
        boost.requestWithdraw(2, id, 1);
        vm.stopPrank();
    }

    function test_lapseReturnsToCapstone() public {
        uint256 id = _open(alice, 2, 1000e18);
        vm.startPrank(alice);
        boost.deposit(2, id, 100e18);
        uint256 maturity = boost.requestWithdraw(2, id, 10e18);
        vm.warp(maturity + P.WITHDRAW_EXECUTION_WINDOW);
        vm.expectRevert(abi.encodeWithSelector(Boost.NotPending.selector, 2, id));
        boost.executeWithdraw(2, id);
        boost.requestWithdraw(2, id, 89e18); // the lapsed 10 counts again first; quota 10 + 89 = 99
        vm.stopPrank();
        assertEq(boost.accountOf(2, id).capstone, 10e18);
    }

    // ── refresh: lowering is open, raising once per epoch per side ────────

    function test_raiseLimitsAreSeparateAndLoweringIsOpen() public {
        valuation.set(0, P.RAY);
        uint256 id = _open(alice, 0, 1000e18);
        vm.prank(alice);
        boost.deposit(0, id, 100e18); // +0.1
        valuation.set(0, P.RAY / 2); // the stake halves in value: +0.2 is due
        vm.prank(bob);
        boost.refresh(0, id);
        assertEq(_bonus(0, id), 20_000);
        valuation.set(0, P.RAY / 4); // +0.4 due
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Boost.RaiseTooSoon.selector, block.timestamp + P.EPOCH_SECONDS));
        boost.refresh(0, id);
        vm.prank(alice); // the owner's allowance is its own
        boost.refresh(0, id);
        assertEq(_bonus(0, id), 40_000);
        valuation.set(0, P.RAY); // back to +0.1: anyone lowers at once
        vm.prank(bob);
        boost.refresh(0, id);
        assertEq(_bonus(0, id), 10_000);
        skip(P.EPOCH_SECONDS);
        valuation.set(0, P.RAY / 2);
        vm.prank(bob);
        boost.refresh(0, id);
        assertEq(_bonus(0, id), 20_000);
    }

    function test_topUpDilutionThenRefreshRestores() public {
        uint256 id = _open(alice, 2, 1000e18); // 990
        vm.startPrank(alice);
        boost.deposit(2, id, 100e18); // +0.1
        pools[2].deposit(id, 1000e18); // custody doubles: the pool halves the bonus
        assertEq(_bonus(2, id), 5_000);
        boost.refresh(2, id); // the true value is +0.05 as well: nothing to raise
        assertEq(_bonus(2, id), 5_000);
        vm.stopPrank();
    }

    // ── fees, escrow, ownership ──────────────────────────────────────────

    function test_feesBurnThroughTheMantle() public {
        uint256 id = _open(alice, 2, 1000e18);
        vm.prank(alice);
        boost.deposit(2, id, 1000e18); // 10 EMBER fee
        assertEq(boost.feesToBurn(), 10e18);
        uint256 supply = ember.totalSupply();
        uint256 accounted = mantle.accounted();
        assertEq(boost.burnFees(), 10e18);
        assertEq(supply - ember.totalSupply(), 10e18);
        assertEq(accounted - mantle.accounted(), 10e18);
        assertEq(ember.balanceOf(address(boost)), boost.accountOf(2, id).capstone);
    }

    function test_escrowMovesIntoCapstoneWithoutFee() public {
        uint256 id = _open(alice, 2, 1000e18);
        stdstore.target(address(emissions)).sig("capstoneOwed(uint256,uint256)").with_key(uint256(2)).with_key(id)
            .checked_write(uint256(50e18));
        vm.prank(kindling);
        ember.transfer(address(emissions), 50e18); // stands in for the minted escrow
        assertEq(boost.claimEscrow(2, id), 50e18);
        assertEq(boost.accountOf(2, id).capstone, 50e18);
        assertEq(_bonus(2, id), uint256(50e18) * 50_000 / 495e18);
        assertEq(boost.claimEscrow(2, id), 0); // nothing more owed
    }

    // ── Deeds (ADR 0011) ─────────────────────────────────────────────────

    function test_listingLocksCapstoneMutations() public {
        address deeds = pools[2].DEEDS();
        uint256 id = _open(alice, 2, 1000e18);
        vm.prank(alice);
        boost.deposit(2, id, 100e18);
        vm.prank(deeds);
        pools[2].list(id, alice);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Boost.Listed.selector, 2, id));
        boost.deposit(2, id, 10e18);
        vm.expectRevert(abi.encodeWithSelector(Boost.Listed.selector, 2, id));
        boost.requestWithdraw(2, id, 10e18);
        vm.stopPrank();
        // Value the position already owns still arrives, and refreshing stays open.
        stdstore.target(address(emissions)).sig("capstoneOwed(uint256,uint256)").with_key(uint256(2)).with_key(id)
            .checked_write(uint256(50e18));
        vm.prank(kindling);
        ember.transfer(address(emissions), 50e18);
        assertEq(boost.claimEscrow(2, id), 50e18);
        vm.prank(bob);
        boost.refresh(2, id);
        // The owner ends the listing in the pool itself; Capstone actions resume.
        vm.prank(alice);
        pools[2].unlist(id);
        vm.prank(alice);
        boost.deposit(2, id, 10e18);
    }

    /// A buyer is not bound by the seller's raise allowance or withdrawal plan, even within the
    /// sale's own second: Boost keys them to the pool's sale count, not to time.
    function test_newOwnerStartsWithFreshAllowanceAndPlan() public {
        address deeds = pools[0].DEEDS();
        valuation.set(0, P.RAY);
        pyre.set(alice, P.PYRE_TIER_2_BURN);
        uint256 id = _open(alice, 0, 1000e18);
        vm.startPrank(alice);
        boost.deposit(0, id, 100e18); // +0.1 and the seller's Pyre
        valuation.set(0, P.RAY / 2);
        boost.refresh(0, id); // the seller's raise for this epoch
        uint256 cap = boost.accountOf(0, id).capstone;
        boost.requestWithdraw(0, id, cap); // the whole plan quota; the bonus scales to 0
        boost.cancelWithdraw(0, id); // stays consumed
        vm.expectRevert(abi.encodeWithSelector(Boost.PlanQuotaExceeded.selector, cap + 1, cap));
        boost.requestWithdraw(0, id, 1);
        vm.stopPrank();
        vm.prank(bob);
        boost.refresh(0, id); // the public raise restores it
        assertEq(_bonus(0, id), 20_000 + boost.pyreUnits(P.PYRE_TIER_2_BURN));

        vm.prank(deeds);
        uint32 listing = pools[0].list(id, alice);
        vm.prank(deeds);
        pools[0].settle(id, bob, listing);
        assertEq(_bonus(0, id), 0, "the pool zeroes the bonus at the sale");

        vm.startPrank(bob);
        boost.refresh(0, id); // same second as the seller's raise: a fresh allowance
        assertEq(_bonus(0, id), 20_000, "the Capstone travels; the seller's Pyre does not");
        uint256 t0 = block.timestamp;
        assertEq(boost.requestWithdraw(0, id, cap / 10) - t0, P.WITHDRAW_TIER_0_SECONDS, "a fresh plan");
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(Boost.NotOwner.selector, 0, id));
        vm.prank(alice);
        boost.cancelWithdraw(0, id);
        // The allowance is the buyer's own from now on: a second raise this epoch waits.
        valuation.set(0, P.RAY / 4);
        vm.expectRevert(abi.encodeWithSelector(Boost.RaiseTooSoon.selector, t0 + P.EPOCH_SECONDS));
        vm.prank(bob);
        boost.refresh(0, id);
    }

    // ── Stoke (ADR 0013) ─────────────────────────────────────────────────

    function test_stokeCompoundsUnclaimedRewardsIntoTheCapstone() public {
        uint256 id = _open(alice, 2, 1000e18); // 990 EMBER staked
        _credit(2, id, 50e18);
        vm.prank(alice);
        emissions.requestClaim(2, id); // a pending Claim snapshots these 50
        _credit(2, id, 99e18);
        uint256 held = ember.balanceOf(address(boost));
        vm.expectEmit(address(boost));
        emit Boost.Stoked(2, id, alice, 99e18, 0);
        vm.prank(alice);
        assertEq(boost.stoke(2, id), 99e18, "only the unclaimed part");
        assertEq(boost.accountOf(2, id).capstone, 99e18, "no fee: the Compound fee is zero");
        assertEq(ember.balanceOf(address(boost)) - held, 99e18);
        assertEq(emissions.unclaimed(2, id), 0);
        assertEq(emissions.claimOf(2, id).amount, 50e18, "the Claim keeps its snapshot");
        assertEq(_bonus(2, id), 10_000, "ratio 0.1: +0.1");
        vm.expectRevert(abi.encodeWithSelector(Boost.NothingToStoke.selector, 2, id));
        vm.prank(alice);
        boost.stoke(2, id);
    }

    function test_stokeGuards() public {
        uint256 id = _open(alice, 2, 1000e18);
        _credit(2, id, 10e18);
        vm.expectRevert(abi.encodeWithSelector(Boost.NotOwner.selector, 2, id));
        vm.prank(bob);
        boost.stoke(2, id);
        vm.expectRevert(abi.encodeWithSelector(ForgeEmissions.NotConsumer.selector, alice));
        vm.prank(alice);
        emissions.takeUnclaimed(2, id); // only the Capstone takes unclaimed rewards
        vm.prank(pools[2].DEEDS());
        pools[2].list(id, alice);
        vm.expectRevert(abi.encodeWithSelector(Boost.Listed.selector, 2, id));
        vm.prank(alice);
        boost.stoke(2, id); // the rewards travel with the Deed
        vm.prank(alice);
        pools[2].emergencyExit(id);
        vm.expectRevert(abi.encodeWithSelector(Boost.Closed.selector, 2, id));
        vm.prank(alice);
        boost.stoke(2, id); // a closed position's rewards stay claimable
    }

    /// A Stoke is fee-free, so its raise spends the owner's once-per-epoch allowance.
    function test_stokeRaiseSpendsTheAllowance() public {
        uint256 id = _open(alice, 2, 1000e18); // 990
        _credit(2, id, 99e18);
        vm.prank(alice);
        boost.stoke(2, id);
        assertEq(_bonus(2, id), 10_000, "the first raise this epoch");
        _credit(2, id, 99e18);
        vm.expectEmit(address(boost));
        emit Boost.RaiseDeferred(2, id, 20_000);
        vm.prank(alice);
        boost.stoke(2, id);
        assertEq(boost.accountOf(2, id).capstone, 198e18, "the Capstone still grows");
        assertEq(_bonus(2, id), 10_000, "a second Stoke in the epoch does not raise");
        vm.expectRevert(abi.encodeWithSelector(Boost.RaiseTooSoon.selector, block.timestamp + P.EPOCH_SECONDS));
        vm.prank(alice);
        boost.refresh(2, id); // the same allowance
        vm.prank(bob);
        boost.refresh(2, id); // the public side is separate
        assertEq(_bonus(2, id), 20_000);
    }

    /// The owner's Stoke spends the owner's allowance and a keeper's the public one: a spent owner
    /// side does not hold back the keeper's raise.
    function test_keeperRaiseSpendsThePublicAllowance() public {
        uint256 id = _open(alice, 2, 1000e18); // 990
        vm.prank(alice);
        boost.setKeeper(2, id, P.AUTO_STOKE_TIP_MIN_BPS, P.AUTO_STOKE_MIN_INTERVAL, P.AUTO_STOKE_MIN_SIZE);
        _credit(2, id, 99e18);
        vm.prank(alice);
        boost.stoke(2, id);
        assertEq(_bonus(2, id), 10_000, "the owner's raise");
        assertEq(boost.accountOf(2, id).ownerRaiseAt, block.timestamp);
        _credit(2, id, 100e18);
        vm.prank(bob);
        boost.keeperStoke(2, id); // 0.1% tip: the Capstone holds 99 + 99.9
        assertEq(_bonus(2, id), uint256(198.9e18) * 50_000 / 495e18, "the keeper's raise, same epoch");
        assertEq(boost.accountOf(2, id).publicRaiseAt, block.timestamp);
    }

    function test_keeperIsOffUntilTheOwnerOptsIn() public {
        uint256 id = _open(alice, 2, 1000e18);
        _credit(2, id, 500e18);
        vm.expectRevert(abi.encodeWithSelector(Boost.KeeperOff.selector, 2, id));
        vm.prank(bob);
        boost.keeperStoke(2, id);
        vm.startPrank(alice);
        vm.expectRevert(Boost.BadKeeperSettings.selector);
        boost.setKeeper(2, id, P.AUTO_STOKE_TIP_MIN_BPS - 1, P.AUTO_STOKE_MIN_INTERVAL, P.AUTO_STOKE_MIN_SIZE);
        vm.expectRevert(Boost.BadKeeperSettings.selector);
        boost.setKeeper(2, id, P.AUTO_STOKE_TIP_MAX_BPS + 1, P.AUTO_STOKE_MIN_INTERVAL, P.AUTO_STOKE_MIN_SIZE);
        vm.expectRevert(Boost.BadKeeperSettings.selector);
        boost.setKeeper(2, id, P.AUTO_STOKE_TIP_MIN_BPS, P.AUTO_STOKE_MIN_INTERVAL - 1, P.AUTO_STOKE_MIN_SIZE);
        vm.expectRevert(Boost.BadKeeperSettings.selector);
        boost.setKeeper(2, id, P.AUTO_STOKE_TIP_MAX_BPS, P.AUTO_STOKE_MIN_INTERVAL, P.AUTO_STOKE_MIN_SIZE - 1);
        boost.setKeeper(2, id, P.AUTO_STOKE_TIP_MIN_BPS, P.AUTO_STOKE_MIN_INTERVAL, P.AUTO_STOKE_MIN_SIZE); // the edges
        boost.setKeeper(2, id, P.AUTO_STOKE_TIP_MAX_BPS, P.AUTO_STOKE_MIN_INTERVAL, P.AUTO_STOKE_MIN_SIZE);
        boost.setKeeper(2, id, 0, 1, 1); // off, whatever else is passed
        vm.stopPrank();
        assertEq(abi.encode(boost.accountOf(2, id).keeper), abi.encode(Boost.Keeper(0, 0, 0, 0)));
        vm.expectRevert(abi.encodeWithSelector(Boost.NotOwner.selector, 2, id));
        vm.prank(bob);
        boost.setKeeper(2, id, P.AUTO_STOKE_TIP_DEFAULT_BPS, P.AUTO_STOKE_DEFAULT_INTERVAL, P.AUTO_STOKE_MIN_SIZE);
    }

    function test_keeperStokePaysTheTipWithinTheOwnersLimits() public {
        uint256 id = _open(alice, 2, 1000e18);
        vm.prank(alice);
        boost.setKeeper(2, id, P.AUTO_STOKE_TIP_DEFAULT_BPS, 1 days, 150e18);
        _credit(2, id, 200e18);
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        (uint256 amount, uint256 tip) = boost.keeperStoke(2, id);
        assertEq(abi.encode(amount, tip), abi.encode(200e18, 1e18), "0.5% of 200");
        assertEq(ember.balanceOf(keeper), 1e18);
        assertEq(boost.accountOf(2, id).capstone, 199e18);
        _credit(2, id, 200e18);
        vm.expectRevert(abi.encodeWithSelector(Boost.StokeTooSoon.selector, block.timestamp + 1 days));
        vm.prank(keeper);
        boost.keeperStoke(2, id);
        skip(1 days);
        vm.prank(alice); // changing settings keeps the interval running from the last keeper Stoke
        boost.setKeeper(2, id, P.AUTO_STOKE_TIP_MAX_BPS, 2 days, 300e18);
        vm.expectRevert(abi.encodeWithSelector(Boost.StokeTooSoon.selector, block.timestamp + 1 days));
        vm.prank(keeper);
        boost.keeperStoke(2, id);
        skip(1 days);
        vm.expectRevert(abi.encodeWithSelector(Boost.BelowStokeMinimum.selector, 200e18, 300e18));
        vm.prank(keeper);
        boost.keeperStoke(2, id);
        _credit(2, id, 100e18);
        vm.prank(alice); // the owner earns no tip, even through the keeper path
        (amount, tip) = boost.keeperStoke(2, id);
        assertEq(abi.encode(amount, tip), abi.encode(300e18, 0));
        assertEq(boost.accountOf(2, id).capstone, 499e18);
    }

    /// A listing locks keeper Stokes; the owner may still opt out. A sale ends the settings, and
    /// a buyer's own first settings survive their first sync.
    function test_keeperSettingsEndAtASale() public {
        address deeds = pools[2].DEEDS();
        uint256 id = _open(alice, 2, 1000e18);
        vm.prank(alice);
        boost.setKeeper(2, id, P.AUTO_STOKE_TIP_MAX_BPS, P.AUTO_STOKE_MIN_INTERVAL, P.AUTO_STOKE_MIN_SIZE);
        _credit(2, id, 500e18);
        vm.prank(deeds);
        uint32 listing = pools[2].list(id, alice);
        vm.expectRevert(abi.encodeWithSelector(Boost.Listed.selector, 2, id));
        boost.keeperStoke(2, id);
        vm.prank(deeds);
        pools[2].settle(id, bob, listing);
        vm.expectRevert(abi.encodeWithSelector(Boost.KeeperOff.selector, 2, id));
        boost.keeperStoke(2, id); // the seller's settings do not bind the buyer
        vm.prank(bob);
        boost.setKeeper(2, id, P.AUTO_STOKE_TIP_MIN_BPS, P.AUTO_STOKE_MIN_INTERVAL, P.AUTO_STOKE_MIN_SIZE);
        (, uint256 tip) = boost.keeperStoke(2, id);
        assertEq(tip, 0.5e18, "the buyer's settings: 0.1% of 500");
    }

    function test_onlyTheOwnerMovesCapstone() public {
        uint256 id = _open(alice, 2, 1000e18);
        vm.prank(alice);
        boost.deposit(2, id, 100e18);
        vm.startPrank(bob);
        vm.expectRevert(abi.encodeWithSelector(Boost.NotOwner.selector, 2, id));
        boost.deposit(2, id, 1e18);
        vm.expectRevert(abi.encodeWithSelector(Boost.NotOwner.selector, 2, id));
        boost.requestWithdraw(2, id, 1e18);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(Boost.UnknownPool.selector, 4));
        boost.refresh(4, id);
    }

    /// End to end through the real settlement: a 30-day Seal on the EMBER pool vests, its escrow
    /// is settled into the Capstone ledger and claimed into the Capstone, and the next day's W
    /// beats an identical unboosted position by exactly stake · time · bonus.
    function test_vestedEscrowRaisesTheNextDaysHeat() public {
        uint256 id = _open(alice, 2, 1000e18);
        uint256 control = _open(bob, 2, 1000e18);
        vm.prank(alice);
        pools[2].seal(id, 0);
        for (uint256 e; e < 31; ++e) {
            skip(1 days);
            mantle.finalizeEpoch();
            emissions.openEpoch();
            for (uint256 i; i < 4; ++i) {
                while (emissions.poolEpoch(e, i).phase != ForgeEmissions.Phase.Done) emissions.advance(e, i);
            }
        }
        uint256 late = emissions.capstoneOwed(2, id); // escrow paged after the term ended goes straight here
        uint256 escrow = emissions.settleSeal(2, id, 1) + late;
        assertGt(escrow, late);
        assertEq(emissions.capstoneOwed(2, id), escrow);
        vm.prank(bob); // anyone moves it
        assertEq(boost.claimEscrow(2, id), escrow);
        assertEq(boost.accountOf(2, id).capstone, escrow);
        uint256 units = _bonus(2, id);
        assertEq(units, boost.capstoneUnits(escrow, 990e18, P.RAY));
        assertGt(units, 0);

        uint256 t0 = block.timestamp;
        skip(1 days);
        pools[2].poke(id);
        pools[2].poke(control);
        (uint256 s, uint256 w,,,) = pools[2].epochMeasure(id, t0, block.timestamp);
        (uint256 s2, uint256 w2,,,) = pools[2].epochMeasure(control, t0, block.timestamp);
        assertEq(s, s2);
        assertEq(w - w2, s * units * P.ORDINARY_BONUS_UNIT_RAY);
    }

    function test_dustDepositsPayAFeeOrRevert() public {
        uint256 id = _open(alice, 2, 1000e18);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Boost.BelowMinimum.selector, 99));
        boost.deposit(2, id, 99); // its 1% fee would round to zero
        boost.deposit(2, id, 100);
        vm.stopPrank();
        assertEq(boost.feesToBurn(), 1);
    }

    function test_gas_boost() public {
        valuation.set(0, P.RAY);
        pyre.set(alice, 250e18);
        uint256 id = _open(alice, 0, 1e18);
        vm.startPrank(alice);
        for (uint256 i = 1; i < 32; ++i) {
            skip(1 hours);
            pools[0].deposit(id, 1e18);
        }
        skip(1 days);
        uint256 g = gasleft();
        boost.deposit(0, id, 10e18);
        emit log_named_uint("Capstone deposit, raising 32 lots", g - gasleft());
        skip(1 days);
        g = gasleft();
        uint256 maturity = boost.requestWithdraw(0, id, 1e18);
        emit log_named_uint("Capstone requestWithdraw, lowering 32 lots (no price)", g - gasleft());
        vm.warp(maturity);
        g = gasleft();
        boost.executeWithdraw(0, id);
        emit log_named_uint("Capstone executeWithdraw", g - gasleft());
        skip(1 days);
        g = gasleft();
        boost.refresh(0, id);
        emit log_named_uint("refresh, raising 32 lots", g - gasleft());
        boost.setKeeper(0, id, P.AUTO_STOKE_TIP_DEFAULT_BPS, P.AUTO_STOKE_MIN_INTERVAL, P.AUTO_STOKE_MIN_SIZE);
        vm.stopPrank();
        _credit(0, id, 100e18);
        skip(1 days); // new segments for all 32 lots, not an in-place rewrite
        vm.prank(makeAddr("keeper"));
        g = gasleft();
        boost.keeperStoke(0, id);
        emit log_named_uint("keeperStoke, raising 32 lots (the keeper's worst case)", g - gasleft());
        g = gasleft();
        boost.burnFees();
        emit log_named_uint("burnFees", g - gasleft());
    }

    function test_closedPositionKeepsItsCapstoneWithdrawable() public {
        uint256 id = _open(alice, 2, 1000e18);
        vm.startPrank(alice);
        boost.deposit(2, id, 100e18);
        pools[2].emergencyExit(id);
        vm.expectRevert(abi.encodeWithSelector(Boost.Closed.selector, 2, id));
        boost.deposit(2, id, 1e18);
        uint256 maturity = boost.requestWithdraw(2, id, 99e18);
        vm.warp(maturity);
        assertEq(boost.executeWithdraw(2, id), 99e18 - 99e18 / 100);
        vm.stopPrank();
    }
}

contract BoostHandler is BoostFixture {
    struct Pos {
        uint256 pool;
        uint256 id;
        address owner;
    }

    Pos[] internal positions;
    bool public exitBroken;
    bool public withdrawRaised;
    uint256 public requests;
    uint256 public executions;
    uint256 public sales;
    uint256 public stokes;
    uint256 public keeperStokes;

    constructor() {
        _deployBoost();
        valuation.set(0, P.RAY);
        valuation.set(1, 5 * P.RAY);
        valuation.set(3, 2e12 * P.RAY);
        uint256[3] memory ps = [uint256(0), 2, 3];
        for (uint256 k; k < 3; ++k) {
            uint256 amount = ps[k] == 3 ? 1000e6 : 1000e18;
            positions.push(Pos(ps[k], _open(alice, ps[k], amount), alice));
            positions.push(Pos(ps[k], _open(bob, ps[k], amount), bob));
        }
    }

    function count() external view returns (uint256) {
        return positions.length;
    }

    function at(uint256 k) external view returns (uint256 pool, uint256 id) {
        return (positions[k].pool, positions[k].id);
    }

    function deposit(uint256 seed, uint256 amount) external {
        Pos memory q = positions[seed % positions.length];
        vm.prank(q.owner);
        try boost.deposit(q.pool, q.id, bound(amount, 1, 2_000e18)) {} catch {}
    }

    function request(uint256 seed, uint256 bps) external {
        Pos memory q = positions[seed % positions.length];
        Boost.Account memory a = boost.accountOf(q.pool, q.id);
        uint256 amount = (uint256(a.capstone) * bound(bps, 1, 10_000)) / 10_000;
        uint256 before = _bonus(q.pool, q.id);
        vm.prank(q.owner);
        try boost.requestWithdraw(q.pool, q.id, amount) {
            ++requests;
            if (_bonus(q.pool, q.id) > before) withdrawRaised = true;
        } catch {}
    }

    function execute(uint256 seed, uint256 late) external {
        Pos memory q = positions[seed % positions.length];
        Boost.Account memory a = boost.accountOf(q.pool, q.id);
        // Past its window a ticket has lapsed back into the Capstone: nothing to execute.
        if (a.pending.amount == 0 || block.timestamp >= uint256(a.pending.maturity) + P.WITHDRAW_EXECUTION_WINDOW) return;
        uint256 at_ = uint256(a.pending.maturity) + bound(late, 0, P.WITHDRAW_EXECUTION_WINDOW - 1);
        if (at_ > block.timestamp) vm.warp(at_);
        vm.prank(q.owner);
        try boost.executeWithdraw(q.pool, q.id) {
            ++executions;
        } catch {
            exitBroken = true; // matured, inside its window: must pay whatever the valuation does
        }
    }

    function cancel(uint256 seed) external {
        Pos memory q = positions[seed % positions.length];
        Boost.Account memory a = boost.accountOf(q.pool, q.id);
        if (a.pending.amount == 0 || block.timestamp >= uint256(a.pending.maturity) + P.WITHDRAW_EXECUTION_WINDOW) return;
        vm.prank(q.owner);
        try boost.cancelWithdraw(q.pool, q.id) {} catch {
            exitBroken = true;
        }
    }

    function refresh(uint256 seed, bool asOwner) external {
        Pos memory q = positions[seed % positions.length];
        vm.prank(asOwner ? q.owner : address(0xBEEF));
        try boost.refresh(q.pool, q.id) {} catch {}
    }

    function topUp(uint256 seed, uint256 amount) external {
        Pos memory q = positions[seed % positions.length];
        vm.prank(q.owner);
        try pools[q.pool].deposit(q.id, bound(amount, q.pool == 3 ? 1e6 : 1e15, q.pool == 3 ? 1e10 : 1e22)) {} catch {}
    }

    function market(uint256 pool, uint256 rate, bool down) external {
        pool = [uint256(0), 1, 3][pool % 3];
        valuation.set(pool, pool == 3 ? bound(rate, 1e38, 1e40) : bound(rate, P.RAY / 10, 10 * P.RAY));
        valuation.setDown(down);
    }

    function burnPyre(bool who, uint256 burned) external {
        pyre.set(who ? alice : bob, bound(burned, 0, 10_000e18));
    }

    function burnFees() external {
        boost.burnFees();
    }

    /// Rewards credited to a position, then compounded by its owner (ADR 0013).
    function stoke(uint256 seed, uint256 amount) external {
        Pos memory q = positions[seed % positions.length];
        _credit(q.pool, q.id, bound(amount, 0, 1_000e18));
        vm.prank(q.owner);
        try boost.stoke(q.pool, q.id) {
            ++stokes;
        } catch {}
    }

    /// The owner opts in with some tip; a keeper Stokes once credits reach the minimum.
    function keeperStoke(uint256 seed, uint256 tip, uint256 amount) external {
        Pos memory q = positions[seed % positions.length];
        vm.prank(q.owner);
        try boost.setKeeper(q.pool, q.id, bound(tip, P.AUTO_STOKE_TIP_MIN_BPS, P.AUTO_STOKE_TIP_MAX_BPS), 1 days, 100e18) {} catch {}
        _credit(q.pool, q.id, bound(amount, 0, 1_000e18));
        vm.prank(address(0xBEEF));
        try boost.keeperStoke(q.pool, q.id) {
            ++keeperStokes;
        } catch {}
    }

    /// A Deed sale to the other wallet (ADR 0011), when the market's own precondition holds: no
    /// Capstone withdrawal pending. The pool refuses a listing with cooling pending.
    function sell(uint256 seed) external {
        uint256 k = seed % positions.length;
        Pos memory q = positions[k];
        if (boost.accountOf(q.pool, q.id).pending.amount != 0) return;
        address deeds = pools[q.pool].DEEDS();
        vm.prank(deeds);
        try pools[q.pool].list(q.id, q.owner) returns (uint32 listing) {
            vm.prank(deeds);
            pools[q.pool].settle(q.id, q.owner == alice ? bob : alice, listing);
            positions[k].owner = q.owner == alice ? bob : alice;
            ++sales;
        } catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 2 days));
    }
}

/// @notice Random Capstone deposits, withdrawals, refreshes, top-ups, valuation moves and
///         outages, and Pyre burns. Capstone EMBER is always fully backed, a matured
///         withdrawal always pays (whatever the valuation does), and a withdrawal request
///         never raises a bonus.
/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 100
contract BoostInvariantTest is BoostFixture {
    BoostHandler handler;

    function setUp() public {
        handler = new BoostHandler();
        targetContract(address(handler));
    }

    function invariant_capstoneFullyBacked() public view {
        Boost b = handler.boost();
        uint256 owed = b.feesToBurn();
        for (uint256 k; k < handler.count(); ++k) {
            (uint256 pool, uint256 id) = handler.at(k);
            Boost.Account memory a = b.accountOf(pool, id);
            owed += uint256(a.capstone) + a.pending.amount;
        }
        assertEq(handler.ember().balanceOf(address(b)), owed);
    }

    function invariant_withdrawalsIndependentOfTheValuation() public view {
        assertFalse(handler.exitBroken(), "a valid Capstone withdrawal reverted");
    }

    function invariant_withdrawalNeverRaisesTheBonus() public view {
        assertFalse(handler.withdrawRaised(), "a withdrawal request raised a bonus");
    }

    function invariant_bonusWithinTheCeiling() public view {
        for (uint256 k; k < handler.count(); ++k) {
            (uint256 pool, uint256 id) = handler.at(k);
            assertLe(handler.pools(pool).positionOf(id).ordinaryBonus, P.MAX_ORDINARY_BONUS_UNITS);
        }
    }
}

/// @dev Coverage probe for the invariant suite (one fixed sequence): requests and executions happen.
contract BoostInvariantCoverageTest is Test {
    function test_handlerReachesWithdrawals() public {
        BoostHandler h = new BoostHandler();
        for (uint256 i; i < 40; ++i) {
            h.deposit(i, 500e18);
            h.request(i, 3_000 + i * 97);
            h.market(i, i * 7919 * 1e24, i % 5 == 0);
            h.execute(i, i * 3_600);
            if (i % 4 == 0) h.cancel(i);
            if (i % 3 == 0) h.sell(i);
            if (i % 2 == 0) h.stoke(i, 200e18 + i * 1e18);
            h.keeperStoke(i + 1, i * 7, 150e18);
            h.warp(i * 4_000);
        }
        assertGt(h.stokes(), 5, "owners stoke");
        assertGt(h.keeperStokes(), 5, "keepers stoke");
        assertGt(h.requests(), 20);
        assertGt(h.executions(), 10);
        assertGt(h.sales(), 3, "positions change hands");
        assertFalse(h.exitBroken());
        assertFalse(h.withdrawRaised());
    }
}
