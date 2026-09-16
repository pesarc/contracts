// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OracleAdapter} from "../src/liquidity/OracleAdapter.sol";
import {IChainlinkAggregatorV3} from "../src/liquidity/interfaces/IChainlinkAggregatorV3.sol";
import {BadConfig, OnlyHook} from "../src/errors/OracleAdapterErrors.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

contract OracleAdapterTest is Test {
    using PoolIdLibrary for PoolKey;

    OracleAdapter oracle;
    address owner = address(0xA11CE);
    address hook = address(0xC0FFEE);
    address stranger = address(0xB0B);

    PoolKey key;

    function setUp() public {
        oracle = new OracleAdapter(owner);
        key = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
    }

    function _cfg() internal pure returns (OracleAdapter.PoolOracleConfig memory) {
        return OracleAdapter.PoolOracleConfig({
            aggregator: IChainlinkAggregatorV3(address(0)),
            maxStaleSeconds: 3600,
            maxPoolStaleSeconds: 1800,
            aggregatorDecimals: 8,
            token0Decimals: 18,
            token1Decimals: 18
        });
    }

    function test_SetHook_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setHook(hook);

        vm.prank(owner);
        oracle.setHook(hook);
        assertEq(oracle.hook(), hook);
    }

    function test_SetPoolConfig_OnlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        oracle.setPoolOracleConfig(key, _cfg());
    }

    function test_SetPoolConfig_Stores() public {
        vm.prank(owner);
        oracle.setPoolOracleConfig(key, _cfg());
        (, uint32 maxStale, uint32 maxPoolStale,,,) = oracle.poolOracle(key.toId());
        assertEq(maxStale, 3600);
        assertEq(maxPoolStale, 1800);
    }

    function test_SetPoolConfig_BadConfig() public {
        vm.startPrank(owner);

        OracleAdapter.PoolOracleConfig memory c = _cfg();
        c.maxStaleSeconds = 0;
        vm.expectRevert(BadConfig.selector);
        oracle.setPoolOracleConfig(key, c);

        c = _cfg();
        c.maxPoolStaleSeconds = 0;
        vm.expectRevert(BadConfig.selector);
        oracle.setPoolOracleConfig(key, c);

        c = _cfg();
        c.aggregatorDecimals = 31; // > 30
        vm.expectRevert(BadConfig.selector);
        oracle.setPoolOracleConfig(key, c);

        vm.stopPrank();
    }

    function test_UpdateFromPool_OnlyHook() public {
        vm.prank(stranger);
        vm.expectRevert(OnlyHook.selector);
        oracle.updateFromPool(IPoolManager(address(0)), key);
    }
}
