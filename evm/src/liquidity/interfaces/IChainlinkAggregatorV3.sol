// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Minimal Chainlink AggregatorV3 Interface
/// @notice Narrow interface used by `OracleAdapter` to read external reference prices.
interface IChainlinkAggregatorV3 {
    /// @notice Returns the number of decimals used by the feed answer.
    function decimals() external view returns (uint8);

    /// @notice Returns the latest round payload exposed by the feed.
    /// @dev `OracleAdapter` relies on `answer` and `updatedAt` for freshness checks.
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}
