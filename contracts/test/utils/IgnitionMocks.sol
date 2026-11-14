// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FurnaceParams as P} from "../../src/generated/FurnaceParams.sol";

/// @dev A stand-in Cold Storage (Forge pool 3) for the model replay: `openIgnition` pulls exactly,
///      books the standard deposit fee and opens a position, with a USDC pool's minimum (one unit).
contract MockColdStorage {
    using SafeERC20 for IERC20;

    IERC20 public immutable STAKE_TOKEN;
    address public immutable IGNITION;
    uint256 public positionCount;
    uint256 public feesBooked;
    mapping(address => uint256) public stakedOf;
    mapping(address => uint256) public positionsOf;
    mapping(uint256 => address) public ownerOf;

    error NotIgnition();
    error BelowMinimum(uint256 net);
    error NonStandardToken();

    constructor(IERC20 stakeToken, address ignition) {
        (STAKE_TOKEN, IGNITION) = (stakeToken, ignition);
    }

    function openIgnition(address owner, uint256 amount) external returns (uint256 id) {
        if (msg.sender != IGNITION) revert NotIgnition();
        uint256 before = STAKE_TOKEN.balanceOf(address(this));
        STAKE_TOKEN.safeTransferFrom(msg.sender, address(this), amount);
        if (STAKE_TOKEN.balanceOf(address(this)) - before != amount) revert NonStandardToken();
        uint256 fee = (amount * P.FORGE_DEPOSIT_FEE_PCT) / 100;
        uint256 net = amount - fee;
        if (net == 0) revert BelowMinimum(net);
        feesBooked += fee;
        stakedOf[owner] += net;
        ++positionsOf[owner];
        id = ++positionCount;
        ownerOf[id] = owner;
    }
}

/// @dev Kindling as Ignition reads it: only `closedAt`, set by the test.
contract MockClosedAt {
    uint256 public closedAt;

    function setClosedAt(uint256 t) external {
        closedAt = t;
    }
}
