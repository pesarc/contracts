// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {GoldgardHook} from "../src/liquidity/GoldgardHook.sol";
import {OracleAdapter} from "../src/liquidity/OracleAdapter.sol";
import {SafetyModule} from "../src/liquidity/SafetyModule.sol";
import {HedgeReserve} from "../src/liquidity/HedgeReserve.sol";
import {RewardDistributor} from "../src/liquidity/RewardDistributor.sol";
import {PoolConfig} from "../src/liquidity/GoldgardHookTypes.sol";
import {IChainlinkAggregatorV3} from "../src/liquidity/interfaces/IChainlinkAggregatorV3.sol";
import {MockAggregatorV3} from "../src/mocks/MockAggregatorV3.sol";
import {TestStable} from "../src/tokens/TestStable.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {HookMiner} from "./utils/HookMiner.sol";

/// Proves the Goldgard hook stack that now lives in this repo can be mined to a
/// valid v4 hook address, deployed, wired, and used to configure a corridor pool —
/// the same sequence DeployGoldgard.s.sol runs on-chain. The test contract is the
/// CREATE2 deployer here (a plain `new X{salt:...}` deploys from it), so the salt
/// is mined against address(this), mirroring how forge's CREATE2 factory is used
/// in the broadcast script.
contract GoldgardHookDeployTest is Test {
    using PoolIdLibrary for PoolKey;

    uint160 internal constant HOOK_FLAGS = uint160((1 << 10) | (1 << 8) | (1 << 7) | (1 << 6) | (1 << 2));

    IPoolManager manager;
    OracleAdapter oracle;
    SafetyModule safety;
    HedgeReserve hedge;
    RewardDistributor rewards;
    GoldgardHook hook;
    TestStable usdc;
    TestStable lst;
    MockAggregatorV3 feed;

    address owner = address(this);

    function setUp() public {
        manager = IPoolManager(address(new PoolManager(owner)));
        usdc = new TestStable("USD Coin", "USDC");
        lst = new TestStable("cNGN", "cNGN");
        feed = new MockAggregatorV3(8, 1e8);

        oracle = new OracleAdapter(owner);
        safety = new SafetyModule(owner, IERC20(address(usdc)), "Goldgard Safety USDC", "gSAFE");
        hedge = new HedgeReserve(owner, manager, oracle);
        rewards = new RewardDistributor(owner);

        bytes memory initCode = abi.encodePacked(
            type(GoldgardHook).creationCode, abi.encode(owner, manager, oracle, safety, hedge, rewards)
        );
        (bytes32 salt, address predicted) =
            HookMiner.findSalt(address(this), keccak256(initCode), HOOK_FLAGS, 200_000);
        hook = new GoldgardHook{salt: salt}(owner, manager, oracle, safety, hedge, rewards);
        assertEq(address(hook), predicted, "mined address mismatch");

        oracle.setHook(address(hook));
        safety.setHook(address(hook));
        hedge.setHook(address(hook));
        rewards.setHook(address(hook));
    }

    function test_minedAddressEncodesPermissionFlags() public view {
        // The low 14 bits of the hook address must equal the required flag mask.
        assertEq(uint160(address(hook)) & uint160((1 << 14) - 1), HOOK_FLAGS);
    }

    function test_modulesAreImmutableAndWired() public view {
        assertEq(address(hook.oracle()), address(oracle));
        assertEq(address(hook.safetyModule()), address(safety));
        assertEq(address(hook.hedgeReserve()), address(hedge));
        assertEq(address(hook.rewards()), address(rewards));
    }

    function test_initialiseAndConfigurePool() public {
        (address c0, address c1) =
            address(usdc) < address(lst) ? (address(usdc), address(lst)) : (address(lst), address(usdc));
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        manager.initialize(key, 79228162514264337593543950336); // 1:1

        hook.setPoolConfig(
            key,
            PoolConfig({
                baseLpFee: 3000,
                maxLpFee: 30000,
                feeSlopeBps: 50,
                deviationBps: 100,
                circuitBreakerBps: 500,
                rebalanceBps: 200,
                twapWindowSeconds: 1800,
                circuitBreakerCooldownSeconds: 3600,
                pausedUntil: 0
            })
        );

        oracle.setPoolOracleConfig(
            key,
            OracleAdapter.PoolOracleConfig({
                aggregator: IChainlinkAggregatorV3(address(feed)),
                maxStaleSeconds: 3600,
                maxPoolStaleSeconds: 1800,
                aggregatorDecimals: 8,
                token0Decimals: 6,
                token1Decimals: 18
            })
        );

        (uint24 baseLpFee,,,,,,,,) = hook.poolConfig(key.toId());
        assertEq(baseLpFee, 3000);
    }
}
