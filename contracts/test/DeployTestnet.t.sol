// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {ForgeEmissions} from "../src/forge/ForgeEmissions.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {ForgeView} from "../src/forge/ForgeView.sol";
import {FurnaceTestnet} from "../script/DeployTestnet.s.sol";
import {TestnetToken, TestnetValuation} from "../script/testnet/TestnetStandIns.sol";
import {EmberPair} from "../src/pairs/EmberPair.sol";
import {Vent} from "../src/vent/Vent.sol";
import {Mantle} from "../src/Mantle.sol";
import {Kindling} from "../src/kindling/Kindling.sol";

using ForgeView for ForgePool;

/// @notice The testnet kit, offline: CreateX's runtime (fixture, fetched from LiteForge and equal to
///         Ethereum's) is etched at its address and the chain id set to LiteForge's. The same
///         deployment is rehearsed live by `pnpm testnet:dry-run` on a fork of chain 4441.
contract DeployTestnetTest is Test, FurnaceTestnet {
    address deployer = makeAddr("deployer");
    address operator = makeAddr("operator");

    function setUp() public {
        vm.chainId(LITEFORGE_CHAIN_ID);
        vm.warp(1_790_000_000);
        bytes memory code = vm.parseBytes(vm.readFile("contracts/test/fixtures/createx-runtime.hex"));
        assertEq(keccak256(code), CREATEX_CODEHASH, "fixture is CreateX");
        vm.etch(address(CREATEX), code);
    }

    function _deployAs(address who, address op, string memory version) internal returns (Deployment memory d) {
        return _deployAs(who, op, version, true);
    }

    function _deployAs(address who, address op, string memory version, bool pairsNow)
        internal
        returns (Deployment memory d)
    {
        vm.startPrank(who);
        d = _deploy(who, Options(op, version, block.timestamp, address(0), address(0), pairsNow, false, 0));
        vm.stopPrank();
    }

    /// @dev The real-Kindling mode (ADR 0021), opening `start`.
    function _deployWithKindling(uint256 start) internal returns (Deployment memory d) {
        vm.startPrank(operator);
        d = _deploy(operator, Options(operator, "1", block.timestamp, address(0), address(0), true, true, start));
        vm.stopPrank();
    }

    function _contributeTo(Deployment memory d, address who, uint256 gross) internal {
        TestnetToken usdc = TestnetToken(address(d.pairQuote[0]));
        vm.startPrank(who);
        usdc.mint(who, gross);
        usdc.approve(address(d.kindling), gross);
        d.kindling.contribute(gross);
        vm.stopPrank();
    }

    function test_deploysAndWiresTheCore() public {
        Deployment memory d = _deployAs(deployer, operator, "1");
        assertEq(address(d.boost.EMISSIONS()), address(d.emissions));
        assertEq(address(d.stake[2]), address(d.ember), "pool 2 stakes EMBER itself");
        for (uint256 i; i < 4; ++i) {
            assertEq(d.pools[i].DEEDS(), operator, "the Deed slot is the operator's");
            assertEq(d.pools[i].FEE_COLLECTOR(), address(d.vent), "the Vent collects every pool's fees");
        }
        assertEq(d.mantle.KINDLING(), operator);
        assertEq(d.mantle.TREASURY(), operator);
        assertEq(d.emissions.MATCH_RESERVE(), operator);
        assertEq(d.emissions.SEALED_POT(), operator);
        assertEq(TestnetToken(address(d.stake[3])).decimals(), 6, "the USDC stand-in has USDC's decimals");
        // The EMBER pairs (ADR 0015): pools 0 and 1 stake their receipts.
        assertTrue(d.pairsLive);
        Plan memory pl = _plan(deployer, "1");
        for (uint256 i; i < 2; ++i) {
            assertEq(address(d.stake[i]), address(d.pairs[i]), "pool i stakes pair i");
            assertEq(address(d.pairs[i]), pl.pair[i], "at the predicted address");
            assertEq(address(d.pairs[i].EMBER()), address(d.ember));
            assertEq(d.pairs[i].INITIALIZER(), operator, "the Kindling slot initializes");
            assertEq(d.pairs[i].FEE_ROUTER(), address(d.vent), "the Vent collects every pair's fees");
        }
        assertEq(address(d.pairs[0].QUOTE()), address(d.stake[3]), "BlastPool quotes the USDC that pool 3 stakes");
        assertEq(TestnetToken(address(d.pairs[1].QUOTE())).decimals(), 18, "SmelterPool quotes tWETH");
        assertEq(d.pairs[0].QUOTE_SCALE(), 1e12);
        // Flow (ADR 0016): the pairs and the LP pools name it; the single-asset pools do not.
        assertEq(address(d.flow), pl.flow, "Flow at its predicted address");
        for (uint256 i; i < 2; ++i) assertEq(d.pairs[i].FLOW(), address(d.flow), "pair i routes through Flow");
        assertEq(d.pools[0].FLOW(), address(d.flow));
        assertEq(d.pools[1].FLOW(), address(d.flow));
        assertEq(d.pools[2].FLOW(), address(0), "no fee-free stake into the EMBER pool");
        assertEq(d.pools[3].FLOW(), address(0), "nor the USDC pool");
        assertEq(d.flow.COMPOUNDER(), operator, "the compounder slot is the operator's");
        // Source-lot additions (ADR 0017): the same compounder, on the LP pools only.
        assertEq(d.pools[0].COMPOUNDER(), operator, "the compounder adds to pool 0's lots");
        assertEq(d.pools[1].COMPOUNDER(), operator);
        assertEq(d.pools[2].COMPOUNDER(), address(0), "the EMBER pool pays liquid EMBER instead");
        assertEq(d.pools[3].COMPOUNDER(), address(0), "and so does the USDC pool");
        // Kindling, First Flame and the head start (ADR 0018, ADR 0019).
        for (uint256 i; i < 4; ++i) {
            assertEq(d.pools[i].KINDLING(), i == 0 ? operator : address(0), "Kindling stakes pool 0's LP");
            assertEq(d.pools[i].FOUNDERS(), address(d.founders), "every pool reads the founder record");
            assertEq(d.pools[i].IGNITION(), operator, "Ignition grants head starts in every pool");
        }
        assertEq(address(d.flow.REBATES()), address(d.rebates));
        assertEq(uint8(d.mantle.registrarCategory(address(d.vent))), uint8(Mantle.BurnCategory.Protocol), "the Vent's burns are registered");
        assertEq(address(d.vent.PAIR_0()), address(d.pairs[0]));
        assertEq(address(d.vent.POOL_3()), address(d.pools[3]));
        assertEq(d.vent.TREASURY(), operator, "the operator stands in for every recipient");
        assertEq(d.vent.COMPOUNDER(), operator);
    }

    /// The Vent (ADR 0020) on the real pools and pairs: the smoke run's fees are collected; once the
    /// TWAP has matured and the 24 h clock has run, the burn lane buys EMBER back and burns it for
    /// Ashfall credit. An emergency exit never touches it.
    function test_theVentBuysBackAndBurns() public {
        Deployment memory d = _deployAs(operator, operator, "1");
        vm.startPrank(operator);
        uint256[4] memory ids = _smoke(d, operator);
        vm.stopPrank();
        Vent.Lane memory l = d.vent.lane(0);
        assertGt(l.burnQuote, 0, "the smoke run's fees wait in BlastPool's burn lane");
        assertGt(d.vent.totalBurned(), 0, "EMBER-side shares burned at once");
        assertGt(d.vent.owed(Vent.Recipient.Treasury, d.pairQuote[0]), 0);
        // The smoke run's own vent deferred: a fresh pair has no 30-minute TWAP.
        uint256 supply = IERC20(address(d.ember)).totalSupply();
        vm.warp(block.timestamp + P.VENT_MAX_WAIT);
        for (uint256 k; k < 8; ++k) {
            vm.warp(block.timestamp + 300);
            d.pairs[0].checkpoint();
        }
        uint256 credits = d.mantle.creditsOf(d.mantle.epochAt(block.timestamp));
        (Vent.Deferral r, uint256 quoteIn, uint256 out) = d.vent.vent(0);
        assertEq(uint256(r), uint256(Vent.Deferral.None), "a buyback");
        assertGt(quoteIn, 0);
        assertEq(IERC20(address(d.ember)).totalSupply(), supply - out, "the bought EMBER is burned");
        assertEq(d.mantle.creditsOf(d.mantle.epochAt(block.timestamp)), credits + (out * P.RECYCLE_PROTOCOL_BURN_PCT) / 100);
        // The Treasury's share reaches the operator standing in for it; the match reserve does not.
        uint256 owed = d.vent.owed(Vent.Recipient.Treasury, d.pairQuote[0]);
        uint256 before = d.pairQuote[0].balanceOf(operator);
        d.vent.release(Vent.Recipient.Treasury, d.pairQuote[0]);
        assertEq(d.pairQuote[0].balanceOf(operator), before + owed);
        // Principal exits never wait on the Vent.
        vm.prank(operator);
        d.pools[3].emergencyExit(ids[3]);
    }

    /// Salts bind the deployer and the chain: another deployer, or a new salt version, gets a fresh
    /// set of addresses; reusing a salt cannot overwrite a deployment.
    function test_saltsBindDeployerChainAndVersion() public {
        Deployment memory a = _deployAs(deployer, operator, "1");
        Deployment memory b = _deployAs(deployer, operator, "2");
        Deployment memory c = _deployAs(operator, operator, "1");
        assertTrue(address(a.mantle) != address(b.mantle) && address(a.mantle) != address(c.mantle));
        bytes32 salt = _salt(deployer, "1", "Mantle");
        assertEq(address(bytes20(salt)), deployer, "the salt names its deployer");
        assertEq(uint8(salt[20]), 1, "with cross-chain redeploy protection");
        vm.chainId(LOCAL_CHAIN_ID);
        assertTrue(_predict(deployer, salt) != address(a.mantle), "another chain, another address");
        vm.chainId(LITEFORGE_CHAIN_ID);
        vm.expectRevert(abi.encodeWithSelector(SaltVersionUsed.selector, "1", address(a.ember)));
        this.redeploy(deployer, operator, "1");
    }

    function redeploy(address who, address op, string memory version) external {
        _deployAs(who, op, version);
    }

    function pairsAs(address who, Deployment memory d) external {
        vm.startPrank(who);
        _deployPairs(_plan(d.deployer, d.saltVersion), d);
        vm.stopPrank();
    }

    function test_refusesChainsOutsideTheTestnetList() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(NotATestnet.selector, 1));
        this.redeploy(deployer, operator, "1");
    }

    function test_refusesAMissingOrDifferentFactory() public {
        vm.etch(address(CREATEX), hex"00");
        vm.expectRevert(abi.encodeWithSelector(CreateXMissing.selector, keccak256(hex"00")));
        this.redeploy(deployer, operator, "1");
    }

    /// The smoke actions, then one whole epoch settled: positions in every pool earn EMBER.
    function test_smokeThenAFirstEpochSettles() public {
        Deployment memory d = _deployAs(operator, operator, "1");
        vm.startPrank(operator);
        uint256[4] memory ids = _smoke(d, operator);
        TestnetValuation(address(d.valuation)).setRate(0, P.RAY / 2);
        d.boost.refresh(0, ids[0]);
        vm.stopPrank();
        assertGt(d.pools[0].positionOf(ids[0]).ordinaryBonus, 0, "the Capstone raised the bonus");
        assertEq(d.pools[0].lotCount(ids[0]), 2, "the opening lot and the zap's; the addition took no slot");

        vm.warp(d.start + P.EPOCH_SECONDS);
        d.mantle.finalizeEpoch();
        d.emissions.openEpoch();
        for (uint256 i; i < 4; ++i) {
            for (uint256 n; d.emissions.poolEpoch(0, i).phase != ForgeEmissions.Phase.Done; ++n) {
                assertLt(n, 16, "bounded pages");
                d.emissions.advance(0, i);
            }
            assertGt(d.emissions.unclaimed(i, ids[i]), 0, "the position earned");
        }
        assertGt(IERC20(address(d.ember)).balanceOf(address(d.emissions)), 0);
    }

    /// The add-on (ADR 0015): before the pairs exist, pools 0 and 1 refuse deposits and an epoch
    /// settles around them; once the pairs are deployed at the predicted addresses, those pools
    /// take LP and earn, with no migration.
    function test_pairsActivateLaterAtThePredictedAddresses() public {
        Deployment memory d = _deployAs(operator, operator, "1", false);
        assertFalse(d.pairsLive);
        Plan memory pl = _plan(operator, "1");
        for (uint256 i; i < 2; ++i) {
            assertEq(address(d.pools[i].STAKE_TOKEN()), pl.pair[i], "pool i names pair i's address");
            assertEq(pl.pair[i].code.length, 0, "which holds no code yet");
        }
        vm.startPrank(operator);
        uint256[4] memory ids = _smoke(d, operator); // pools 2 and 3 only
        vm.expectRevert(); // a call to an address with no code
        d.pools[0].open(1e18);
        vm.expectRevert();
        d.pools[1].open(1e18);
        vm.stopPrank();
        assertEq(ids[0], 0);

        // The Vent works around the missing pairs: pool 2's EMBER fees burn, while pool 3's
        // USDC (BlastPool's quote) and the LP pools wait until the pairs exist.
        d.vent.collectAll();
        assertGt(d.vent.totalBurned(), 0, "pool 2's EMBER fees burned");
        assertGt(d.pools[3].feesOwed(0), 0, "pool 3's fees wait in the pool");

        vm.warp(d.start + P.EPOCH_SECONDS);
        _settle(d, 0);
        assertGt(d.emissions.unclaimed(2, ids[2]), 0, "the live pools earn");

        // CreateX binds each salt to its deployer: anyone else lands on another address.
        address stranger = makeAddr("stranger");
        vm.expectPartialRevert(AddressMismatch.selector);
        this.pairsAs(stranger, d);

        vm.startPrank(operator);
        _deployPairs(pl, d);
        _seedPairs(d, operator);
        IERC20(address(d.pairs[0])).approve(address(d.pools[0]), type(uint256).max);
        ids[0] = d.pools[0].open(d.pairs[0].balanceOf(operator) / 2);
        vm.stopPrank();
        assertEq(address(d.pairs[0]), pl.pair[0]);
        assertEq(address(d.pairs[1]), pl.pair[1]);

        vm.expectRevert(abi.encodeWithSelector(PairsAlreadyLive.selector, pl.pair[0]));
        this.pairsAs(operator, d);

        vm.warp(d.start + 2 * P.EPOCH_SECONDS);
        _settle(d, 1);
        assertGt(d.emissions.unclaimed(0, ids[0]), 0, "pool 0 earns once its pair exists");
    }

    function _settle(Deployment memory d, uint256 epoch) internal {
        d.mantle.finalizeEpoch();
        d.emissions.openEpoch();
        for (uint256 i; i < 4; ++i) {
            for (uint256 n; d.emissions.poolEpoch(epoch, i).phase != ForgeEmissions.Phase.Done; ++n) {
                assertLt(n, 16, "bounded pages");
                d.emissions.advance(epoch, i);
            }
        }
    }

    // ── the real Kindling (ADR 0021) ──────────────────────────────────────

    /// The genesis event end to end on the real core: Kindling holds the Mantle's seed, BlastPool's
    /// first deposit and pool 0's Kindling slot; it raises, settles, opens BlastPool at the raise's
    /// price, sinks 10% of the LP, and its contributors' positions earn in pool 0's first epoch.
    function test_theRealKindlingOpensBlastPoolAndItsPositionsEarn() public {
        Deployment memory d = _deployWithKindling(block.timestamp);
        Plan memory pl = _plan(operator, "1");
        assertTrue(d.kindlingLive);
        assertEq(address(d.kindling), pl.kindling, "Kindling at its predicted address");
        assertEq(address(d.escrow), pl.escrow);
        assertEq(address(d.sink), pl.sink);
        assertEq(d.mantle.KINDLING(), address(d.kindling), "the seed is Kindling's");
        assertEq(d.pairs[0].INITIALIZER(), address(d.kindling), "Kindling opens BlastPool");
        assertEq(d.pairs[1].INITIALIZER(), operator, "SmelterPool's seeding is a separate event");
        assertEq(d.pools[0].KINDLING(), address(d.kindling), "Kindling opens pool 0 positions");
        for (uint256 i = 1; i < 4; ++i) assertEq(d.pools[i].KINDLING(), address(0));
        assertEq(d.escrow.TREASURY(), operator, "the operator stands in for the Treasury");
        assertEq(uint256(d.kindling.venueCheck()), uint256(Kindling.Venue.None), "BlastPool is untouched");
        vm.expectRevert(Mantle.NotKindling.selector);
        vm.prank(operator);
        d.mantle.mintKindlingSeed();

        // The smoke run contributes the operator's wallet cap; four more wallets reach the minimum.
        vm.startPrank(operator);
        uint256[4] memory ids = _smoke(d, operator);
        vm.stopPrank();
        assertEq(d.kindling.accepted(), 25_000e6, "the smoke run contributed the cap");
        address[4] memory crowd = [makeAddr("c0"), makeAddr("c1"), makeAddr("c2"), makeAddr("c3")];
        for (uint256 i; i < 4; ++i) _contributeTo(d, crowd[i], 20_000e6);
        vm.warp(d.kindling.END());
        address keeper = makeAddr("keeper");
        vm.prank(keeper);
        uint256 g = gasleft();
        uint256 minted = d.kindling.settle();
        emit log_named_uint("settle on the real core", g - gasleft());
        (uint112 rE, uint112 rQ,) = d.pairs[0].getReserves();
        assertEq(rE, P.EMBER_KINDLING_SEED);
        assertEq(rQ, 101_850e6, "the net raise: 105,000 less 3%");
        assertEq(d.pairs[0].balanceOf(address(d.sink)), minted - (minted * 90) / 100, "10% sunk");
        assertEq(IERC20(address(d.pairQuote[0])).balanceOf(keeper), 52_500_000, "5 bps of $105,000");
        assertEq(d.kindling.closedAt(), block.timestamp, "Ignition's head-start clock");

        g = gasleft();
        uint256 id = d.kindling.materialize(operator);
        emit log_named_uint("materialize into the real pool 0", g - gasleft());
        assertEq(d.pools[0].ownerOf(id), operator);
        address[] memory page = new address[](4);
        for (uint256 i; i < 4; ++i) page[i] = crowd[i];
        assertEq(d.kindling.materializeMany(page), 4);
        assertEq(d.kindling.lpPaid(), d.kindling.contributorLp(), "every unit of the 90% placed");
        assertEq(d.pairs[0].balanceOf(address(d.kindling)), 0, "Kindling keeps nothing");

        // Kindling's 24 h are epoch 0, so its positions open as epoch 0 ends and earn from epoch 1.
        for (uint256 e; e < 2; ++e) {
            vm.warp(d.start + (e + 1) * P.EPOCH_SECONDS);
            d.mantle.finalizeEpoch();
            d.emissions.openEpoch();
            for (uint256 i; i < 4; ++i) {
                for (uint256 n; d.emissions.poolEpoch(e, i).phase != ForgeEmissions.Phase.Done; ++n) {
                    assertLt(n, 16, "bounded pages");
                    d.emissions.advance(e, i);
                }
            }
        }
        assertGt(d.emissions.unclaimed(0, id), 0, "a contributor's position earned");
        assertGt(d.emissions.unclaimed(3, ids[3]), 0, "and the USDC pool's");
    }

    /// Below the minimum at the deadline, the real event fails and refunds principal plus every fee.
    function test_theRealKindlingRefundsAFailedEvent() public {
        Deployment memory d = _deployWithKindling(block.timestamp + 1 hours);
        vm.startPrank(operator);
        _smoke(d, operator); // before START: no contribution
        vm.stopPrank();
        assertEq(d.kindling.accepted(), 0);
        vm.warp(d.kindling.START());
        _contributeTo(d, makeAddr("c0"), 25_000e6);
        address c1 = makeAddr("c1");
        _contributeTo(d, c1, 10_000e6);
        vm.prank(c1);
        d.kindling.cancel(9_700e6);
        vm.warp(d.kindling.END());
        vm.expectRevert(abi.encodeWithSelector(Kindling.BelowMinimumRaise.selector, 25_000e6, 100_000e6));
        d.kindling.settle();
        assertEq(uint256(d.kindling.fail()), uint256(Kindling.Failure.BelowMinimum));
        assertEq(d.kindling.refund(makeAddr("c0")), 25_000e6);
        assertEq(d.kindling.refund(c1), 300e6, "the cancelled contribution's fee comes back too");
        assertEq(IERC20(address(d.pairQuote[0])).balanceOf(address(d.escrow)), 0);
        assertEq(d.pairs[0].totalSupply(), 0, "BlastPool never opened");
        assertFalse(d.mantle.seedReserved() == 0, "the seed stays reserved (ADR 0003)");
    }
}
