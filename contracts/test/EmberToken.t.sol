// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {EmberToken} from "../src/EmberToken.sol";
import {FurnaceParams as P} from "../src/generated/FurnaceParams.sol";

contract EmberTokenTest is Test {
    EmberToken ember;
    address mantle = makeAddr("mantle");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        ember = new EmberToken(mantle);
    }

    function test_identityFromConfig() public view {
        assertEq(ember.name(), "Ember");
        assertEq(ember.symbol(), "EMBER");
        assertEq(ember.decimals(), 18);
        assertEq(ember.MAX_SUPPLY(), 21_000_000e18);
        assertEq(ember.CONFIG_HASH(), P.CONFIG_HASH);
        assertEq(ember.MANTLE(), mantle);
    }

    function test_nothingPreMinted() public view {
        assertEq(ember.totalSupply(), 0, "Kindling seed and vesting are Mantle-reserved, not pre-minted");
    }

    function test_rejectsZeroMantle() public {
        vm.expectRevert(EmberToken.ZeroMantle.selector);
        new EmberToken(address(0));
    }

    function testFuzz_onlyMantleMints(address caller, uint256 amount) public {
        vm.assume(caller != mantle);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(EmberToken.NotMantle.selector, caller));
        ember.mint(alice, amount);
    }

    function test_ceiling_exactlyReachable_notExceedable() public {
        vm.startPrank(mantle);
        ember.mint(alice, P.EMBER_MAX_SUPPLY);
        vm.expectRevert(abi.encodeWithSelector(EmberToken.SupplyCeilingExceeded.selector, P.EMBER_MAX_SUPPLY + 1));
        ember.mint(alice, 1);
        vm.stopPrank();
    }

    function test_burnReopensLocalHeadroom() public {
        vm.prank(mantle);
        ember.mint(alice, P.EMBER_MAX_SUPPLY);
        vm.prank(alice);
        ember.burn(5_000e18);
        assertEq(ember.localHeadroom(), 5_000e18, "live ceiling, not cumulative");
    }

    function test_deadAddressTransferIsNotABurn() public {
        vm.prank(mantle);
        ember.mint(alice, 1_000e18);
        uint256 before = ember.localHeadroom();
        vm.prank(alice);
        assertTrue(ember.transfer(0x000000000000000000000000000000000000dEaD, 1_000e18));
        assertEq(ember.localHeadroom(), before);
    }

    function testFuzz_zeroTransferTax(uint256 mintAmt, uint256 sendAmt) public {
        mintAmt = bound(mintAmt, 0, P.EMBER_MAX_SUPPLY);
        sendAmt = bound(sendAmt, 0, mintAmt);
        vm.prank(mantle);
        ember.mint(alice, mintAmt);
        uint256 supply = ember.totalSupply();
        vm.prank(alice);
        assertTrue(ember.transfer(bob, sendAmt));
        assertEq(ember.balanceOf(bob), sendAmt, "recipient gets the full amount");
        assertEq(ember.balanceOf(alice), mintAmt - sendAmt);
        assertEq(ember.totalSupply(), supply, "transfers neither mint nor burn");
    }

    function test_permit() public {
        (address owner, uint256 pk) = makeAddrAndKey("owner");
        vm.prank(mantle);
        ember.mint(owner, 10e18);
        uint256 deadline = block.timestamp + 1 hours;
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ember.DOMAIN_SEPARATOR(), keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            owner, bob, 10e18, ember.nonces(owner), deadline))));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        ember.permit(owner, bob, 10e18, deadline, v, r, s);
        assertEq(ember.allowance(owner, bob), 10e18);
    }
}

/// @dev Random mint/burn/transfer sequences from the Mantle and holders.
contract EmberHandler is Test {
    EmberToken public ember;
    address public mantle;
    address[] public actors;

    constructor(EmberToken e, address m) {
        ember = e;
        mantle = m;
        actors.push(makeAddr("a"));
        actors.push(makeAddr("b"));
        actors.push(makeAddr("c"));
    }

    function actorCount() external view returns (uint256) { return actors.length; }

    function mint(uint256 who, uint256 amount) external {
        amount = bound(amount, 0, ember.localHeadroom() + 1e24); // sometimes over the ceiling: must revert
        vm.prank(mantle);
        try ember.mint(actors[who % actors.length], amount) {} catch {}
    }

    function burn(uint256 who, uint256 amount) external {
        address a = actors[who % actors.length];
        amount = bound(amount, 0, ember.balanceOf(a));
        vm.prank(a);
        ember.burn(amount);
    }

    function transfer(uint256 from, uint256 to, uint256 amount) external {
        address a = actors[from % actors.length];
        amount = bound(amount, 0, ember.balanceOf(a));
        vm.prank(a);
        assertTrue(ember.transfer(actors[to % actors.length], amount));
    }
}

contract EmberTokenInvariantTest is Test {
    EmberToken ember;
    EmberHandler handler;

    function setUp() public {
        address mantle = makeAddr("mantle");
        ember = new EmberToken(mantle);
        handler = new EmberHandler(ember, mantle);
        targetContract(address(handler));
    }

    function invariant_liveSupplyCeiling() public view {
        assertLe(ember.totalSupply(), P.EMBER_MAX_SUPPLY);
    }

    function invariant_balancesSumToSupply() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) sum += ember.balanceOf(handler.actors(i));
        assertEq(sum, ember.totalSupply());
    }
}
