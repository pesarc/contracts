// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategyAdapter} from "./IStrategyAdapter.sol";

/// @title ReserveStrategy
/// @notice A chain-agnostic strategy that simply HOLDS the vault's asset as a
///         reserve. It needs no external venue, so it works on EVERY chain the
///         vault runs on — including Arc, which has no Aave. `totalAssets` is the
///         adapter's own balance, so any yield routed in (a rewards transfer, a
///         market rebate, a manual top-up on testnet) is reflected automatically
///         and the vault crystallizes its performance fee on it. Only the vault
///         can move funds. Use it as the baseline venue, or anywhere a lending
///         market (AaveV3Adapter) isn't available yet.
contract ReserveStrategy is IStrategyAdapter {
    using SafeERC20 for IERC20;

    IERC20 public immutable assetToken;
    address public immutable vault;

    error NotVault();
    error ZeroAddress();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor(address asset_, address vault_) {
        if (asset_ == address(0) || vault_ == address(0)) revert ZeroAddress();
        assetToken = IERC20(asset_);
        vault = vault_;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    /// @notice Value held = the adapter's balance of the asset.
    function totalAssets() external view returns (uint256) {
        return assetToken.balanceOf(address(this));
    }

    /// @notice Pull `amount` of the asset from the vault into the reserve.
    function deposit(uint256 amount) external onlyVault {
        assetToken.safeTransferFrom(vault, address(this), amount);
    }

    /// @notice Return up to `amount` of the asset to the vault (capped at the
    ///         balance so a rounding request can never revert the vault).
    function withdraw(uint256 amount) external onlyVault returns (uint256 sent) {
        uint256 bal = assetToken.balanceOf(address(this));
        sent = amount > bal ? bal : amount;
        assetToken.safeTransfer(vault, sent);
    }
}
