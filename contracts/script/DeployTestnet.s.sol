// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";
import {EmberToken} from "../src/EmberToken.sol";
import {IEmberMintBurn, Mantle} from "../src/Mantle.sol";
import {ForgePool} from "../src/forge/ForgePool.sol";
import {IMantleDistribution, ForgeEmissions} from "../src/forge/ForgeEmissions.sol";
import {Boost, IValuation, IPyreLedger} from "../src/forge/Boost.sol";
import {ForgeLens} from "../src/forge/ForgeLens.sol";
import {EmberPair} from "../src/pairs/EmberPair.sol";
import {Flow, IFeeRebate} from "../src/flow/Flow.sol";
import {Vent, IVentFeePool, IVentPair, IVentMantle} from "../src/vent/Vent.sol";
import {
    TestnetToken, TestnetValuation, TestnetPyreLedger, TestnetFeeRebate, TestnetFounders
} from "./testnet/TestnetStandIns.sol";

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
///         Treasury, the fee router, the guardian, the compounder, the Deed market, the match
///         reserve, the Sealed pot) is the testnet operator's wallet; Relics' fee rebate is a
///         stand-in the operator sets. Flow is built (ADR 0016) and deployed here. Not audited.
///
///         The EMBER pairs (BlastPool, SmelterPool; ADR 0015) are an add-on: Forge pools 0 and 1
///         stake their CREATE3-predicted addresses, so the pairs can deploy in the same run (the
///         default) or later from the same deployer (`DeployTestnetPairs`), with no migration.
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
        EmberPair[2] pairs; // at their predicted addresses, deployed or not
        IERC20[2] pairQuote; // tUSDC (or FURNACE_TESTNET_USDC), tWETH (or FURNACE_TESTNET_WETH)
        bool pairsLive;
        Flow flow; // at its predicted address; the pairs and pools 0 and 1 name it
        Vent vent; // at its predicted address; every pool's fee collector, every pair's fee router
        TestnetFeeRebate rebates;
        TestnetFounders founders;
        TestnetValuation valuation;
        TestnetPyreLedger pyre;
        ForgeLens lens;
    }

    error NotATestnet(uint256 chainId);
    error CreateXMissing(bytes32 codehash);
    error AddressMismatch(string label, address predicted, address deployed);
    error Miswired(string what);
    error SaltVersionUsed(string version, address existing);
    error PairsAlreadyLive(address blastPool);

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
        address[2] pair;
        address flow;
        address vent;
    }

    function _poolLabel(uint256 i) internal pure returns (string memory) {
        return i == 0 ? "ForgePool0" : i == 1 ? "ForgePool1" : i == 2 ? "ForgePool2" : "ForgePool3";
    }

    function _pairLabel(uint256 i) internal pure returns (string memory) {
        return i == 0 ? "BlastPool" : "SmelterPool";
    }

    function _plan(address deployer, string memory version) internal view returns (Plan memory pl) {
        (pl.deployer, pl.version) = (deployer, version);
        pl.ember = _predict(deployer, _salt(deployer, version, "EmberToken"));
        pl.mantle = _predict(deployer, _salt(deployer, version, "Mantle"));
        pl.emissions = _predict(deployer, _salt(deployer, version, "ForgeEmissions"));
        pl.boost = _predict(deployer, _salt(deployer, version, "Boost"));
        for (uint256 i; i < 4; ++i) pl.pool[i] = _predict(deployer, _salt(deployer, version, _poolLabel(i)));
        for (uint256 i; i < 2; ++i) pl.pair[i] = _predict(deployer, _salt(deployer, version, _pairLabel(i)));
        pl.flow = _predict(deployer, _salt(deployer, version, "Flow"));
        pl.vent = _predict(deployer, _salt(deployer, version, "Vent"));
    }

    function _create3(Plan memory pl, string memory label, address predicted, bytes memory initCode)
        internal
        returns (address deployed)
    {
        deployed = CREATEX.deployCreate3(_salt(pl.deployer, pl.version, label), initCode);
        if (deployed != predicted) revert AddressMismatch(label, predicted, deployed);
    }

    /// @notice What `_deploy` takes beyond the deployer: the testnet's choices.
    struct Options {
        address operator;
        string version;
        uint256 start;
        address usdc; // an existing testnet USDC, or zero for the tUSDC stand-in
        address weth; // an existing testnet WETH, or zero for the tWETH stand-in
        bool pairsNow; // deploy the EMBER pairs in this run (else later, with DeployTestnetPairs)
    }

    /// @notice Deploy and wire everything. Every call must come from `deployer` (a broadcast or a
    ///         prank), since CreateX binds each salt to its caller.
    function _deploy(address deployer, Options memory o) internal returns (Deployment memory d) {
        if (!_isTestnet(block.chainid)) revert NotATestnet(block.chainid);
        if (address(CREATEX).codehash != CREATEX_CODEHASH) revert CreateXMissing(address(CREATEX).codehash);
        (d.deployer, d.operator, d.saltVersion, d.start) = (deployer, o.operator, o.version, o.start);

        // 1. Stand-ins (plain CREATE: nothing names them before they exist).
        d.valuation = new TestnetValuation(o.operator);
        d.pyre = new TestnetPyreLedger(o.operator);
        d.rebates = new TestnetFeeRebate(o.operator);
        d.founders = new TestnetFounders(o.operator);
        d.pairQuote[0] = o.usdc != address(0)
            ? IERC20(o.usdc)
            : IERC20(address(new TestnetToken("Furnace Testnet USDC (stand-in)", "tUSDC", 6, 1_000_000e6)));
        d.pairQuote[1] = o.weth != address(0)
            ? IERC20(o.weth)
            : IERC20(address(new TestnetToken("Furnace Testnet WETH (stand-in)", "tWETH", 18, 1_000_000e18)));
        d.stake[3] = d.pairQuote[0]; // usdc-single

        // 2. Predict the core: each constructor names addresses deployed after it.
        Plan memory pl = _plan(deployer, o.version);
        // A reused salt would make CREATE3 collide, which burns all the gas sent: refuse it first.
        if (pl.ember.code.length != 0) revert SaltVersionUsed(o.version, pl.ember);
        d.stake[2] = IERC20(pl.ember); // pool 2 stakes EMBER itself (ember-single)
        for (uint256 i; i < 2; ++i) {
            d.pairs[i] = EmberPair(pl.pair[i]);
            d.stake[i] = IERC20(pl.pair[i]); // pools 0 and 1 stake the pairs' receipts, live or not
        }

        // 3. Deploy in constructor-dependency order: EMBER and the Mantle store addresses only;
        //    the pairs read EMBER's and their quote's decimals; ForgeEmissions reads the Mantle and
        //    the pools; Boost checks every wire.
        _deployTokenAndMantle(pl, d);
        if (o.pairsNow) _deployPairs(pl, d);
        _deployPools(pl, d);
        _deployFlow(pl, d);
        _deployVent(pl, d);
        _deployEmissionsAndBoost(pl, d);
        d.lens = new ForgeLens();
        _checkWiring(d);
    }

    function _deployTokenAndMantle(Plan memory pl, Deployment memory d) internal {
        d.ember = EmberToken(
            _create3(pl, "EmberToken", pl.ember, abi.encodePacked(type(EmberToken).creationCode, abi.encode(pl.mantle)))
        );
        // Boost burns Capstone fees; the Vent burns every other protocol fee (ADR 0020). Both are
        // Protocol registrars, fixed here for good.
        address[] memory registrars = new address[](2);
        Mantle.BurnCategory[] memory categories = new Mantle.BurnCategory[](2);
        (registrars[0], categories[0]) = (pl.boost, Mantle.BurnCategory.Protocol);
        (registrars[1], categories[1]) = (pl.vent, Mantle.BurnCategory.Protocol);
        bytes memory args =
            abi.encode(IEmberMintBurn(pl.ember), pl.emissions, d.operator, d.operator, d.start, registrars, categories);
        d.mantle = Mantle(_create3(pl, "Mantle", pl.mantle, abi.encodePacked(type(Mantle).creationCode, args)));
    }

    /// @notice The two EMBER pairs at their predicted addresses. They name Flow's and the Vent's
    ///         predicted addresses; the operator holds the guardian and initializer slots
    ///         (Kindling is not built).
    function _deployPairs(Plan memory pl, Deployment memory d) internal {
        if (pl.pair[0].code.length != 0) revert PairsAlreadyLive(pl.pair[0]);
        string[2] memory names = ["Furnace Testnet Blast Furnace EMBER/USDC LP", "Furnace Testnet Smelter EMBER/WETH LP"];
        string[2] memory symbols = ["tBLAST-LP", "tSMELT-LP"];
        for (uint256 i; i < 2; ++i) {
            bytes memory args = abi.encode(
                names[i], symbols[i], IERC20(pl.ember), d.pairQuote[i], pl.vent, pl.flow, d.operator, d.operator
            );
            d.pairs[i] = EmberPair(
                _create3(pl, _pairLabel(i), pl.pair[i], abi.encodePacked(type(EmberPair).creationCode, args))
            );
        }
        d.pairsLive = true;
        _checkPairs(d);
    }

    function _checkPairs(Deployment memory d) internal view {
        for (uint256 i; i < 2; ++i) {
            EmberPair p = d.pairs[i];
            if (address(p.EMBER()) != address(d.stake[2]) || address(p.QUOTE()) != address(d.pairQuote[i])) {
                revert Miswired("pair tokens");
            }
            if (p.FEE_ROUTER() != _predict(d.deployer, _salt(d.deployer, d.saltVersion, "Vent"))) revert Miswired("pair FEE_ROUTER");
            if (p.GUARDIAN() != d.operator) revert Miswired("pair slots");
            if (p.FLOW() != _predict(d.deployer, _salt(d.deployer, d.saltVersion, "Flow"))) revert Miswired("pair FLOW");
            if (p.INITIALIZER() != d.operator) revert Miswired("pair initializer");
        }
    }

    function _deployPools(Plan memory pl, Deployment memory d) internal {
        bool[4] memory isLp = [P.FORGE_POOL_0_IS_LP, P.FORGE_POOL_1_IS_LP, P.FORGE_POOL_2_IS_LP, P.FORGE_POOL_3_IS_LP];
        for (uint256 i; i < 4; ++i) {
            // Only the LP pools take Flow's fee-free same-route stake (spec v5.5 §4; ADR 0016) and
            // the compounder's source-lot additions (ADR 0017): the operator stands in for the
            // unbuilt compounder, as it does for Flow's.
            address flow = isLp[i] ? pl.flow : address(0);
            address compounder = isLp[i] ? d.operator : address(0);
            // Kindling's LP is EMBER/USDC, pool 0's receipt (spec v5.5 §3); the operator stands in.
            // Every pool reads the same founder record for First Flame (ADR 0018).
            address kindling = i == 0 ? d.operator : address(0);
            // The operator stands in for Ignition, the head start's granter, on every pool (ADR 0019).
            // The Vent collects every pool's fees (ADR 0020).
            bytes memory args = abi.encode(
                d.stake[i],
                isLp[i],
                pl.vent,
                pl.boost,
                d.operator,
                flow,
                compounder,
                kindling,
                address(d.founders),
                d.operator
            );
            d.pools[i] =
                ForgePool(_create3(pl, _poolLabel(i), pl.pool[i], abi.encodePacked(type(ForgePool).creationCode, args)));
        }
    }

    /// @notice Flow reads nothing at construction, so it can deploy before or after the pairs.
    ///         The operator is its compounder (the Stoke-into-LP consumer is not built).
    function _deployFlow(Plan memory pl, Deployment memory d) internal {
        bytes memory args = abi.encode(
            IERC20(pl.ember),
            EmberPair(pl.pair[0]),
            EmberPair(pl.pair[1]),
            ForgePool(pl.pool[0]),
            ForgePool(pl.pool[1]),
            IFeeRebate(address(d.rebates)),
            d.operator
        );
        d.flow = Flow(_create3(pl, "Flow", pl.flow, abi.encodePacked(type(Flow).creationCode, args)));
    }

    /// @notice The Vent reads only the Mantle's registrar record at construction, so it deploys
    ///         before or after the pairs. The operator stands in for the Hearth, the Treasury, the
    ///         stakers' and Quote-yield distributors, the Deed market and the compounder.
    function _deployVent(Plan memory pl, Deployment memory d) internal {
        IVentFeePool[4] memory pools;
        for (uint256 i; i < 4; ++i) pools[i] = IVentFeePool(pl.pool[i]);
        IVentPair[2] memory pairs = [IVentPair(pl.pair[0]), IVentPair(pl.pair[1])];
        address op = d.operator;
        bytes memory args = abi.encode(IERC20(pl.ember), IVentMantle(pl.mantle), pools, pairs, op, op, op, op, op, op);
        d.vent = Vent(_create3(pl, "Vent", pl.vent, abi.encodePacked(type(Vent).creationCode, args)));
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
        if (d.mantle.registrarCategory(address(d.vent)) != Mantle.BurnCategory.Protocol) revert Miswired("Mantle Vent registrar");
        if (d.emissions.CAPSTONE() != address(d.boost)) revert Miswired("ForgeEmissions.CAPSTONE");
        for (uint256 i; i < 4; ++i) {
            ForgePool p = d.pools[i];
            if (address(d.emissions.poolAt(i)) != address(p)) revert Miswired("ForgeEmissions pool");
            if (p.BOOST() != address(d.boost) || address(p.STAKE_TOKEN()) != address(d.stake[i])) revert Miswired("pool");
            if (p.ANNEX().code.length == 0) revert Miswired("pool annex");
            if (p.FLOW() != (p.IS_LP() ? address(d.flow) : address(0))) revert Miswired("pool FLOW");
            if (p.COMPOUNDER() != (p.IS_LP() ? d.operator : address(0))) revert Miswired("pool COMPOUNDER");
            if (p.KINDLING() != (i == 0 ? d.operator : address(0))) revert Miswired("pool KINDLING");
            if (p.FOUNDERS() != address(d.founders)) revert Miswired("pool FOUNDERS");
            if (p.IGNITION() != d.operator) revert Miswired("pool IGNITION");
            if (p.FEE_COLLECTOR() != address(d.vent)) revert Miswired("pool FEE_COLLECTOR");
        }
        Vent v = d.vent;
        if (address(v.EMBER()) != address(d.ember) || address(v.MANTLE()) != address(d.mantle)) revert Miswired("Vent core");
        if (address(v.POOL_0()) != address(d.pools[0]) || address(v.POOL_1()) != address(d.pools[1])) revert Miswired("Vent pools");
        if (address(v.POOL_2()) != address(d.pools[2]) || address(v.POOL_3()) != address(d.pools[3])) revert Miswired("Vent pools");
        if (address(v.PAIR_0()) != address(d.pairs[0]) || address(v.PAIR_1()) != address(d.pairs[1])) revert Miswired("Vent pairs");
        if (v.HEARTH() != d.operator || v.TREASURY() != d.operator || v.STAKERS() != d.operator) revert Miswired("Vent recipients");
        if (v.QUOTE_YIELD() != d.operator || v.DEEDS() != d.operator || v.COMPOUNDER() != d.operator) revert Miswired("Vent slots");
        Flow f = d.flow;
        if (address(f.PAIR0()) != address(d.pairs[0]) || address(f.PAIR1()) != address(d.pairs[1])) revert Miswired("Flow pairs");
        if (address(f.POOL0()) != address(d.pools[0]) || address(f.POOL1()) != address(d.pools[1])) revert Miswired("Flow pools");
        if (address(f.EMBER()) != address(d.ember) || address(f.REBATES()) != address(d.rebates)) revert Miswired("Flow tokens");
        if (f.COMPOUNDER() != d.operator) revert Miswired("Flow compounder");
    }

    /// @notice A first exercise of every principal path the deployment allows, as `actor`. The
    ///         EMBER steps need the operator (the Kindling slot and each pair's initializer are the
    ///         operator's wallet); any other actor only stakes tUSDC. Mints the stand-ins, so a
    ///         FURNACE_TESTNET_USDC or _WETH token must be mintable by the actor.
    function _smoke(Deployment memory d, address actor) internal returns (uint256[4] memory ids) {
        TestnetToken usdc = TestnetToken(address(d.pairQuote[0]));
        usdc.mint(actor, 1_000_000e6);
        usdc.approve(address(d.pools[3]), type(uint256).max);
        ids[3] = d.pools[3].open(100e6);
        if (actor == d.operator) {
            d.mantle.mintKindlingSeed(); // 420,000 test EMBER to the operator
            IERC20 ember = IERC20(address(d.ember));
            ember.approve(address(d.pools[2]), type(uint256).max);
            ids[2] = d.pools[2].open(1_000e18);
            ember.approve(address(d.boost), type(uint256).max);
            if (d.pairsLive) {
                _seedPairs(d, actor);
                for (uint256 i; i < 2; ++i) {
                    IERC20(address(d.pairs[i])).approve(address(d.pools[i]), type(uint256).max);
                    ids[i] = d.pools[i].open(d.pairs[i].balanceOf(actor) / 2);
                }
                // One buy and one sell on BlastPool, at the full fee.
                usdc.approve(address(d.pairs[0]), type(uint256).max);
                uint256 got = d.pairs[0].buy(100e6, 0, actor);
                d.pairs[0].sell(got / 2, 0, actor);
                // A zap of 100 tUSDC into BlastPool, staked fee-free into the pool-0 position. The
                // deadline allows for the broadcast landing after the script ran.
                usdc.approve(address(d.flow), type(uint256).max);
                d.flow.zapAndStake(0, true, 100e6, 0, ids[0], block.timestamp + 1 hours);
                // The operator, standing in for the compounder, returns 1 LP to that position's
                // first lot at the lot's own age, fee-free (ADR 0017).
                d.pools[0].addToLot(ids[0], 0, 1e18);
                // The operator, standing in for Kindling, opens a contributor position for itself at
                // the standard fee, then marks itself a founder and refreshes First Flame (ADR 0018).
                d.pools[0].openKindling(actor, 10e18);
                d.founders.setFounder(actor, true);
                d.pools[0].refreshFounder(ids[0]);
                // And, standing in for Ignition, grants that position's first lot a 30-day head start.
                d.pools[0].grantHeadStart(ids[0], 0, 30 days);
                // The Vent collects every fee taken so far. A buyback in a pair this young
                // defers (no 30-minute TWAP yet): the quote waits, fail closed (ADR 0020).
                d.vent.collectAll();
                d.vent.vent(0);
            }
            d.boost.deposit(d.pairsLive ? 0 : 2, d.pairsLive ? ids[0] : ids[2], 100e18); // a Capstone
        }
        d.pools[3].requestCooling(ids[3], 1e6);
    }

    /// @notice First liquidity: 50,000 EMBER with 50,000 tUSDC (1 USDC per EMBER) and 20,000
    ///         EMBER with 10 tWETH. Test prices, set by hand.
    function _seedPairs(Deployment memory d, address actor) internal {
        TestnetToken weth = TestnetToken(address(d.pairQuote[1]));
        weth.mint(actor, 1_000e18);
        uint256[2] memory emberIn = [uint256(50_000e18), 20_000e18];
        uint256[2] memory quoteIn = [uint256(50_000e6), 10e18];
        for (uint256 i; i < 2; ++i) {
            IERC20(address(d.ember)).approve(address(d.pairs[i]), type(uint256).max);
            d.pairQuote[i].approve(address(d.pairs[i]), type(uint256).max);
            d.pairs[i].addLiquidity(emberIn[i], quoteIn[i], emberIn[i], quoteIn[i], actor);
        }
    }
}

