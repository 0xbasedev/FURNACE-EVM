// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ForgePool} from "../../src/forge/ForgePool.sol";
import {ForgeEmissions} from "../../src/forge/ForgeEmissions.sol";
import {MockERC20} from "./MockERC20.sol";

/// @dev Stands in for ForgeEmissions' settled epochs: a test settles any (epoch, pool) with the
///      measures it chooses, and funds the Sealed pots. The pools are real ForgePools, so owners
///      and listings are read from real storage.
contract MockMeasures {
    uint256 public immutable START;
    ForgePool[4] internal _pools;
    MockERC20 public immutable EMBER;
    address public sealedPot;

    mapping(uint256 => mapping(uint256 => ForgeEmissions.PoolEpoch)) internal _epochs;
    mapping(uint256 => mapping(uint256 => mapping(uint256 => ForgeEmissions.Measure))) internal _measures;
    mapping(uint256 => uint256) public pot;

    error UnknownPool(uint256 pool);
    error NotConsumer(address caller);

    constructor(uint256 start, ForgePool[4] memory pools, MockERC20 ember) {
        (START, _pools, EMBER) = (start, pools, ember);
    }

    function setSealedPot(address who) external {
        sealedPot = who;
    }

    function poolAt(uint256 i) public view returns (ForgePool) {
        if (i >= 4) revert UnknownPool(i);
        return _pools[i];
    }

    /// @dev Settle (epoch, pool): positions 1..ids get these measures; totals are their sums.
    function settle(uint256 epoch, uint256 pool, ForgeEmissions.Measure[] memory m) external {
        ForgeEmissions.PoolEpoch storage pe = _epochs[epoch][pool];
        pe.phase = ForgeEmissions.Phase.Done;
        (pe.stakeSeconds, pe.heatSeconds, pe.candidateSeconds, pe.ashfallWeight) = (0, 0, 0, 0);
        for (uint256 k; k < m.length; ++k) {
            _measures[epoch][pool][k + 1] = m[k];
            pe.stakeSeconds += m[k].stakeSeconds;
            pe.heatSeconds += m[k].heatSeconds;
            pe.candidateSeconds += m[k].candidateSeconds;
            pe.ashfallWeight += m[k].ashfallWeight;
        }
    }

    function poolEpoch(uint256 epoch, uint256 pool) external view returns (ForgeEmissions.PoolEpoch memory) {
        poolAt(pool);
        return _epochs[epoch][pool];
    }

    function measureOf(uint256 epoch, uint256 pool, uint256 id) external view returns (ForgeEmissions.Measure memory) {
        return _measures[epoch][pool][id];
    }

    function fundPot(uint256 pool, uint256 amount) external {
        EMBER.mint(address(this), amount);
        pot[pool] += amount;
    }

    function takeSealedPot(uint256 pool) external returns (uint256 amount) {
        if (msg.sender != sealedPot) revert NotConsumer(msg.sender);
        poolAt(pool);
        amount = pot[pool];
        pot[pool] = 0;
        if (amount != 0) IERC20(address(EMBER)).transfer(msg.sender, amount);
    }
}

/// @dev The measures a seed gives positions 1..3 of pool `i` in epoch `e`: the model's
///      `measuresOf`, the same keccak over the same five bytes. Seed bit 16 empties the pool, bit 17
///      seals nobody, bit 18 makes nobody Ashfall-eligible; position 3 is never sealed.
library SeedMeasures {
    function measures(uint256 e, uint256 i, uint256 seed) internal pure returns (ForgeEmissions.Measure[] memory m) {
        m = new ForgeEmissions.Measure[](3);
        bool empty = (seed >> 16) & 1 == 1;
        for (uint256 id = 1; id <= 3; ++id) {
            // forge-lint: disable-next-line(unsafe-typecast) — every value is below 256
            uint256 h = uint256(keccak256(abi.encodePacked(uint8(e), uint8(i), uint8(id), uint8(seed & 0xff), uint8((seed >> 8) & 0xff))));
            uint256 s = empty ? 0 : (h % 1e24) + 1;
            m[id - 1].stakeSeconds = s;
            m[id - 1].heatSeconds = empty ? 0 : s + ((h >> 80) % 1e24);
            m[id - 1].ashfallWeight = empty || (seed >> 18) & 1 == 1 ? 0 : (h >> 160) % 1e30;
            m[id - 1].candidateSeconds = empty || (seed >> 17) & 1 == 1 || id == 3 ? 0 : (h >> 120) % 1e22;
        }
    }
}

