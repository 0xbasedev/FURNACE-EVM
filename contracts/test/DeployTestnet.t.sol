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
import {KindlingAshBonus} from "../src/ash/KindlingAshBonus.sol";
import {Ignition} from "../src/ignition/Ignition.sol";
import {ForgePoolBase} from "../src/forge/ForgePoolBase.sol";

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
        d = _deploy(who, Options(op, version, block.timestamp, address(0), address(0), pairsNow, false, 0, false, 0));
        vm.stopPrank();
    }

    /// @dev The real-Kindling mode (ADR 0021), opening `start`.
    function _deployWithKindling(uint256 start) internal returns (Deployment memory d) {
        vm.startPrank(operator);
        d = _deploy(operator, Options(operator, "1", block.timestamp, address(0), address(0), true, true, start, false, 0));
        vm.stopPrank();
    }

    /// @dev The full genesis (ADR 0023): Ignition at `ignitionStart`, then Kindling and the Mantle
    ///         where its free-exit window ends.
    function _deployWithIgnition(uint256 ignitionStart) internal returns (Deployment memory d) {
        uint256 genesis = ignitionStart + P.IGNITION_DURATION + P.IGNITION_EXIT_WINDOW;
        vm.startPrank(operator);
        d = _deploy(operator, Options(operator, "1", genesis, address(0), address(0), true, true, genesis, true, ignitionStart));
        vm.stopPrank();
    }

    /// @dev External, so a revert inside `_deploy` can be expected.
    function deployIgnitionWithoutKindling() external {
        vm.startPrank(operator);
        _deploy(operator, Options(operator, "2", block.timestamp, address(0), address(0), true, false, 0, true, block.timestamp));
        vm.stopPrank();
    }

    function _farm(Deployment memory d, address who, uint8 pool, uint256 gross) internal {
        IERC20 token = pool == 0 ? d.pairQuote[0] : pool == 1 ? d.pairQuote[1] : d.wbtc;
        vm.startPrank(who);
        TestnetToken(address(token)).mint(who, gross);
        token.approve(address(d.ignition), gross);
        d.ignition.deposit(pool, gross, false);
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
        assertEq(d.emissions.MATCH_RESERVE(), address(d.compounder), "the Compounder is the match reserve (ADR 0026)");
        assertEq(d.emissions.CAST_POOLS(), 3, "so the LP pools cast");
        assertEq(d.emissions.SEALED_POT(), address(d.sealedPot), "the Sealed-pot stream (ADR 0024)");
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
        assertEq(address(d.compounder), pl.compounder, "the Compounder at its predicted address");
        assertEq(d.flow.COMPOUNDER(), address(d.compounder), "Flow's waiver is the Compounder's");
        // Source-lot additions (ADR 0017): the same compounder, on the LP pools only.
        assertEq(d.pools[0].COMPOUNDER(), address(d.compounder), "the Compounder adds to pool 0's lots");
        assertEq(d.pools[1].COMPOUNDER(), address(d.compounder));
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
        assertEq(d.vent.TREASURY(), operator, "the operator stands in for the Treasury");
        // The Hearth (ADR 0025): the Vent's Hearth share goes to staked test ASH.
        assertEq(address(d.hearth), pl.hearth, "the Hearth at its predicted address");
        assertEq(d.vent.HEARTH(), address(d.hearth));
        assertEq(address(d.hearth.ASH()), address(d.ash));
        assertEq(d.hearth.assetAt(0), address(d.ember));
        assertEq(d.hearth.assetAt(1), address(d.pairQuote[0]));
        assertEq(d.hearth.assetAt(2), address(d.pairQuote[1]));
        assertEq(d.vent.COMPOUNDER(), address(d.compounder), "only the Compounder draws the liquidity lane");
        assertEq(d.compounder.SINK(), address(d.sink), "its idle auto-pair ends in the permanent sink");
        assertEq(address(d.compounder.EMISSIONS()), address(d.emissions));
        assertEq(d.compounder.START(), d.start, "on the Mantle's epoch clock");
        // ASH (ADR 0022): the ledger is the token's only minter; the operator stands in for Ignition and the Forge.
        assertEq(address(d.ash), pl.ash, "ASH at its predicted address");
        assertEq(d.ash.LEDGER(), address(d.ashLedger));
        assertEq(d.ashLedger.IGNITION(), operator);
        assertEq(d.ashLedger.KINDLING_BONUS(), operator, "no bonus while the operator stands in for Kindling");
        assertEq(d.ashLedger.START(), d.start);
        assertEq(address(d.ashBonus), address(0));
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
        assertEq(d.pools[0].lotCount(ids[0]), 2, "the opening lot and the zap's");

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

        // The epoch splitters pay from the settled epoch's own measures (ADR 0024). ForgeAsh: the
        // day's vested ASH, by the pools' ASH weights; Cold Storage's weight is zero.
        uint256 ash = d.forgeAsh.claim(0, 0, ids[0], address(d.ash));
        assertGt(ash, 0, "the pool-0 position's ASH for epoch 0");
        assertEq(IERC20(address(d.ash)).balanceOf(operator), ash + P.ASH_IGNITION_ALLOCATION - 1_000e18, "paid to the owner");
        assertEq(d.ashLedger.forgeReleased(), d.ashLedger.vestedAt(block.timestamp), "released exactly V(now)");
        assertEq(d.forgeAsh.shareOf(0, 3, ids[3], address(d.ash)), 0);
        // The Vent's Quote-yield lane pays the splitter, which books it into the running epoch.
        d.vent.collectAll();
        uint256 owed = d.vent.owed(Vent.Recipient.QuoteYield, d.pairQuote[0]);
        assertGt(owed, 0, "the smoke run's sell paid Quote yield");
        {
            d.vent.release(Vent.Recipient.QuoteYield, d.pairQuote[0]);
            assertEq(d.quoteYield.book(address(d.pairQuote[0])), owed, "booked what the Vent released");
            assertEq(d.quoteYield.liability(address(d.pairQuote[0])), owed);
        }
        // The Hearth (ADR 0025): the smoke run staked 1,000 test ASH, so the Vent's Hearth share of
        // the smoke run's fees goes to that stake when it arrives.
        assertEq(d.hearth.stakeOf(operator), 1_000e18);
        owed = d.vent.owed(Vent.Recipient.Hearth, IERC20(address(d.ember)));
        assertGt(owed, 0, "the smoke run's fees owe the Hearth EMBER");
        d.vent.release(Vent.Recipient.Hearth, IERC20(address(d.ember)));
        vm.prank(operator);
        uint256 got = d.hearth.claim(address(d.ember));
        assertApproxEqAbs(got, owed, 1, "the staker is paid the Hearth's share, to the wei");
        assertEq(d.hearth.treasuryOwed(address(d.ember)), 0, "nothing went to the Treasury while ASH was staked");

        // Casting (ADR 0026): a quarter of pool 0's ordinary credit waited for the Compounder. On a
        // fresh TWAP it freezes the epoch's budget from the Vent's liquidity lane and casts the
        // share into the position's source lot, at that lot's age.
        assertEq(d.compounder.seed(), 100e18, "the smoke run funded the idle auto-pair's seed");
        uint256 share = d.emissions.castOf(0, 0, ids[0]);
        assertGt(share, 0, "the LP pool withheld its Cast share");
        assertEq(d.emissions.castOf(0, 2, ids[2]), 0, "the EMBER pool paid liquid");
        d.vent.collectAll();
        d.pairs[0].checkpoint();
        vm.warp(block.timestamp + P.PAIR_TWAP_SECONDS);
        d.pairs[0].checkpoint();
        uint256 budget = d.compounder.freeze(0, 0);
        assertGt(budget, 0, "the smoke run's fees funded a budget");
        uint256 before = d.emissions.unclaimed(0, ids[0]);
        uint256 lots = d.pools[0].lotCount(ids[0]);
        uint256 lp = d.compounder.cast(0, 0, ids[0]);
        assertGt(lp, 0, "the share became LP");
        assertEq(d.pools[0].lotCount(ids[0]), lots, "in an existing lot: no slot used");
        assertTrue(d.emissions.castTaken(0, 0, ids[0]));
        assertLe(d.emissions.unclaimed(0, ids[0]), before + share, "and what was not paired is the owner's, liquid");
        assertEq(IERC20(address(d.pairs[0])).balanceOf(address(d.compounder)), 0, "the Compounder keeps no LP");
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
        // The 1,000-ASH bonus (ADR 0022), pro rata on the same net principal.
        assertEq(d.ashLedger.KINDLING_BONUS(), address(d.ashBonus));
        uint256 bonus = d.ashBonus.claim(crowd[0]);
        assertEq(bonus, (P.ASH_KINDLING_BONUS * 19_400e6) / d.kindling.totalNet(), "floor(1,000 x net / totalNet)");
        assertEq(IERC20(address(d.ash)).balanceOf(crowd[0]), bonus);
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
        vm.expectRevert(KindlingAshBonus.NotSettled.selector);
        d.ashBonus.claim(c1);
        assertFalse(d.ashLedger.bonusReleased(), "and the ASH bonus is never minted");
    }

    /// The real Ignition: it farms, closes, auto-stakes USDC into the real Cold Storage, founds
    /// First Flame, and dates a lot back to its start once Kindling has closed.
    function test_theRealIgnitionRunsTheWholeGenesis() public {
        uint256 t0 = block.timestamp + 1 hours;
        Deployment memory d = _deployWithIgnition(t0);
        Plan memory pl = _plan(operator, "1");
        Ignition g = d.ignition;
        assertTrue(d.ignitionLive);
        assertEq(address(g), pl.ignition, "Ignition at its predicted address");
        for (uint256 i; i < 4; ++i) {
            assertEq(d.pools[i].IGNITION(), address(g), "every pool's head-start granter");
            assertEq(d.pools[i].FOUNDERS(), address(g), "every pool's founder record");
        }
        assertEq(d.ashLedger.IGNITION(), address(g), "ASH's Ignition leaf");
        assertEq(g.budgetOf(3), 0, "the LP pool is unbound");
        assertEq(g.budgetOf(0), P.ASH_IGNITION_ALLOCATION / 3, "its weight goes to the three bound pools");
        assertEq(d.kindling.START(), g.END() + P.IGNITION_EXIT_WINDOW, "Kindling opens after the free-exit window");

        // The smoke run farms while Ignition is open.
        vm.warp(t0);
        vm.startPrank(operator);
        uint256[4] memory ids = _smoke(d, operator);
        vm.stopPrank();
        assertEq(g.accountOf(operator, 0).principal, 970e6, "1,000 tUSDC less the 3% fee");
        assertEq(g.accountOf(operator, 2).principal, 0.1e8 - 0.003e8);
        address farmer = makeAddr("farmer");
        _farm(d, farmer, 0, 20_000e6);
        _farm(d, farmer, 1, 5e18);
        vm.warp(t0 + P.IGNITION_DURATION / 2);
        address late = makeAddr("late");
        _farm(d, late, 1, 5e18);

        // The close: the farm finalizes and pays; ASH outside the three pools' accrual burns.
        vm.warp(g.END());
        assertTrue(g.isFounder(farmer), "kept principal through close");
        assertFalse(g.isFounder(makeAddr("nobody")));
        uint256 paid = g.claim(farmer);
        assertGt(g.claim(late), 0);
        assertLt(g.claim(operator), paid, "the operator farmed less");
        assertEq(d.ash.totalSupply(), P.ASH_IGNITION_ALLOCATION - g.burned(), "only the Ignition leaf, less its burn");

        // After the free-exit window USDC auto-stakes into Cold Storage: the farmer's own position.
        vm.warp(g.END() + P.IGNITION_EXIT_WINDOW);
        (uint256 cold, uint256 staked) = g.stakeUsdc(farmer);
        assertEq(staked, 19_400e6);
        assertEq(d.pools[3].ownerOf(cold), farmer);
        assertEq(d.pools[3].custodyOf(cold), 19_400e6 - 194e6, "at the standard 1% fee");
        vm.prank(farmer);
        g.withdraw(1, 4.85e18); // WETH is claimable fee-free

        // Kindling runs and settles; its close opens the head-start window.
        address[4] memory crowd = [makeAddr("c0"), makeAddr("c1"), makeAddr("c2"), makeAddr("c3")];
        for (uint256 i; i < 4; ++i) _contributeTo(d, crowd[i], 25_000e6);
        vm.warp(d.kindling.END());
        d.kindling.settle();
        vm.prank(farmer);
        uint256 s = g.grantHeadStart(d.pools[3], cold, 0);
        assertEq(s, g.END() + P.IGNITION_EXIT_WINDOW - t0, "dated back to Ignition's start");
        ForgePoolBase.Position memory p = d.pools[3].positionOf(cold);
        assertTrue(p.headStartActive);
        assertEq(p.headStart, s);
        // First Flame, read from Ignition's record.
        assertTrue(d.pools[3].refreshFounder(cold));
        assertTrue(d.pools[3].positionOf(cold).founder);
        assertTrue(ids[3] != 0, "the smoke run opened its USDC position");
        // Genesis order: the real Ignition reads Kindling's close, so it never deploys alone.
        vm.expectRevert(IgnitionNeedsKindling.selector);
        this.deployIgnitionWithoutKindling();
    }
}