/// @notice `forge script contracts/script/DeployTestnet.s.sol --rpc-url liteforge` (a dry run on a
///         fork); add `--broadcast --account <keystore>` to deploy. Environment, all optional:
///         FURNACE_TESTNET_OPERATOR (default: the deployer), FURNACE_TESTNET_SALT_VERSION (default
///         "1"; bump it to deploy a fresh set), FURNACE_TESTNET_START (default: now),
///         FURNACE_TESTNET_USDC and FURNACE_TESTNET_WETH (existing testnet tokens instead of the
///         stand-ins), FURNACE_TESTNET_PAIRS=later (leave the EMBER pairs for DeployTestnetPairs)
///         and FURNACE_TESTNET_SMOKE=1 (also run the smoke actions).
contract DeployTestnet is Script, FurnaceTestnet {
    function run() external returns (Deployment memory d) {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        Options memory o;
        o.operator = vm.envOr("FURNACE_TESTNET_OPERATOR", deployer);
        o.version = vm.envOr("FURNACE_TESTNET_SALT_VERSION", string("1"));
        o.start = vm.envOr("FURNACE_TESTNET_START", block.timestamp);
        o.usdc = vm.envOr("FURNACE_TESTNET_USDC", address(0));
        o.weth = vm.envOr("FURNACE_TESTNET_WETH", address(0));
        o.pairsNow = keccak256(bytes(vm.envOr("FURNACE_TESTNET_PAIRS", string("now")))) != keccak256("later");
        d = _deploy(deployer, o);
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
        console2.log(d.pairsLive ? "EMBER pairs: deployed" : "EMBER pairs: predicted, not deployed (DeployTestnetPairs)");
        console2.log("BlastPool        ", address(d.pairs[0]));
        console2.log("  quote          ", address(d.pairQuote[0]));
        console2.log("SmelterPool      ", address(d.pairs[1]));
        console2.log("  quote          ", address(d.pairQuote[1]));
        for (uint256 i; i < 4; ++i) {
            console2.log("ForgePool", i, address(d.pools[i]));
            console2.log("  stake token    ", address(d.stake[i]));
            console2.log("  annex          ", d.pools[i].ANNEX());
        }
        console2.log("Flow             ", address(d.flow));
        console2.log("Vent             ", address(d.vent));
        console2.log("TestnetFeeRebate ", address(d.rebates));
        console2.log("TestnetFounders  ", address(d.founders));
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
        vm.serializeAddress(k, "BlastPool", address(d.pairs[0]));
        vm.serializeAddress(k, "BlastPoolQuote", address(d.pairQuote[0]));
        vm.serializeAddress(k, "SmelterPool", address(d.pairs[1]));
        vm.serializeAddress(k, "SmelterPoolQuote", address(d.pairQuote[1]));
        vm.serializeBool(k, "pairsLive", d.pairsLive);
        vm.serializeAddress(k, "Flow", address(d.flow));
        vm.serializeAddress(k, "Vent", address(d.vent));
        vm.serializeAddress(k, "TestnetFeeRebate", address(d.rebates));
        vm.serializeAddress(k, "TestnetFounders", address(d.founders));
        for (uint256 i; i < 4; ++i) {
            vm.serializeAddress(k, string.concat("ForgePool", vm.toString(i)), address(d.pools[i]));
            vm.serializeAddress(k, string.concat("ForgePool", vm.toString(i), "Annex"), d.pools[i].ANNEX());
            vm.serializeAddress(k, string.concat("ForgePool", vm.toString(i), "StakeToken"), address(d.stake[i]));
        }
        string memory json = vm.serializeString(k, "status", "testnet only: not audited, stand-ins for unbuilt modules");
        vm.writeJson(json, _manifestPath());
        console2.log("manifest         ", _manifestPath());
    }
}

