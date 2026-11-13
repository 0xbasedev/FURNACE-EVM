// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {EmberPair} from "../src/pairs/EmberPair.sol";
import {GenesisFeeEscrow} from "../src/kindling/GenesisFeeEscrow.sol";
import {Kindling} from "../src/kindling/Kindling.sol";
import {MockQuote} from "./utils/KindlingMocks.sol";
import {KindlingRig} from "./Kindling.t.sol";

/// @notice Random contributions, top-ups, cancellations, time, settlement, failure, refunds,
///         materializations and donations, against one Kindling event.
contract KindlingHandler is Test {
    Kindling public k;
    GenesisFeeEscrow internal escrow;
    MockQuote internal usdc;
    EmberPair internal pair;
    address[] internal wallets;
    address internal keeper;

    /// Per wallet: USDC paid in, and USDC paid back (cancellations and refunds).
    mapping(address => uint256) public paidIn;
    mapping(address => uint256) public paidBack;
    uint256 public donatedToEscrow;
    uint256 public settles;
    uint256 public fails;
    bool public treasuryPaidBeforeSuccess;

    constructor(Kindling k_, MockQuote usdc_, address[] memory w, address keeper_) {
        (k, usdc, wallets, keeper) = (k_, usdc_, w, keeper_);
        escrow = k_.ESCROW();
        pair = EmberPair(address(k_.PAIR()));
    }

    function walletCount() external view returns (uint256) {
        return wallets.length;
    }

    function walletAt(uint256 i) external view returns (address) {
        return wallets[i];
    }

    function _who(uint256 seed) internal view returns (address) {
        return wallets[seed % wallets.length];
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 1, 14 hours));
    }

    function contribute(uint256 who, uint256 gross) external {
        address w = _who(who);
        gross = bound(gross, 1, 26_000e6);
        uint256 before = usdc.balanceOf(w);
        vm.prank(w);
        try k.contribute(gross) {
            paidIn[w] += before - usdc.balanceOf(w);
        } catch {}
    }

    function cancel(uint256 who, uint256 amount) external {
        address w = _who(who);
        (, uint128 net,,) = k.contributions(w);
        if (net == 0) return;
        amount = bound(amount, 1, net);
        uint256 before = usdc.balanceOf(w);
        vm.prank(w);
        try k.cancel(amount) {
            paidBack[w] += usdc.balanceOf(w) - before;
        } catch {}
    }

    function settle() external {
        uint256 t = usdc.balanceOf(escrow.TREASURY());
        vm.prank(keeper);
        try k.settle() {
            ++settles;
        } catch {
            if (usdc.balanceOf(escrow.TREASURY()) != t) treasuryPaidBeforeSuccess = true;
        }
    }

    function failEvent() external {
        try k.fail() {
            ++fails;
        } catch {}
    }

    function refund(uint256 who) external {
        address w = _who(who);
        uint256 before = usdc.balanceOf(w);
        try k.refund(w) {
            paidBack[w] += usdc.balanceOf(w) - before;
        } catch {}
    }

    function materialize(uint256 who) external {
        try k.materialize(_who(who)) {} catch {}
    }

    function materializePage(uint256 mask) external {
        uint256 n;
        for (uint256 i; i < wallets.length; ++i) {
            if ((mask >> i) & 1 == 1) ++n;
        }
        address[] memory page = new address[](n);
        n = 0;
        for (uint256 i; i < wallets.length; ++i) {
            if ((mask >> i) & 1 == 1) page[n++] = wallets[i];
        }
        try k.materializeMany(page) {} catch {}
    }

    function donate(uint256 to, uint256 amount) external {
        amount = bound(amount, 1, 10_000e6);
        uint256 t = to % 3;
        if (t == 0) {
            usdc.mint(address(escrow), amount);
            donatedToEscrow += amount;
        } else if (t == 1) {
            usdc.mint(address(k), amount);
        } else {
            usdc.mint(address(pair), amount);
        }
    }
}

