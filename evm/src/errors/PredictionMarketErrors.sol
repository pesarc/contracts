// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Custom errors for the prediction & hedge market. File-level so the selectors
// are stable and the contract body stays focused on logic.

error BadParam();
error NotTrading();
error TradingClosed();
error TooEarly();
error NotAttestor();
error WrongSourceKind();
error DisputesDisabled();
error WindowClosed();
error WindowOpen();
error BadStatus();
error NoOracleData();
error AlreadyClaimed();
error NothingToClaim();
error NotInvalid();
