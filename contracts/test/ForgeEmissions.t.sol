// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EmberToken} from "../src/EmberToken.sol";
import {Mantle, IEmberMintBurn} from "../src/Mantle.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {ForgeEmissions, IMantleDistribution} from "../src/forge/ForgeEmissions.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {MockERC20} from "./utils/MockERC20.sol";

/// @dev EMBER, the Mantle and ForgeEmissions reference one another: predict the CREATE
///      addresses. Stake assets are MOCK tokens in every pool, including ember-single
///      (which stakes real EMBER in production); these tests do not cover EMBER-in/EMBER-out.
abstract contract SettlementFixture is Test {
    MockERC20[4] stake;
    ForgePool[4] pools;
    EmberToken ember;
    Mantle mantle;
    ForgeEmissions emissions;
    address feeRouter = makeAddr("feeRouter");
    address boost = makeAddr("boost");
    address capstone = makeAddr("capstone");
    address matchReserveSink = makeAddr("matchReserve");
    address sealedPotStream = makeAddr("sealedPot");
    /// A Protocol-category burn registrar (a Vent burn lane stand-in): its burns fund Ashfall.
    address registrar = makeAddr("registrar");
    uint256 start;

    function _deploySettlement(uint256 start_) internal {
        start = start_;
        bool[4] memory lp = [true, true, false, false];
        for (uint256 i; i < 4; ++i) {
            stake[i] = new MockERC20("Stake", "STK");
            pools[i] = new ForgePool(IERC20(address(stake[i])), lp[i], feeRouter, boost);
        }
        uint256 nonce = vm.getNonce(address(this));
        address mantleAt = vm.computeCreateAddress(address(this), nonce + 1);
        address emissionsAt = vm.computeCreateAddress(address(this), nonce + 2);
        ember = new EmberToken(mantleAt);
        address[] memory registrars = new address[](1);
        Mantle.BurnCategory[] memory categories = new Mantle.BurnCategory[](1);
        (registrars[0], categories[0]) = (registrar, Mantle.BurnCategory.Protocol);
        mantle = new Mantle(
            IEmberMintBurn(address(ember)), emissionsAt, makeAddr("kindling"), makeAddr("treasury"), start, registrars, categories
        );
        emissions = _newEmissions(pools);
        require(address(mantle) == mantleAt && address(emissions) == emissionsAt, "prediction");
    }

    function _newEmissions(ForgePool[4] memory ps) internal returns (ForgeEmissions) {
        return new ForgeEmissions(
            IMantleDistribution(address(mantle)), IERC20(address(ember)), ps, capstone, matchReserveSink, sealedPotStream
        );
    }

    function _user(uint256 pos) internal pure returns (address) {
        return address(uint160(0x3000 + pos));
    }

    function _fund(address who) internal {
        for (uint256 i; i < 4; ++i) {
            stake[i].mint(who, 1e30);
            vm.prank(who);
            stake[i].approve(address(pools[i]), type(uint256).max);
        }
    }
}

