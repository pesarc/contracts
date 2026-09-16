// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Custom errors for the Goldgard Uniswap-v4 hook.

error CircuitBreakerActive();
error OracleUnavailable();
error OracleDeviationTooHigh(uint256 deviationBps);
error InvalidFee(uint24 fee);
error OnlyReactiveCallbackProxy();
error OnlyAuthorized();
error BadConfig();
