// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {AaveV3Adapter} from "../src/liquidity/AaveV3Adapter.sol";

/// @notice Deploy an AaveV3Adapter for a CorridorVault on a chain that has Aave
///         V3 (Base, Arbitrum, Optimism, Polygon, Ethereum — not Arc).
/// @dev Env:
///   VAULT_ASSET   the asset (USDC) — must equal the vault's asset
///   AAVE_POOL     the Aave V3 Pool address on this chain
///   AAVE_ATOKEN   the aToken for VAULT_ASSET on this chain
///   VAULT_ADDRESS the deployed CorridorVault
///
/// After deploying, the vault owner calls `vault.addStrategy(adapter)`.
contract DeployAaveAdapter is Script {
    function run() external {
        address asset = vm.envAddress("VAULT_ASSET");
        address pool = vm.envAddress("AAVE_POOL");
        address aToken = vm.envAddress("AAVE_ATOKEN");
        address vault = vm.envAddress("VAULT_ADDRESS");

        vm.startBroadcast();
        AaveV3Adapter adapter = new AaveV3Adapter(asset, pool, aToken, vault);
        vm.stopBroadcast();

        console2.log("AaveV3Adapter", address(adapter));
        console2.log("  -> vault owner must call vault.addStrategy(", address(adapter), ")");
    }
}