/// @notice Differential replay: custody actions in four pools plus Mantle finalization,
///         epoch opening, measure and credit pages, and claims. Reverts and a keccak of
///         the settlement state must equal SettlementModel's after every action, and
///         every credited payout equals canonical settleBaseEpoch (checked in the model).
contract ForgeEmissionsDifferentialTest is SettlementFixture {
    enum K {
        Open,
        Deposit,
        Request,
        Execute,
        Cancel,
        Emergency,
        Poke,
        Finalize,
        OpenEpoch,
        Advance,
        RequestClaim,
        ExecuteClaim,
        Seal,
        SettleSeal,
        Burn,
        BurnForfeits,
        TakeCapstone,
        TakeMatchReserve,
        TakeSealedPot,
        Boost
    }

    string json;

    function setUp() public {
        json = vm.readFile(string.concat(vm.projectRoot(), "/contracts/test/fixtures/settlement-vectors.json"));
    }

    function test_settle_steadyTwoStakers() public { _replay("steadyTwoStakers"); }
    function test_settle_touchedBeforePage() public { _replay("touchedBeforePage"); }
    function test_settle_lapseInsideEpoch() public { _replay("lapseInsideEpoch"); }
    function test_settle_partialOccupancy() public { _replay("partialOccupancy"); }
    function test_settle_latePages() public { _replay("latePages"); }
    function test_settle_claimSnapshot() public { _replay("claimSnapshot"); }
    function test_settle_pagedLots() public { _replay("pagedLots"); }
    function test_settle_recordSpam() public { _replay("recordSpam"); }
    function test_settle_lapseBudget() public { _replay("lapseBudget"); }
    function test_settle_sealCapBinds() public { _replay("sealCapBinds"); }
    function test_settle_sealCandidateBinds() public { _replay("sealCandidateBinds"); }
    function test_settle_sealVestLate() public { _replay("sealVestLate"); }
    function test_settle_sealForfeitRouted() public { _replay("sealForfeitRouted"); }
    function test_settle_sealPausedInEpoch() public { _replay("sealPausedInEpoch"); }
    function test_settle_ashfallHeatSquared() public { _replay("ashfallHeatSquared"); }
    function test_settle_boostedHeat() public { _replay("boostedHeat"); }
    function test_settle_random0() public { _replay("random0"); }
    function test_settle_random1() public { _replay("random1"); }
    function test_settle_random2() public { _replay("random2"); }

    function test_everySettlementScenarioIsReplayed() public view {
        assertEq(vm.parseJsonStringArray(json, ".names").length, 19, "add a test_settle_* for each new scenario");
    }

    function _uints(string memory key) internal view returns (uint256[] memory out) {
        string[] memory raw = vm.parseJsonStringArray(json, key);
        out = new uint256[](raw.length);
        for (uint256 i; i < raw.length; ++i) out[i] = vm.parseUint(raw[i]);
    }

    function _replay(string memory name) internal {
        string memory base = string.concat(".scenarios.", name);
        uint256 positions = vm.parseJsonUint(json, string.concat(base, ".positions"));
        uint256[] memory a = _uints(string.concat(base, ".actions"));
        string[] memory rawHashes = vm.parseJsonStringArray(json, string.concat(base, ".hash"));
        uint256[] memory probe = _uints(string.concat(base, ".probe"));
        assertEq(a.length, rawHashes.length * 6, "layout");

        _deploySettlement(vm.parseUint(vm.parseJsonString(json, ".start")));
        for (uint256 k = 1; k <= positions; ++k) _fund(_user(k));

        for (uint256 i; i < rawHashes.length; ++i) {
            uint256[6] memory x = [a[6 * i], a[6 * i + 1], a[6 * i + 2], a[6 * i + 3], a[6 * i + 4], a[6 * i + 5]];
            vm.warp(x[1]);
            string memory where = string.concat(name, " step ", vm.toString(i));
            if (x[5] == 1) vm.expectRevert();
            _act(K(x[0]), x[2], x[3], x[4]);
            assertEq(ember.balanceOf(address(emissions)), probe[3 * i], string.concat(where, ": EMBER held"));
            assertEq(emissions.nextEpoch(), probe[3 * i + 1], string.concat(where, ": next epoch"));
            assertEq(mantle.nextEpoch(), probe[3 * i + 2], string.concat(where, ": Mantle epoch"));
            assertEq(this.snapshot(positions), vm.parseBytes32(rawHashes[i]), string.concat(where, ": state hash"));
        }
    }

    function _act(K kind, uint256 poolIdx, uint256 pos, uint256 arg) internal {
        ForgePool pool = poolIdx < 4 ? pools[poolIdx] : ForgePool(address(0));
        if (kind == K.Finalize) {
            mantle.finalizeEpoch();
        } else if (kind == K.OpenEpoch) {
            emissions.openEpoch();
        } else if (kind == K.Advance) {
            emissions.advance(arg, poolIdx);
        } else if (kind == K.SettleSeal) {
            emissions.settleSeal(poolIdx, pos, arg);
        } else if (kind == K.Burn) {
            this.burnVia(_user(pos), arg); // one external call, so an expected revert covers all of it
        } else if (kind == K.BurnForfeits) {
            emissions.burnForfeits();
        } else if (kind == K.TakeCapstone) {
            vm.prank(capstone);
            emissions.takeCapstone(poolIdx, pos);
        } else if (kind == K.TakeMatchReserve) {
            vm.prank(matchReserveSink);
            emissions.takeMatchReserve();
        } else if (kind == K.TakeSealedPot) {
            vm.prank(sealedPotStream);
            emissions.takeSealedPot(poolIdx);
        } else if (kind == K.Boost) {
            vm.prank(boost);
            pool.setOrdinaryBonus(pos, arg);
        } else {
            vm.prank(_user(pos));
            if (kind == K.Open) assertEq(pool.open(arg), pos, "position id");
            else if (kind == K.Deposit) pool.deposit(pos, arg);
            else if (kind == K.Request) pool.requestCooling(pos, arg);
            else if (kind == K.Execute) pool.executeWithdrawal(pos, uint32(arg));
            else if (kind == K.Cancel) pool.cancelCooling(pos, uint32(arg));
            else if (kind == K.Emergency) pool.emergencyExit(pos);
            else if (kind == K.Poke) pool.poke(pos);
            else if (kind == K.RequestClaim) emissions.requestClaim(poolIdx, pos);
            else if (kind == K.Seal) pool.seal(pos, arg);
            else emissions.executeClaim(poolIdx, pos);
        }
    }

    /// @dev A user hands claimed EMBER to the Protocol registrar, which burns it (50% Ashfall credit).
    function burnVia(address user, uint256 amount) external {
        require(msg.sender == address(this));
        vm.prank(user);
        ember.transfer(registrar, amount);
        vm.startPrank(registrar);
        ember.approve(address(mantle), amount);
        mantle.burnRegistered(amount);
        vm.stopPrank();
    }

    /// @dev Word layout mirrored by scripts/settlement-scenarios.ts::words; external so
    ///      each call gets fresh memory.
    function snapshot(uint256 positions) external view returns (bytes32) {
        uint256[] memory w = new uint256[](20_000);
        uint256 n;
        for (uint256 i; i < 4; ++i) {
            (w[n], w[n + 1], w[n + 2], w[n + 3]) = (
                pools[i].activePrincipal(),
                pools[i].frozenPrincipal(),
                pools[i].occupiedSecondsAt(block.timestamp),
                pools[i].positionCount()
            );
            n += 4;
        }
        uint256 finalized = mantle.nextEpoch();
        (w[n], w[n + 1], w[n + 2]) = (finalized, mantle.queuedAshfall(), mantle.accounted());
        n += 3;
        for (uint256 e; e < finalized; ++e) {
            (uint128 b, uint128 a, uint128 minted, uint128 aMinted, uint128 released, uint128 rolled) = mantle.budgets(e);
            (w[n], w[n + 1], w[n + 2]) = (b, minted, released);
            (w[n + 3], w[n + 4], w[n + 5]) = (a, aMinted, rolled);
            n += 6;
        }
        for (uint256 e; e <= mantle.epochAt(block.timestamp); ++e) w[n++] = mantle.creditsOf(e);
        uint256 opened = emissions.nextEpoch();
        (w[n], w[n + 1]) = (opened, ember.balanceOf(address(emissions)));
        n += 2;
        for (uint256 e; e < opened; ++e) {
            for (uint256 i; i < 4; ++i) n = _pushPoolEpoch(w, n, e, i);
        }
        for (uint256 i; i < 4; ++i) {
            for (uint256 id = 1; id <= positions; ++id) {
                n = _pushHolder(w, n, i, id);
            }
        }
        (w[n], w[n + 1]) = (emissions.burnLane(), emissions.matchReserve());
        n += 2;
        for (uint256 i; i < 4; ++i) w[n++] = emissions.sealedPot(i);
        for (uint256 id = 1; id <= positions; ++id) w[n++] = ember.balanceOf(_user(id));
        (w[n], w[n + 1], w[n + 2], w[n + 3]) = (
            ember.balanceOf(capstone),
            ember.balanceOf(matchReserveSink),
            ember.balanceOf(sealedPotStream),
            ember.balanceOf(registrar)
        );
        n += 4;
        assembly ("memory-safe") {
            mstore(w, n)
        }
        return keccak256(abi.encodePacked(w));
    }

    function _pushHolder(uint256[] memory w, uint256 n, uint256 i, uint256 id) internal view returns (uint256) {
        ForgeEmissions.Claim memory c = emissions.claimOf(i, id);
        uint256 seals = pools[i].positionOf(id).sealCount;
        (w[n], w[n + 1], w[n + 2]) = (emissions.unclaimed(i, id), c.amount, c.maturesAt);
        (w[n + 3], w[n + 4], w[n + 5]) = (emissions.capstoneOwed(i, id), seals, uint256(emissions.sealStatus(i, id, seals)));
        n += 6;
        for (uint256 k = 1; k <= seals; ++k) w[n++] = emissions.sealEscrow(i, id, k);
        return n;
    }

    function _pushProgress(uint256[] memory w, uint256 n, uint256 e, uint256 i) internal view returns (uint256) {
        ForgeEmissions.Progress memory pr = emissions.progressOf(e, i);
        (w[n], w[n + 1], w[n + 2], w[n + 3]) = (pr.id, pr.slot, pr.seg, pr.seal);
        (w[n + 4], w[n + 5], w[n + 6], w[n + 7]) =
            (pr.stakeSeconds, pr.heatSeconds, pr.sealedStakeSeconds, pr.sealedHeatSeconds);
        (w[n + 8], w[n + 9]) = (pr.ashfallQuotient, pr.ashfallRemainder);
        return n + 10;
    }

    function _pushPoolEpoch(uint256[] memory w, uint256 n, uint256 e, uint256 i) internal view returns (uint256) {
        ForgeEmissions.PoolEpoch memory pe = emissions.poolEpoch(e, i);
        uint256[20] memory head = [
            uint256(pe.phase),
            pe.positions,
            pe.cursor,
            pe.credited,
            pe.escrowed,
            pe.target,
            pe.admitted,
            pe.bucket,
            pe.flat,
            pe.heat,
            pe.escrow,
            pe.paid,
            pe.stakeSeconds,
            pe.heatSeconds,
            pe.candidateSeconds,
            emissions.earnerCount(e, i),
            emissions.sealedEarnerCount(e, i),
            pe.ashfall,
            pe.ashfallPaid,
            pe.ashfallWeight
        ];
        for (uint256 k; k < 20; ++k) w[n++] = head[k];
        n = _pushProgress(w, n, e, i);
        for (uint256 k; k < head[15]; ++k) n = _pushMeasure(w, n, e, i, emissions.earnerAt(e, i, k));
        return n;
    }

    function _pushMeasure(uint256[] memory w, uint256 n, uint256 e, uint256 i, uint256 id)
        internal
        view
        returns (uint256)
    {
        ForgeEmissions.Measure memory m = emissions.measureOf(e, i, id);
        (w[n], w[n + 1], w[n + 2], w[n + 3]) = (id, m.stakeSeconds, m.heatSeconds, m.sealSeconds);
        (w[n + 4], w[n + 5], w[n + 6], w[n + 7]) = (m.candidateSeconds, m.escrow, m.seal, m.ashfallWeight);
        return n + 8;
    }
}

