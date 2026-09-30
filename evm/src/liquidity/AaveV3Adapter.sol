// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IStrategyAdapter} from "./IStrategyAdapter.sol";

/// @notice The subset of the Aave V3 Pool this adapter uses.
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/// @title AaveV3Adapter
/// @notice Supplies the vault's asset (USDC) to Aave V3 and earns lending yield.
///         The aToken is 1:1 with the underlying and accrues interest, so
///         `totalAssets` = the adapter's aToken balance. Only the vault can move
///         funds; withdrawals are sent straight from Aave to the vault. This is
///         the lowest-risk strategy — the conservative first venue.
/// @dev    Lives only on chains with an Aave V3 deployment (Base, Arbitrum,
///         Optimism, Polygon, Ethereum) — not Arc.
contract AaveV3Adapter is IStrategyAdapter {
    using SafeERC20 for IERC20;

    IERC20 public immutable assetToken;
    IAaveV3Pool public immutable pool;
    IERC20 public immutable aToken;
    address public immutable vault;

    error NotVault();
    error ZeroAddress();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor(address asset_, address pool_, address aToken_, address vault_) {
        if (asset_ == address(0) || pool_ == address(0) || aToken_ == address(0) || vault_ == address(0)) {
            revert ZeroAddress();
        }
        assetToken = IERC20(asset_);
        pool = IAaveV3Pool(pool_);
        aToken = IERC20(aToken_);
        vault = vault_;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    /// @notice Value of the position (aToken accrues interest 1:1 with underlying).
    function totalAssets() external view returns (uint256) {
        return aToken.balanceOf(address(this));
    }

    /// @notice Pull `amount` from the vault and supply it to Aave.
    function deposit(uint256 amount) external onlyVault {
        assetToken.safeTransferFrom(vault, address(this), amount);
        assetToken.forceApprove(address(pool), amount);
        pool.supply(address(assetToken), amount, address(this), 0);
    }

    /// @notice Withdraw `amount` from Aave straight to the vault. Aave caps the
    ///         amount at the available balance and returns what was sent.
    function withdraw(uint256 amount) external onlyVault returns (uint256 sent) {
        sent = pool.withdraw(address(assetToken), amount, vault);
    }
}
