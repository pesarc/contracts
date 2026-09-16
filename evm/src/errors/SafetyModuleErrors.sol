// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Custom errors for the safety module (premium vault + claims).

error BadConfig();
error OnlyHook();
error OnlyReactiveCallbackProxy();
error OnlyAuthorized();
error ClaimPending();
error CooldownNotPassed();
error ClaimsPaused();
error NotEligible();
error ZeroPayout();
error ClaimsViewAlreadySet();
error ClaimsViewNotSet();
error NoPendingClaimsView();
error ClaimsViewNotReady();
