// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {EmberToken} from "../src/EmberToken.sol";
import {Mantle, IEmberMintBurn} from "../src/Mantle.sol";
import {EmissionMath} from "../src/libraries/EmissionMath.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {OracleVectors} from "./utils/OracleVectors.sol";

/// @dev Test-only subclass: lets a scenario start near the supply ceiling.
contract MantleHarness is Mantle {
    constructor(
        IEmberMintBurn ember,
        address distributor,
        address kindling,
        address treasury,
        uint256 start,
        address[] memory registrars,
        BurnCategory[] memory categories
    ) Mantle(ember, distributor, kindling, treasury, start, registrars, categories) {}

    function setAccountedForTest(uint256 value) external {
        accounted = value;
    }
}

abstract contract MantleFixture is OracleVectors {
    EmberToken ember;
    MantleHarness mantle;
    address distributor = makeAddr("forgeEmissions");
    address kindling = makeAddr("kindling");
    address treasury = makeAddr("treasury");
    address vent = makeAddr("ventBurnLane");
    address pyre = makeAddr("pyre");
    address alice = makeAddr("alice");
    uint256 start = 1_800_000_000;

    function _deploy() internal {
        // EMBER and the Mantle reference each other: predict the Mantle's CREATE address.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        ember = new EmberToken(predicted);
        address[] memory regs = new address[](2);
        Mantle.BurnCategory[] memory cats = new Mantle.BurnCategory[](2);
        regs[0] = vent;
        cats[0] = Mantle.BurnCategory.Protocol;
        regs[1] = pyre;
        cats[1] = Mantle.BurnCategory.Pyre;
        mantle = new MantleHarness(IEmberMintBurn(address(ember)), distributor, kindling, treasury, start, regs, cats);
        require(address(mantle) == predicted, "prediction");
    }

    function _endOf(uint256 epoch) internal view returns (uint256) {
        return start + (epoch + 1) * P.EPOCH_SECONDS;
    }

    /// Give `who` EMBER via a finalized epoch-0 base budget.
    function _fund(address who, uint256 amount) internal {
        if (mantle.nextEpoch() == 0) {
            vm.warp(_endOf(0));
            mantle.finalizeEpoch();
        }
        vm.prank(distributor);
        mantle.mintBase(0, who, amount);
    }

    /// Finalize every epoch up to and including `epoch`.
    function _finalizeThrough(uint256 epoch) internal {
        while (mantle.nextEpoch() <= epoch) {
            uint256 endsAt = _endOf(mantle.nextEpoch());
            if (block.timestamp < endsAt) vm.warp(endsAt);
            mantle.finalizeEpoch();
        }
    }

    function _burn(address registrar, uint256 amount) internal returns (uint256) {
        vm.startPrank(registrar);
        ember.approve(address(mantle), amount);
        uint256 credit = mantle.burnRegistered(amount);
        vm.stopPrank();
        return credit;
    }
}

