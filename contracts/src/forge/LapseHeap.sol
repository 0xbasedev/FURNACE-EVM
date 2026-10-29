// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title LapseHeap
/// @notice Indexed binary min-heap of pending cooling-ticket deadlines. A node packs
///         `deadline << 216 | key`, so nodes order by deadline, then by key
///         (`positionId << 32 | ticketId`). Every operation is O(log n) and entries are
///         removed eagerly, so the top is always a live, unprocessed ticket.
library LapseHeap {
    error KeyTooLarge(uint256 key);
    error AlreadyQueued(uint256 key);
    error NotQueued(uint256 key);

    uint256 private constant KEY_BITS = 216;
    uint256 private constant KEY_MASK = (1 << KEY_BITS) - 1;

    struct Heap {
        uint256[] nodes;
        mapping(uint256 key => uint256 indexPlusOne) slot;
    }

    function length(Heap storage h) internal view returns (uint256) {
        return h.nodes.length;
    }

    function contains(Heap storage h, uint256 key) internal view returns (bool) {
        return h.slot[key] != 0;
    }

    /// @return ok false when empty; otherwise the earliest deadline and its key.
    function peek(Heap storage h) internal view returns (bool ok, uint256 deadline, uint256 key) {
        if (h.nodes.length == 0) return (false, 0, 0);
        uint256 node = h.nodes[0];
        return (true, node >> KEY_BITS, node & KEY_MASK);
    }

    function push(Heap storage h, uint256 deadline, uint256 key) internal {
        if (key > KEY_MASK) revert KeyTooLarge(key);
        if (h.slot[key] != 0) revert AlreadyQueued(key);
        h.nodes.push((deadline << KEY_BITS) | key);
        uint256 i = h.nodes.length - 1;
        h.slot[key] = i + 1;
        _up(h, i);
    }

    function remove(Heap storage h, uint256 key) internal {
        uint256 indexPlusOne = h.slot[key];
        if (indexPlusOne == 0) revert NotQueued(key);
        uint256 i = indexPlusOne - 1;
        uint256 last = h.nodes.length - 1;
        delete h.slot[key];
        if (i != last) {
            uint256 moved = h.nodes[last];
            h.nodes[i] = moved;
            h.slot[moved & KEY_MASK] = i + 1;
        }
        h.nodes.pop();
        if (i < h.nodes.length) {
            _down(h, i);
            _up(h, i);
        }
    }

    function _up(Heap storage h, uint256 i) private {
        uint256 node = h.nodes[i];
        while (i > 0) {
            uint256 parent = (i - 1) / 2;
            uint256 above = h.nodes[parent];
            if (above <= node) break;
            h.nodes[i] = above;
            h.slot[above & KEY_MASK] = i + 1;
            i = parent;
        }
        h.nodes[i] = node;
        h.slot[node & KEY_MASK] = i + 1;
    }

    function _down(Heap storage h, uint256 i) private {
        uint256 n = h.nodes.length;
        uint256 node = h.nodes[i];
        while (true) {
            uint256 child = 2 * i + 1;
            if (child >= n) break;
            uint256 smallest = h.nodes[child];
            if (child + 1 < n && h.nodes[child + 1] < smallest) {
                child += 1;
                smallest = h.nodes[child];
            }
            if (node <= smallest) break;
            h.nodes[i] = smallest;
            h.slot[smallest & KEY_MASK] = i + 1;
            i = child;
        }
        h.nodes[i] = node;
        h.slot[node & KEY_MASK] = i + 1;
    }
}
