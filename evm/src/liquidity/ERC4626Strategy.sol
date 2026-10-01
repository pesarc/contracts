// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "openzeppelin-contracts/contracts/interfaces/IERC4626.sol";
import {IStrategyAdapter} from "./IStrategyAdapter.sol";

/// @title  ERC4626Strategy
/// @notice Routes the vault's asset into any ERC-4626 vault and earns its yield.
///         The headline use is the Goldgard v4 hook's **SafetyModule** (gSAFE),
///         which backstops the corridor pool and earns the hook's swap PREMIUMS in
///         USDC — a real yield from the Uniswap-v4 hook, but denominated in the
///         vault's own asset with NO impermanent loss (unlike providing pool
///         liquidity directly, which would add local-currency exposure and break
///         "withdraw anytime"). The same adapter plugs in Morpho, a Yearn/ERC-4626
///         market, or any 4626 vault whose asset matches.
/// @dev    Only the CorridorVault calls deposit/withdraw. `totalAssets` reflects
///         accrued yield via the 4626's own `convertToAssets`. Withdrawals go
///         straight from the 4626 to the vault.
contract ERC4626Strategy is IStrategyAdapter {
    using SafeERC20 for IERC20;

    IERC20 public immutable assetToken;
    IERC4626 public immutable target;
    address public immutable vault;

    error NotVault();
    error ZeroAddress();
    error AssetMismatch();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor(address asset_, address erc4626_, address vault_) {
        if (asset_ == address(0) || erc4626_ == address(0) || vault_ == address(0)) revert ZeroAddress();
        if (IERC4626(erc4626_).asset() != asset_) revert AssetMismatch();
        assetToken = IERC20(asset_);
        target = IERC4626(erc4626_);
        vault = vault_;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    /// @notice Current value of the position in asset units (shares priced at the
    ///         4626's live exchange rate, so accrued premium/yield is included).
    function totalAssets() external view returns (uint256) {
        return target.convertToAssets(target.balanceOf(address(this)));
    }

    /// @notice Pull `amount` from the vault and deposit it into the 4626.
    function deposit(uint256 amount) external onlyVault {
        assetToken.safeTransferFrom(vault, address(this), amount);
        assetToken.forceApprove(address(target), amount);
        target.deposit(amount, address(this));
    }

    /// @notice Return up to `amount` of the asset to the vault. Capped at the
    ///         position's value so a rounding request can't revert the vault; a
    ///         full exit redeems all shares (avoids 1-wei share-rounding reverts).
    function withdraw(uint256 amount) external onlyVault returns (uint256 sent) {
        uint256 have = target.convertToAssets(target.balanceOf(address(this)));
        if (amount == 0 || have == 0) return 0;
        if (amount >= have) {
            return target.redeem(target.balanceOf(address(this)), vault, address(this));
        }
        target.withdraw(amount, vault, address(this));
        return amount;
    }
}
