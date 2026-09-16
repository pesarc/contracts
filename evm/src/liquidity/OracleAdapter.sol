// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

import {IChainlinkAggregatorV3} from "./interfaces/IChainlinkAggregatorV3.sol";

/// @title Goldgard Oracle Adapter
/// @notice Combines a pool-derived TWAP with an external Chainlink-style feed
///         and exposes a live-safe reference price for the rest of the system.
contract OracleAdapter is Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error OnlyHook();
    error BadConfig();
    error OracleUnavailable();

    event OraclePriceUpdated(uint256 twap, uint256 external_, uint256 deviationBps, uint256 timestamp);

    uint8 internal constant OBSERVATION_CARDINALITY = 32;
    uint32 public constant MIN_TWAP_WINDOW_SECONDS = 10 minutes;

    /// @notice Per-pool config for feed selection, freshness, and decimal normalization.
    struct PoolOracleConfig {
        IChainlinkAggregatorV3 aggregator;
        uint32 maxStaleSeconds;
        uint32 maxPoolStaleSeconds;
        uint8 aggregatorDecimals;
        uint8 token0Decimals;
        uint8 token1Decimals;
    }

    /// @notice Single ring-buffer observation used to reconstruct TWAP state.
    struct Observation {
        uint64 timestamp;
        uint256 sqrtPriceX96Cumulative;
    }

    address public hook;

    mapping(PoolId => PoolOracleConfig) public poolOracle;
    mapping(PoolId => Observation[OBSERVATION_CARDINALITY]) internal observations;

    /// @notice Rolling pool-side state used to maintain TWAP observations.
    struct PoolState {
        uint64 lastUpdated;
        uint160 lastSqrtPriceX96;
        uint256 sqrtPriceX96Cumulative;
        uint8 index;
        uint8 cardinality;
    }

    mapping(PoolId => PoolState) public poolState;

    constructor(address _owner) Ownable(_owner) {}

    /// @notice Sets the hook that is allowed to push pool observations into the adapter.
    function setHook(address _hook) external onlyOwner {
        hook = _hook;
    }

    /// @notice Configures the external feed and freshness windows for a pool.
    function setPoolOracleConfig(PoolKey calldata key, PoolOracleConfig calldata cfg) external onlyOwner {
        if (cfg.maxStaleSeconds == 0) revert BadConfig();
        if (cfg.maxPoolStaleSeconds == 0) revert BadConfig();
        if (cfg.aggregatorDecimals > 30) revert BadConfig();
        if (cfg.token0Decimals > 30) revert BadConfig();
        if (cfg.token1Decimals > 30) revert BadConfig();
        poolOracle[key.toId()] = PoolOracleConfig({
            aggregator: cfg.aggregator,
            maxStaleSeconds: cfg.maxStaleSeconds,
            maxPoolStaleSeconds: cfg.maxPoolStaleSeconds,
            aggregatorDecimals: cfg.aggregatorDecimals,
            token0Decimals: cfg.token0Decimals,
            token1Decimals: cfg.token1Decimals
        });
    }

    /// @notice Captures the latest pool price and appends it to the TWAP history.
    /// @dev Called by the hook during pool activity so the fallback path stays fresh.
    function updateFromPool(IPoolManager manager, PoolKey calldata key) external {
        if (msg.sender != hook) revert OnlyHook();

        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);

        uint64 t = uint64(block.timestamp);
        PoolState storage st = poolState[poolId];
        if (st.lastUpdated == 0) {
            st.lastUpdated = t;
            st.lastSqrtPriceX96 = sqrtPriceX96;
            st.sqrtPriceX96Cumulative = 0;

            observations[poolId][0] = Observation({timestamp: t, sqrtPriceX96Cumulative: 0});
            st.index = 1;
            st.cardinality = 1;
            return;
        }

        uint64 dt = t - st.lastUpdated;
        if (dt == 0) return;

        st.sqrtPriceX96Cumulative += uint256(st.lastSqrtPriceX96) * uint256(dt);
        st.lastUpdated = t;
        st.lastSqrtPriceX96 = sqrtPriceX96;

        uint8 i = st.index;
        observations[poolId][i] = Observation({timestamp: t, sqrtPriceX96Cumulative: st.sqrtPriceX96Cumulative});
        unchecked {
            i++;
        }
        if (i == OBSERVATION_CARDINALITY) i = 0;
        st.index = i;
        if (st.cardinality < OBSERVATION_CARDINALITY) st.cardinality++;

        (uint160 clSqrtPriceX96, bool ok) = getChainlinkSqrtPriceX96(key);
        if (ok && clSqrtPriceX96 != 0) {
            uint160 twapSqrtPriceX96 = getTwapSqrtPriceX96(key, MIN_TWAP_WINDOW_SECONDS);
            if (twapSqrtPriceX96 != 0) {
                uint256 twap = _price1e18FromSqrt(twapSqrtPriceX96);
                uint256 external_ = _price1e18FromSqrt(clSqrtPriceX96);
                uint256 deviationBps = _deviationBps256(twap, external_);
                emit OraclePriceUpdated(twap, external_, deviationBps, block.timestamp);
            }
        }
    }

    /// @notice Returns the pool-side TWAP sqrt price for the requested window.
    function getTwapSqrtPriceX96(PoolKey calldata key, uint32 windowSeconds) public view returns (uint160) {
        PoolId poolId = key.toId();
        PoolState memory st = poolState[poolId];
        if (st.lastUpdated == 0) return 0;

        uint64 t = uint64(block.timestamp);
        if (t <= st.lastUpdated) return st.lastSqrtPriceX96;

        uint64 dtNow = t - st.lastUpdated;
        uint256 cumulativeNow = st.sqrtPriceX96Cumulative + uint256(st.lastSqrtPriceX96) * uint256(dtNow);

        uint32 effectiveWindow = windowSeconds;
        if (effectiveWindow == 0) effectiveWindow = 1;
        if (effectiveWindow < MIN_TWAP_WINDOW_SECONDS) {
            effectiveWindow = MIN_TWAP_WINDOW_SECONDS;
        }

        uint64 target = t > effectiveWindow ? t - uint64(effectiveWindow) : 0;
        (uint64 obsTs, uint256 obsCumulative) = _getObservationAtOrBefore(poolId, target, st.index, st.cardinality);

        uint64 dt = t - obsTs;
        if (dt == 0) return st.lastSqrtPriceX96;

        uint256 avg = (cumulativeNow - obsCumulative) / uint256(dt);
        if (avg > type(uint160).max) avg = type(uint160).max;
        return SafeCast.toUint160(avg);
    }

    /// @notice Reads and normalizes the configured external feed into sqrt-price form.
    /// @return sqrtPriceX96 External price converted into Uniswap sqrt-price notation.
    /// @return ok True only when the feed is configured, positive, and fresh enough.
    function getChainlinkSqrtPriceX96(PoolKey calldata key) public view returns (uint160 sqrtPriceX96, bool ok) {
        PoolOracleConfig memory cfg = poolOracle[key.toId()];
        if (address(cfg.aggregator) == address(0)) return (0, false);

        (, int256 answer,, uint256 updatedAt,) = cfg.aggregator.latestRoundData();
        if (answer <= 0) return (0, false);
        if (updatedAt == 0 || updatedAt > block.timestamp) return (0, false);
        if (block.timestamp > updatedAt + uint256(cfg.maxStaleSeconds)) {
            return (0, false);
        }

        uint256 price1e18 = _scaleTo1e18(SafeCast.toUint256(answer), cfg.aggregatorDecimals);

        if (cfg.token0Decimals > 18) {
            price1e18 = Math.mulDiv(price1e18, 1, _pow10(cfg.token0Decimals - 18));
        } else if (cfg.token0Decimals < 18) {
            price1e18 = Math.mulDiv(price1e18, _pow10(18 - cfg.token0Decimals), 1);
        }

        if (cfg.token1Decimals > 18) {
            price1e18 = Math.mulDiv(price1e18, _pow10(cfg.token1Decimals - 18), 1);
        } else if (cfg.token1Decimals < 18) {
            price1e18 = Math.mulDiv(price1e18, 1, _pow10(18 - cfg.token1Decimals));
        }

        uint256 ratioX192 = Math.mulDiv(price1e18, uint256(1) << 192, 1e18);
        uint256 sqrtRatioX96 = Math.sqrt(ratioX192);
        if (sqrtRatioX96 > type(uint160).max) sqrtRatioX96 = type(uint160).max;
        return (SafeCast.toUint160(sqrtRatioX96), true);
    }

    /// @notice Returns a 1e18 reference price using fresh Chainlink first, then fresh TWAP.
    function getPrice1e18(PoolKey calldata key, uint32 twapWindowSeconds) external view returns (uint256 price1e18) {
        (uint160 sqrtPriceX96,) = getReferenceSqrtPriceX96(key, twapWindowSeconds);
        if (sqrtPriceX96 == 0) return 0;
        return _price1e18FromSqrt(sqrtPriceX96);
    }

    /// @notice Returns the strict reference price required by core contract flows.
    /// @dev Reverts only when both Chainlink and the TWAP fallback are stale or missing.
    function getPrice1e18Strict(PoolKey calldata key) external view returns (uint256 price1e18) {
        (uint160 sqrtPriceX96,) = getReferenceSqrtPriceX96(key, MIN_TWAP_WINDOW_SECONDS);
        if (sqrtPriceX96 == 0) revert OracleUnavailable();
        return _price1e18FromSqrt(sqrtPriceX96);
    }

    /// @notice Returns the TWAP only when the pool-side observation history is still fresh.
    function getTwapSqrtPriceX96IfFresh(PoolKey calldata key, uint32 windowSeconds)
        public
        view
        returns (uint160 sqrtPriceX96, bool ok)
    {
        PoolId poolId = key.toId();
        PoolOracleConfig memory cfg = poolOracle[poolId];
        PoolState memory st = poolState[poolId];
        if (st.lastUpdated == 0) return (0, false);
        if (block.timestamp > uint256(st.lastUpdated) + uint256(cfg.maxPoolStaleSeconds)) return (0, false);

        sqrtPriceX96 = getTwapSqrtPriceX96(key, windowSeconds);
        ok = sqrtPriceX96 != 0;
    }

    /// @notice Returns the preferred reference source for a pool.
    /// @return sqrtPriceX96 Preferred reference price in Uniswap sqrt-price notation.
    /// @return usingChainlink True when the returned sqrt price came from the external feed.
    function getReferenceSqrtPriceX96(PoolKey calldata key, uint32 twapWindowSeconds)
        public
        view
        returns (uint160 sqrtPriceX96, bool usingChainlink)
    {
        (uint160 cl, bool ok) = getChainlinkSqrtPriceX96(key);
        if (ok && cl != 0) return (cl, true);

        (uint160 twap, bool twapOk) = getTwapSqrtPriceX96IfFresh(key, twapWindowSeconds);
        if (!twapOk) return (0, false);
        return (twap, false);
    }

    function _scaleTo1e18(uint256 value, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return value;
        if (decimals > 18) {
            return Math.mulDiv(value, 1, _pow10(decimals - 18));
        }
        return Math.mulDiv(value, _pow10(18 - decimals), 1);
    }

    function _pow10(uint8 exp) internal pure returns (uint256 r) {
        r = 1;
        for (uint256 i = 0; i < exp; i++) {
            r *= 10;
            if (r == 0) revert BadConfig();
        }
    }

    function _getObservationAtOrBefore(PoolId poolId, uint64 target, uint8 index, uint8 cardinality)
        internal
        view
        returns (uint64 ts, uint256 cumulative)
    {
        Observation memory oldest = observations[poolId][index];
        if (oldest.timestamp != 0) {
            ts = oldest.timestamp;
            cumulative = oldest.sqrtPriceX96Cumulative;
        } else {
            uint8 oldestIndex = index;
            if (cardinality == OBSERVATION_CARDINALITY) {
                oldestIndex = index;
            } else {
                oldestIndex = 0;
            }
            Observation memory o = observations[poolId][oldestIndex];
            ts = o.timestamp;
            cumulative = o.sqrtPriceX96Cumulative;
        }

        for (uint256 k = 0; k < cardinality; k++) {
            uint8 j = index;
            if (j == 0) j = OBSERVATION_CARDINALITY;
            unchecked {
                j--;
            }
            Observation memory o = observations[poolId][j];
            if (o.timestamp == 0) break;
            if (o.timestamp <= target) return (o.timestamp, o.sqrtPriceX96Cumulative);
            index = j;
            ts = o.timestamp;
            cumulative = o.sqrtPriceX96Cumulative;
        }
    }

    function _deviationBps256(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == b) return 0;
        uint256 hi = a > b ? a : b;
        uint256 lo = a > b ? b : a;
        if (lo == 0) return type(uint256).max;
        return ((hi - lo) * 10_000) / lo;
    }

    function _price1e18FromSqrt(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 a = uint256(sqrtPriceX96);
        uint256 denom = uint256(1) << 192;
        uint256 q = FullMath.mulDiv(a, a, denom);
        uint256 r = mulmod(a, a, denom);
        return (q * 1e18) + Math.mulDiv(r, 1e18, denom);
    }
}