contract MantleTest is MantleFixture {
    function setUp() public {
        _loadVectors();
        _deploy();
    }

    // ── Construction / reservations ─────────────────────────────────────
    function test_initialReservations() public view {
        assertEq(ember.MANTLE(), address(mantle));
        assertEq(mantle.accounted(), 0);
        assertEq(mantle.seedReserved(), 420_000e18);
        assertEq(mantle.vestingReserved(), 500_000e18);
        assertEq(mantle.reserved(), 920_000e18);
        assertEq(mantle.headroom(), 21_000_000e18 - 920_000e18);
        assertEq(uint256(mantle.registrarCategory(vent)), uint256(Mantle.BurnCategory.Protocol));
        assertEq(uint256(mantle.registrarCategory(pyre)), uint256(Mantle.BurnCategory.Pyre));
        assertEq(uint256(mantle.registrarCategory(alice)), uint256(Mantle.BurnCategory.None));
    }

    function test_constructorRejectsBadWiring() public {
        address[] memory regs = new address[](2);
        Mantle.BurnCategory[] memory cats = new Mantle.BurnCategory[](2);
        regs[0] = vent;
        regs[1] = vent;
        cats[0] = Mantle.BurnCategory.Protocol;
        cats[1] = Mantle.BurnCategory.Pyre;
        IEmberMintBurn e = IEmberMintBurn(address(ember));
        vm.expectRevert(abi.encodeWithSelector(Mantle.DuplicateRegistrar.selector, vent));
        new Mantle(e, distributor, kindling, treasury, start, regs, cats);
        vm.expectRevert(Mantle.ZeroAddress.selector);
        new Mantle(e, address(0), kindling, treasury, start, new address[](0), new Mantle.BurnCategory[](0));
        vm.expectRevert(Mantle.LengthMismatch.selector);
        new Mantle(e, distributor, kindling, treasury, start, regs, new Mantle.BurnCategory[](1));
    }

    // ── Kindling seed ───────────────────────────────────────────────────
    function test_seed_onlyKindling_exactlyOnce() public {
        vm.expectRevert(Mantle.NotKindling.selector);
        mantle.mintKindlingSeed();
        vm.prank(kindling);
        mantle.mintKindlingSeed();
        assertEq(ember.balanceOf(kindling), 420_000e18);
        assertEq(mantle.seedReserved(), 0);
        assertEq(mantle.accounted(), 420_000e18);
        vm.prank(kindling);
        vm.expectRevert(Mantle.SeedAlreadyMinted.selector);
        mantle.mintKindlingSeed();
    }

    // ── Treasury vesting ────────────────────────────────────────────────
    function test_vestedAt_exactVsCanonical() public view {
        uint256[] memory elapsed = _uints(".vesting.elapsed");
        uint256[] memory want = _uints(".vesting.out");
        for (uint256 i; i < elapsed.length; ++i) assertEq(mantle.vestedAt(start + elapsed[i]), want[i], "vested");
        assertEq(mantle.vestedAt(start - 1), 0, "nothing before start");
    }

    function test_vesting_dailyReleasesSumExactly() public {
        for (uint256 d = 1; d <= 366; ++d) {
            vm.warp(start + d * 1 days);
            mantle.releaseVesting();
            assertLe(mantle.vestingReleased(), mantle.vestedAt(block.timestamp), "never anticipatory");
        }
        assertEq(ember.balanceOf(treasury), 500_000e18, "exact total, no rounding drift");
        assertEq(mantle.vestingReserved(), 0);
        assertEq(mantle.releaseVesting(), 0, "nothing more");
    }

    // ── Epochs ──────────────────────────────────────────────────────────
    function test_finalize_onlyAfterEpochEnds_inOrder() public {
        vm.warp(_endOf(0) - 1);
        vm.expectRevert(abi.encodeWithSelector(Mantle.EpochNotOver.selector, 0, _endOf(0)));
        mantle.finalizeEpoch();
        vm.warp(_endOf(2)); // three epochs over: catch up one per call
        assertEq(mantle.finalizeEpoch(), 0);
        assertEq(mantle.finalizeEpoch(), 1);
        assertEq(mantle.finalizeEpoch(), 2);
        vm.expectRevert(abi.encodeWithSelector(Mantle.EpochNotOver.selector, 3, _endOf(3)));
        mantle.finalizeEpoch();
        (uint128 base0,,,,,) = mantle.budgets(0);
        (uint128 base1,,,,,) = mantle.budgets(1);
        (uint128 base2,,,,,) = mantle.budgets(2);
        assertEq(base0, EmissionMath.baseEmissionPerDay(0), "home share 100% at launch");
        assertEq(base2, EmissionMath.baseEmissionPerDay(2));
        assertEq(mantle.epochReserved(), uint256(base0) + base1 + base2);
    }

    function test_distributorPulls_boundedByBudget() public {
        vm.warp(_endOf(0));
        mantle.finalizeEpoch();
        uint256 budget = EmissionMath.baseEmissionPerDay(0);
        vm.expectRevert(Mantle.NotDistributor.selector);
        mantle.mintBase(0, alice, 1);
        vm.expectRevert(abi.encodeWithSelector(Mantle.EpochNotFinalized.selector, 1));
        vm.prank(distributor);
        mantle.mintBase(1, alice, 1);
        vm.startPrank(distributor);
        mantle.mintBase(0, alice, budget - 5e18);
        mantle.releaseBase(0, 5e18); // e.g. empty-pool time: never re-issued
        vm.expectRevert(abi.encodeWithSelector(Mantle.ExceedsBudget.selector, 1, 0));
        mantle.mintBase(0, alice, 1);
        vm.stopPrank();
        assertEq(ember.balanceOf(alice), budget - 5e18);
        assertEq(mantle.epochReserved(), 0);
        assertEq(mantle.accounted(), budget - 5e18);
    }

    // ── Registered burns and Ashfall ────────────────────────────────────
    function test_burns_recognizedByCategory_withOneEpochLag() public {
        _fund(vent, 1_000e18);
        _fund(pyre, 1_000e18);
        uint256 acc = mantle.accounted();
        assertEq(_burn(vent, 400e18), 200e18, "protocol burns recycle 50%");
        assertEq(_burn(pyre, 400e18), 100e18, "Pyre burns recycle 25%");
        assertEq(mantle.accounted(), acc - 800e18, "recognized burns reopen headroom");
        assertEq(ember.totalSupply(), mantle.accounted());
        uint256 burnEpoch = mantle.epochAt(block.timestamp);
        assertEq(mantle.creditsOf(burnEpoch), 300e18);

        // Credits fund the epoch AFTER the one they were recognized in.
        _finalizeThrough(burnEpoch);
        (,uint128 ashBurnEpoch,,,,) = mantle.budgets(burnEpoch);
        assertEq(ashBurnEpoch, 0, "no same-epoch recycling");
        _finalizeThrough(burnEpoch + 1);
        (,uint128 ashNext,,,,) = mantle.budgets(burnEpoch + 1);
        assertEq(ashNext, 300e18);
        vm.prank(distributor);
        mantle.mintAshfall(burnEpoch + 1, alice, 300e18);
        assertEq(ember.balanceOf(alice), 300e18);
    }

    function test_unregisteredBurnsAreNotRecognized() public {
        _fund(alice, 100e18);
        uint256 acc = mantle.accounted();
        vm.prank(alice);
        ember.burn(100e18);
        assertEq(mantle.accounted(), acc, "raw burns never reopen headroom");
        vm.startPrank(alice);
        vm.expectRevert(Mantle.NotRegistrar.selector);
        mantle.burnRegistered(0);
        vm.stopPrank();
    }

    function test_rolledAshfallRequeues() public {
        _fund(vent, 1_000e18);
        _burn(vent, 1_000e18); // 500 credit in burn epoch b
        uint256 b = mantle.epochAt(block.timestamp);
        _finalizeThrough(b + 1); // epoch b+1 gets the 500
        (,uint128 ash1,,,,) = mantle.budgets(b + 1);
        assertEq(ash1, 500e18);
        vm.prank(distributor);
        mantle.rollAshfall(b + 1, 500e18); // nobody eligible
        assertEq(mantle.queuedAshfall(), 500e18);
        _finalizeThrough(b + 2);
        (,uint128 ash2,,,,) = mantle.budgets(b + 2);
        assertEq(ash2, 500e18, "rolls forward, never vanishes");
        assertEq(mantle.queuedAshfall(), 0);
    }

    // ── Near the ceiling ────────────────────────────────────────────────
    function test_nearCap_sharedHeadroomScalesBaseAndAshfall_queuesShortfall() public {
        _fund(vent, 400e18);
        _burn(vent, 400e18); // 200 Ashfall credit in burn epoch b
        uint256 e = mantle.epochAt(block.timestamp) + 1;
        _finalizeThrough(e - 1);
        // Leave exactly 100 EMBER of headroom.
        mantle.setAccountedForTest(P.EMBER_MAX_SUPPLY - mantle.reserved() - 100e18);
        _finalizeThrough(e); // epoch e: base target ~21.5k + Ashfall 200, room 100
        (uint128 base, uint128 ash,,,,) = mantle.budgets(e);
        uint256 baseTarget = EmissionMath.baseEmissionPerDay(e);
        assertLe(uint256(base) + ash, 100e18, "never past the ceiling");
        assertGt(ash, 0, "Ashfall shares the budget pro-rata");
        assertEq(uint256(base) + ash + mantle.residueOf(e), 100e18, "residue tagged, not lost");
        assertApproxEqAbs(base, (100e18 * baseTarget) / (baseTarget + 200e18), 1);
        assertEq(mantle.queuedAshfall(), 200e18 - ash, "cap-constrained Ashfall stays queued");
        assertEq(mantle.headroom(), mantle.residueOf(e));
    }
}

