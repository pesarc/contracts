// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

import {OracleAdapter} from "./OracleAdapter.sol";

/// @title Goldgard Hedge Reserve
/// @notice Reserve inventory used by the hook to offset exposure after swaps
///         while guarding conversions with oracle sanity checks.
contract HedgeReserve is Ownable2Step {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    error BadConfig();
    error OnlyHook();
    error InsufficientLiquidity();
    error OracleDeviationTooHigh(uint256 deviationBps);

    event ReserveBalanceChanged(uint256 newBalance, int256 delta, address indexed triggeredBy);
    event ReserveBalanceChangedDetailed(
        address indexed token, uint256 newBalance, int256 delta, address indexed triggeredBy
    );

    address public hook;
    OracleAdapter public immutable oracle;
    IPoolManager public immutable manager;
    uint16 public maxSpotOracleDeviationBps;

    constructor(address _owner, IPoolManager _manager, OracleAdapter _oracle) Ownable(_owner) {
        manager = _manager;
        oracle = _oracle;
        maxSpotOracleDeviationBps = 10_000;
    }

    /// @notice Sets the hook allowed to move reserve inventory.
    function setHook(address _hook) external onlyOwner {
        hook = _hook;
    }

    /// @notice Caps how far spot price may drift from the oracle before reserve conversions stop.
    function setMaxSpotOracleDeviationBps(uint16 deviationBps) external onlyOwner {
        if (deviationBps == 0) revert BadConfig();
        maxSpotOracleDeviationBps = deviationBps;
    }

    /// @notice Transfers reserve inventory directly to the hook for settlement.
    function fundHook(Currency currency, uint256 amount, address to) external {
        if (msg.sender != hook) revert OnlyHook();
        address token = Currency.unwrap(currency);
        uint256 beforeBal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
        uint256 afterBal = IERC20(token).balanceOf(address(this));
        emit ReserveBalanceChangedDetailed(token, afterBal, int256(afterBal) - int256(beforeBal), msg.sender);
        emit ReserveBalanceChanged(afterBal, int256(afterBal) - int256(beforeBal), msg.sender);
    }

    /// @notice Converts token0 inventory into token1 using the strict reference price.
    /// @dev Reverts when spot and oracle prices diverge too far, protecting the reserve.
    function convertToken0ToToken1(PoolKey calldata key, uint256 amount0In, uint32)
        external
        returns (uint256 amount1Out)
    {
        if (msg.sender != hook) revert OnlyHook();

        uint256 p = oracle.getPrice1e18Strict(key);
        _checkSpotDeviation(key, p);
        amount1Out = Math.mulDiv(amount0In, p, 1e18);

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        uint256 before0 = IERC20(token0).balanceOf(address(this));
        uint256 before1 = IERC20(token1).balanceOf(address(this));

        IERC20(Currency.unwrap(key.currency0)).safeTransferFrom(msg.sender, address(this), amount0In);
        if (key.currency1.balanceOfSelf() < amount1Out) {
            revert InsufficientLiquidity();
        }
        key.currency1.transfer(msg.sender, amount1Out);

        uint256 after0 = IERC20(token0).balanceOf(address(this));
        uint256 after1 = IERC20(token1).balanceOf(address(this));
        emit ReserveBalanceChangedDetailed(token0, after0, int256(after0) - int256(before0), msg.sender);
        emit ReserveBalanceChangedDetailed(token1, after1, int256(after1) - int256(before1), msg.sender);
        emit ReserveBalanceChanged(after1, int256(after1) - int256(before1), msg.sender);
    }

    /// @notice Converts token1 inventory into token0 using the strict reference price.
    function convertToken1ToToken0(PoolKey calldata key, uint256 amount1In, uint32)
        external
        returns (uint256 amount0Out)
    {
        if (msg.sender != hook) revert OnlyHook();

        uint256 p = oracle.getPrice1e18Strict(key);
        _checkSpotDeviation(key, p);
        amount0Out = Math.mulDiv(amount1In, 1e18, p);

        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        uint256 before0 = IERC20(token0).balanceOf(address(this));
        uint256 before1 = IERC20(token1).balanceOf(address(this));

        IERC20(Currency.unwrap(key.currency1)).safeTransferFrom(msg.sender, address(this), amount1In);
        if (key.currency0.balanceOfSelf() < amount0Out) {
            revert InsufficientLiquidity();
        }
        key.currency0.transfer(msg.sender, amount0Out);

        uint256 after0 = IERC20(token0).balanceOf(address(this));
        uint256 after1 = IERC20(token1).balanceOf(address(this));
        emit ReserveBalanceChangedDetailed(token0, after0, int256(after0) - int256(before0), msg.sender);
        emit ReserveBalanceChangedDetailed(token1, after1, int256(after1) - int256(before1), msg.sender);
        emit ReserveBalanceChanged(after1, int256(after1) - int256(before1), msg.sender);
    }

    /// @notice Deprecated exact-out helper left in place to preserve interface compatibility.
    function rebalanceExactToken1Out(IPoolManager, PoolKey calldata, uint256, uint256) external pure {
        revert("deprecated");
    }

    /// @notice Deprecated exact-out helper left in place to preserve interface compatibility.
    function rebalanceExactToken0Out(IPoolManager, PoolKey calldata, uint256, uint256) external pure {
        revert("deprecated");
    }

    /// @dev Prevents reserve conversions from executing on clearly stale or manipulated spot prices.
    function _checkSpotDeviation(PoolKey calldata key, uint256 oraclePrice1e18) internal view {
        PoolId poolId = key.toId();
        (uint160 spotSqrtPriceX96,,,) = manager.getSlot0(poolId);
        uint256 spot = _price1e18FromSqrt(spotSqrtPriceX96);
        uint256 deviation = _deviationBps(spot, oraclePrice1e18);
        if (deviation > type(uint16).max) deviation = type(uint16).max;
        if (deviation > uint256(maxSpotOracleDeviationBps)) {
            revert OracleDeviationTooHigh(deviation);
        }
    }

    function _price1e18FromSqrt(uint160 sqrtPriceX96) internal pure returns (uint256) {
        uint256 a = uint256(sqrtPriceX96);
        uint256 denom = uint256(1) << 192;
        uint256 q = FullMath.mulDiv(a, a, denom);
        uint256 r = mulmod(a, a, denom);
        return (q * 1e18) + Math.mulDiv(r, 1e18, denom);
    }

    function _deviationBps(uint256 a, uint256 b) internal pure returns (uint256) {
        if (a == b) return 0;
        uint256 hi = a > b ? a : b;
        uint256 lo = a > b ? b : a;
        if (lo == 0) return type(uint256).max;
        return ((hi - lo) * 10_000) / lo;
    }
}