/// @notice Focused settlement properties.
contract ForgeEmissionsTest is SettlementFixture {
    address alice = _user(1);
    address bob = _user(2);

    function setUp() public {
        vm.warp(1_800_000_000);
        _deploySettlement(block.timestamp);
        _fund(alice);
        _fund(bob);
    }

    function _settle(uint256 e) internal {
        mantle.finalizeEpoch();
        emissions.openEpoch();
        for (uint256 i; i < 4; ++i) {
            while (true) {
                ForgeEmissions.Phase ph = emissions.poolEpoch(e, i).phase;
                if (ph == ForgeEmissions.Phase.None || ph == ForgeEmissions.Phase.Done) break;
                emissions.advance(e, i);
            }
        }
    }

    function test_constructorChecksPoolKinds() public {
        ForgePool[4] memory swapped = [pools[2], pools[1], pools[0], pools[3]];
        vm.expectRevert(abi.encodeWithSelector(ForgeEmissions.PoolMismatch.selector, 0));
        _newEmissions(swapped);
    }

    function test_constructorRejectsZeroConsumers() public {
        vm.expectRevert(ForgeEmissions.ZeroAddress.selector);
        new ForgeEmissions(IMantleDistribution(address(mantle)), IERC20(address(ember)), pools, address(0), matchReserveSink, sealedPotStream);
        vm.expectRevert(ForgeEmissions.ZeroAddress.selector);
        new ForgeEmissions(IMantleDistribution(address(mantle)), IERC20(address(ember)), pools, capstone, address(0), sealedPotStream);
        vm.expectRevert(ForgeEmissions.ZeroAddress.selector);
        new ForgeEmissions(IMantleDistribution(address(mantle)), IERC20(address(ember)), pools, capstone, matchReserveSink, address(0));
    }

    function test_soleStakerEarnsTheWholeAdmittedBudget() public {
        vm.prank(alice);
        pools[0].open(100e18);
        skip(1 days);
        _settle(0);
        ForgeEmissions.PoolEpoch memory pe = emissions.poolEpoch(0, 0);
        uint256 target = (21_600e18 * P.FORGE_POOL_0_ALLOC_POINTS) / P.FORGE_ALLOC_POINTS_TOTAL;
        assertEq(pe.target, target);
        assertEq(pe.admitted, target, "occupied the whole epoch");
        // 10% bucket returns to Heat with no Seals: flat = 27%, heat = 73%.
        assertEq(pe.flat, ((target - target / 10) * 30) / 100);
        assertEq(pe.flat + pe.heat, target);
        assertApproxEqAbs(emissions.unclaimed(0, 1), target, 1, "a sole staker earns E (floor dust at most 1 wei)");
        (, , uint128 minted, , uint128 released,) = mantle.budgets(0);
        assertEq(minted + released, 21_600e18, "every base wei is minted or released");
    }

    function test_unoccupiedTimeIsReleasedNotReissued() public {
        skip(12 hours);
        vm.prank(alice);
        pools[0].open(100e18); // half the epoch
        skip(12 hours);
        _settle(0);
        ForgeEmissions.PoolEpoch memory pe = emissions.poolEpoch(0, 0);
        assertEq(pe.admitted, pe.target / 2);
        (, , uint128 minted, , uint128 released,) = mantle.budgets(0);
        assertEq(minted, emissions.unclaimed(0, 1));
        assertEq(minted + released, 21_600e18);
    }

    function test_claimIsASnapshotWithA24hTimer() public {
        vm.prank(alice);
        pools[0].open(100e18);
        skip(1 days);
        _settle(0);
        uint256 first = emissions.unclaimed(0, 1);
        vm.prank(alice);
        emissions.requestClaim(0, 1);
        skip(1 days);
        _settle(1); // credited after the snapshot
        uint256 later = emissions.unclaimed(0, 1);
        assertGt(later, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(ForgeEmissions.NotOwner.selector, 0, 1));
        emissions.executeClaim(0, 1);
        vm.prank(alice);
        assertEq(emissions.executeClaim(0, 1), first, "only the snapshot is paid");
        assertEq(ember.balanceOf(alice), first);
        assertEq(emissions.unclaimed(0, 1), later);
    }

    function test_settlementNeverBlocksAnExit() public {
        vm.prank(alice);
        uint256 id = pools[0].open(100e18);
        skip(2 days); // two epochs unsettled
        vm.prank(alice);
        pools[0].emergencyExit(id);
        _settle(0);
        _settle(1);
        assertGt(emissions.unclaimed(0, id), 0, "rewards earned before the exit stay claimable");
    }

    function test_epochMustBeFinalizedFirst() public {
        skip(1 days);
        vm.expectRevert(abi.encodeWithSelector(ForgeEmissions.EpochNotFinalized.selector, 0));
        emissions.openEpoch();
    }

    /// A full page of 32 one-lot positions, then a credit page crediting all 32.
    function test_gas_fullPages() public {
        for (uint256 k = 1; k <= 32; ++k) {
            address u = _user(100 + k);
            _fund(u);
            vm.prank(u);
            pools[0].open(1e18 * k);
        }
        skip(1 days);
        mantle.finalizeEpoch();
        emissions.openEpoch();
        uint256 g = gasleft();
        emissions.advance(0, 0);
        emit log_named_uint("measure page (32 positions x 1 lot)", g - gasleft());
        g = gasleft();
        emissions.advance(0, 0);
        emit log_named_uint("credit page (32 earners, one mint)", g - gasleft());
        assertEq(uint256(emissions.poolEpoch(0, 0).phase), uint256(ForgeEmissions.Phase.Done));
    }

    /// Ashfall page gas, its costliest case: below the age cap (live Heat² roots on every
    /// segment) and past the 30-day minimums. Pool 0: 32 one-lot positions; pool 2: one
    /// position with 32 lots. Epoch 32 carries an Ashfall budget from a burn in epoch 31.
    function test_gas_ashfallPages() public {
        for (uint256 k = 1; k <= 32; ++k) {
            address u = _user(100 + k);
            _fund(u);
            vm.prank(u);
            pools[0].open(1e18 * k);
        }
        vm.startPrank(bob);
        uint256 id = pools[2].open(1e18);
        for (uint256 i = 1; i < 32; ++i) {
            skip(30 minutes);
            pools[2].deposit(id, 1e18);
        }
        vm.stopPrank();
        vm.prank(alice);
        pools[1].open(100e18);
        vm.warp(start + 1 days + 1);
        _settle(0);
        vm.prank(alice);
        emissions.requestClaim(1, 1);
        skip(1 days);
        vm.prank(alice);
        uint256 amount = emissions.executeClaim(1, 1);
        vm.warp(start + 31 days + 1);
        vm.prank(alice);
        ember.transfer(registrar, amount);
        vm.startPrank(registrar);
        ember.approve(address(mantle), amount);
        mantle.burnRegistered(amount);
        vm.stopPrank();
        vm.warp(start + 33 days + 1);
        for (uint256 e = 1; e <= 32; ++e) mantle.finalizeEpoch();
        for (uint256 e = 1; e <= 32; ++e) emissions.openEpoch();
        assertGt(emissions.poolEpoch(32, 0).ashfall, 0, "epoch 32 carries Ashfall");
        uint256 g = gasleft();
        emissions.advance(32, 0);
        emit log_named_uint("Ashfall measure page (32 positions x 1 lot)", g - gasleft());
        g = gasleft();
        emissions.advance(32, 0);
        emit log_named_uint("Ashfall credit page (32 earners, two mints)", g - gasleft());
        g = gasleft();
        emissions.advance(32, 2);
        emit log_named_uint("Ashfall measure page (1 position, 32 lots)", g - gasleft());
        assertEq(uint256(emissions.poolEpoch(32, 0).phase), uint256(ForgeEmissions.Phase.Done));
        assertGt(emissions.poolEpoch(32, 0).ashfallPaid, 0, "Ashfall credited");
    }

    /// Settlement page gas: one 32-lot position, then a credit page.
    function test_gas_pages() public {
        vm.startPrank(alice);
        uint256 id = pools[0].open(1e18);
        for (uint256 i = 1; i < 32; ++i) {
            skip(30 minutes);
            pools[0].deposit(id, 1e18);
        }
        vm.stopPrank();
        skip(1 days);
        mantle.finalizeEpoch();
        uint256 g = gasleft();
        emissions.openEpoch();
        emit log_named_uint("openEpoch (4 pools)", g - gasleft());
        g = gasleft();
        emissions.advance(0, 0);
        emit log_named_uint("measure page (1 position, 32 lots)", g - gasleft());
        g = gasleft();
        emissions.advance(0, 0);
        emit log_named_uint("credit page", g - gasleft());
        vm.prank(alice);
        g = gasleft();
        emissions.requestClaim(0, id);
        emit log_named_uint("requestClaim", g - gasleft());
    }
}
