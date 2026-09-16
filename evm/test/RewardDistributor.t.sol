// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RewardDistributor} from "../src/liquidity/RewardDistributor.sol";
import {OnlyHook} from "../src/errors/RewardDistributorErrors.sol";

contract RewardDistributorTest is Test {
    RewardDistributor dist;
    address owner = address(0xA11CE);
    address hook = address(0xC0FFEE);
    address lp = address(0xB0B);

    function setUp() public {
        dist = new RewardDistributor(owner);
    }

    function test_SetHook_OnlyOwner() public {
        vm.prank(lp);
        vm.expectRevert(); // Ownable: not owner
        dist.setHook(hook);

        vm.prank(owner);
        dist.setHook(hook);
        assertEq(dist.hook(), hook);
    }

    function test_MintReward_OnlyHook() public {
        vm.prank(owner);
        dist.setHook(hook);

        // Non-hook cannot mint.
        vm.prank(lp);
        vm.expectRevert(OnlyHook.selector);
        dist.mintReward(lp, 100e18);

        // Hook mints reward units to the LP.
        vm.prank(hook);
        dist.mintReward(lp, 100e18);
        assertEq(dist.balanceOf(lp, dist.GGARD_ID()), 100e18);
    }

    function test_MintReward_RevertsBeforeHookSet() public {
        vm.prank(hook);
        vm.expectRevert(OnlyHook.selector);
        dist.mintReward(lp, 1e18);
    }
}
