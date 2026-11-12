// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {EmberToken} from "../src/EmberToken.sol";
import {IEmberMintBurn, Mantle} from "../src/Mantle.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {IMantleDistribution, ForgeEmissions} from "../src/forge/ForgeEmissions.sol";
import {Boost, IValuation, IPyreLedger} from "../src/forge/Boost.sol";
import {ForgeLens} from "../src/forge/ForgeLens.sol";
import {TestnetToken, TestnetValuation, TestnetPyreLedger} from "./testnet/TestnetStandIns.sol";

/// @dev CreateX (https://github.com/pcaversaccio/createx), at the same address on every chain.
interface ICreateX {
    function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address);
    function computeCreate3Address(bytes32 guardedSalt) external view returns (address);
}

/// @title FurnaceTestnet
/// @notice Deploys and wires the built Furnace core on a TESTNET, with stand-ins for the modules that
///         are not built (docs/testnet/litvm-liteforge.md). The core goes through CreateX's CREATE3,
///         as the canonical deployment does (spec v5.5 §23): the Mantle, EMBER, ForgeEmissions,
///         Boost and the four pools name each other in their constructors, so every address is
///         predicted first and checked against the address CreateX returns.
///
///         This is NOT the canonical deployment. Salts are bound to the deployer AND the chain (the
///         0x01 flag), so they can never reproduce an address on another chain; the canonical
///         registry's mined salts are not used. Every slot for an unbuilt module (Kindling, the
///         Treasury, the fee router, the Deed market, the match reserve, the Sealed pot) is the
///         testnet operator's wallet. Not audited.
abstract contract FurnaceTestnet {
    ICreateX internal constant CREATEX = ICreateX(P.CREATEX);
    /// @dev keccak256 of CreateX's runtime code, the same on Ethereum and on LiteForge (checked
    ///      against both chains when this was written).
    bytes32 internal constant CREATEX_CODEHASH = 0xbd8a7ea8cfca7b4e5f5041d7d4b17bc317c5ce42cfbc42066a00cf26b43eb53f;
    uint256 internal constant LITEFORGE_CHAIN_ID = 4441;
    uint256 internal constant LOCAL_CHAIN_ID = 31337;

    struct Deployment {
        address deployer;
        address operator;
        string saltVersion;
        uint256 start;
        EmberToken ember;
        Mantle mantle;
        ForgeEmissions emissions;
        Boost boost;
        ForgePool[4] pools;
        IERC20[4] stake;
        TestnetValuation valuation;
        TestnetPyreLedger pyre;
        ForgeLens lens;
    }

    error NotATestnet(uint256 chainId);
    error CreateXMissing(bytes32 codehash);
    error AddressMismatch(string label, address predicted, address deployed);
    error Miswired(string what);
    error SaltVersionUsed(string version, address existing);

    /// @notice Testnet chains this kit deploys to. Anything else is refused.
    function _isTestnet(uint256 chainId) internal pure returns (bool) {
        return chainId == LITEFORGE_CHAIN_ID || chainId == LOCAL_CHAIN_ID;
    }

    /// @notice A CreateX salt bound to `deployer` and, by the 0x01 flag, to this chain id.
    function _salt(address deployer, string memory version, string memory label) internal pure returns (bytes32) {
        bytes11 entropy = bytes11(keccak256(abi.encodePacked("furnace.testnet.v", version, ".", label)));
        return bytes32(abi.encodePacked(deployer, bytes1(0x01), entropy));
    }

    /// @notice CreateX's guard for a salt bound to its caller with cross-chain redeploy protection.
    function _predict(address deployer, bytes32 salt) internal view returns (address) {
        return CREATEX.computeCreate3Address(keccak256(abi.encode(deployer, block.chainid, salt)));
    }

    /// @notice The core's addresses, predicted before anything is deployed.
    struct Plan {
        address deployer;
        string version;
        address ember;
        address mantle;
        address emissions;
        address boost;
        address[4] pool;
    }

    function _poolLabel(uint256 i) internal pure returns (string memory) {
        return i == 0 ? "ForgePool0" : i == 1 ? "ForgePool1" : i == 2 ? "ForgePool2" : "ForgePool3";
    }

    function _plan(address deployer, string memory version) internal view returns (Plan memory pl) {
        (pl.deployer, pl.version) = (deployer, version);
        pl.ember = _predict(deployer, _salt(deployer, version, "EmberToken"));
        pl.mantle = _predict(deployer, _salt(deployer, version, "Mantle"));
        pl.emissions = _predict(deployer, _salt(deployer, version, "ForgeEmissions"));
        pl.boost = _predict(deployer, _salt(deployer, version, "Boost"));
        for (uint256 i; i < 4; ++i) pl.pool[i] = _predict(deployer, _salt(deployer, version, _poolLabel(i)));
    }

    function _create3(Plan memory pl, string memory label, address predicted, bytes memory initCode)
        internal
        returns (address deployed)
    {
        deployed = CREATEX.deployCreate3(_salt(pl.deployer, pl.version, label), initCode);
        if (deployed != predicted) revert AddressMismatch(label, predicted, deployed);
    }

    /// @notice Deploy and wire everything. Every call must come from `deployer` (a broadcast or a
    ///         prank), since CreateX binds each salt to its caller.
    function _deploy(address deployer, address operator, string memory version, uint256 start, address usdc)
        internal
        returns (Deployment memory d)
    {
        if (!_isTestnet(block.chainid)) revert NotATestnet(block.chainid);
        if (address(CREATEX).codehash != CREATEX_CODEHASH) revert CreateXMissing(address(CREATEX).codehash);
        (d.deployer, d.operator, d.saltVersion, d.start) = (deployer, operator, version, start);

        // 1. Stand-ins (plain CREATE: nothing names them before they exist).
        d.valuation = new TestnetValuation(operator);
        d.pyre = new TestnetPyreLedger(operator);
        d.stake[0] = new TestnetToken("Furnace Testnet EMBER/USDC LP (stand-in)", "tBLAST-LP", 18, 1_000_000e18);
        d.stake[1] = new TestnetToken("Furnace Testnet EMBER/WETH LP (stand-in)", "tSMELT-LP", 18, 1_000_000e18);
        d.stake[3] = usdc != address(0)
            ? IERC20(usdc)
            : IERC20(address(new TestnetToken("Furnace Testnet USDC (stand-in)", "tUSDC", 6, 1_000_000e6)));

        // 2. Predict the core: each constructor names addresses deployed after it.
        Plan memory pl = _plan(deployer, version);
        // A reused salt would make CREATE3 collide, which burns all the gas sent: refuse it first.
        if (pl.ember.code.length != 0) revert SaltVersionUsed(version, pl.ember);
        d.stake[2] = IERC20(pl.ember); // pool 2 stakes EMBER itself (ember-single)

        // 3. Deploy in constructor-dependency order: EMBER and the Mantle store addresses only;
        //    ForgeEmissions reads the Mantle and the pools; Boost checks every wire.
        _deployTokenAndMantle(pl, d);
        _deployPools(pl, d);
        _deployEmissionsAndBoost(pl, d);
        d.lens = new ForgeLens();
        _checkWiring(d);
    }

    function _deployTokenAndMantle(Plan memory pl, Deployment memory d) internal {
        d.ember = EmberToken(
            _create3(pl, "EmberToken", pl.ember, abi.encodePacked(type(EmberToken).creationCode, abi.encode(pl.mantle)))
        );
        address[] memory registrars = new address[](1);
        Mantle.BurnCategory[] memory categories = new Mantle.BurnCategory[](1);
        (registrars[0], categories[0]) = (pl.boost, Mantle.BurnCategory.Protocol);
        bytes memory args =
            abi.encode(IEmberMintBurn(pl.ember), pl.emissions, d.operator, d.operator, d.start, registrars, categories);
        d.mantle = Mantle(_create3(pl, "Mantle", pl.mantle, abi.encodePacked(type(Mantle).creationCode, args)));
    }

    function _deployPools(Plan memory pl, Deployment memory d) internal {
        bool[4] memory isLp = [P.FORGE_POOL_0_IS_LP, P.FORGE_POOL_1_IS_LP, P.FORGE_POOL_2_IS_LP, P.FORGE_POOL_3_IS_LP];
        for (uint256 i; i < 4; ++i) {
            bytes memory args = abi.encode(d.stake[i], isLp[i], d.operator, pl.boost, d.operator);
            d.pools[i] =
                ForgePool(_create3(pl, _poolLabel(i), pl.pool[i], abi.encodePacked(type(ForgePool).creationCode, args)));
        }
    }

    function _deployEmissionsAndBoost(Plan memory pl, Deployment memory d) internal {
        bytes memory args =
            abi.encode(IMantleDistribution(pl.mantle), IERC20(pl.ember), d.pools, pl.boost, d.operator, d.operator);
        d.emissions = ForgeEmissions(
            _create3(pl, "ForgeEmissions", pl.emissions, abi.encodePacked(type(ForgeEmissions).creationCode, args))
        );
        args = abi.encode(d.emissions, IValuation(address(d.valuation)), IPyreLedger(address(d.pyre)));
        d.boost = Boost(_create3(pl, "Boost", pl.boost, abi.encodePacked(type(Boost).creationCode, args)));
    }

    /// @notice Boost's constructor already checks its own wires; these are the rest.
    function _checkWiring(Deployment memory d) internal view {
        if (d.ember.MANTLE() != address(d.mantle)) revert Miswired("EMBER.MANTLE");
        if (d.ember.CONFIG_HASH() != P.CONFIG_HASH) revert Miswired("EMBER.CONFIG_HASH");
        if (address(d.mantle.EMBER()) != address(d.ember)) revert Miswired("Mantle.EMBER");
        if (d.mantle.DISTRIBUTOR() != address(d.emissions)) revert Miswired("Mantle.DISTRIBUTOR");
        if (d.mantle.registrarCategory(address(d.boost)) != Mantle.BurnCategory.Protocol) revert Miswired("Mantle registrar");
        if (d.emissions.CAPSTONE() != address(d.boost)) revert Miswired("ForgeEmissions.CAPSTONE");
        for (uint256 i; i < 4; ++i) {
            ForgePool p = d.pools[i];
            if (address(d.emissions.poolAt(i)) != address(p)) revert Miswired("ForgeEmissions pool");
            if (p.BOOST() != address(d.boost) || address(p.STAKE_TOKEN()) != address(d.stake[i])) revert Miswired("pool");
            if (p.ANNEX().code.length == 0) revert Miswired("pool annex");
        }
    }

    /// @notice A first exercise of every principal path the stand-ins allow, as `actor` (who must
    ///         be the operator for the EMBER steps: the Kindling slot is the operator's wallet).
    function _smoke(Deployment memory d, address actor) internal returns (uint256[4] memory ids) {
        for (uint256 i; i < 4; ++i) {
            if (i == 2) continue;
            uint256 unit = 10 ** TestnetToken(address(d.stake[i])).decimals();
            TestnetToken(address(d.stake[i])).mint(actor, 1_000 * unit);
            d.stake[i].approve(address(d.pools[i]), type(uint256).max);
            ids[i] = d.pools[i].open(100 * unit);
        }
        if (actor == d.operator) {
            d.mantle.mintKindlingSeed(); // 420,000 test EMBER to the operator
            IERC20(address(d.ember)).approve(address(d.pools[2]), type(uint256).max);
            ids[2] = d.pools[2].open(1_000e18);
            IERC20(address(d.ember)).approve(address(d.boost), type(uint256).max);
            d.boost.deposit(0, ids[0], 100e18); // a Capstone on the EMBER/USDC stand-in position
        }
        d.pools[0].requestCooling(ids[0], 1e18);
    }
}

