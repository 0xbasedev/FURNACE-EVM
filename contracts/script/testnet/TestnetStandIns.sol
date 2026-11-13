// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IValuation, IPyreLedger} from "../../src/forge/Boost.sol";
import {IFeeRebate} from "../../src/flow/Flow.sol";
import {IFounders} from "../../src/forge/ForgePoolBase.sol";

// TESTNET ONLY. These contracts stand in for modules that are not built, or not deployed on the
// target testnet, so the built core (EMBER, the Mantle, ForgePool, ForgeEmissions, Boost) can be
// exercised end to end. None of them is part of a canonical deployment, none is audited, and
// none may be deployed on a chain where assets have value: DeployTestnet refuses any chain id
// outside its testnet list. See docs/testnet/litvm-liteforge.md.

/// @notice A freely mintable ERC20 standing in for an asset with no deployment on the testnet:
///         the LP receipts of the unbuilt BlastPool and SmelterPool, and USDC. Anyone may mint
///         up to FAUCET_CAP per call. It has no value.
contract TestnetToken is ERC20 {
    uint8 private immutable DECIMALS;
    uint256 public immutable FAUCET_CAP;

    error AboveFaucetCap(uint256 amount, uint256 cap);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint256 faucetCap)
        ERC20(name_, symbol_)
    {
        (DECIMALS, FAUCET_CAP) = (decimals_, faucetCap);
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        if (amount > FAUCET_CAP) revert AboveFaucetCap(amount, FAUCET_CAP);
        _mint(to, amount);
    }
}

/// @notice Stands in for the protected valuation source (ADR 0009), which is not built. The
///         operator sets each pool's EMBER-per-stake rate (RAY per stake-wei) by hand. An unset
///         rate is zero, which gives a zero Capstone bonus. A real source must be a protected
///         checkpoint, never an operator: this one exists only so testers can see Boost raise.
contract TestnetValuation is IValuation {
    address public immutable OPERATOR;
    mapping(uint256 pool => uint256) public rateOf;

    event RateSet(uint256 indexed pool, uint256 rate);

    error NotOperator();

    constructor(address operator) {
        OPERATOR = operator;
    }

    function setRate(uint256 pool, uint256 rate) external {
        if (msg.sender != OPERATOR) revert NotOperator();
        rateOf[pool] = rate;
        emit RateSet(pool, rate);
    }

    function emberPerStake(uint256 pool) external view returns (uint256) {
        return rateOf[pool];
    }
}

/// @notice Stands in for the Relics contract's Pyre ledger, which is not built. The operator
///         records a wallet's cumulative Pyre burns by hand (EMBER-wei); unset wallets have none.
contract TestnetPyreLedger is IPyreLedger {
    address public immutable OPERATOR;
    mapping(address wallet => uint256) public burnedOf;

    event BurnedSet(address indexed wallet, uint256 amount);

    error NotOperator();

    constructor(address operator) {
        OPERATOR = operator;
    }

    function setBurned(address wallet, uint256 amount) external {
        if (msg.sender != OPERATOR) revert NotOperator();
        burnedOf[wallet] = amount;
        emit BurnedSet(wallet, amount);
    }

    function pyreBurned(address wallet) external view returns (uint256) {
        return burnedOf[wallet];
    }
}

/// @notice Stands in for the Relics contract's fee-rebate perk, which is not built. The operator
///         sets a wallet's rebate percent by hand; Flow snaps it down to a configured tier
///         (25 or 50) and treats anything below the first tier as none (ADR 0016).
contract TestnetFeeRebate is IFeeRebate {
    address public immutable OPERATOR;
    mapping(address wallet => uint256) public rebatePctOf;

    event RebateSet(address indexed wallet, uint256 pct);

    error NotOperator();

    constructor(address operator) {
        OPERATOR = operator;
    }

    function setRebate(address wallet, uint256 pct) external {
        if (msg.sender != OPERATOR) revert NotOperator();
        rebatePctOf[wallet] = pct;
        emit RebateSet(wallet, pct);
    }
}

/// @notice Stands in for Ignition's First Flame record, which is not built. The operator marks
///         founder wallets by hand; a pool's `refreshFounder` reads it (ADR 0018).
contract TestnetFounders is IFounders {
    address public immutable OPERATOR;
    mapping(address wallet => bool) public isFounder;

    event FounderMarked(address indexed wallet, bool founder);

    error NotOperator();

    constructor(address operator) {
        OPERATOR = operator;
    }

    function setFounder(address wallet, bool founder) external {
        if (msg.sender != OPERATOR) revert NotOperator();
        isFounder[wallet] = founder;
        emit FounderMarked(wallet, founder);
    }
}
