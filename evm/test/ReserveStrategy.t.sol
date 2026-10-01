// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CorridorVault} from "../src/liquidity/CorridorVault.sol";
import {ReserveStrategy} from "../src/liquidity/ReserveStrategy.sol";
import {TestStable} from "../src/tokens/TestStable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract ReserveStrategyTest is Test {
    TestStable usdc;
    CorridorVault vault;
    ReserveStrategy reserve;

    address owner = address(0xA11CE);
    address fee = address(0xFEE);
    address operator = address(0x0B0B);
    address alice = address(0xA1);

    function setUp() public {
        usdc = new TestStable("USD Coin", "USDC");
        vault = new CorridorVault(IERC20(address(usdc)), "Pesarc Corridor USDC", "pcUSDC", owner, fee);
        reserve = new ReserveStrategy(address(usdc), address(vault));
        vm.startPrank(owner);
        vault.setOperator(operator);
        vault.addStrategy(address(reserve));
        vm.stopPrank();
        usdc.mint(alice, 1_000e18);
    }

    function _deposit(address who, uint256 amt) internal {
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        vault.deposit(amt, who);
        vm.stopPrank();
        vault.harvestFees();
    }

    function test_asset_matchesVault() public view {
        assertEq(reserve.asset(), vault.asset());
    }

    function test_allocateMovesIntoReserve() public {
        _deposit(alice, 100e18);
        vm.prank(operator);
        vault.allocate(address(reserve), 70e18); // buffer keeps >=20 idle
        assertEq(reserve.totalAssets(), 70e18);
        assertEq(vault.idle(), 30e18);
        assertEq(vault.totalAssets(), 100e18); // unchanged: moved, not lost
    }

    function test_yieldRoutedInIsReflectedAndFeed() public {
        _deposit(alice, 100e18);
        vm.prank(operator);
        vault.allocate(address(reserve), 70e18);

        // Yield arrives as a plain transfer into the reserve (a rewards rebate).
        usdc.mint(address(reserve), 7e18);
        assertEq(reserve.totalAssets(), 77e18);
        assertEq(vault.totalAssets(), 107e18);

        vault.harvestFees();
        assertGt(vault.balanceOf(fee), 0); // performance fee on the 7 yield
    }

    function test_deallocateReturnsToVault() public {
        _deposit(alice, 100e18);
        vm.prank(operator);
        vault.allocate(address(reserve), 70e18);
        vm.prank(operator);
        vault.deallocate(address(reserve), 70e18);
        assertEq(reserve.totalAssets(), 0);
        assertEq(vault.idle(), 100e18);
    }

    function test_withdrawCapsAtBalance() public {
        _deposit(alice, 100e18);
        vm.prank(operator);
        vault.allocate(address(reserve), 50e18);
        // Asking for more than held returns only what's there, never reverts.
        vm.prank(operator);
        vault.deallocate(address(reserve), 999e18);
        assertEq(reserve.totalAssets(), 0);
        assertEq(vault.idle(), 100e18);
    }

    function test_onlyVaultMovesFunds() public {
        vm.expectRevert(ReserveStrategy.NotVault.selector);
        reserve.deposit(1e18);
        vm.expectRevert(ReserveStrategy.NotVault.selector);
        reserve.withdraw(1e18);
    }
}
