// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CorridorVault} from "../src/liquidity/CorridorVault.sol";
import {IStrategyAdapter} from "../src/liquidity/IStrategyAdapter.sol";
import {TestStable} from "../src/tokens/TestStable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// A trivial strategy that just holds the asset; yield is simulated by minting.
contract MockStrategy is IStrategyAdapter {
    TestStable public immutable token;
    address public immutable vault;

    constructor(address token_, address vault_) {
        token = TestStable(token_);
        vault = vault_;
    }

    function asset() external view returns (address) {
        return address(token);
    }

    function totalAssets() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function deposit(uint256 amount) external {
        token.transferFrom(vault, address(this), amount);
    }

    function withdraw(uint256 amount) external returns (uint256) {
        token.transfer(vault, amount);
        return amount;
    }

    function simulateYield(uint256 amount) external {
        token.mint(address(this), amount);
    }
}

contract CorridorVaultTest is Test {
    TestStable usdc;
    CorridorVault vault;

    address owner = address(0xA11CE);
    address fee = address(0xFEE);
    address operator = address(0x0B0B);
    address alice = address(0xA1);

    function setUp() public {
        usdc = new TestStable("USD Coin", "USDC");
        vault = new CorridorVault(IERC20(address(usdc)), "Pesarc Corridor USDC", "pcUSDC", owner, fee);
        vm.prank(owner);
        vault.setOperator(operator);
        usdc.mint(alice, 1_000e18);
        usdc.mint(operator, 1_000e18);
    }

    function _deposit(address who, uint256 amt) internal returns (uint256 shares) {
        vm.startPrank(who);
        usdc.approve(address(vault), amt);
        shares = vault.deposit(amt, who);
        vm.stopPrank();
        vault.harvestFees(); // establish/refresh the high-water mark
    }

    function test_depositTracksAssets() public {
        _deposit(alice, 100e18);
        assertEq(vault.totalAssets(), 100e18);
        assertEq(vault.maxWithdraw(alice), 100e18);
        assertGt(vault.highWaterMark(), 0);
    }

    function test_borrowRespectsBuffer() public {
        _deposit(alice, 100e18); // buffer keeps >=20 idle
        vm.prank(operator);
        vault.borrow(80e18);
        assertEq(vault.deployed(), 80e18);
        assertEq(vault.idle(), 20e18);
        vm.expectRevert(CorridorVault.BufferBreached.selector);
        vm.prank(operator);
        vault.borrow(1e18);
    }

    function test_onlyOperatorBorrows() public {
        _deposit(alice, 100e18);
        vm.expectRevert(CorridorVault.NotOperator.selector);
        vault.borrow(1e18);
    }

    function test_repayProfitChargesFeeViaHWM() public {
        _deposit(alice, 100e18);
        uint256 priceBefore = vault.convertToAssets(1e18);
        vm.prank(operator);
        vault.borrow(50e18);
        vm.startPrank(operator);
        usdc.approve(address(vault), 60e18);
        vault.repay(50e18, 10e18); // +10 profit
        vm.stopPrank();

        vault.harvestFees();
        assertEq(vault.totalAssets(), 110e18);
        assertGt(vault.balanceOf(fee), 0); // ~10% of 10e18
        assertGt(vault.convertToAssets(1e18), priceBefore);
        uint256 aliceAssets = vault.convertToAssets(vault.balanceOf(alice));
        assertApproxEqAbs(aliceAssets, 109e18, 1e17); // keeps ~90% of profit
    }

    function test_lossRecoversToHWMBeforeFee() public {
        _deposit(alice, 100e18);

        // Lose 10.
        vm.prank(operator);
        vault.borrow(40e18);
        vm.startPrank(operator);
        usdc.approve(address(vault), 30e18);
        vault.reportLoss(40e18, 10e18);
        vm.stopPrank();
        vault.harvestFees();
        assertEq(vault.totalAssets(), 90e18);
        assertEq(vault.balanceOf(fee), 0); // below HWM, no fee

        // Earn 8 back -> still below the 100 HWM, no fee.
        vm.prank(operator);
        vault.borrow(40e18);
        vm.startPrank(operator);
        usdc.approve(address(vault), 48e18);
        vault.repay(40e18, 8e18);
        vm.stopPrank();
        vault.harvestFees();
        assertEq(vault.totalAssets(), 98e18);
        assertEq(vault.balanceOf(fee), 0);

        // Earn 7 more -> 105 total, fee only on the 5 above the 100 HWM.
        vm.prank(operator);
        vault.borrow(40e18);
        vm.startPrank(operator);
        usdc.approve(address(vault), 47e18);
        vault.repay(40e18, 7e18);
        vm.stopPrank();
        vault.harvestFees();
        assertEq(vault.totalAssets(), 105e18);
        assertGt(vault.balanceOf(fee), 0);
    }

    function test_strategyAllocateEarnDeallocate() public {
        _deposit(alice, 100e18);
        MockStrategy strat = new MockStrategy(address(usdc), address(vault));
        vm.prank(owner);
        vault.addStrategy(address(strat));

        vm.prank(operator);
        vault.allocate(address(strat), 50e18);
        assertEq(vault.idle(), 50e18);
        assertEq(strat.totalAssets(), 50e18);
        assertEq(vault.totalAssets(), 100e18);

        strat.simulateYield(5e18); // strategy earned 5
        assertEq(vault.totalAssets(), 105e18);
        vault.harvestFees();
        assertGt(vault.balanceOf(fee), 0); // fee on the 5 yield

        vm.prank(operator);
        vault.deallocate(address(strat), 55e18);
        assertEq(strat.totalAssets(), 0);
        assertEq(vault.idle(), 105e18);
    }

    function test_addStrategyRejectsWrongAsset() public {
        TestStable other = new TestStable("Other", "OTH");
        MockStrategy bad = new MockStrategy(address(other), address(vault));
        vm.expectRevert(CorridorVault.BadStrategy.selector);
        vm.prank(owner);
        vault.addStrategy(address(bad));
    }

    function test_withdrawLimitedToIdle() public {
        _deposit(alice, 100e18);
        vm.prank(operator);
        vault.borrow(80e18);
        assertEq(vault.maxWithdraw(alice), 20e18);
        vm.prank(alice);
        vault.withdraw(20e18, alice, alice);
        assertEq(usdc.balanceOf(alice), 920e18);
    }
}
