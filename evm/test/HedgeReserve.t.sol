// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HedgeReserve} from "../src/liquidity/HedgeReserve.sol";
import {OracleAdapter} from "../src/liquidity/OracleAdapter.sol";
import {TestStable} from "../src/tokens/TestStable.sol";
import {BadConfig, OnlyHook} from "../src/errors/HedgeReserveErrors.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/types/Currency.sol";

contract HedgeReserveTest is Test {
    HedgeReserve reserve;
    OracleAdapter oracle;
    TestStable token;

    address owner = address(0xA11CE);
    address hook = address(0xC0FFEE);
    address to = address(0xB0B);

    function setUp() public {
        oracle = new OracleAdapter(owner);
        // manager is only touched by the convert() paths, not by the ones tested here.
        reserve = new HedgeReserve(owner, IPoolManager(address(0)), oracle);
        token = new TestStable("cNGN", "cNGN");
    }

    function test_Constructor_Defaults() public view {
        assertEq(reserve.maxSpotOracleDeviationBps(), 10_000);
        assertEq(address(reserve.oracle()), address(oracle));
    }

    function test_SetHook_OnlyOwner() public {
        vm.prank(to);
        vm.expectRevert();
        reserve.setHook(hook);

        vm.prank(owner);
        reserve.setHook(hook);
        assertEq(reserve.hook(), hook);
    }

    function test_SetMaxDeviation_OwnerAndBounds() public {
        vm.prank(owner);
        vm.expectRevert(BadConfig.selector);
        reserve.setMaxSpotOracleDeviationBps(0);

        vm.prank(owner);
        reserve.setMaxSpotOracleDeviationBps(500);
        assertEq(reserve.maxSpotOracleDeviationBps(), 500);
    }

    function test_FundHook_OnlyHook() public {
        vm.prank(to);
        vm.expectRevert(OnlyHook.selector);
        reserve.fundHook(Currency.wrap(address(token)), 1e18, to);
    }

    function test_FundHook_TransfersReserveInventory() public {
        vm.prank(owner);
        reserve.setHook(hook);
        token.mint(address(reserve), 100e18);

        vm.prank(hook);
        reserve.fundHook(Currency.wrap(address(token)), 40e18, to);
        assertEq(token.balanceOf(to), 40e18);
        assertEq(token.balanceOf(address(reserve)), 60e18);
    }
}