function _manifestPath() view returns (string memory) {
    return string.concat("deployments/testnet-", Strings.toString(block.chainid), ".json");
}

/// @notice Deploys the EMBER pairs later, at the addresses Forge pools 0 and 1 already stake
///         (ADR 0015): `forge script contracts/script/DeployTestnet.s.sol:DeployTestnetPairs
///         --rpc-url liteforge --broadcast --account <the original deployer's keystore>`. Reads
///         the deployment from `deployments/testnet-<chain id>.json`; CreateX binds each salt to
///         its caller, so only the original deployer can do this, and only once.
contract DeployTestnetPairs is Script, FurnaceTestnet {
    error NotTheDeployer(address broadcaster, address deployer);

    function run() external returns (EmberPair[2] memory pairs) {
        string memory json = vm.readFile(_manifestPath());
        if (vm.parseJsonUint(json, ".chainId") != block.chainid) revert Miswired("manifest chain id");
        Deployment memory d;
        d.deployer = vm.parseJsonAddress(json, ".deployer");
        d.operator = vm.parseJsonAddress(json, ".operator");
        d.saltVersion = vm.parseJsonString(json, ".saltVersion");
        d.stake[2] = IERC20(vm.parseJsonAddress(json, ".EmberToken"));
        d.pairQuote[0] = IERC20(vm.parseJsonAddress(json, ".BlastPoolQuote"));
        d.pairQuote[1] = IERC20(vm.parseJsonAddress(json, ".SmelterPoolQuote"));
        Plan memory pl = _plan(d.deployer, d.saltVersion);
        if (pl.ember != address(d.stake[2])) revert Miswired("manifest EMBER");
        for (uint256 i; i < 2; ++i) {
            ForgePool pool = ForgePool(vm.parseJsonAddress(json, string.concat(".ForgePool", vm.toString(i))));
            if (address(pool.STAKE_TOKEN()) != pl.pair[i]) revert Miswired("pool stake token");
        }
        vm.startBroadcast();
        (, address broadcaster,) = vm.readCallers();
        if (broadcaster != d.deployer) revert NotTheDeployer(broadcaster, d.deployer);
        _deployPairs(pl, d);
        vm.stopBroadcast();
        pairs = d.pairs;
        console2.log("BlastPool        ", address(pairs[0]));
        console2.log("SmelterPool      ", address(pairs[1]));
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) vm.writeJson("true", _manifestPath(), ".pairsLive");
    }
}