contract KindlingInvariantTest is KindlingRig {
    KindlingHandler internal handler;
    World internal w;

    function setUp() public {
        vm.warp(T0);
        w = _world(T0);
        address[] memory ws = new address[](WALLETS);
        for (uint256 i; i < WALLETS; ++i) ws[i] = _wallet(i);
        handler = new KindlingHandler(w.k, w.usdc, ws, keeper);
        // $85,000 already raised through the handler (so its ghosts see it): the fuzzer's own
        // contributions and cancellations decide whether the event reaches the minimum.
        for (uint256 i; i < 3; ++i) handler.contribute(i, 25_000e6);
        handler.contribute(3, 10_000e6);
        targetContract(address(handler));
    }

    /// The escrow always holds every liability it books, and beyond them only donations; while the
    /// event is live its ledgers are the event's totals.
    function invariant_theEscrowBacksItsLiabilities() public view {
        GenesisFeeEscrow e = w.escrow;
        uint256 owed = e.principal() + e.fees();
        assertEq(w.usdc.balanceOf(address(e)), owed + handler.donatedToEscrow(), "liabilities plus donations");
        if (w.k.status() == Kindling.Status.Live) {
            assertEq(e.principal(), w.k.totalNet(), "principal ledger");
            assertEq(e.fees(), w.k.totalFees(), "fee ledger");
        }
    }

    /// Success and failure are exclusive, and the event and its escrow agree on which happened.
    function invariant_successAndFailureAreExclusive() public view {
        assertLe(handler.settles() + handler.fails(), 1, "one ending at most");
        Kindling.Status s = w.k.status();
        assertEq(uint256(w.escrow.state()), uint256(s), "the event and its escrow agree");
        assertEq(w.k.closedAt() != 0, s == Kindling.Status.Settled, "closedAt marks success only");
        assertEq(w.mantle.seedMinted(), s == Kindling.Status.Settled, "the seed exists only on success");
    }

    /// No wallet is ever paid back more than it paid in; after a failure and its refund, every
    /// unit it paid in is back.
    function invariant_noPrincipalIsPaidTwice() public view {
        for (uint256 i; i < handler.walletCount(); ++i) {
            address who = handler.walletAt(i);
            assertLe(handler.paidBack(who), handler.paidIn(who), "never more than paid in");
            (,,, bool done) = w.k.contributions(who);
            if (w.k.status() == Kindling.Status.Failed && done) {
                assertEq(handler.paidBack(who), handler.paidIn(who), "a refund completes the return");
            }
        }
    }

    /// The Treasury receives nothing unless the event succeeded, and then exactly the fees less
    /// the bounty: never refund backing.
    function invariant_theTreasuryNeverTakesRefundBacking() public view {
        uint256 t = w.usdc.balanceOf(treasury);
        assertFalse(handler.treasuryPaidBeforeSuccess(), "no refused settlement paid the Treasury");
        if (w.k.status() != Kindling.Status.Settled) {
            assertEq(t, 0, "nothing before success");
        } else {
            assertEq(t + w.usdc.balanceOf(keeper), w.k.totalFees(), "exactly the fees");
            assertEq(
                w.usdc.balanceOf(keeper), (w.k.accepted() * P.KINDLING_CLOSE_BOUNTY_BPS) / 10_000, "the bounty"
            );
        }
    }

    /// Every unit of LP has exactly one owner: contributors' positions, the sink, Kindling (owed,
    /// not yet materialized) or the pair's burned minimum.
    function invariant_theLpIsConserved() public view {
        if (w.k.status() != Kindling.Status.Settled) {
            assertEq(w.pair.totalSupply(), 0, "no LP before success");
            return;
        }
        uint256 minted = w.pair.balanceOf(address(w.pool)) + w.pair.balanceOf(address(w.sink))
            + w.pair.balanceOf(address(w.k));
        assertEq(minted, w.k.liquidity(), "the minted LP, all accounted for");
        assertEq(w.pair.balanceOf(P.BURN_ADDRESS), 1000, "the minimum liquidity, separately");
        assertEq(minted + 1000, w.pair.totalSupply(), "conserved");
        assertEq(w.pair.balanceOf(address(w.k)), w.k.contributorLp() - w.k.lpPaid(), "Kindling holds what is owed");
        assertGe(w.pair.balanceOf(address(w.sink)), w.k.liquidity() - w.k.contributorLp(), "the sink's 10%");
    }
}