/// @notice `forge script contracts/script/DeployTestnet.s.sol --rpc-url liteforge` (a dry run on a
///         fork); add `--broadcast --account <keystore>` to deploy. Environment, all optional:
///         FURNACE_TESTNET_OPERATOR (default: the deployer), FURNACE_TESTNET_SALT_VERSION (default
///         "1"; bump it to deploy a fresh set), FURNACE_TESTNET_START (default: now),
///         FURNACE_TESTNET_USDC (an existing testnet USDC instead of the stand-in) and
///         FURNACE_TESTNET_SMOKE=1 (also run the smoke actions).
contract DeployTestnet is Script, FurnaceTestnet {
    function run() external returns (Deployment memory d) {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        address operator = vm.envOr("FURNACE_TESTNET_OPERATOR", deployer);
        string memory version = vm.envOr("FURNACE_TESTNET_SALT_VERSION", string("1"));
        uint256 start = vm.envOr("FURNACE_TESTNET_START", block.timestamp);
        address usdc = vm.envOr("FURNACE_TESTNET_USDC", address(0));
        d = _deploy(deployer, operator, version, start, usdc);
        if (vm.envOr("FURNACE_TESTNET_SMOKE", false)) _smoke(d, deployer);
        vm.stopBroadcast();
        _report(d);
    }

    function _report(Deployment memory d) internal {
        console2.log("chain id         ", block.chainid);
        console2.log("deployer         ", d.deployer);
        console2.log("operator         ", d.operator);
        console2.log("Mantle START     ", d.start);
        console2.log("EmberToken       ", address(d.ember));
        console2.log("Mantle           ", address(d.mantle));
        console2.log("ForgeEmissions   ", address(d.emissions));
        console2.log("Boost            ", address(d.boost));
        for (uint256 i; i < 4; ++i) {
            console2.log("ForgePool", i, address(d.pools[i]));
            console2.log("  stake token    ", address(d.stake[i]));
            console2.log("  annex          ", d.pools[i].ANNEX());
        }
        console2.log("ForgeLens        ", address(d.lens));
        console2.log("TestnetValuation ", address(d.valuation));
        console2.log("TestnetPyreLedger", address(d.pyre));
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) return;
        string memory k = "furnace";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeString(k, "saltVersion", d.saltVersion);
        vm.serializeUint(k, "mantleStart", d.start);
        vm.serializeAddress(k, "deployer", d.deployer);
        vm.serializeAddress(k, "operator", d.operator);
        vm.serializeAddress(k, "createx", address(CREATEX));
        vm.serializeAddress(k, "EmberToken", address(d.ember));
        vm.serializeAddress(k, "Mantle", address(d.mantle));
        vm.serializeAddress(k, "ForgeEmissions", address(d.emissions));
        vm.serializeAddress(k, "Boost", address(d.boost));
        vm.serializeAddress(k, "ForgeLens", address(d.lens));
        vm.serializeAddress(k, "TestnetValuation", address(d.valuation));
        vm.serializeAddress(k, "TestnetPyreLedger", address(d.pyre));
        for (uint256 i; i < 4; ++i) {
            vm.serializeAddress(k, string.concat("ForgePool", vm.toString(i)), address(d.pools[i]));
            vm.serializeAddress(k, string.concat("ForgePool", vm.toString(i), "Annex"), d.pools[i].ANNEX());
            vm.serializeAddress(k, string.concat("ForgePool", vm.toString(i), "StakeToken"), address(d.stake[i]));
        }
        string memory json = vm.serializeString(k, "status", "testnet only: not audited, stand-ins for unbuilt modules");
        string memory path = string.concat("deployments/testnet-", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("manifest         ", path);
    }
}
