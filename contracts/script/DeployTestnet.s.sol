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
import {GenesisFeeEscrow} from "../src/kindling/GenesisFeeEscrow.sol";
import {PermanentLiquidity} from "../src/kindling/PermanentLiquidity.sol";
import {Kindling, IKindlingMantle, IKindlingPair, IKindlingPool} from "../src/kindling/Kindling.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AshToken} from "../src/ash/AshToken.sol";
import {AshLedger, IAshMint} from "../src/ash/AshLedger.sol";
import {KindlingAshBonus, IKindlingBonusView, IAshBonusLedger} from "../src/ash/KindlingAshBonus.sol";
import {Ignition, IIgnitionLedger, IIgnitionKindling, IIgnitionPair} from "../src/ignition/Ignition.sol";
import {EpochSplitter, IEpochMeasures} from "../src/yield/EpochSplitter.sol";
import {ForgeAsh, IAshForgeLedger} from "../src/yield/ForgeAsh.sol";
import {BookedSplitter} from "../src/yield/BookedSplitter.sol";
import {SealedPotStream} from "../src/yield/SealedPotStream.sol";
import {Hearth} from "../src/hearth/Hearth.sol";
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
///         registry's mined salts are not used. Every slot for an unbuilt module (the Treasury, the
///         guardian, the compounder, the Deed market, the match reserve, the Sealed pot, Ignition)
///         is the testnet operator's wallet; Relics' fee rebate is a stand-in the operator sets.
///         Flow (ADR 0016) and the Vent (ADR 0020) are built and deployed here.
///
///         Kindling (ADR 0021) has two modes. By default the operator stands in for it (the
///         Mantle's KINDLING, BlastPool's initializer, pool 0's openKindling), so the smoke run can
///         seed the pairs at once. With FURNACE_TESTNET_KINDLING=1 the real Kindling, its
///         GenesisFeeEscrow and the permanent LP sink deploy at their predicted addresses and hold
///         those slots: no EMBER exists until the event settles.
///
///         Ignition (ADR 0023) runs before Kindling. With FURNACE_TESTNET_IGNITION=1 (which needs
///         the real Kindling too) the real Ignition deploys at its predicted address and is every
///         pool's IGNITION and FOUNDERS and the ASH ledger's IGNITION; it farms tUSDC, tWETH and a
///         tWBTC stand-in, its LP pool unbound. Kindling then opens after Ignition's free-exit
///         window. Not audited.
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
        bool kindlingLive; // the real Kindling holds its slots (else the operator stands in)
        Kindling kindling; // at its predicted address in that mode; zero otherwise
        GenesisFeeEscrow escrow;
        PermanentLiquidity sink;
        AshToken ash; // ASH and its issuance ledger (ADR 0022)
        AshLedger ashLedger;
        KindlingAshBonus ashBonus; // with the real Kindling only; zero otherwise
        bool ignitionLive; // the real Ignition holds its slots (else the operator stands in)
        Ignition ignition; // at its predicted address in that mode; zero otherwise
        IERC20 wbtc; // Ignition's tWBTC stand-in, in that mode
        ForgeAsh forgeAsh; // the epoch splitters (ADR 0024): the ASH ledger's FORGE
        BookedSplitter stayers; // the Vent's STAKERS
        BookedSplitter quoteYield; // the Vent's QUOTE_YIELD
        SealedPotStream sealedPot; // ForgeEmissions' SEALED_POT
        Hearth hearth; // the Vent's HEARTH (ADR 0025): staked ASH earns its fee share
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
    error IgnitionNeedsKindling();

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
        address kindling;
        address escrow;
        address sink;
        address ash;
        address ashLedger;
        address ashBonus;
        address ignition;
        address forgeAsh;
        address stayers;
        address quoteYield;
        address sealedPot;
        address hearth;
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
        pl.kindling = _predict(deployer, _salt(deployer, version, "Kindling"));
        pl.escrow = _predict(deployer, _salt(deployer, version, "GenesisFeeEscrow"));
        pl.sink = _predict(deployer, _salt(deployer, version, "PermanentLiquidity"));
        pl.ash = _predict(deployer, _salt(deployer, version, "AshToken"));
        pl.ashLedger = _predict(deployer, _salt(deployer, version, "AshLedger"));
        pl.ashBonus = _predict(deployer, _salt(deployer, version, "KindlingAshBonus"));
        pl.ignition = _predict(deployer, _salt(deployer, version, "Ignition"));
        pl.forgeAsh = _predict(deployer, _salt(deployer, version, "ForgeAsh"));
        pl.stayers = _predict(deployer, _salt(deployer, version, "Stayers"));
        pl.quoteYield = _predict(deployer, _salt(deployer, version, "QuoteYield"));
        pl.sealedPot = _predict(deployer, _salt(deployer, version, "SealedPotStream"));
        pl.hearth = _predict(deployer, _salt(deployer, version, "Hearth"));
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
        bool kindling; // deploy the real Kindling, escrow and sink (else the operator stands in)
        uint256 kindlingStart; // when Kindling opens (its 24 h runs from here)
        bool ignition; // deploy the real Ignition (needs the real Kindling)
        uint256 ignitionStart; // when Ignition opens (its 120 h run from here)
    }

    /// @notice Deploy and wire everything. Every call must come from `deployer` (a broadcast or a
    ///         prank), since CreateX binds each salt to its caller.
    function _deploy(address deployer, Options memory o) internal returns (Deployment memory d) {
        if (!_isTestnet(block.chainid)) revert NotATestnet(block.chainid);
        if (address(CREATEX).codehash != CREATEX_CODEHASH) revert CreateXMissing(address(CREATEX).codehash);
        (d.deployer, d.operator, d.saltVersion, d.start) = (deployer, o.operator, o.version, o.start);
        d.kindlingLive = o.kindling;
        d.ignitionLive = o.ignition;
        // Genesis runs Ignition, then Kindling: the real Ignition reads Kindling's close.
        if (o.ignition && !o.kindling) revert IgnitionNeedsKindling();

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
        if (o.ignition) d.wbtc = IERC20(address(new TestnetToken("Furnace Testnet WBTC (stand-in)", "tWBTC", 8, 100e8)));

        // 2. Predict the core: each constructor names addresses deployed after it.
        Plan memory pl = _plan(deployer, o.version);
        // A reused salt would make CREATE3 collide, which burns all the gas sent: refuse it first.
        if (pl.ember.code.length != 0) revert SaltVersionUsed(o.version, pl.ember);
        d.stake[2] = IERC20(pl.ember); // pool 2 stakes EMBER itself (ember-single)
        for (uint256 i; i < 2; ++i) {
            d.pairs[i] = EmberPair(pl.pair[i]);
            d.stake[i] = IERC20(pl.pair[i]); // pools 0 and 1 stake the pairs' receipts, live or not
        }
        if (o.kindling) d.kindling = Kindling(pl.kindling); // BlastPool and pool 0 name it
        if (o.ignition) d.ignition = Ignition(pl.ignition); // every pool and the ASH ledger name it

        // 3. Deploy in constructor-dependency order: EMBER and the Mantle store addresses only;
        //    the pairs read EMBER's and their quote's decimals; ForgeEmissions reads the Mantle and
        //    the pools; Boost checks every wire.
        _deployTokenAndMantle(pl, d);
        if (o.pairsNow) _deployPairs(pl, d);
        _deployPools(pl, d);
        _deployFlow(pl, d);
        _deployVent(pl, d);
        if (o.kindling) _deployKindling(pl, d, o.kindlingStart);
        _deployAsh(pl, d);
        if (o.ignition) _deployIgnition(pl, d, o.ignitionStart);
        _deploySplitters(pl, d);
        _deployHearth(pl, d);
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
        address kindling = d.kindlingLive ? pl.kindling : d.operator;
        bytes memory args =
            abi.encode(IEmberMintBurn(pl.ember), pl.emissions, kindling, d.operator, d.start, registrars, categories);
        d.mantle = Mantle(_create3(pl, "Mantle", pl.mantle, abi.encodePacked(type(Mantle).creationCode, args)));
    }

    /// @notice The two EMBER pairs at their predicted addresses. They name Flow's and the Vent's
    ///         predicted addresses; the operator holds the guardian slot. BlastPool's initializer is
    ///         Kindling in the real mode, else the operator; SmelterPool's is the operator (its own
    ///         seeding is a separately funded Treasury event, not built).
    function _deployPairs(Plan memory pl, Deployment memory d) internal {
        if (pl.pair[0].code.length != 0) revert PairsAlreadyLive(pl.pair[0]);
        string[2] memory names = ["Furnace Testnet Blast Furnace EMBER/USDC LP", "Furnace Testnet Smelter EMBER/WETH LP"];
        string[2] memory symbols = ["tBLAST-LP", "tSMELT-LP"];
        for (uint256 i; i < 2; ++i) {
            bytes memory args = abi.encode(
                names[i], symbols[i], IERC20(pl.ember), d.pairQuote[i], pl.vent, pl.flow, d.operator, _initializer(d, i)
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
            if (p.INITIALIZER() != _initializer(d, i)) revert Miswired("pair initializer");
        }
    }

    /// @notice Who opens pair `i`: Kindling opens BlastPool in the real mode; the operator otherwise.
    function _initializer(Deployment memory d, uint256 i) internal pure returns (address) {
        return i == 0 && address(d.kindling) != address(0) ? address(d.kindling) : d.operator;
    }

    /// @notice Who may open Kindling positions in pool `i`: only pool 0, by Kindling or its stand-in.
    function _kindlingSlot(Deployment memory d, uint256 i) internal pure returns (address) {
        if (i != 0) return address(0);
        return address(d.kindling) != address(0) ? address(d.kindling) : d.operator;
    }

    /// @notice Who grants the head start on every pool, and takes ASH's Ignition leaf.
    function _ignitionSlot(Deployment memory d) internal pure returns (address) {
        return address(d.ignition) != address(0) ? address(d.ignition) : d.operator;
    }

    /// @notice Every pool's founder record: Ignition's, else the TestnetFounders stand-in.
    function _foundersSlot(Deployment memory d) internal pure returns (address) {
        return address(d.ignition) != address(0) ? address(d.ignition) : address(d.founders);
    }

    function _deployPools(Plan memory pl, Deployment memory d) internal {
        bool[4] memory isLp = [P.FORGE_POOL_0_IS_LP, P.FORGE_POOL_1_IS_LP, P.FORGE_POOL_2_IS_LP, P.FORGE_POOL_3_IS_LP];
        for (uint256 i; i < 4; ++i) {
            // Only the LP pools take Flow's fee-free same-route stake (spec v5.5 §4; ADR 0016) and
            // the compounder's source-lot additions (ADR 0017): the operator stands in for the
            // unbuilt compounder, as it does for Flow's.
            address flow = isLp[i] ? pl.flow : address(0);
            address compounder = isLp[i] ? d.operator : address(0);
            // Kindling's LP is EMBER/USDC, pool 0's receipt (spec v5.5 §3): Kindling or its stand-in.
            // Every pool reads the same founder record for First Flame (ADR 0018).
            address kindling = _kindlingSlot(d, i);
            // Ignition grants the head start (ADR 0019) and keeps the founder record (ADR 0018) on
            // every pool; without it the operator and the TestnetFounders stand-in do.
            // The Vent collects every pool's fees (ADR 0020).
            // Every argument is static, so the two halves concatenate to the full encoding.
            bytes memory args = bytes.concat(
                abi.encode(d.stake[i], isLp[i], pl.vent, pl.boost, d.operator),
                abi.encode(flow, compounder, kindling, _foundersSlot(d), _ignitionSlot(d))
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
    ///         before or after the pairs. Its Hearth is the real Hearth (ADR 0025), and its stakers'
    ///         and Quote-yield recipients are the epoch splitters (ADR 0024); the operator stands in
    ///         for the Treasury, the Deed market and the compounder.
    function _deployVent(Plan memory pl, Deployment memory d) internal {
        IVentFeePool[4] memory pools;
        for (uint256 i; i < 4; ++i) pools[i] = IVentFeePool(pl.pool[i]);
        IVentPair[2] memory pairs = [IVentPair(pl.pair[0]), IVentPair(pl.pair[1])];
        address op = d.operator;
        bytes memory args = abi.encode(IERC20(pl.ember), IVentMantle(pl.mantle), pools, pairs, pl.hearth, op, pl.stayers, pl.quoteYield, op, op);
        d.vent = Vent(_create3(pl, "Vent", pl.vent, abi.encodePacked(type(Vent).creationCode, args)));
    }

    /// @notice The real Kindling (ADR 0021): the sink, then the escrow naming Kindling's predicted
    ///         address, then Kindling, which reads only the escrow and USDC's decimals. The operator
    ///         is the escrow's Treasury.
    function _deployKindling(Plan memory pl, Deployment memory d, uint256 start) internal {
        d.sink = PermanentLiquidity(
            _create3(pl, "PermanentLiquidity", pl.sink, type(PermanentLiquidity).creationCode)
        );
        bytes memory args = abi.encode(d.pairQuote[0], pl.kindling, d.operator);
        d.escrow = GenesisFeeEscrow(
            _create3(pl, "GenesisFeeEscrow", pl.escrow, abi.encodePacked(type(GenesisFeeEscrow).creationCode, args))
        );
        args = abi.encode(
            d.pairQuote[0],
            IERC20(pl.ember),
            IKindlingMantle(pl.mantle),
            IKindlingPair(pl.pair[0]),
            IKindlingPool(pl.pool[0]),
            d.escrow,
            address(d.sink),
            start
        );
        d.kindling = Kindling(_create3(pl, "Kindling", pl.kindling, abi.encodePacked(type(Kindling).creationCode, args)));
    }

    /// @notice ASH (ADR 0022): the token names its ledger and the ledger its recipients, all by
    ///         address. ForgeAsh (ADR 0024) receives the Forge's vesting; the operator stands in for
    ///         Ignition unless it is real; the Kindling bonus is real with the real Kindling.
    function _deployAsh(Plan memory pl, Deployment memory d) internal {
        d.ash = AshToken(_create3(pl, "AshToken", pl.ash, abi.encodePacked(type(AshToken).creationCode, abi.encode(pl.ashLedger))));
        address bonus = d.kindlingLive ? pl.ashBonus : d.operator;
        bytes memory args = abi.encode(IAshMint(pl.ash), _ignitionSlot(d), bonus, pl.forgeAsh, d.start);
        d.ashLedger = AshLedger(_create3(pl, "AshLedger", pl.ashLedger, abi.encodePacked(type(AshLedger).creationCode, args)));
        if (d.kindlingLive) {
            args = abi.encode(IKindlingBonusView(address(d.kindling)), ERC20Burnable(pl.ash), IAshBonusLedger(pl.ashLedger));
            d.ashBonus = KindlingAshBonus(
                _create3(pl, "KindlingAshBonus", pl.ashBonus, abi.encodePacked(type(KindlingAshBonus).creationCode, args))
            );
        }
    }

    /// @notice The real Ignition (ADR 0023). It stores addresses only. It farms tUSDC (BlastPool's
    ///         quote), tWETH (SmelterPool's) and tWBTC; the WETH/USDC LP stays unbound, and its
    ///         weight goes to the other three. The operator is its Treasury.
    function _deployIgnition(Plan memory pl, Deployment memory d, uint256 start) internal {
        Ignition.Config memory c;
        (c.usdc, c.weth, c.wbtc, c.lp) = (d.pairQuote[0], d.pairQuote[1], d.wbtc, IERC20(address(0)));
        (c.ash, c.ledger, c.treasury) = (ERC20Burnable(pl.ash), IIgnitionLedger(pl.ashLedger), d.operator);
        (c.coldStorage, c.lpPool, c.blastPool) = (ForgePool(pl.pool[3]), ForgePool(pl.pool[0]), IIgnitionPair(pl.pair[0]));
        (c.kindling, c.start) = (IIgnitionKindling(pl.kindling), start);
        d.ignition = Ignition(_create3(pl, "Ignition", pl.ignition, abi.encodePacked(type(Ignition).creationCode, abi.encode(c))));
    }

    /// @notice The epoch splitters (ADR 0024). Each stores ForgeEmissions' predicted address and
    ///         reads it only when paying, so they deploy before it.
    function _deploySplitters(Plan memory pl, Deployment memory d) internal {
        IEpochMeasures m = IEpochMeasures(pl.emissions);
        bytes memory args = abi.encode(m, IERC20(pl.ash), IAshForgeLedger(pl.ashLedger));
        d.forgeAsh = ForgeAsh(_create3(pl, "ForgeAsh", pl.forgeAsh, abi.encodePacked(type(ForgeAsh).creationCode, args)));
        args = abi.encode(m, EpochSplitter.Measure.Stake);
        d.stayers = BookedSplitter(_create3(pl, "Stayers", pl.stayers, abi.encodePacked(type(BookedSplitter).creationCode, args)));
        args = abi.encode(m, EpochSplitter.Measure.Ashfall);
        d.quoteYield =
            BookedSplitter(_create3(pl, "QuoteYield", pl.quoteYield, abi.encodePacked(type(BookedSplitter).creationCode, args)));
        args = abi.encode(m, IERC20(pl.ember));
        d.sealedPot = SealedPotStream(
            _create3(pl, "SealedPotStream", pl.sealedPot, abi.encodePacked(type(SealedPotStream).creationCode, args))
        );
    }

    /// @notice The Hearth (ADR 0025): staked test ASH earns the Vent's Hearth share in its fee
    ///         assets, EMBER and each pair's quote. It stores addresses only. The operator is its
    ///         Treasury, for batches booked while nothing is staked.
    function _deployHearth(Plan memory pl, Deployment memory d) internal {
        address[] memory assets = new address[](3);
        (assets[0], assets[1], assets[2]) = (pl.ember, address(d.pairQuote[0]), address(d.pairQuote[1]));
        bytes memory args = abi.encode(IERC20(pl.ash), d.operator, assets);
        d.hearth = Hearth(_create3(pl, "Hearth", pl.hearth, abi.encodePacked(type(Hearth).creationCode, args)));
    }

    function _deployEmissionsAndBoost(Plan memory pl, Deployment memory d) internal {
        bytes memory args =
            abi.encode(IMantleDistribution(pl.mantle), IERC20(pl.ember), d.pools, pl.boost, d.operator, pl.sealedPot);
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
        if (d.mantle.KINDLING() != (d.kindlingLive ? address(d.kindling) : d.operator)) revert Miswired("Mantle.KINDLING");
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
            if (p.KINDLING() != _kindlingSlot(d, i)) revert Miswired("pool KINDLING");
            if (p.FOUNDERS() != _foundersSlot(d)) revert Miswired("pool FOUNDERS");
            if (p.IGNITION() != _ignitionSlot(d)) revert Miswired("pool IGNITION");
            if (p.FEE_COLLECTOR() != address(d.vent)) revert Miswired("pool FEE_COLLECTOR");
        }
        Vent v = d.vent;
        if (address(v.EMBER()) != address(d.ember) || address(v.MANTLE()) != address(d.mantle)) revert Miswired("Vent core");
        if (address(v.POOL_0()) != address(d.pools[0]) || address(v.POOL_1()) != address(d.pools[1])) revert Miswired("Vent pools");
        if (address(v.POOL_2()) != address(d.pools[2]) || address(v.POOL_3()) != address(d.pools[3])) revert Miswired("Vent pools");
        if (address(v.PAIR_0()) != address(d.pairs[0]) || address(v.PAIR_1()) != address(d.pairs[1])) revert Miswired("Vent pairs");
        if (v.HEARTH() != address(d.hearth) || v.TREASURY() != d.operator || v.STAKERS() != address(d.stayers)) revert Miswired("Vent recipients");
        if (v.QUOTE_YIELD() != address(d.quoteYield) || v.DEEDS() != d.operator || v.COMPOUNDER() != d.operator) revert Miswired("Vent slots");
        Flow f = d.flow;
        if (address(f.PAIR0()) != address(d.pairs[0]) || address(f.PAIR1()) != address(d.pairs[1])) revert Miswired("Flow pairs");
        if (address(f.POOL0()) != address(d.pools[0]) || address(f.POOL1()) != address(d.pools[1])) revert Miswired("Flow pools");
        if (address(f.EMBER()) != address(d.ember) || address(f.REBATES()) != address(d.rebates)) revert Miswired("Flow tokens");
        if (f.COMPOUNDER() != d.operator) revert Miswired("Flow compounder");
        if (d.kindlingLive) _checkKindling(d);
        _checkAsh(d);
        if (d.ignitionLive) _checkIgnition(d);
        _checkSplitters(d);
        _checkHearth(d);
    }

    function _checkHearth(Deployment memory d) internal view {
        Hearth h = d.hearth;
        if (address(h.ASH()) != address(d.ash) || h.TREASURY() != d.operator || h.ASSET_COUNT() != 3) revert Miswired("Hearth");
        if (h.assetAt(0) != address(d.ember) || h.assetAt(1) != address(d.pairQuote[0]) || h.assetAt(2) != address(d.pairQuote[1])) {
            revert Miswired("Hearth assets");
        }
    }

    function _checkSplitters(Deployment memory d) internal view {
        if (d.emissions.SEALED_POT() != address(d.sealedPot)) revert Miswired("ForgeEmissions.SEALED_POT");
        EpochSplitter[4] memory s = [EpochSplitter(d.forgeAsh), d.stayers, d.quoteYield, d.sealedPot];
        EpochSplitter.Measure[4] memory m = [
            EpochSplitter.Measure.Ordinary,
            EpochSplitter.Measure.Stake,
            EpochSplitter.Measure.Ashfall,
            EpochSplitter.Measure.Conviction
        ];
        for (uint256 i; i < 4; ++i) {
            if (address(s[i].EMISSIONS()) != address(d.emissions) || s[i].MEASURE() != m[i]) revert Miswired("splitter");
        }
        if (address(d.forgeAsh.ASH()) != address(d.ash) || address(d.forgeAsh.LEDGER()) != address(d.ashLedger)) revert Miswired("ForgeAsh");
        if (address(d.sealedPot.EMBER()) != address(d.ember)) revert Miswired("SealedPotStream");
        // ForgeAsh slices the ledger's curve on ForgeEmissions' clock: the two must start together.
        if (d.ashLedger.START() != d.emissions.START()) revert Miswired("ASH vesting and epoch clocks");
    }

    function _checkIgnition(Deployment memory d) internal view {
        Ignition g = d.ignition;
        if (address(g.USDC()) != address(d.pairQuote[0]) || address(g.WETH()) != address(d.pairQuote[1])) revert Miswired("Ignition tokens");
        if (address(g.WBTC()) != address(d.wbtc) || address(g.LP()) != address(0)) revert Miswired("Ignition WBTC and LP");
        if (address(g.ASH()) != address(d.ash) || address(g.LEDGER()) != address(d.ashLedger)) revert Miswired("Ignition ASH");
        if (address(g.COLD_STORAGE()) != address(d.pools[3]) || address(g.LP_POOL()) != address(d.pools[0])) revert Miswired("Ignition pools");
        if (address(g.BLASTPOOL()) != address(d.pairs[0]) || address(g.KINDLING()) != address(d.kindling)) revert Miswired("Ignition venue");
        if (g.TREASURY() != d.operator) revert Miswired("Ignition Treasury");
        // Kindling opens only after Ignition's free-exit window (spec v5.5 §2, §3).
        if (d.kindling.START() < g.END() + P.IGNITION_EXIT_WINDOW) revert Miswired("Kindling before Ignition's exit window");
    }

    function _checkAsh(Deployment memory d) internal view {
        AshLedger l = d.ashLedger;
        if (d.ash.LEDGER() != address(l) || address(l.TOKEN()) != address(d.ash)) revert Miswired("ASH ledger");
        if (l.IGNITION() != _ignitionSlot(d) || l.FORGE() != address(d.forgeAsh) || l.START() != d.start) revert Miswired("ASH recipients");
        if (l.KINDLING_BONUS() != (d.kindlingLive ? address(d.ashBonus) : d.operator)) revert Miswired("ASH bonus slot");
        if (d.kindlingLive) {
            KindlingAshBonus b = d.ashBonus;
            if (address(b.KINDLING()) != address(d.kindling) || address(b.ASH()) != address(d.ash)) revert Miswired("bonus");
            if (address(b.LEDGER()) != address(l)) revert Miswired("bonus ledger");
        }
    }

    function _checkKindling(Deployment memory d) internal view {
        Kindling k = d.kindling;
        if (address(k.USDC()) != address(d.pairQuote[0]) || address(k.EMBER()) != address(d.ember)) revert Miswired("Kindling tokens");
        if (address(k.MANTLE()) != address(d.mantle) || address(k.PAIR()) != address(d.pairs[0])) revert Miswired("Kindling venue");
        if (address(k.POOL()) != address(d.pools[0]) || address(k.SINK()) != address(d.sink)) revert Miswired("Kindling pool and sink");
        GenesisFeeEscrow e = d.escrow;
        if (address(k.ESCROW()) != address(e) || e.EVENT() != address(k)) revert Miswired("Kindling escrow");
        if (address(e.QUOTE()) != address(d.pairQuote[0]) || e.TREASURY() != d.operator) revert Miswired("escrow slots");
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
        if (d.ignitionLive && block.timestamp >= d.ignition.START() && block.timestamp < d.ignition.END()) {
            // Ignition is open: farm 1,000 tUSDC (auto-staked into Cold Storage at close) and
            // 0.1 tWBTC.
            usdc.approve(address(d.ignition), type(uint256).max);
            d.ignition.deposit(0, 1_000e6, false);
            TestnetToken(address(d.wbtc)).mint(actor, 1e8);
            d.wbtc.approve(address(d.ignition), type(uint256).max);
            d.ignition.deposit(2, 0.1e8, false);
        }
        if (d.kindlingLive) {
            // No EMBER exists before Kindling settles: contribute the wallet cap to the genesis
            // event instead. Its minimum needs at least four such wallets (KindlingSettle).
            if (block.timestamp >= d.kindling.START() && block.timestamp < d.kindling.END()) {
                usdc.approve(address(d.kindling), type(uint256).max);
                d.kindling.contribute(d.kindling.WALLET_CAP());
            }
        } else if (actor == d.operator) {
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
        // The operator, standing in for Ignition, takes Ignition's 41,000 test ASH (ADR 0022).
        if (actor == d.operator && !d.ignitionLive) {
            d.ashLedger.releaseIgnition();
            // ...and stakes 1,000 of it in the Hearth, which then earns the Vent's Hearth share (ADR 0025).
            IERC20(address(d.ash)).approve(address(d.hearth), 1_000e18);
            d.hearth.stake(1_000e18);
        }
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
///         stand-ins), FURNACE_TESTNET_PAIRS=later (leave the EMBER pairs for DeployTestnetPairs),
///         FURNACE_TESTNET_KINDLING=1 (the real Kindling, escrow and sink; KindlingSettle ends it)
///         with FURNACE_TESTNET_KINDLING_START (default: the Mantle START),
///         FURNACE_TESTNET_IGNITION=1 (the real Ignition before it, with Kindling; IgnitionClose
///         closes it) with FURNACE_TESTNET_IGNITION_START (default: now; Kindling and the Mantle
///         then default to its free-exit window's end), and FURNACE_TESTNET_SMOKE=1 (also run the
///         smoke actions).
contract DeployTestnet is Script, FurnaceTestnet {
    function run() external returns (Deployment memory d) {
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        Options memory o;
        o.operator = vm.envOr("FURNACE_TESTNET_OPERATOR", deployer);
        o.version = vm.envOr("FURNACE_TESTNET_SALT_VERSION", string("1"));
        o.ignition = vm.envOr("FURNACE_TESTNET_IGNITION", false);
        o.ignitionStart = vm.envOr("FURNACE_TESTNET_IGNITION_START", block.timestamp);
        // With Ignition, genesis continues where its free-exit window ends.
        uint256 genesis = o.ignition ? o.ignitionStart + P.IGNITION_DURATION + P.IGNITION_EXIT_WINDOW : block.timestamp;
        o.start = vm.envOr("FURNACE_TESTNET_START", genesis);
        o.usdc = vm.envOr("FURNACE_TESTNET_USDC", address(0));
        o.weth = vm.envOr("FURNACE_TESTNET_WETH", address(0));
        o.pairsNow = keccak256(bytes(vm.envOr("FURNACE_TESTNET_PAIRS", string("now")))) != keccak256("later");
        o.kindling = vm.envOr("FURNACE_TESTNET_KINDLING", o.ignition);
        o.kindlingStart = vm.envOr("FURNACE_TESTNET_KINDLING_START", o.ignition ? genesis : o.start);
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
        if (d.kindlingLive) {
            console2.log("Kindling         ", address(d.kindling));
            console2.log("  opens / closes ", d.kindling.START(), d.kindling.END());
            console2.log("GenesisFeeEscrow ", address(d.escrow));
            console2.log("PermanentLiquidity", address(d.sink));
        } else {
            console2.log("Kindling: the operator stands in (FURNACE_TESTNET_KINDLING=1 deploys it)");
        }
        console2.log("AshToken         ", address(d.ash));
        console2.log("AshLedger        ", address(d.ashLedger));
        if (d.kindlingLive) console2.log("KindlingAshBonus ", address(d.ashBonus));
        if (d.ignitionLive) {
            console2.log("Ignition         ", address(d.ignition));
            console2.log("  opens / closes ", d.ignition.START(), d.ignition.END());
            console2.log("  tWBTC          ", address(d.wbtc));
        } else {
            console2.log("Ignition: the operator stands in (FURNACE_TESTNET_IGNITION=1 deploys it)");
        }
        console2.log("ForgeAsh         ", address(d.forgeAsh));
        console2.log("Stayers          ", address(d.stayers));
        console2.log("QuoteYield       ", address(d.quoteYield));
        console2.log("SealedPotStream  ", address(d.sealedPot));
        console2.log("Hearth           ", address(d.hearth));
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
        vm.serializeBool(k, "kindlingLive", d.kindlingLive);
        vm.serializeAddress(k, "Kindling", address(d.kindling));
        vm.serializeAddress(k, "GenesisFeeEscrow", address(d.escrow));
        vm.serializeAddress(k, "PermanentLiquidity", address(d.sink));
        vm.serializeAddress(k, "AshToken", address(d.ash));
        vm.serializeAddress(k, "AshLedger", address(d.ashLedger));
        vm.serializeAddress(k, "KindlingAshBonus", address(d.ashBonus));
        vm.serializeBool(k, "ignitionLive", d.ignitionLive);
        vm.serializeAddress(k, "Ignition", address(d.ignition));
        vm.serializeAddress(k, "IgnitionWbtc", address(d.wbtc));
        vm.serializeAddress(k, "ForgeAsh", address(d.forgeAsh));
        vm.serializeAddress(k, "Stayers", address(d.stayers));
        vm.serializeAddress(k, "QuoteYield", address(d.quoteYield));
        vm.serializeAddress(k, "SealedPotStream", address(d.sealedPot));
        vm.serializeAddress(k, "Hearth", address(d.hearth));
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
        // Older manifests predate Kindling: the operator stood in.
        if (vm.keyExistsJson(json, ".Kindling")) d.kindling = Kindling(vm.parseJsonAddress(json, ".Kindling"));
        Plan memory pl = _plan(d.deployer, d.saltVersion);
        if (address(d.kindling) != address(0) && address(d.kindling) != pl.kindling) revert Miswired("manifest Kindling");
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

/// @notice Ends the real testnet Kindling once its 24 h are over (ADR 0021): `forge script
///         contracts/script/DeployTestnet.s.sol:KindlingSettle --rpc-url liteforge --broadcast
///         --account <any keystore>`. Anyone may run it. It settles when the event can (the caller
///         earns the close bounty) and fails it when it must, then claims the caller's own
///         entitlement (a pool 0 position) or refund. Reads `deployments/testnet-<chain id>.json`.
contract KindlingSettle is Script {
    error NoKindling();

    function run() external returns (Kindling.Status status) {
        string memory json = vm.readFile(_manifestPath());
        if (!vm.keyExistsJson(json, ".Kindling")) revert NoKindling();
        Kindling k = Kindling(vm.parseJsonAddress(json, ".Kindling"));
        if (address(k) == address(0)) revert NoKindling();
        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        status = k.status();
        if (status == Kindling.Status.Live) {
            if (block.timestamp < k.END()) {
                console2.log("Kindling is open until", k.END());
            } else if (k.accepted() < k.MIN_RAISE() || block.timestamp >= k.SETTLE_DEADLINE()) {
                k.fail();
            } else if (k.venueCheck() == Kindling.Venue.None) {
                k.settle();
            } else {
                // BlastPool not deployed yet, or the wrong one: settlement waits, never forced.
                console2.log("Kindling waits on its venue, reason", uint256(k.venueCheck()));
            }
            status = k.status();
        }
        if (status == Kindling.Status.Settled && k.entitlementOf(me) != 0) k.materialize(me);
        if (status == Kindling.Status.Failed && k.refundableOf(me) != 0) k.refund(me);
        vm.stopBroadcast();
        console2.log("Kindling status (0 live, 1 settled, 2 failed)", uint256(status));
        console2.log("accepted gross   ", k.accepted());
        console2.log("closedAt         ", k.closedAt());
    }
}

/// @notice Closes the real testnet Ignition (ADR 0023): `forge script
///         contracts/script/DeployTestnet.s.sol:IgnitionClose --rpc-url liteforge --broadcast
///         --account <any keystore>`. Anyone may run it. From END it finalizes the farm (taking the
///         41,000 test ASH and burning what accrued to nobody) and claims the caller's ASH; after
///         the free-exit window it also stakes the caller's USDC into Cold Storage, unless the
///         caller opted out. Reads `deployments/testnet-<chain id>.json`.
contract IgnitionClose is Script {
    error NoIgnition();

    function run() external returns (uint256 claimed, uint256 positionId) {
        string memory json = vm.readFile(_manifestPath());
        if (!vm.keyExistsJson(json, ".Ignition")) revert NoIgnition();
        Ignition g = Ignition(vm.parseJsonAddress(json, ".Ignition"));
        if (address(g) == address(0)) revert NoIgnition();
        vm.startBroadcast();
        (, address me,) = vm.readCallers();
        if (block.timestamp < g.END()) {
            console2.log("Ignition is open until", g.END());
        } else {
            if (!g.finalized()) g.finalize();
            if (g.pending(me) != 0) claimed = g.claim(me);
            (bool optedOut,,,,,) = g.wallets(me);
            if (block.timestamp >= g.END() + P.IGNITION_EXIT_WINDOW && !optedOut && g.accountOf(me, 0).principal != 0) {
                (positionId,) = g.stakeUsdc(me);
            }
        }
        vm.stopBroadcast();
        console2.log("ASH burned at close", g.burned());
        console2.log("ASH claimed       ", claimed);
        console2.log("Cold Storage position", positionId);
    }
}
