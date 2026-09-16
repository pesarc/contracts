// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {OnlyHook} from "../errors/RewardDistributorErrors.sol";

import {ERC6909} from "v4-core/ERC6909.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";

/// @title Goldgard Reward Distributor
/// @notice Minimal ERC-6909 reward minter used by the hook to issue protocol
///         reward units without giving arbitrary accounts mint access.
contract RewardDistributor is ERC6909, Ownable2Step {
    uint256 public constant GGARD_ID = 1;

    address public hook;

    constructor(address _owner) Ownable(_owner) {}

    /// @notice Sets the only address allowed to mint reward units.
    function setHook(address _hook) external onlyOwner {
        hook = _hook;
    }

    /// @notice Mints GGARD reward units to a recipient after hook activity.
    function mintReward(address to, uint256 amount) external {
        if (msg.sender != hook) revert OnlyHook();
        _mint(to, GGARD_ID, amount);
    }
}