/// @dev Random sequences of every Mantle action.
contract MantleHandler is MantleFixture {
    uint256 public totalCredits;
    uint256 public totalAshfallMinted;
    mapping(uint256 => uint256) public baseMintedOf;

    constructor(EmberToken e, MantleHarness m, uint256 s) {
        ember = e;
        mantle = m;
        start = s;
    }

    function warpAndFinalize(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 0, 3 days));
        if (block.timestamp >= _endOf(mantle.nextEpoch())) mantle.finalizeEpoch();
    }

    function mintBase(uint256 epochSeed, uint256 amount) external {
        uint256 n = mantle.nextEpoch();
        if (n == 0) return;
        uint256 e = epochSeed % n;
        (uint128 base,, uint128 minted,, uint128 released,) = mantle.budgets(e);
        amount = bound(amount, 0, base - minted - released);
        vm.prank(distributor);
        mantle.mintBase(e, epochSeed % 2 == 0 ? vent : pyre, amount);
        baseMintedOf[e] += amount;
    }

    function mintOrRollAshfall(uint256 epochSeed, uint256 amount, bool roll) external {
        uint256 n = mantle.nextEpoch();
        if (n == 0) return;
        uint256 e = epochSeed % n;
        (, uint128 ash,, uint128 minted,, uint128 rolled) = mantle.budgets(e);
        amount = bound(amount, 0, ash - minted - rolled);
        vm.prank(distributor);
        if (roll) {
            mantle.rollAshfall(e, amount);
        } else {
            mantle.mintAshfall(e, alice, amount);
            totalAshfallMinted += amount;
        }
    }

    function releaseBase(uint256 epochSeed, uint256 amount) external {
        uint256 n = mantle.nextEpoch();
        if (n == 0) return;
        uint256 e = epochSeed % n;
        (uint128 base,, uint128 minted,, uint128 released,) = mantle.budgets(e);
        amount = bound(amount, 0, base - minted - released);
        vm.prank(distributor);
        mantle.releaseBase(e, amount);
    }

    function registeredBurn(bool fromVent, uint256 amount) external {
        address r = fromVent ? vent : pyre;
        amount = bound(amount, 0, ember.balanceOf(r));
        totalCredits += _burn(r, amount);
    }

    function rawBurn(uint256 amount) external {
        amount = bound(amount, 0, ember.balanceOf(vent));
        vm.prank(vent);
        ember.burn(amount);
    }

    function seed() external {
        if (mantle.seedReserved() == 0) return;
        vm.prank(kindling);
        mantle.mintKindlingSeed();
    }

    function vest() external {
        mantle.releaseVesting();
    }
}

