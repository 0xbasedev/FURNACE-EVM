// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Mantle} from "../src/Mantle.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {ForgeEmissions} from "../src/forge/ForgeEmissions.sol";
import {SettlementFixture} from "./ForgeEmissions.t.sol";

contract SettlementHandler is Test {
    ForgePool[4] internal pools;
    ForgeEmissions internal emissions;
    address internal mantleAddr;
    address[3] internal users;
    uint256[2][] internal owned; // (pool, id)
    /// The Protocol burn registrar and the three ledger consumers (see SettlementFixture).
    address[4] internal actors;

    constructor(
        ForgePool[4] memory pools_,
        ForgeEmissions emissions_,
        address mantle_,
        address[3] memory users_,
        address[4] memory actors_
    ) {
        (pools, emissions, mantleAddr, users, actors) = (pools_, emissions_, mantle_, users_, actors_);
        for (uint256 u; u < 3; ++u) {
            for (uint256 i; i < 4; ++i) {
                vm.prank(users[u]);
                owned.push([i, pools[i].open(1e18 * (u + 1))]);
            }
        }
    }

    function ownedCount() external view returns (uint256) {
        return owned.length;
    }

    function ownedAt(uint256 k) external view returns (uint256 pool, uint256 id) {
        return (owned[k][0], owned[k][1]);
    }

    function _pick(uint256 seed) internal view returns (ForgePool pool, uint256 poolIdx, uint256 id, address owner) {
        uint256[2] memory o = owned[seed % owned.length];
        (poolIdx, id) = (o[0], o[1]);
        pool = pools[poolIdx];
        owner = pool.positionOf(id).owner;
    }

    function open(uint256 who, uint256 poolSeed, uint256 amount) external {
        if (owned.length >= 24) return;
        uint256 i = poolSeed % 4;
        vm.prank(users[who % 3]);
        try pools[i].open(bound(amount, 1e15, 1e24)) returns (uint256 id) {
            owned.push([i, id]);
        } catch {}
    }

    function deposit(uint256 seed, uint256 amount) external {
        (ForgePool pool,, uint256 id, address owner) = _pick(seed);
        vm.prank(owner);
        try pool.deposit(id, bound(amount, 1e15, 1e24)) {} catch {}
    }

    function request(uint256 seed, uint256 bps) external {
        (ForgePool pool,, uint256 id, address owner) = _pick(seed);
        uint256 active;
        for (uint256 j; j < 32; ++j) {
            (uint256 a,,,) = pool.lotAt(id, j);
            active += a;
        }
        vm.prank(owner);
        try pool.requestCooling(id, (active * bound(bps, 1, 10_000)) / 10_000) {} catch {}
    }

    function execute(uint256 seed, uint256 pick) external {
        (ForgePool pool,, uint256 id, address owner) = _pick(seed);
        uint32[] memory pend = pool.pendingTickets(id);
        if (pend.length == 0) return;
        uint32 t = pend[pick % pend.length];
        uint256 maturity = pool.ticketOf(id, t).maturity;
        if (maturity > block.timestamp) vm.warp(maturity);
        vm.prank(owner);
        try pool.executeWithdrawal(id, t) {} catch {}
    }

    function cancel(uint256 seed, uint256 pick) external {
        (ForgePool pool,, uint256 id, address owner) = _pick(seed);
        uint32[] memory pend = pool.pendingTickets(id);
        if (pend.length == 0) return;
        vm.prank(owner);
        try pool.cancelCooling(id, pend[pick % pend.length]) {} catch {}
    }

    function emergency(uint256 seed, uint256 coin) external {
        if (coin % 12 != 0) return;
        (ForgePool pool,, uint256 id, address owner) = _pick(seed);
        vm.prank(owner);
        try pool.emergencyExit(id) {} catch {}
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 2 days));
    }

    /// Rarely, a long quiet stretch: positions cross the 30-day Ashfall minimums.
    function longWarp(uint256 dt, uint256 coin) external {
        if (coin % 6 != 0) return;
        vm.warp(block.timestamp + bound(dt, 10 days, 35 days));
    }

    /// A user hands EMBER to the Protocol registrar, which burns it: next epoch's Ashfall.
    function burn(uint256 who, uint256 amount) external {
        address user = users[who % 3];
        IERC20 ember = emissions.EMBER();
        amount = bound(amount, 0, ember.balanceOf(user));
        if (amount == 0) return;
        vm.prank(user);
        ember.transfer(actors[0], amount);
        vm.startPrank(actors[0]);
        ember.approve(mantleAddr, amount);
        Mantle(mantleAddr).burnRegistered(amount);
        vm.stopPrank();
    }

    function burnForfeits() external {
        emissions.burnForfeits();
    }

    /// The ledgers' consumers pull what they are owed.
    function take(uint256 seed, uint256 which) external {
        (, uint256 poolIdx, uint256 id,) = _pick(seed);
        which %= 3;
        vm.prank(actors[1 + which]);
        if (which == 0) emissions.takeCapstone(poolIdx, id);
        else if (which == 1) emissions.takeMatchReserve();
        else emissions.takeSealedPot(poolIdx);
    }

    function seal(uint256 seed, uint256 track) external {
        (ForgePool pool,, uint256 id, address owner) = _pick(seed);
        vm.prank(owner);
        try pool.seal(id, track % 4) {} catch {}
    }

    /// BOOST sets an ordinary bonus (ADR 0008); the ceiling's neighbour reverts.
    function boost(uint256 seed, uint256 units) external {
        (ForgePool pool,, uint256 id,) = _pick(seed);
        vm.prank(pool.BOOST());
        try pool.setOrdinaryBonus(id, bound(units, 0, 65_001)) {} catch {}
    }

    /// Settle any position's latest Seal; reverts (not ended, nothing locked) are expected.
    function settleSeal(uint256 seed) external {
        (ForgePool pool, uint256 poolIdx, uint256 id,) = _pick(seed);
        try emissions.settleSeal(poolIdx, id, pool.positionOf(id).sealCount) {} catch {}
    }

    /// The keeper: finalize what has ended (catching up several epochs), open it, and page
    /// whatever is pending.
    function keep(uint256 pages) external {
        for (uint256 k; k < 8; ++k) {
            (bool ok,) = mantleAddr.call(abi.encodeWithSignature("finalizeEpoch()"));
            if (!ok) break;
        }
        for (uint256 k; k < 8; ++k) {
            try emissions.openEpoch() {} catch { break; }
        }
        pages = bound(pages, 1, 12);
        for (uint256 e; e < emissions.nextEpoch() && pages != 0; ++e) {
            for (uint256 i; i < 4 && pages != 0; ++i) {
                ForgeEmissions.Phase ph = emissions.poolEpoch(e, i).phase;
                if (ph == ForgeEmissions.Phase.Measuring || ph == ForgeEmissions.Phase.Escrowing || ph == ForgeEmissions.Phase.Crediting) {
                    emissions.advance(e, i);
                    --pages;
                }
            }
        }
    }

    /// Prefer a position that has something to claim (or a claim to execute).
    function _pickWhere(uint256 seed, bool pending) internal view returns (uint256 poolIdx, uint256 id, address owner) {
        uint256 n = owned.length;
        for (uint256 k; k < n; ++k) {
            uint256[2] memory o = owned[(seed % n + k) % n];
            bool hit = pending ? emissions.claimOf(o[0], o[1]).amount != 0 : emissions.unclaimed(o[0], o[1]) != 0;
            if (hit) return (o[0], o[1], pools[o[0]].positionOf(o[1]).owner);
        }
        (, poolIdx, id, owner) = _pick(seed);
    }

    function requestClaim(uint256 seed) external {
        (uint256 poolIdx, uint256 id, address owner) = _pickWhere(seed, false);
        vm.prank(owner);
        try emissions.requestClaim(poolIdx, id) {} catch {}
    }

    function executeClaim(uint256 seed) external {
        (uint256 poolIdx, uint256 id, address owner) = _pickWhere(seed, true);
        uint256 maturesAt = emissions.claimOf(poolIdx, id).maturesAt;
        if (maturesAt > block.timestamp) vm.warp(maturesAt);
        vm.prank(owner);
        try emissions.executeClaim(poolIdx, id) {} catch {}
    }
}

