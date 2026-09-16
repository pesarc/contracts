// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Custom errors for the hedge reserve.

error BadConfig();
error OnlyHook();
error InsufficientLiquidity();
error OracleDeviationTooHigh(uint256 deviationBps);
