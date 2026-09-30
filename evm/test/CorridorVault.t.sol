// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CorridorVault} from "../src/liquidity/CorridorVault.sol";
import {TestStable} from "../src/tokens/TestStable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract CorridorVaultTest is Test {
    TestStable usdc;
    CorridorVault vault;

    address owner = address(0xA11CE);
    address fee = address(0xFEE);
    address operator = address(0x0B0B);
    address alice = address(0xA1);
    address bob = address(0xB0B2);

    function setUp() public {
        usdc = new TestStable("USD Coin", "USDC");
        vault = new CorridorVault(IERC20(address(usdc)), "Pesarc Corridor USDC", "pcUSDC", owner, fee);
        vm.prank(owner);
        vault.setOperator(operator);

        usdc.mint(alice, 1_000e18);
        usdc.mint(bob, 1_000e18);
        usdc.mint(operator, 1_000e18); // operator's own funds to repay profit with
    }

    function _deposit(address who, uint256 amt) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        shares = vault.deposit(amt, who);
        vm.stopPrank();
    }

    function test_depositMintsSharesAndTracksAssets() public {
        uint256 shares = _deposit(alice, 100e18);
        assertEq(vault.totalAssets(), 100e18);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(vault.maxWithdraw(alice), 100e18);
    }

    function test_onlyOperatorCanBorrow() public {
        _deposit(alice, 100e18);
        vm.expectRevert(CorridorVault.NotOperator.selector);
        vm.prank(bob);
        vault.borrow(10e18);
    }

    function test_borrowRespectsDeployCap() public {
        _deposit(alice, 100e18); // cap = 80% = 80e18
        vm.prank(operator);
        vault.borrow(80e18);
        assertEq(vault.deployed(), 80e18);
        assertEq(vault.idle(), 20e18);
        vm.expectRevert(CorridorVault.ExceedsDeployCap.selector);
        vm.prank(operator);
        vault.borrow(1e18);
    }

    function test_repayWithProfitRaisesSharePriceAndTakesFee() public {
        _deposit(alice, 100e18);
        uint256 priceBefore = vault.convertToAssets(1e18);

        vm.prank(operator);
        vault.borrow(50e18);

        // Operator returns principal + 10e18 profit.
        vm.startPrank(operator);
        usdc.approve(address(vault), 60e18);
        vault.repay(50e18, 10e18);
        vm.stopPrank();

        assertEq(vault.deployed(), 0);
        assertEq(vault.totalAssets(), 110e18);
        // Fee recipient got ~10% of the 10e18 profit as shares.
        assertGt(vault.balanceOf(fee), 0);
        // Alice's shares are now worth more.
        assertGt(vault.convertToAssets(1e18), priceBefore);
        // Roughly: alice keeps ~90% of profit. Allow rounding slack.
        uint256 aliceAssets = vault.convertToAssets(vault.balanceOf(alice));
        assertApproxEqAbs(aliceAssets, 109e18, 1e17);
    }

    function test_lossCarryForwardBlocksFeeUntilRecovered() public {
        _deposit(alice, 100e18);

        // Borrow 40, lose 10 of it.
        vm.prank(operator);
        vault.borrow(40e18);
        vm.startPrank(operator);
        usdc.approve(address(vault), 30e18);
        vault.reportLoss(40e18, 10e18); // returns 30, carries 10 loss
        vm.stopPrank();
        assertEq(vault.lossCarry(), 10e18);
        assertEq(vault.totalAssets(), 90e18);
        assertEq(vault.balanceOf(fee), 0);

        // Borrow 40 again, earn 8 profit -> all recoups loss, no fee.
        vm.prank(operator);
        vault.borrow(40e18);
        vm.startPrank(operator);
        usdc.approve(address(vault), 48e18);
        vault.repay(40e18, 8e18);
        vm.stopPrank();
        assertEq(vault.lossCarry(), 2e18); // 10 - 8
        assertEq(vault.balanceOf(fee), 0); // still no fee

        // Earn 12 more -> 2 recoups the rest, 10 net profit -> fee on 10.
        vm.prank(operator);
        vault.borrow(40e18);
        vm.startPrank(operator);
        usdc.approve(address(vault), 52e18);
        vault.repay(40e18, 12e18);
        vm.stopPrank();
        assertEq(vault.lossCarry(), 0);
        assertGt(vault.balanceOf(fee), 0);
    }

    function test_withdrawLimitedToIdle() public {
        _deposit(alice, 100e18);
        vm.prank(operator);
        vault.borrow(80e18); // only 20 idle
        assertEq(vault.maxWithdraw(alice), 20e18);
        vm.prank(alice);
        vault.withdraw(20e18, alice, alice);
        assertEq(usdc.balanceOf(alice), 920e18); // 1000 - 100 + 20
    }
}
