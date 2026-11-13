// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FurnaceParams as P} from "../../src/generated/FurnaceParams.sol";
import {MockBurnableERC20} from "./VentMocks.sol";

/// @dev Test-only quote token with any decimals and open minting.
contract MockQuote is ERC20 {
    uint8 internal immutable DECIMALS;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return DECIMALS;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev A quote that keeps 1% of every transferFrom: Kindling must refuse it.
contract MockFeeOnTransferQuote is MockQuote {
    constructor() MockQuote("Taxed USD", "tUSD", 6) {}

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 tax = amount / 100;
        _burn(from, tax);
        return super.transferFrom(from, to, amount - tax);
    }
}

/// @dev A quote that calls back into `target` with `data` on every transferFrom (a hook token).
contract MockCallbackQuote is MockQuote {
    address public target;
    bytes public data;
    bool public lastOk;
    bytes public lastRet;

    constructor() MockQuote("Hook USD", "hUSD", 6) {}

    function arm(address target_, bytes calldata data_) external {
        (target, data) = (target_, data_);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (target != address(0)) {
            address t = target;
            target = address(0);
            (lastOk, lastRet) = t.call(data);
        }
        return super.transferFrom(from, to, amount);
    }
}

/// @dev Test-only Mantle: the one-time Kindling seed, minted to KINDLING once. `amount` lets a
///      test mint the wrong seed.
contract MockKindlingMantle {
    MockBurnableERC20 public immutable EMBER;
    address public immutable KINDLING;
    uint256 public immutable AMOUNT;
    bool public seedMinted;

    error NotKindling();
    error SeedAlreadyMinted();

    constructor(MockBurnableERC20 ember, address kindling, uint256 amount) {
        (EMBER, KINDLING, AMOUNT) = (ember, kindling, amount);
    }

    function mintKindlingSeed() external {
        if (msg.sender != KINDLING) revert NotKindling();
        if (seedMinted) revert SeedAlreadyMinted();
        seedMinted = true;
        EMBER.mint(KINDLING, AMOUNT);
    }
}

/// @dev Test-only Forge pool 0: `openKindling` as ForgePool's, the standard deposit fee and the LP
///      minimum included, with the positions recorded per owner.
contract MockKindlingPool {
    using SafeERC20 for IERC20;

    IERC20 public immutable STAKE_TOKEN;
    address public immutable KINDLING;
    uint256 public positionCount;
    uint256 public feesBooked;
    mapping(address => uint256) public stakedOf;
    mapping(uint256 => address) public ownerOf;

    error NotKindling();
    error BelowMinimum(uint256 net);
    error NonStandardToken();

    constructor(IERC20 stakeToken, address kindling) {
        (STAKE_TOKEN, KINDLING) = (stakeToken, kindling);
    }

    function openKindling(address owner, uint256 amount) external returns (uint256 id) {
        if (msg.sender != KINDLING) revert NotKindling();
        uint256 before = STAKE_TOKEN.balanceOf(address(this));
        STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        if (STAKE_TOKEN.balanceOf(address(this)) - before != amount) revert NonStandardToken();
        uint256 fee = (amount * P.FORGE_DEPOSIT_FEE_PCT) / 100;
        uint256 net = amount - fee;
        if (net < P.MIN_STAKE_LP) revert BelowMinimum(net);
        feesBooked += fee;
        stakedOf[owner] += net;
        id = ++positionCount;
        ownerOf[id] = owner;
    }
}

/// @dev A stand-in venue whose every answer a test sets, for the venue checks.
contract MockVenuePair {
    IERC20 public EMBER;
    IERC20 public QUOTE;
    address public INITIALIZER;
    uint256 public totalSupply;
    uint112 internal _e;
    uint112 internal _q;

    constructor(IERC20 ember, IERC20 quote, address initializer) {
        (EMBER, QUOTE, INITIALIZER) = (ember, quote, initializer);
    }

    function set(uint256 supply, uint112 e, uint112 q) external {
        (totalSupply, _e, _q) = (supply, e, q);
    }

    function wire(IERC20 ember, IERC20 quote, address initializer) external {
        (EMBER, QUOTE, INITIALIZER) = (ember, quote, initializer);
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (_e, _q, 0);
    }
}

/// @dev A stand-in pool whose wiring a test sets.
contract MockVenuePool {
    IERC20 public STAKE_TOKEN;
    address public KINDLING;

    constructor(IERC20 stakeToken, address kindling) {
        (STAKE_TOKEN, KINDLING) = (stakeToken, kindling);
    }

    function wire(IERC20 stakeToken, address kindling) external {
        (STAKE_TOKEN, KINDLING) = (stakeToken, kindling);
    }
}