contract MantleInvariantTest is MantleFixture {
    MantleHandler handler;

    function setUp() public {
        _deploy();
        vm.warp(start);
        handler = new MantleHandler(ember, mantle, start);
        targetContract(address(handler));
    }

    function invariant_ceiling() public view {
        assertLe(mantle.accounted() + mantle.reserved(), P.EMBER_MAX_SUPPLY);
    }

    function invariant_supplyNeverExceedsLedger() public view {
        assertLe(ember.totalSupply(), mantle.accounted());
    }

    function invariant_seedAndVestingBounds() public view {
        uint256 seedOut = P.EMBER_KINDLING_SEED - mantle.seedReserved();
        assertTrue(seedOut == 0 || seedOut == P.EMBER_KINDLING_SEED, "seed is all-or-nothing");
        assertLe(mantle.vestingReleased(), mantle.vestedAt(block.timestamp));
    }

    function invariant_ashfallBackedByCredits() public view {
        assertLe(handler.totalAshfallMinted(), handler.totalCredits());
    }

    function invariant_baseNeverAboveSchedule() public view {
        uint256 n = mantle.nextEpoch();
        for (uint256 e; e < n; ++e) {
            (uint128 base,,,,,) = mantle.budgets(e);
            assertLe(base, EmissionMath.baseEmissionPerDay(e));
            assertLe(handler.baseMintedOf(e), base);
        }
    }
}
