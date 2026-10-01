// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CorridorVault} from "../src/liquidity/CorridorVault.sol";
import {ERC4626Strategy} from "../src/liquidity/ERC4626Strategy.sol";
import {TestStable} from "../src/tokens/TestStable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "openzeppelin-contracts/contracts/token/ERC20/extensions/ERC4626.sol";

/// A stand-in for the Goldgard SafetyModule (or any ERC-4626): plain 4626 over the
/// asset; "yield" is simulated by transferring extra asset in, which lifts the
/// share price exactly as premiums would.
contract Mock4626 is ERC4626 {
    constructor(IERC20 a) ERC4626(a) ERC20("Mock Safety", "mSAFE") {}
}

contract ERC4626StrategyTest is Test {
    TestStable usdc;
    CorridorVault vault;
    Mock4626 market;
    ERC4626Strategy strat;

    address owner = address(0xA11CE);
    address fee = address(0xFEE);
    address operator = address(0x0B0B);
    address alice = address(0xA1);

    function setUp() public {
        usdc = new TestStable("USD Coin", "USDC");
        vault = new CorridorVault(IERC20(address(usdc)), "Pesarc Corridor USDC", "pcUSDC", owner, fee);
        market = new Mock4626(IERC20(address(usdc)));
        strat = new ERC4626Strategy(address(usdc), address(market), address(vault));
        vm.startPrank(owner);
        vault.setOperator(operator);
        vault.addStrategy(address(strat));
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

    function test_constructor_rejectsWrongAsset() public {
        TestStable other = new TestStable("Other", "OTH");
        Mock4626 wrong = new Mock4626(IERC20(address(other)));
        vm.expectRevert(ERC4626Strategy.AssetMismatch.selector);
        new ERC4626Strategy(address(usdc), address(wrong), address(vault));
    }

    function test_allocateDepositsIntoMarket() public {
        _deposit(alice, 100e18);
        vm.prank(operator);
        vault.allocate(address(strat), 70e18); // buffer keeps >=20 idle
        assertEq(strat.totalAssets(), 70e18);
        assertEq(market.balanceOf(address(strat)), 70e18); // 1:1 shares at start
        assertEq(vault.idle(), 30e18);
        assertEq(vault.totalAssets(), 100e18);
    }

    function test_premiumYieldLiftsPositionAndCharges() public {
        _deposit(alice, 100e18);
        vm.prank(operator);
        vault.allocate(address(strat), 70e18);

        // Premiums arrive: extra asset transferred into the 4626 lifts its price.
        usdc.mint(address(market), 7e18);
        assertApproxEqAbs(strat.totalAssets(), 77e18, 1);
        assertApproxEqAbs(vault.totalAssets(), 107e18, 1);

        vault.harvestFees();
        assertGt(vault.balanceOf(fee), 0); // performance fee on the 7 yield
    }

    function test_deallocateReturnsWithYield() public {
        _deposit(alice, 100e18);
        vm.prank(operator);
        vault.allocate(address(strat), 70e18);
        usdc.mint(address(market), 7e18); // +10% on the position

        // Full exit: redeem all shares back to the vault.
        vm.prank(operator);
        vault.deallocate(address(strat), type(uint256).max);
        assertEq(strat.totalAssets(), 0);
        assertApproxEqAbs(vault.idle(), 107e18, 1); // 30 idle + 77 returned
    }

    function test_partialWithdraw() public {
        _deposit(alice, 100e18);
        vm.prank(operator);
        vault.allocate(address(strat), 70e18);
        vm.prank(operator);
        vault.deallocate(address(strat), 20e18);
        assertApproxEqAbs(strat.totalAssets(), 50e18, 1);
        assertApproxEqAbs(vault.idle(), 50e18, 1);
    }

    function test_onlyVaultMovesFunds() public {
        vm.expectRevert(ERC4626Strategy.NotVault.selector);
        strat.deposit(1e18);
        vm.expectRevert(ERC4626Strategy.NotVault.selector);
        strat.withdraw(1e18);
    }
}
