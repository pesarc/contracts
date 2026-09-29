// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Per-pool fee, breaker, and rebalance policy for GoldgardHook.
struct PoolConfig {
    uint24 baseLpFee;
    uint24 maxLpFee;
    uint16 feeSlopeBps;
    uint16 deviationBps;
    uint16 circuitBreakerBps;
    uint16 rebalanceBps;
    uint32 twapWindowSeconds;
    uint32 circuitBreakerCooldownSeconds;
    uint64 pausedUntil;
}

/// @notice Per-position state used for enrollment, eligibility, and claim previews.
struct PositionInfo {
    uint128 liquidity;
    uint64 lastTimestamp;
    uint256 totalLiquiditySeconds;
    uint256 inRangeLiquiditySeconds;
    uint256 principalToken1;
    uint160 enrolledSqrtPriceX96;
    int24 tickLower;
    int24 tickUpper;
}
