// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
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

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

/// @title  DeployGoldgard — chain-agnostic Goldgard v4 hook deploy
/// @notice Deploys the full Goldgard hook stack (OracleAdapter, SafetyModule,
///         HedgeReserve, RewardDistributor, and the GoldgardHook itself mined to a
///         valid v4 hook address) and wires the modules to the hook. Plugable to
///         ANY EVM chain the way Uniswap v4 is: point it at an existing PoolManager
///         (POOL_MANAGER) or let it deploy its own, and give it the USD leg
///         (USDC_ADDRESS). If a second token (LST_ADDRESS) is supplied it also
///         initialises a dynamic-fee corridor pool and seeds the oracle config; the
///         Reactive automation layer stays optional and is wired later via
///         setReactiveCallbackProxy, so it is not required to stand the hook up.
///
/// @dev    The broadcaster becomes the owner of every contract. Pass the key with
///         forge's --interactive / --account / --ledger — never inline it.
///
///         Env:
///           USDC_ADDRESS      USD leg of the corridor (required)
///           POOL_MANAGER      existing v4 PoolManager (optional; else deploys one)
///           LST_ADDRESS       second token; set to also init a pool (optional)
///           CHAINLINK_FEED    reference price feed (optional; else a MockAggregatorV3)
///           USDC_DECIMALS     defaults to 6
///           LST_DECIMALS      defaults to 18
///           INIT_SQRT_PRICE_X96  initial pool price (optional; defaults to 1:1)
contract DeployGoldgard is Script {
    // Hook permission flags GoldgardHook asserts in its constructor:
    // afterAddLiquidity(1<<10) | afterRemoveLiquidity(1<<8) | beforeSwap(1<<7)
    // | afterSwap(1<<6) | afterSwapReturnDelta(1<<2) = 0x5C4.
    uint160 internal constant HOOK_FLAGS = uint160((1 << 10) | (1 << 8) | (1 << 7) | (1 << 6) | (1 << 2));
    // CREATE2 factory Foundry deploys through (deterministic across chains).
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint256 internal constant MINE_ATTEMPTS = 200_000;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2**96

    function run() external {
        address owner = msg.sender;
        address usdc = vm.envAddress("USDC_ADDRESS");
        address lst = vm.envOr("LST_ADDRESS", address(0));

        vm.startBroadcast();

        // 1. PoolManager: reuse the chain's if given, else deploy our own.
        IPoolManager manager = IPoolManager(vm.envOr("POOL_MANAGER", address(0)));
        if (address(manager) == address(0)) {
            manager = IPoolManager(address(new PoolManager(owner)));
            console2.log("PoolManager (deployed)", address(manager));
        } else {
            console2.log("PoolManager (reused)  ", address(manager));
        }

        // 2. Reference feed: reuse a real Chainlink feed, else a deterministic mock.
        IChainlinkAggregatorV3 feed = IChainlinkAggregatorV3(vm.envOr("CHAINLINK_FEED", address(0)));
        if (address(feed) == address(0)) {
            feed = IChainlinkAggregatorV3(address(new MockAggregatorV3(8, 1e8)));
            console2.log("Chainlink feed (mock) ", address(feed));
        } else {
            console2.log("Chainlink feed (reused)", address(feed));
        }

        // 3. Modules.
        OracleAdapter oracle = new OracleAdapter(owner);
        SafetyModule safety = new SafetyModule(owner, IERC20(usdc), "Goldgard Safety USDC", "gSAFE");
        HedgeReserve hedge = new HedgeReserve(owner, manager, oracle);
        RewardDistributor rewards = new RewardDistributor(owner);

        // 4. Mine a hook address that encodes the required v4 permission flags, then
        //    deploy the hook there via the deterministic CREATE2 factory.
        bytes memory initCode = abi.encodePacked(
            type(GoldgardHook).creationCode, abi.encode(owner, manager, oracle, safety, hedge, rewards)
        );
        (bytes32 salt, address predicted) =
            HookMiner.findSalt(CREATE2_DEPLOYER, keccak256(initCode), HOOK_FLAGS, MINE_ATTEMPTS);
        GoldgardHook hook = new GoldgardHook{salt: salt}(owner, manager, oracle, safety, hedge, rewards);
        require(address(hook) == predicted, "hook address mismatch");

        // 5. Wire every module to the hook.
        oracle.setHook(address(hook));
        safety.setHook(address(hook));
        hedge.setHook(address(hook));
        rewards.setHook(address(hook));

        // 6. Optionally stand up a dynamic-fee corridor pool for USDC <-> LST.
        if (lst != address(0)) {
            _initPool(manager, oracle, hook, usdc, lst, feed);
        }

        vm.stopBroadcast();

        console2.log("OracleAdapter        ", address(oracle));
        console2.log("SafetyModule (gSAFE) ", address(safety));
        console2.log("HedgeReserve         ", address(hedge));
        console2.log("RewardDistributor    ", address(rewards));
        console2.log("GoldgardHook         ", address(hook));
    }

    /// @dev Sorts the pair, initialises a dynamic-fee pool with the hook attached,
    ///      and seeds the per-pool fee policy + oracle config in the sorted order.
    function _initPool(
        IPoolManager manager,
        OracleAdapter oracle,
        GoldgardHook hook,
        address usdc,
        address lst,
        IChainlinkAggregatorV3 feed
    ) internal {
        uint8 usdcDec = uint8(vm.envOr("USDC_DECIMALS", uint256(6)));
        uint8 lstDec = uint8(vm.envOr("LST_DECIMALS", uint256(18)));

        (address c0, address c1) = usdc < lst ? (usdc, lst) : (lst, usdc);
        (uint8 d0, uint8 d1) = usdc < lst ? (usdcDec, lstDec) : (lstDec, usdcDec);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        uint160 initPrice = uint160(vm.envOr("INIT_SQRT_PRICE_X96", uint256(SQRT_PRICE_1_1)));
        manager.initialize(key, initPrice);

        hook.setPoolConfig(
            key,
            PoolConfig({
                baseLpFee: 3000, // 0.30% floor
                maxLpFee: 30000, // 3.00% ceiling under stress
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
                aggregator: feed,
                maxStaleSeconds: 3600,
                maxPoolStaleSeconds: 1800,
                aggregatorDecimals: feed.decimals(),
                token0Decimals: d0,
                token1Decimals: d1
            })
        );

        console2.log("Pool initialised: currency0", c0);
        console2.log("                  currency1", c1);
    }
}
