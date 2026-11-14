// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockERC20} from "./MockERC20.sol";
import {Vent} from "../../src/vent/Vent.sol";

/// @dev ForgeEmissions' Cast ledger as the Compounder sees it, with the same consumer rules
///      (`takeCast` once, never more than the share, the rest back to unclaimed), fed by the test:
///      it credits shares into open pool-epochs and settles them once each epoch has ended.
contract MockCastLedger {
    MockERC20 public immutable EMBER;
    uint256 public immutable START;
    address public consumer;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) public share;
    mapping(uint256 => mapping(uint256 => uint256)) public demand;
    mapping(uint256 => mapping(uint256 => bool)) public done;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => bool))) public castTaken;
    mapping(uint256 => mapping(uint256 => uint256)) public unclaimed;
    uint256 public forfeits;

    error Settled();
    error Early();
    error NotConsumer(address caller);
    error NothingToCast(uint256 epoch, uint256 pool, uint256 id);
    error AlreadyCast(uint256 epoch, uint256 pool, uint256 id);
    error CastExceeded(uint256 used, uint256 cast);

    constructor(MockERC20 ember, uint256 start) {
        (EMBER, START) = (ember, start);
    }

    function setConsumer(address c) external {
        require(consumer == address(0));
        consumer = c;
    }

    function credit(uint256 e, uint256 i, uint256 id, uint256 amount) external {
        if (done[e][i]) revert Settled();
        EMBER.mint(address(this), amount);
        share[e][i][id] += amount;
        demand[e][i] += amount;
    }

    function settle(uint256 e, uint256 i) external {
        if (block.timestamp < START + (e + 1) * 1 days) revert Early();
        done[e][i] = true;
    }

    function forfeit(uint256 amount) external {
        EMBER.mint(address(this), amount);
        forfeits += amount;
    }

    function castOf(uint256 e, uint256 i, uint256 id) public view returns (uint256) {
        return done[e][i] ? share[e][i][id] : 0;
    }

    function castDemand(uint256 e, uint256 i) external view returns (uint256, bool) {
        return (demand[e][i], done[e][i]);
    }

    function takeCast(uint256 e, uint256 i, uint256 id, uint256 used) external returns (uint256 c) {
        if (msg.sender != consumer) revert NotConsumer(msg.sender);
        c = castOf(e, i, id);
        if (c == 0) revert NothingToCast(e, i, id);
        if (castTaken[e][i][id]) revert AlreadyCast(e, i, id);
        if (used > c) revert CastExceeded(used, c);
        castTaken[e][i][id] = true;
        unclaimed[i][id] += c - used;
        if (used != 0) EMBER.transfer(msg.sender, used);
    }

    function takeMatchReserve() external returns (uint256 amount) {
        if (msg.sender != consumer) revert NotConsumer(msg.sender);
        amount = forfeits;
        forfeits = 0;
        if (amount != 0) EMBER.transfer(msg.sender, amount);
    }
}

/// @dev The Vent's liquidity lane per pair, funded by the test, drawn only by the consumer.
contract MockMatchVent {
    MockERC20[2] internal quotes;
    uint128[2] public lanes;
    address public consumer;

    error NotCompounder();
    error ExceedsReserve(uint256 amount, uint256 reserve);

    constructor(MockERC20 q0, MockERC20 q1) {
        quotes = [q0, q1];
    }

    function setConsumer(address c) external {
        require(consumer == address(0));
        consumer = c;
    }

    function fund(uint256 j, uint256 amount) external {
        quotes[j].mint(address(this), amount);
        lanes[j] += uint128(amount);
    }

    function lane(uint256 j) external view returns (Vent.Lane memory l) {
        l.matchReserve = lanes[j];
    }

    function drawMatchReserve(uint256 j, uint256 amount) external {
        if (msg.sender != consumer) revert NotCompounder();
        if (amount > lanes[j]) revert ExceedsReserve(amount, lanes[j]);
        lanes[j] -= uint128(amount);
        IERC20(address(quotes[j])).transfer(msg.sender, amount);
    }
}