/// @notice Random custody + Seals + settlement + claims across four pools and the Mantle. Every
///         handler call must succeed (fail_on_revert): the keeper path, finalize → open →
///         advance, never reverts, whatever the custody actions did in between.
/// forge-config: default.invariant.runs = 48
/// forge-config: default.invariant.depth = 120
/// forge-config: default.invariant.fail_on_revert = true
contract SettlementInvariantTest is SettlementFixture {
    SettlementHandler handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        _deploySettlement(block.timestamp);
        address[3] memory users = [_user(1), _user(2), _user(3)];
        for (uint256 u; u < 3; ++u) _fund(users[u]);
        handler = new SettlementHandler(
            pools, emissions, address(mantle), users, [registrar, capstone, matchReserveSink, sealedPotStream]
        );
        // A diligent keeper settles the first 31 days, so every starting position meets the
        // 30-day Ashfall minimums and every user holds claimed EMBER to burn: random runs
        // then exercise Ashfall budgets, Heat² credits and roll-backs, not just base.
        for (uint256 e; e < 31; ++e) {
            skip(1 days);
            mantle.finalizeEpoch();
            emissions.openEpoch();
            for (uint256 i; i < 4; ++i) {
                while (emissions.poolEpoch(e, i).phase != ForgeEmissions.Phase.Done) emissions.advance(e, i);
            }
        }
        for (uint256 k; k < handler.ownedCount(); ++k) {
            (uint256 i, uint256 id) = handler.ownedAt(k);
            vm.prank(pools[i].positionOf(id).owner);
            emissions.requestClaim(i, id);
        }
        skip(1 days);
        for (uint256 k; k < handler.ownedCount(); ++k) {
            (uint256 i, uint256 id) = handler.ownedAt(k);
            vm.prank(pools[i].positionOf(id).owner);
            emissions.executeClaim(i, id);
        }
        targetContract(address(handler));
    }

    /// Every finalized epoch: minted + released ≤ base, and = base once all pools are done.
    function invariant_baseBudgetConserved() public view {
        uint256 opened = emissions.nextEpoch();
        for (uint256 e; e < mantle.nextEpoch(); ++e) {
            (uint128 base,, uint128 minted,, uint128 released,) = mantle.budgets(e);
            assertLe(uint256(minted) + released, base);
            if (e >= opened) continue;
            bool done = true;
            uint256 targets;
            for (uint256 i; i < 4; ++i) {
                ForgeEmissions.PoolEpoch memory pe = emissions.poolEpoch(e, i);
                done = done && pe.phase == ForgeEmissions.Phase.Done;
                targets += pe.target;
                assertLe(pe.admitted, pe.target, "admitted within the pool's share");
                assertLe(pe.paid, pe.admitted, "credited within the admitted budget");
                assertLe(pe.escrow, pe.bucket, "escrow within the Conviction bucket");
                assertLe(emissions.sealedEarnerCount(e, i), emissions.earnerCount(e, i));
                assertLe(pe.cursor, pe.positions, "cursor bounded");
                assertLe(emissions.earnerCount(e, i), pe.cursor, "each position counted at most once");
            }
            assertLe(targets, base);
            if (done) assertEq(uint256(minted) + released, base, "every base wei minted or released");
        }
    }

    /// Every finalized epoch's Ashfall: minted + rolled ≤ budget, and = budget once all pools
    /// are done; no pool pays more than its share.
    function invariant_ashfallConserved() public view {
        uint256 opened = emissions.nextEpoch();
        for (uint256 e; e < mantle.nextEpoch(); ++e) {
            (, uint128 ashfall,, uint128 minted,, uint128 rolled) = mantle.budgets(e);
            assertLe(uint256(minted) + rolled, ashfall);
            if (e >= opened) continue;
            bool done = true;
            uint256 paid;
            for (uint256 i; i < 4; ++i) {
                ForgeEmissions.PoolEpoch memory pe = emissions.poolEpoch(e, i);
                done = done && pe.phase == ForgeEmissions.Phase.Done;
                assertLe(pe.ashfallPaid, pe.ashfall, "a pool pays at most its Ashfall share");
                paid += pe.ashfallPaid;
            }
            assertEq(paid, minted, "minted Ashfall is exactly what pools credited");
            if (done) assertEq(uint256(minted) + rolled, ashfall, "every Ashfall wei credited or rolled back");
        }
    }

    /// EMBER held by ForgeEmissions backs exactly the unclaimed and pending rewards and
    /// every Seal ledger, and EMBER supply equals the Mantle's ledger (mints minus
    /// recognized burns: registered burns and burned forfeits).
    function invariant_rewardsBacked() public view {
        uint256 owed = emissions.burnLane() + emissions.matchReserve();
        for (uint256 i; i < 4; ++i) owed += emissions.sealedPot(i);
        for (uint256 k; k < handler.ownedCount(); ++k) {
            (uint256 i, uint256 id) = handler.ownedAt(k);
            owed += emissions.unclaimed(i, id) + emissions.claimOf(i, id).amount + emissions.capstoneOwed(i, id);
            uint256 seals = pools[i].positionOf(id).sealCount;
            for (uint256 j = 1; j <= seals; ++j) owed += emissions.sealEscrow(i, id, j);
        }
        assertEq(ember.balanceOf(address(emissions)), owed, "EMBER held backs every claim and escrow ledger");
        assertEq(ember.totalSupply(), mantle.accounted(), "supply equals the Mantle's ledger");
    }

    /// Settlement state never blocks principal: every open position can exit.
    function invariant_exitsIndependentOfSettlement() public {
        for (uint256 k; k < handler.ownedCount(); k += 3) {
            (uint256 i, uint256 id) = handler.ownedAt(k);
            ForgePool.Position memory p = pools[i].positionOf(id);
            if (p.closedAt != 0) continue;
            uint256 snap = vm.snapshotState();
            vm.prank(p.owner);
            try pools[i].emergencyExit(id) {}
            catch (bytes memory err) {
                if (bytes4(err) != ForgePool.NothingToExit.selector) revert("emergency exit reverted");
            }
            vm.revertToState(snap);
        }
    }
}
