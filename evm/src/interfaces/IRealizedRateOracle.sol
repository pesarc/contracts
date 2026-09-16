// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The slice of the RealizedRateOracle the prediction market depends on.
interface IRealizedRateOracle {
    function consult(
        address tokenIn,
        address tokenOut,
        uint32 window
    ) external view returns (uint256 twap1e18);
    function hasData(
        address tokenIn,
        address tokenOut
    ) external view returns (bool);
}
