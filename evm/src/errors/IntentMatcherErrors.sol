// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Custom errors for the intent matcher (local-currency P2P settlement).

error BadAmount();
error BadRecipient();
error BadToken();
error NotMaker();
error NotSolver();
error IntentInactive();
error IntentExpired();
error NotExpired();
error NotOpposing();
error LimitNotMet();
error FillTooLarge();
error BadRing();
error DuplicateIntent();
