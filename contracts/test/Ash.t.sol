// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {AshToken} from "../src/ash/AshToken.sol";
import {AshLedger, IAshMint} from "../src/ash/AshLedger.sol";
import {KindlingAshBonus, IKindlingBonusView, IAshBonusLedger} from "../src/ash/KindlingAshBonus.sol";
import {KindlingRig} from "./Kindling.t.sol";

/// @dev A ledger that mints the wrong bonus, for the bonus's funding check.
contract ShortLedger {
    AshToken public token;

    function set(AshToken t) external {
        token = t;
    }

    function releaseKindlingBonus() external returns (uint256) {
        token.mint(msg.sender, P.ASH_KINDLING_BONUS - 1);
        return P.ASH_KINDLING_BONUS - 1;
    }
}

contract AshTest is KindlingRig {
    address internal ignition = makeAddr("ignition");
    address internal forgeAsh = makeAddr("forgeAsh");
    uint256 internal constant START = 1_790_000_000;

    struct Ash {
        AshToken token;
        AshLedger ledger;
        KindlingAshBonus bonus;
    }

    /// @dev The token, its ledger and the bonus at predicted addresses, as the kit deploys them.
    function _ash(address kindling) internal returns (Ash memory a) {
        uint256 n = vm.getNonce(address(this));
        address ledgerAt = vm.computeCreateAddress(address(this), n + 1);
        address bonusAt = vm.computeCreateAddress(address(this), n + 2);
        a.token = new AshToken(ledgerAt);
        a.ledger = new AshLedger(IAshMint(address(a.token)), ignition, bonusAt, forgeAsh, START);
        a.bonus = new KindlingAshBonus(
            IKindlingBonusView(kindling), ERC20Burnable(address(a.token)), IAshBonusLedger(address(a.ledger))
        );
        assertEq(address(a.ledger), ledgerAt);
        assertEq(address(a.bonus), bonusAt);
    }

    // ── the token ─────────────────────────────────────────────────────────

    function test_onlyTheLedgerMintsAndBurnsNeverMakeRoom() public {
        AshToken t = new AshToken(address(this));
        assertEq(t.name(), "Ash");
        assertEq(t.symbol(), "ASH");
        assertEq(t.decimals(), 18);
        assertEq(t.MAX_SUPPLY(), 70_000e18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(AshToken.NotLedger.selector, stranger));
        t.mint(stranger, 1);
        t.mint(address(this), 70_000e18);
        t.burn(5_000e18);
        assertEq(t.totalSupply(), 65_000e18);
        assertEq(t.totalMinted(), 70_000e18, "a burn is never re-issued");
        assertEq(t.unissued(), 0);
        vm.expectRevert(abi.encodeWithSelector(AshToken.IssuanceExceeded.selector, 70_000e18 + 1));
        t.mint(address(this), 1);
        vm.expectRevert(AshToken.ZeroLedger.selector);
        new AshToken(address(0));
    }

    // ── the ledger ────────────────────────────────────────────────────────

    function test_theForgeVestsExactlyAsTheCanonicalCurve() public {
        Ash memory a = _ash(makeAddr("kindling"));
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/contracts/test/fixtures/oracle-vectors.json"));
        string[] memory elapsed = vm.parseJsonStringArray(json, ".ashVesting.elapsed");
        string[] memory want = vm.parseJsonStringArray(json, ".ashVesting.out");
        assertGt(elapsed.length, 10);
        for (uint256 i; i < elapsed.length; ++i) {
            assertEq(a.ledger.vestedAt(START + vm.parseUint(elapsed[i])), vm.parseUint(want[i]), "V(t)");
        }
        assertEq(a.ledger.vestedAt(START - 1), 0, "nothing before START");
        assertEq(a.ledger.vestedAt(START + 730 days), 28_000e18, "all of it at 730 days");
    }

    function test_dailyForgeReleasesSumExactlyAndNeverAnticipate() public {
        Ash memory a = _ash(makeAddr("kindling"));
        vm.warp(START);
        assertEq(a.ledger.releaseForge(), 0, "nothing at START");
        for (uint256 d = 1; d <= 731; ++d) {
            vm.warp(START + d * 1 days);
            a.ledger.releaseForge();
            assertEq(a.ledger.forgeReleased(), a.ledger.vestedAt(block.timestamp), "released = V(now)");
        }
        assertEq(a.token.balanceOf(forgeAsh), 28_000e18, "exactly the allocation");
        assertEq(a.ledger.releaseForge(), 0);
    }

    function testFuzz_forgeReleasesAtAnyTimesEqualTheCurve(uint32[6] memory gaps) public {
        Ash memory a = _ash(makeAddr("kindling"));
        uint256 t = START;
        for (uint256 i; i < gaps.length; ++i) {
            t += bound(gaps[i], 0, 200 days);
            vm.warp(t);
            vm.prank(stranger);
            a.ledger.releaseForge();
            assertEq(a.token.balanceOf(forgeAsh), a.ledger.vestedAt(t));
        }
    }

    function test_eachAllocationOnceToItsRecipientAndNeverMoreThan70k() public {
        Ash memory a = _ash(makeAddr("kindling"));
        vm.prank(stranger);
        assertEq(a.ledger.releaseIgnition(), 41_000e18);
        assertEq(a.token.balanceOf(ignition), 41_000e18);
        vm.expectRevert(AshLedger.AlreadyReleased.selector);
        a.ledger.releaseIgnition();
        vm.expectRevert(abi.encodeWithSelector(AshLedger.NotKindlingBonus.selector, address(this)));
        a.ledger.releaseKindlingBonus();
        vm.prank(address(a.bonus));
        a.ledger.releaseKindlingBonus();
        vm.prank(address(a.bonus));
        vm.expectRevert(AshLedger.AlreadyReleased.selector);
        a.ledger.releaseKindlingBonus();
        vm.warp(START + 3650 days);
        a.ledger.releaseForge();
        assertEq(a.ledger.issued(), 70_000e18);
        assertEq(a.token.totalMinted(), 70_000e18, "exactly the cumulative budget");
        assertEq(a.token.unissued(), 0);
    }

    function test_theLedgerRefusesZeroInputs() public {
        IAshMint t = IAshMint(makeAddr("token"));
        vm.expectRevert(AshLedger.ZeroAddress.selector);
        new AshLedger(IAshMint(address(0)), ignition, ignition, forgeAsh, START);
        vm.expectRevert(AshLedger.ZeroAddress.selector);
        new AshLedger(t, address(0), ignition, forgeAsh, START);
        vm.expectRevert(AshLedger.ZeroAddress.selector);
        new AshLedger(t, ignition, address(0), forgeAsh, START);
        vm.expectRevert(AshLedger.ZeroAddress.selector);
        new AshLedger(t, ignition, ignition, address(0), START);
        vm.expectRevert(AshLedger.ZeroAddress.selector);
        new AshLedger(t, ignition, ignition, forgeAsh, 0);
    }

    // ── the Kindling bonus, on a real Kindling ────────────────────────────

    function _settled(uint256[] memory grosses) internal returns (World memory w, Ash memory a) {
        vm.warp(T0);
        w = _world(T0);
        a = _ash(address(w.k));
        for (uint256 i; i < grosses.length; ++i) _contribute(w, _wallet(i), grosses[i]);
        vm.warp(T0 + 1 days);
        w.k.settle();
    }

    function test_theBonusPaysProRataOnNetAndBurnsOnlyTheRemainder() public {
        uint256[] memory g = new uint256[](6);
        (g[0], g[1], g[2], g[3], g[4], g[5]) = (25_000e6, 25_000e6, 24_123e6, 25_000e6, 7_777e6, 100e6);
        (World memory w, Ash memory a) = _settled(g);
        uint256 totalNet = w.k.totalNet();
        uint256 sum;
        for (uint256 i; i < 6; ++i) {
            (, uint128 net,,) = w.k.contributions(_wallet(i));
            uint256 want = (P.ASH_KINDLING_BONUS * net) / totalNet;
            assertEq(a.bonus.bonusOf(_wallet(i)), want, "the view");
            vm.prank(stranger);
            assertEq(a.bonus.claim(_wallet(i)), want, "floor(1,000 x net / totalNet)");
            assertEq(a.token.balanceOf(_wallet(i)), want, "paid to the wallet, not the caller");
            sum += want;
        }
        assertEq(a.token.balanceOf(stranger), 0);
        assertEq(a.token.balanceOf(address(a.bonus)), 0, "nothing left behind");
        assertEq(a.token.totalSupply(), sum, "the remainder burned");
        assertEq(a.token.totalMinted(), P.ASH_KINDLING_BONUS, "minted once, exactly");
        assertEq(a.bonus.paid(), P.ASH_KINDLING_BONUS);
        vm.expectRevert(abi.encodeWithSelector(KindlingAshBonus.NothingOwed.selector, _wallet(0)));
        a.bonus.claim(_wallet(0));
        vm.expectRevert(abi.encodeWithSelector(KindlingAshBonus.NothingOwed.selector, _wallet(7)));
        a.bonus.claim(_wallet(7));
        assertEq(a.bonus.bonusOf(_wallet(0)), 0);
    }

    function test_pagesSkipWhatIsNotOwed() public {
        uint256[] memory g = new uint256[](4);
        (g[0], g[1], g[2], g[3]) = (25_000e6, 25_000e6, 25_000e6, 25_000e6);
        (World memory w, Ash memory a) = _settled(g);
        w; // the world is only needed for its settled Kindling
        address[] memory page = new address[](6);
        for (uint256 i; i < 6; ++i) page[i] = _wallet(i);
        vm.recordLogs();
        assertEq(a.bonus.claimMany(page), P.ASH_KINDLING_BONUS, "four equal shares, no remainder");
        // Wallets that never contributed are skipped outright: never marked, no Claimed event.
        assertFalse(a.bonus.claimed(_wallet(4)), "a non-contributor is not marked");
        assertFalse(a.bonus.claimed(_wallet(5)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 events;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(a.bonus) && logs[i].topics[0] == KindlingAshBonus.Claimed.selector) ++events;
        }
        assertEq(events, 4, "one Claimed per contributor, none for the others");
        assertEq(a.bonus.claimMany(page), 0, "a second page pays nothing");
    }

    function test_noBonusBeforeSettlementOrAfterFailure() public {
        vm.warp(T0);
        World memory w = _world(T0);
        Ash memory a = _ash(address(w.k));
        _contribute(w, _wallet(0), 25_000e6);
        vm.expectRevert(KindlingAshBonus.NotSettled.selector);
        a.bonus.claim(_wallet(0));
        vm.warp(T0 + 1 days);
        w.k.fail();
        vm.expectRevert(KindlingAshBonus.NotSettled.selector);
        a.bonus.claim(_wallet(0));
        assertFalse(a.ledger.bonusReleased(), "a failed Kindling never mints the bonus");
        assertEq(a.token.totalMinted(), 0);
        assertEq(a.bonus.bonusOf(_wallet(0)), 0);
    }

    function test_theBonusRefusesAShortFunding() public {
        uint256[] memory g = new uint256[](4);
        (g[0], g[1], g[2], g[3]) = (25_000e6, 25_000e6, 25_000e6, 25_000e6);
        vm.warp(T0);
        World memory w = _world(T0);
        for (uint256 i; i < 4; ++i) _contribute(w, _wallet(i), g[i]);
        vm.warp(T0 + 1 days);
        w.k.settle();
        ShortLedger short = new ShortLedger();
        AshToken t = new AshToken(address(short));
        short.set(t);
        KindlingAshBonus b =
            new KindlingAshBonus(IKindlingBonusView(address(w.k)), ERC20Burnable(address(t)), IAshBonusLedger(address(short)));
        vm.expectRevert(abi.encodeWithSelector(KindlingAshBonus.FundingMismatch.selector, P.ASH_KINDLING_BONUS - 1));
        b.claim(_wallet(0));
    }

    function testFuzz_everyClaimOrderPaysTheWholeBonus(uint256[8] memory raw, uint256 order) public {
        uint256[] memory g = new uint256[](8);
        // Five wallets of at least $20,000 reach the minimum; three more of any size.
        for (uint256 i; i < 8; ++i) g[i] = bound(raw[i], i < 5 ? 20_000e6 : 1e6, 25_000e6);
        (World memory w, Ash memory a) = _settled(g);
        uint256 totalNet = w.k.totalNet();
        uint256 sum;
        for (uint256 k; k < 8; ++k) {
            uint256 i = (order % 8 + k * 3) % 8; // a permutation (3 is coprime to 8)
            (, uint128 net,,) = w.k.contributions(_wallet(i));
            uint256 got = a.bonus.claim(_wallet(i));
            assertEq(got, (P.ASH_KINDLING_BONUS * net) / totalNet);
            sum += got;
        }
        assertLe(P.ASH_KINDLING_BONUS - sum, 8, "at most one unit of rounding per wallet");
        assertEq(a.token.totalSupply(), sum, "the rest burned");
        assertEq(a.token.balanceOf(address(a.bonus)), 0);
    }

    function test_gas_ash() public {
        uint256[] memory g = new uint256[](4);
        (g[0], g[1], g[2], g[3]) = (25_000e6, 25_000e6, 25_000e6, 25_000e6);
        (, Ash memory a) = _settled(g);
        uint256 gas = gasleft();
        a.ledger.releaseIgnition();
        emit log_named_uint("releaseIgnition", gas - gasleft());
        vm.warp(START + 30 days);
        gas = gasleft();
        a.ledger.releaseForge();
        emit log_named_uint("releaseForge", gas - gasleft());
        gas = gasleft();
        a.bonus.claim(_wallet(0));
        emit log_named_uint("bonus claim (funds the bonus)", gas - gasleft());
        gas = gasleft();
        a.bonus.claim(_wallet(1));
        emit log_named_uint("bonus claim", gas - gasleft());
    }
}
