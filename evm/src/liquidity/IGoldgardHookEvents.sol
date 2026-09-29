// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

/// @notice Events emitted by GoldgardHook. Declared in an interface the hook
///         inherits so the hook file stays focused; interfaces carry no storage,
///         so this does not affect the deployed contract's storage layout.
interface IGoldgardHookEvents {
    event CircuitBreakerTripped(PoolId indexed poolId, uint64 until, uint256 deviationBps);
    event PremiumTaken(PoolId indexed poolId, Currency feeCurrency, uint256 feeAmount, uint256 usdcDeposited);
    event Rebalanced(PoolId indexed poolId, int256 poolDelta0, int256 poolDelta1, uint256 amountMoved);
    event RebalanceExecuted(PoolId indexed poolId, bool zeroForOne, uint256 amountIn, uint256 amountOut);
    event LiquidityEnrolled(
        PoolId indexed poolId, bytes32 indexed positionKey, address indexed owner, uint128 liquidity
    );
    event OraclePriceUpdated(uint256 twap, uint256 external_, uint256 deviationBps, uint256 timestamp);
    event PremiumDiverted(
        PoolId indexed poolId,
        address indexed payer,
        Currency feeCurrency,
        uint256 feeAmount,
        uint256 usdcDeposited,
        uint16 premiumBps
    );
    event AlertLevelRaised(uint8 level, uint64 until);
    event RebalanceThresholdTightened(uint256 newThreshold);
    event PremiumRateAdjusted(uint16 newPremiumBps);
    event ReactiveCallbackProxySet(address indexed proxy);
    event AuthorizedCallerSet(address indexed caller);
}
