// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FurnaceParams as P} from "../../src/generated/FurnaceParams.sol";

/// @dev Test-only EMBER: 18 decimals, open minting, burnable.
contract MockBurnableERC20 is ERC20Burnable {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Test-only Mantle: the registered burn, at the Protocol rate, for registrars set by tests.
contract MockMantle {
    ERC20Burnable public immutable EMBER;
    mapping(address => uint8) public registrarCategory;
    uint256 public burned;
    uint256 public credited;

    constructor(ERC20Burnable ember) {
        EMBER = ember;
    }

    function register(address registrar) external {
        registrarCategory[registrar] = 1;
    }

    function burnRegistered(uint256 amount) external returns (uint256 credit) {
        require(registrarCategory[msg.sender] == 1, "not a registrar");
        EMBER.burnFrom(msg.sender, amount);
        credit = (amount * P.RECYCLE_PROTOCOL_BURN_PCT) / 100;
        (burned, credited) = (burned + amount, credited + credit);
    }
}

/// @dev Test-only Forge pool fee ledgers, collected as ForgePool's are.
contract MockFeePool {
    using SafeERC20 for IERC20;

    IERC20 public immutable STAKE_TOKEN;
    address public immutable FEE_COLLECTOR;
    uint256[3] public fees;

    constructor(IERC20 stakeToken, address feeCollector) {
        (STAKE_TOKEN, FEE_COLLECTOR) = (stakeToken, feeCollector);
    }

    /// @dev Book `amount` of kind 0 (deposit), 1 (withdrawal) or 2 (emergency), pulled from the caller.
    function book(uint256 kind, uint256 amount) external {
        STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        fees[kind] += amount;
    }

    function collectFees() external returns (uint256 dep, uint256 wd, uint256 em) {
        require(msg.sender == FEE_COLLECTOR, "not the collector");
        (dep, wd, em) = (fees[0], fees[1], fees[2]);
        delete fees;
        STAKE_TOKEN.safeTransfer(FEE_COLLECTOR, dep + wd + em);
    }
}
