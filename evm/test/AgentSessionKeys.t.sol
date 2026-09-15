// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AgentSessionKeys} from "../src/AgentSessionKeys.sol";
import {TestStable} from "../src/TestStable.sol";

contract Pinged {
    uint256 public pings;

    function ping() external {
        pings++;
    }
}

contract AgentSessionKeysTest is Test {
    AgentSessionKeys keys;
    TestStable cNGN;
    Pinged target;

    address owner = address(0xA11CE); // the user's smart wallet
    address agent = address(0xA6E7); // the agent's session key
    address bob = address(0xB0B); // a recipient

    function setUp() public {
        vm.prank(owner);
        keys = new AgentSessionKeys(owner);
        cNGN = new TestStable("cNGN", "cNGN");
        target = new Pinged();

        // Owner funds themselves and approves the session-key contract to spend.
        cNGN.mint(owner, 1_000_000e18);
        vm.prank(owner);
        cNGN.approve(address(keys), type(uint256).max);
    }

    function _grant(uint128 cap, uint64 expiry) internal {
        vm.prank(owner);
        keys.grantSession(agent, address(cNGN), cap, expiry);
    }

    function test_PayWithinCap_Meters() public {
        _grant(50_000e18, uint64(block.timestamp + 1 days));

        vm.prank(agent);
        keys.pay(bob, 20_000e18);
        assertEq(cNGN.balanceOf(bob), 20_000e18);
        assertEq(keys.remaining(agent), 30_000e18);

        vm.prank(agent);
        keys.pay(bob, 30_000e18);
        assertEq(keys.remaining(agent), 0);
    }

    function test_CapExceeded_Reverts() public {
        _grant(50_000e18, uint64(block.timestamp + 1 days));
        vm.prank(agent);
        vm.expectRevert(AgentSessionKeys.CapExceeded.selector);
        keys.pay(bob, 50_000e18 + 1);
    }

    function test_Expired_Reverts() public {
        _grant(50_000e18, uint64(block.timestamp + 1 hours));
        vm.warp(block.timestamp + 2 hours);
        vm.prank(agent);
        vm.expectRevert(AgentSessionKeys.Expired.selector);
        keys.pay(bob, 1e18);
    }

    function test_Revoke_KillsKey() public {
        _grant(50_000e18, uint64(block.timestamp + 1 days));
        vm.prank(owner);
        keys.revokeSession(agent);
        vm.prank(agent);
        vm.expectRevert(AgentSessionKeys.NoSession.selector);
        keys.pay(bob, 1e18);
        assertEq(keys.remaining(agent), 0);
    }

    function test_NonKey_CannotPay() public {
        _grant(50_000e18, uint64(block.timestamp + 1 days));
        vm.prank(bob); // bob has no session
        vm.expectRevert(AgentSessionKeys.NoSession.selector);
        keys.pay(bob, 1e18);
    }

    function test_OnlyOwnerGrants() public {
        vm.prank(agent);
        vm.expectRevert(); // Ownable: not owner
        keys.grantSession(agent, address(cNGN), 1e18, uint64(block.timestamp + 1 days));
    }

    function test_Execute_AllowlistEnforced() public {
        _grant(1e18, uint64(block.timestamp + 1 days));

        // Not allowed yet → reverts.
        vm.prank(agent);
        vm.expectRevert(AgentSessionKeys.TargetNotAllowed.selector);
        keys.execute(address(target), abi.encodeWithSelector(Pinged.ping.selector));

        // Owner allowlists the target → agent can call it.
        vm.prank(owner);
        keys.setAllowedTarget(agent, address(target), true);
        vm.prank(agent);
        keys.execute(address(target), abi.encodeWithSelector(Pinged.ping.selector));
        assertEq(target.pings(), 1);
    }
}
