// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IStrategyAdapter
/// @notice A yield venue the CorridorVault can allocate idle asset to (Aave,
///         Morpho, a DEX LP, …). One adapter wraps one venue behind a common
///         shape so the vault treats them uniformly. The vault is the only
///         caller of deposit/withdraw; `totalAssets` includes accrued yield so
///         the vault can value the position and crystallize the performance fee.
interface IStrategyAdapter {
    /// @notice The ERC-20 this adapter accepts (must equal the vault's asset).
    function asset() external view returns (address);

    /// @notice Current value of this adapter's position in `asset` units,
    ///         including accrued yield. Never reverts under normal operation.
    function totalAssets() external view returns (uint256);

    /// @notice Pull `amount` of `asset` from the caller (the vault) and deploy it
    ///         into the venue. The vault approves `amount` before calling.
    function deposit(uint256 amount) external;

    /// @notice Withdraw `amount` of `asset` from the venue back to the vault.
    ///         Returns the amount actually sent (<= amount on a shortfall).
    function withdraw(uint256 amount) external returns (uint256 sent);
}
