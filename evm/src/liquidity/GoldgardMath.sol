// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {SafeCast as OZSafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";

/// @title  GoldgardMath — pure pricing/fee math and stateless helpers for GoldgardHook.
/// @notice Extracted verbatim from GoldgardHook so the hook stays focused on its
///         swap/liquidity flow. These are `internal` library functions, so the
///         compiler inlines them into the hook: same bytecode logic, same
///         behavior, just organised. The config-aware helpers take primitive
///         parameters (rather than a storage `PoolConfig`) so they stay pure.
library GoldgardMath {
    using BalanceDeltaLibrary for BalanceDelta;

    uint256 internal constant BPS = 10_000;

    /// @notice Basis-point deviation between two sqrtPriceX96 values.
    function deviationBps(uint160 spot, uint160 oracleSqrt) internal pure returns (uint256) {
        uint256 a = uint256(spot);
        uint256 b = uint256(oracleSqrt);
        if (a == b) return 0;
        uint256 hi = a > b ? a : b;
        uint256 lo = a > b ? b : a;
        return ((hi - lo) * BPS) / lo;
    }

    /// @notice Basis-point deviation between two 1e18-scaled prices.
    function deviationBps256(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == b) return 0;
        uint256 hi = a > b ? a : b;
        uint256 lo = a > b ? b : a;
        if (lo == 0) return type(uint256).max;
        return ((hi - lo) * BPS) / lo;
    }

    /// @notice Converts a sqrtPriceX96 into a 1e18-scaled price.
    function price1e18FromSqrt(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 a = uint256(sqrtPriceX96);
        uint256 denom = uint256(1) << 192;
        uint256 q = FullMath.mulDiv(a, a, denom);
        uint256 r = mulmod(a, a, denom);
        return (q * 1e18) + Math.mulDiv(r, 1e18, denom);
    }

    /// @notice Impermanent-loss in basis points for a 1e18-scaled price ratio.
    function impermanentLossBps(uint256 priceRatio1e18) internal pure returns (uint256) {
        if (priceRatio1e18 == 0) return 0;
        uint256 sqrtR1e18 = Math.sqrt(priceRatio1e18 * 1e18);
        uint256 factor1e18 = Math.mulDiv(2 * sqrtR1e18, 1e18, 1e18 + priceRatio1e18);
        if (factor1e18 >= 1e18) return 0;
        return Math.mulDiv(1e18 - factor1e18, BPS, 1e18);
    }

    /// @notice Converts deviation into an LP fee, capped by the configured max fee.
    function computeDynamicFee(
        uint24 baseLpFee,
        uint24 maxLpFee,
        uint16 feeSlopeBps,
        uint16 cfgDeviationBps,
        uint256 deviation
    ) internal pure returns (uint24) {
        if (deviation <= cfgDeviationBps) return baseLpFee;
        uint256 extra = (deviation - cfgDeviationBps) * uint256(feeSlopeBps);
        uint256 candidate = uint256(baseLpFee) + extra;
        if (candidate > maxLpFee) candidate = maxLpFee;
        return OZSafeCast.toUint24(candidate);
    }

    /// @notice Raises the effective deviation floor while a Reactive alert is active.
    /// @param reactiveAlert Packed alert: level in the low byte, `until` above it.
    function applyReactiveAlertBump(uint256 reactiveAlert, uint16 cfgDeviationBps, uint256 deviation, uint64 nowTs)
        internal
        pure
        returns (uint256)
    {
        uint8 alertLevel = uint8(reactiveAlert);
        if (alertLevel == 0) return deviation;
        uint64 alertUntil = uint64(reactiveAlert >> 8);
        if (nowTs >= alertUntil) return deviation;
        uint256 bump = alertLevel >= 2 ? 500 : 300;
        uint256 bumped = uint256(cfgDeviationBps) + bump;
        return deviation > bumped ? deviation : bumped;
    }

    /// @notice Premium on the swap leg chosen by Uniswap's balance-delta semantics.
    function computePremium(PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, uint16 premiumBps)
        internal
        pure
        returns (Currency feeCurrency, uint256 premium)
    {
        bool specifiedTokenIs0 = (params.amountSpecified < 0 == params.zeroForOne);
        int128 swapAmount = specifiedTokenIs0 ? delta.amount1() : delta.amount0();
        if (swapAmount < 0) swapAmount = -swapAmount;
        feeCurrency = specifiedTokenIs0 ? key.currency1 : key.currency0;

        uint256 swapAmountAbs = OZSafeCast.toUint256(int256(swapAmount));
        premium = (swapAmountAbs * uint256(premiumBps)) / BPS;
    }

    /// @notice Deterministic key for a concentrated-liquidity position.
    function positionKey(PoolId poolId, address owner, ModifyLiquidityParams calldata params)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(poolId, owner, params.tickLower, params.tickUpper, params.salt));
    }

    /// @notice Resolves the position owner from optional 20-byte hookData, else the sender.
    function resolveOwner(address sender, bytes calldata hookData) internal pure returns (address) {
        if (hookData.length == 20) {
            address owner;
            assembly ("memory-safe") {
                owner := shr(96, calldataload(hookData.offset))
            }
            return owner;
        }
        return sender;
    }
}
