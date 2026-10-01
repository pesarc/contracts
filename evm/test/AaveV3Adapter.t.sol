// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AaveV3Adapter} from "../src/liquidity/AaveV3Adapter.sol";
import {TestStable} from "../src/tokens/TestStable.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

contract MockAToken is ERC20 {
    address public pool;

    constructor(address pool_) ERC20("aUSDC", "aUSDC") {
        pool = pool_;
    }

    function mint(address to, uint256 amt) external {
        require(msg.sender == pool, "only pool");
        _mint(to, amt);
    }

    function burn(address from, uint256 amt) external {
        require(msg.sender == pool, "only pool");
        _burn(from, amt);
    }

    // Simulate lending interest accruing to a holder.
    function accrue(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract MockAavePool {
    TestStable public immutable asset;
    MockAToken public aToken;

    constructor(address asset_) {
        asset = TestStable(asset_);
        aToken = new MockAToken(address(this));
    }

    function supply(address, uint256 amount, address onBehalfOf, uint16) external {
        asset.transferFrom(msg.sender, address(this), amount);
        aToken.mint(onBehalfOf, amount);
    }

    function withdraw(address, uint256 amount, address to) external returns (uint256) {
        uint256 bal = aToken.balanceOf(msg.sender);
        uint256 amt = amount > bal ? bal : amount;
        aToken.burn(msg.sender, amt);
        asset.transfer(to, amt);
        return amt;
    }
}

contract AaveV3AdapterTest is Test {
    TestStable usdc;
    MockAavePool pool;
    AaveV3Adapter adapter;
    address vault = address(0xADA1);

    function setUp() public {
        usdc = new TestStable("USD Coin", "USDC");
        pool = new MockAavePool(address(usdc));
        adapter = new AaveV3Adapter(address(usdc), address(pool), address(pool.aToken()), vault);
        usdc.mint(vault, 1_000e18);
        vm.prank(vault);
        usdc.approve(address(adapter), type(uint256).max);
    }

    function test_depositSuppliesToAave() public {
        vm.prank(vault);
        adapter.deposit(100e18);
        assertEq(adapter.totalAssets(), 100e18);
        assertEq(usdc.balanceOf(address(pool)), 100e18);
    }

    function test_yieldAccrues() public {
        vm.prank(vault);
        adapter.deposit(100e18);
        pool.aToken().accrue(address(adapter), 7e18); // 7 interest
        assertEq(adapter.totalAssets(), 107e18);
    }

    function test_withdrawReturnsToVault() public {
        vm.prank(vault);
        adapter.deposit(100e18);
        uint256 before = usdc.balanceOf(vault);
        vm.prank(vault);
        uint256 sent = adapter.withdraw(40e18);
        assertEq(sent, 40e18);
        assertEq(usdc.balanceOf(vault), before + 40e18);
        assertEq(adapter.totalAssets(), 60e18);
    }

    function test_onlyVault() public {
        vm.expectRevert(AaveV3Adapter.NotVault.selector);
        adapter.deposit(1e18);
    }
}
