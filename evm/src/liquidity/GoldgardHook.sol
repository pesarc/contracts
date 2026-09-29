// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {
    CircuitBreakerActive,
    OracleUnavailable,
    OracleDeviationTooHigh,
    InvalidFee,
    OnlyReactiveCallbackProxy,
    OnlyAuthorized,
    BadConfig
} from "../errors/GoldgardHookErrors.sol";

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {SafeCast as OZSafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";

import {BaseHook} from "./libraries/BaseHook.sol";
import {Transient} from "./libraries/Transient.sol";
import {OracleAdapter} from "./OracleAdapter.sol";
import {SafetyModule} from "./SafetyModule.sol";
import {HedgeReserve} from "./HedgeReserve.sol";
import {RewardDistributor} from "./RewardDistributor.sol";
import {GoldgardMath} from "./GoldgardMath.sol";
import {PoolConfig, PositionInfo} from "./GoldgardHookTypes.sol";
import {IGoldgardHookEvents} from "./IGoldgardHookEvents.sol";

/// @title Goldgard Hook
/// @notice Main Uniswap v4 hook for Goldgard. It defends swaps with oracle-aware
///         fees and a circuit breaker, routes insurance premiums into the safety
///         module, tracks LP eligibility for claims, and coordinates reserve rebalancing.
contract GoldgardHook is BaseHook, Ownable2Step, IUnlockCallback, IGoldgardHookEvents {
    using Hooks for IHooks;
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using LPFeeLibrary for uint24;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using StateLibrary for IPoolManager;

    // Events are declared in IGoldgardHookEvents (inherited above).

    uint256 public constant BPS = 10_000;
    uint256 public constant PREMIUM_BPS = 2;
    uint16 internal constant MAX_PREMIUM_BPS = 100;
    uint16 internal constant MAX_COVERAGE_CAP_BPS = 10_000;
    uint64 internal constant ALERT_TTL_SECONDS = 30 minutes;

    bytes32 internal constant TS_REBALANCE_IN_PROGRESS = keccak256("GGARD/rebalance/inProgress");
    bytes32 internal constant TS_REBALANCE_AMOUNT_IN = keccak256("GGARD/rebalance/amountIn");
    bytes32 internal constant TS_REBALANCE_AMOUNT_OUT = keccak256("GGARD/rebalance/amountOut");

    // PoolConfig + PositionInfo structs are defined in GoldgardHookTypes.sol.

    OracleAdapter public immutable oracle;
    SafetyModule public immutable safetyModule;
    HedgeReserve public immutable hedgeReserve;
    RewardDistributor public immutable rewards;

    mapping(PoolId => PoolConfig) public poolConfig;
    mapping(PoolId => PoolKey) public poolKeys;
    mapping(bytes32 => PositionInfo) public positions;
    mapping(PoolId => uint256) public pendingToken0In;
    mapping(PoolId => uint256) public pendingToken1In;

    address public reactiveCallbackProxy;
    address public authorizedCaller;
    uint256 public reactiveAlert;
    uint256 public minRebalanceAmountIn;
    uint16 public premiumBps;
    uint16 public coverageCapBps;

    constructor(
        address _owner,
        IPoolManager _manager,
        OracleAdapter _oracle,
        SafetyModule _safetyModule,
        HedgeReserve _hedgeReserve,
        RewardDistributor _rewards
    ) BaseHook(_manager) Ownable(_owner) {
        oracle = _oracle;
        safetyModule = _safetyModule;
        hedgeReserve = _hedgeReserve;
        rewards = _rewards;
        premiumBps = uint16(PREMIUM_BPS);
        coverageCapBps = MAX_COVERAGE_CAP_BPS;

        Hooks.Permissions memory perms;
        perms.afterAddLiquidity = true;
        perms.afterRemoveLiquidity = true;
        perms.beforeSwap = true;
        perms.afterSwap = true;
        perms.afterSwapReturnDelta = true;
        perms.afterAddLiquidityReturnDelta = false;
        perms.afterRemoveLiquidityReturnDelta = false;
        Hooks.validateHookPermissions(this, perms);
    }

    modifier onlyReactiveCallbackProxy() {
        if (msg.sender != reactiveCallbackProxy) revert OnlyReactiveCallbackProxy();
        _;
    }

    modifier onlyAuthorized() {
        if (msg.sender != authorizedCaller) revert OnlyAuthorized();
        _;
    }

    /// @notice Sets the Reactive callback proxy address once for this hook.
    function setReactiveCallbackProxy(address proxy) external onlyOwner {
        if (proxy == address(0)) revert BadConfig();
        if (reactiveCallbackProxy != address(0)) revert BadConfig();
        reactiveCallbackProxy = proxy;
        emit ReactiveCallbackProxySet(proxy);
    }

    /// @notice Sets the address allowed to mutate alert and premium policy.
    function setAuthorizedCaller(address caller) external onlyOwner {
        if (caller == address(0)) revert BadConfig();
        authorizedCaller = caller;
        emit AuthorizedCallerSet(caller);
    }

    /// @notice Sets the maximum claim coverage cap in basis points.
    function setCoverageCapBps(uint256 newCapBps) external onlyOwner {
        if (newCapBps > MAX_COVERAGE_CAP_BPS) revert BadConfig();
        coverageCapBps = OZSafeCast.toUint16(newCapBps);
    }

    /// @notice Returns the active Reactive alert level and its expiry.
    function getReactiveAlert() external view returns (uint8 level, uint64 until) {
        uint256 packed = reactiveAlert;
        level = uint8(packed);
        until = uint64(packed >> 8);
    }

    /// @notice Stores a temporary alert that pre-warms the defensive fee curve.
    function setAlertLevel(uint8 level) external onlyAuthorized {
        uint64 until = uint64(block.timestamp + ALERT_TTL_SECONDS);
        reactiveAlert = (uint256(until) << 8) | uint256(level);
        emit AlertLevelRaised(level, until);
    }

    /// @notice Backwards-compatible alias for `setAlertLevel`.
    function raiseAlertLevel(uint8 level) external onlyAuthorized {
        uint64 until = uint64(block.timestamp + ALERT_TTL_SECONDS);
        reactiveAlert = (uint256(until) << 8) | uint256(level);
        emit AlertLevelRaised(level, until);
    }

    /// @notice Sets the minimum size required before a pending rebalance can execute.
    function setRebalanceThreshold(uint256 newThreshold) external onlyAuthorized {
        minRebalanceAmountIn = newThreshold;
        emit RebalanceThresholdTightened(newThreshold);
    }

    /// @notice Backwards-compatible alias for `setRebalanceThreshold`.
    function tightenRebalanceThreshold(uint256 newThreshold) external onlyAuthorized {
        minRebalanceAmountIn = newThreshold;
        emit RebalanceThresholdTightened(newThreshold);
    }

    /// @notice Sets the swap premium rate in basis points.
    function setPremiumRate(uint256 newRateBps) external onlyAuthorized {
        if (newRateBps > MAX_PREMIUM_BPS) revert BadConfig();
        premiumBps = OZSafeCast.toUint16(newRateBps);
        emit PremiumRateAdjusted(premiumBps);
    }

    /// @notice Backwards-compatible alias for `setPremiumRate`.
    function adjustPremiumRate(uint256 newRateBps) external onlyAuthorized {
        if (newRateBps > MAX_PREMIUM_BPS) revert BadConfig();
        premiumBps = OZSafeCast.toUint16(newRateBps);
        emit PremiumRateAdjusted(premiumBps);
    }

    /// @notice Registers pool-specific fee, breaker, and rebalance settings.
    function setPoolConfig(PoolKey calldata key, PoolConfig calldata cfg) external onlyOwner {
        if (cfg.maxLpFee < cfg.baseLpFee) revert InvalidFee(cfg.maxLpFee);
        if (cfg.rebalanceBps > BPS) revert InvalidFee(uint24(cfg.rebalanceBps));
        poolConfig[key.toId()] = cfg;
        poolKeys[key.toId()] = key;
    }

    /// @notice Computes the dynamic LP fee before each swap.
    /// @dev This is the core defense path: refresh oracle state, enforce the breaker, then override the fee.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolConfig storage cfg = poolConfig[poolId];
        if (cfg.pausedUntil != 0 && block.timestamp < cfg.pausedUntil) {
            revert CircuitBreakerActive();
        }

        oracle.updateFromPool(manager, key);

        (uint160 spotSqrtPriceX96, uint160 oracleSqrtPriceX96) =
            _loadOracleSqrtPricesAndEmit(key, poolId, cfg.twapWindowSeconds);
        if (oracleSqrtPriceX96 == 0) revert OracleUnavailable();

        uint256 deviationBps = GoldgardMath.deviationBps(spotSqrtPriceX96, oracleSqrtPriceX96);
        _enforceCircuitBreaker(cfg, poolId, deviationBps);

        uint256 feeDeviationBps =
            GoldgardMath.applyReactiveAlertBump(reactiveAlert, cfg.deviationBps, deviationBps, uint64(block.timestamp));
        uint24 dynFee = GoldgardMath.computeDynamicFee(
            cfg.baseLpFee, cfg.maxLpFee, cfg.feeSlopeBps, cfg.deviationBps, feeDeviationBps
        );

        uint24 overrideFee = dynFee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (GoldgardHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, overrideFee);
    }

    function _loadOracleSqrtPricesAndEmit(PoolKey calldata key, PoolId poolId, uint32 twapWindowSeconds)
        internal
        returns (uint160 spotSqrtPriceX96, uint160 oracleSqrtPriceX96)
    {
        (spotSqrtPriceX96,,,) = manager.getSlot0(poolId);

        (uint160 clSqrtPriceX96, bool ok) = oracle.getChainlinkSqrtPriceX96(key);
        (uint160 twapSqrtPriceX96, bool twapOk) = oracle.getTwapSqrtPriceX96IfFresh(key, twapWindowSeconds);
        // Prefer fresh Chainlink when available, but keep recent pool activity as a live-safe fallback.
        oracleSqrtPriceX96 = ok ? clSqrtPriceX96 : twapSqrtPriceX96;

        if (ok && twapOk) {
            uint256 twap = GoldgardMath.price1e18FromSqrt(twapSqrtPriceX96);
            uint256 external_ = GoldgardMath.price1e18FromSqrt(clSqrtPriceX96);
            uint256 oracleDeviationBps = GoldgardMath.deviationBps256(twap, external_);
            emit OraclePriceUpdated(twap, external_, oracleDeviationBps, block.timestamp);
        }
    }

    function _enforceCircuitBreaker(PoolConfig storage cfg, PoolId poolId, uint256 deviationBps) internal {
        if (deviationBps <= cfg.circuitBreakerBps) return;

        uint64 until = uint64(block.timestamp + cfg.circuitBreakerCooldownSeconds);
        cfg.pausedUntil = until;
        emit CircuitBreakerTripped(poolId, until, deviationBps);
        revert OracleDeviationTooHigh(deviationBps);
    }

    /// @notice Pulls the swap-funded premium after execution and updates reserve/reward state.
    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        if (Transient.tloadU256(TS_REBALANCE_IN_PROGRESS) == 1) {
            return (GoldgardHook.afterSwap.selector, 0);
        }
        return _afterSwap(sender, key, params, delta);
    }

    /// @dev Moves premium into the safety module and tracks a portion of flow for later rebalancing.
    function _afterSwap(address sender, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta)
        internal
        returns (bytes4, int128)
    {
        PoolId poolId = key.toId();
        PoolConfig memory cfg = poolConfig[poolId];

        (Currency feeCurrency, uint256 premium) = GoldgardMath.computePremium(key, params, delta, premiumBps);
        if (premium == 0) return (GoldgardHook.afterSwap.selector, 0);

        manager.take(feeCurrency, address(this), premium);
        uint256 usdcDeposited = _depositPremium(key, cfg, feeCurrency, premium);
        _trackPendingRebalance(poolId, cfg, delta);

        uint256 reward = usdcDeposited / 100;
        if (reward > 0) rewards.mintReward(sender, reward);

        emit PremiumDiverted(poolId, sender, feeCurrency, premium, usdcDeposited, premiumBps);
        emit PremiumTaken(poolId, feeCurrency, premium, usdcDeposited);
        return (GoldgardHook.afterSwap.selector, premium.toInt128());
    }

    /// @dev Converts non-reserve premiums into token1, then deposits them into the safety module.
    function _depositPremium(PoolKey calldata key, PoolConfig memory cfg, Currency feeCurrency, uint256 premium)
        internal
        returns (uint256 usdcDeposited)
    {
        if (feeCurrency == key.currency1) {
            IERC20(Currency.unwrap(key.currency1)).approve(address(safetyModule), premium);
            safetyModule.depositPremium(premium);
            return premium;
        }

        IERC20(Currency.unwrap(key.currency0)).approve(address(hedgeReserve), premium);
        uint256 converted = hedgeReserve.convertToken0ToToken1(key, premium, cfg.twapWindowSeconds);
        IERC20(Currency.unwrap(key.currency1)).approve(address(safetyModule), converted);
        safetyModule.depositPremium(converted);
        return converted;
    }

    /// @dev Records pending hedge volume so rebalancing can be executed out-of-band.
    function _trackPendingRebalance(PoolId poolId, PoolConfig memory cfg, BalanceDelta delta) internal {
        if (cfg.rebalanceBps == 0) return;

        int256 poolDelta0 = -int256(delta.amount0());
        int256 poolDelta1 = -int256(delta.amount1());

        if (poolDelta0 > 0) {
            uint256 amount0In = (OZSafeCast.toUint256(poolDelta0) * cfg.rebalanceBps) / BPS;
            pendingToken0In[poolId] += amount0In;
        } else if (poolDelta1 > 0) {
            uint256 amount1In = (OZSafeCast.toUint256(poolDelta1) * cfg.rebalanceBps) / BPS;
            pendingToken1In[poolId] += amount1In;
        }
    }

    /// @notice Tracks liquidity additions so LPs can later qualify for coverage and claims.
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        if (params.liquidityDelta <= 0) {
            return (GoldgardHook.afterAddLiquidity.selector, toBalanceDelta(0, 0));
        }
        return _afterAddLiquidity(sender, key, params, delta, hookData);
    }

    /// @dev Updates insured position state after liquidity is added and captures enrollment pricing.
    function _afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal returns (bytes4, BalanceDelta) {
        address owner = GoldgardMath.resolveOwner(sender, hookData);
        PoolId poolId = key.toId();
        bytes32 positionKey = GoldgardMath.positionKey(poolId, owner, params);

        PositionInfo storage p = positions[positionKey];
        _updatePositionAccrual(p, _currentTick(poolId));
        p.tickLower = params.tickLower;
        p.tickUpper = params.tickUpper;

        p.liquidity += uint256(params.liquidityDelta).toUint128();
        _applyPrincipalOnAdd(p, key, delta);
        _enrollIfNeededByKey(positionKey, key, owner);

        return (GoldgardHook.afterAddLiquidity.selector, toBalanceDelta(0, 0));
    }

    function _currentTick(PoolId poolId) internal view returns (int24 tick) {
        (, tick,,) = manager.getSlot0(poolId);
    }

    /// @dev Converts newly added principal into token1 terms for later claim accounting.
    function _applyPrincipalOnAdd(PositionInfo storage p, PoolKey calldata key, BalanceDelta delta) internal {
        uint256 amount0 = delta.amount0() < 0 ? OZSafeCast.toUint256(int256(-delta.amount0())) : 0;
        uint256 amount1 = delta.amount1() < 0 ? OZSafeCast.toUint256(int256(-delta.amount1())) : 0;

        uint256 price1e18 = oracle.getPrice1e18Strict(key);
        p.principalToken1 += amount1 + Math.mulDiv(amount0, price1e18, 1e18);
    }

    /// @dev Locks the position's initial reference price so IL can be measured later.
    function _enrollIfNeededByKey(bytes32 positionKey, PoolKey calldata key, address owner) internal {
        PositionInfo storage p = positions[positionKey];
        if (p.enrolledSqrtPriceX96 != 0) return;
        uint32 window = poolConfig[key.toId()].twapWindowSeconds;
        (uint160 referenceSqrtPriceX96,) = oracle.getReferenceSqrtPriceX96(key, window);
        if (referenceSqrtPriceX96 == 0) revert OracleUnavailable();
        p.enrolledSqrtPriceX96 = referenceSqrtPriceX96;
        emit LiquidityEnrolled(key.toId(), positionKey, owner, p.liquidity);
    }

    /// @notice Updates insured position state when liquidity is removed.
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        if (params.liquidityDelta >= 0) {
            return (GoldgardHook.afterRemoveLiquidity.selector, toBalanceDelta(0, 0));
        }

        address owner = GoldgardMath.resolveOwner(sender, hookData);
        PoolId poolId = key.toId();
        bytes32 positionKey = keccak256(abi.encode(poolId, owner, params.tickLower, params.tickUpper, params.salt));

        PositionInfo storage p = positions[positionKey];
        if (p.liquidity == 0) {
            return (GoldgardHook.afterRemoveLiquidity.selector, toBalanceDelta(0, 0));
        }

        (, int24 tick,,) = manager.getSlot0(poolId);
        _updatePositionAccrual(p, tick);

        uint128 removed = uint256(-params.liquidityDelta).toUint128();
        if (removed > p.liquidity) removed = p.liquidity;

        uint128 prevLiquidity = p.liquidity;
        p.liquidity = prevLiquidity - removed;

        if (p.principalToken1 != 0) {
            p.principalToken1 = Math.mulDiv(p.principalToken1, uint256(p.liquidity), uint256(prevLiquidity));
        }

        if (p.liquidity == 0) {
            delete positions[positionKey];
        }

        return (GoldgardHook.afterRemoveLiquidity.selector, toBalanceDelta(0, 0));
    }

    /// @notice Returns whether an LP position spent enough time in range to qualify for coverage.
    function isEligible(address account, PoolId poolId) external view returns (bool) {
        bytes32 k = _anyPositionKey(poolId, account);
        PositionInfo memory p = positions[k];
        if (p.liquidity == 0) return false;

        uint256 total = p.totalLiquiditySeconds;
        uint256 inRange = p.inRangeLiquiditySeconds;
        if (p.lastTimestamp != 0 && block.timestamp > p.lastTimestamp) {
            (, int24 tick,,) = manager.getSlot0(poolId);
            uint256 dt = block.timestamp - uint256(p.lastTimestamp);
            uint256 liqSeconds = uint256(p.liquidity) * dt;
            total += liqSeconds;
            if (tick >= p.tickLower && tick < p.tickUpper) {
                inRange += liqSeconds;
            }
        }

        if (total == 0) return true;
        return inRange * 100 >= total * 80;
    }

    /// @notice Estimates the LP's insurance payout from impermanent loss since enrollment.
    /// @dev Payout is capped by both the configured coverage cap and available reserve assets.
    function previewClaim(address account, PoolId poolId) external view returns (uint256 payoutAssets) {
        bytes32 k = _anyPositionKey(poolId, account);
        PositionInfo memory p = positions[k];
        if (p.enrolledSqrtPriceX96 == 0 || p.principalToken1 == 0) return 0;

        uint256 p0 = Math.mulDiv(
            Math.mulDiv(uint256(p.enrolledSqrtPriceX96), uint256(p.enrolledSqrtPriceX96), uint256(1) << 192), 1e18, 1
        );
        PoolKey memory key = poolKeys[poolId];
        uint256 current = oracle.getPrice1e18Strict(key);
        if (current == 0 || p0 == 0) return 0;
        uint256 r = Math.mulDiv(current, 1e18, p0);

        uint256 ilBps = GoldgardMath.impermanentLossBps(r);
        uint16 cap = coverageCapBps;
        if (ilBps > cap) ilBps = cap;
        payoutAssets = Math.mulDiv(p.principalToken1, ilBps, BPS);

        uint256 available = IERC20(address(safetyModule.asset())).balanceOf(address(safetyModule));
        if (payoutAssets > available) payoutAssets = available;
    }

    /// @notice Executes a reserve-backed hedge rebalance for accumulated pending flow.
    function rebalance(PoolKey calldata key, bool zeroForOne, uint256 maxAmountIn)
        external
        returns (uint256 amountOut)
    {
        PoolId poolId = key.toId();
        PoolConfig memory cfg = poolConfig[poolId];
        if (cfg.rebalanceBps == 0) return 0;

        uint256 pending = zeroForOne ? pendingToken0In[poolId] : pendingToken1In[poolId];
        uint256 amountIn = pending;
        if (maxAmountIn != 0 && amountIn > maxAmountIn) amountIn = maxAmountIn;
        if (minRebalanceAmountIn != 0 && amountIn < minRebalanceAmountIn) return 0;
        if (amountIn == 0) return 0;

        bytes memory ret = manager.unlock(abi.encode(key, zeroForOne, amountIn));
        amountOut = abi.decode(ret, (uint256));

        if (zeroForOne) pendingToken0In[poolId] -= amountIn;
        else pendingToken1In[poolId] -= amountIn;

        emit RebalanceExecuted(poolId, zeroForOne, amountIn, amountOut);
    }

    /// @notice Pool-manager callback that performs the rebalance atomically inside `unlock`.
    function unlockCallback(bytes calldata data) external override onlyPoolManager returns (bytes memory) {
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));

        Transient.tstoreU256(TS_REBALANCE_IN_PROGRESS, 1);
        Transient.tstoreU256(TS_REBALANCE_AMOUNT_IN, amountIn);
        Transient.tstoreU256(TS_REBALANCE_AMOUNT_OUT, 0);

        hedgeReserve.fundHook(zeroForOne ? key.currency0 : key.currency1, amountIn, address(this));
        uint256 amountOut = _rebalanceSwap(key, zeroForOne, amountIn);

        Transient.tstoreU256(TS_REBALANCE_AMOUNT_OUT, amountOut);
        _clearTransientRebalanceState();

        return abi.encode(amountOut);
    }

    /// @dev Clears all transient rebalance slots before control returns to outer frames.
    function _clearTransientRebalanceState() internal {
        Transient.tstoreU256(TS_REBALANCE_IN_PROGRESS, 0);
        Transient.tstoreU256(TS_REBALANCE_AMOUNT_IN, 0);
        Transient.tstoreU256(TS_REBALANCE_AMOUNT_OUT, 0);
    }

    /// @dev Performs the actual swap leg of the rebalance and settles the reserve-facing transfers.
    function _rebalanceSwap(PoolKey memory key, bool zeroForOne, uint256 amountIn)
        internal
        returns (uint256 amountOut)
    {
        SwapParams memory p = SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -amountIn.toInt256(),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        BalanceDelta d = manager.swap(key, p, new bytes(0));

        if (zeroForOne) {
            uint256 in0 = OZSafeCast.toUint256(int256(-d.amount0()));
            amountOut = OZSafeCast.toUint256(int256(d.amount1()));

            manager.sync(key.currency0);
            IERC20(Currency.unwrap(key.currency0)).safeTransfer(address(manager), in0);
            manager.settle();

            manager.take(key.currency1, address(this), amountOut);
            IERC20(Currency.unwrap(key.currency1)).safeTransfer(address(hedgeReserve), amountOut);
        } else {
            uint256 in1 = OZSafeCast.toUint256(int256(-d.amount1()));
            amountOut = OZSafeCast.toUint256(int256(d.amount0()));

            manager.sync(key.currency1);
            IERC20(Currency.unwrap(key.currency1)).safeTransfer(address(manager), in1);
            manager.settle();

            manager.take(key.currency0, address(this), amountOut);
            IERC20(Currency.unwrap(key.currency0)).safeTransfer(address(hedgeReserve), amountOut);
        }
    }

    /// @dev Allows integrators to pass the logical LP owner through 20 bytes of hook data.
    function _updatePositionAccrual(PositionInfo storage p, int24 currentTick) internal {
        uint64 t = uint64(block.timestamp);
        if (p.lastTimestamp == 0) {
            p.lastTimestamp = t;
            return;
        }
        uint64 dt = t - p.lastTimestamp;
        if (dt == 0 || p.liquidity == 0) {
            p.lastTimestamp = t;
            return;
        }
        uint256 liqSeconds = uint256(p.liquidity) * uint256(dt);
        p.totalLiquiditySeconds += liqSeconds;

        bool inRange = currentTick >= p.tickLower && currentTick < p.tickUpper;
        if (inRange) p.inRangeLiquiditySeconds += liqSeconds;

        p.lastTimestamp = t;
    }

    // Pure pricing / deviation / fee math lives in the GoldgardMath library.

    function _anyPositionKey(PoolId poolId, address account) internal view returns (bytes32) {
        PoolKey memory key = poolKeys[poolId];
        int24 lower = TickMath.minUsableTick(key.tickSpacing);
        int24 upper = TickMath.maxUsableTick(key.tickSpacing);
        return keccak256(abi.encode(poolId, account, lower, upper, bytes32(0)));
    }
}
