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

using ForgeView for ForgePool;

/// @notice The testnet kit, offline: CreateX's runtime (fixture, fetched from LiteForge and equal to
///         Ethereum's) is etched at its address and the chain id set to LiteForge's. The same
///         deployment is rehearsed live by `pnpm deploy:liteforge:dry` on a fork of chain 4441.
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
        vm.startPrank(who);
        d = _deploy(who, op, version, block.timestamp, address(0));
        vm.stopPrank();
    }

    function test_deploysAndWiresTheCore() public {
        Deployment memory d = _deployAs(deployer, operator, "1");
        assertEq(address(d.boost.EMISSIONS()), address(d.emissions));
        assertEq(address(d.stake[2]), address(d.ember), "pool 2 stakes EMBER itself");
        for (uint256 i; i < 4; ++i) {
            assertEq(d.pools[i].DEEDS(), operator, "the Deed slot is the operator's");
            assertEq(d.pools[i].FEE_COLLECTOR(), operator);
        }
        assertEq(d.mantle.KINDLING(), operator);
        assertEq(d.mantle.TREASURY(), operator);
        assertEq(d.emissions.MATCH_RESERVE(), operator);
        assertEq(d.emissions.SEALED_POT(), operator);
        assertEq(TestnetToken(address(d.stake[3])).decimals(), 6, "the USDC stand-in has USDC's decimals");
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
}
