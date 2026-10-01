// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CorridorVault} from "../src/liquidity/CorridorVault.sol";
import {ReserveStrategy} from "../src/liquidity/ReserveStrategy.sol";
import {AaveV3Adapter} from "../src/liquidity/AaveV3Adapter.sol";

/// @notice Deploy a strategy adapter for a CorridorVault AND register it in one
///         transaction, so the vault has a market to allocate into. The broadcaster
///         MUST be the vault owner (addStrategy is onlyOwner).
///
/// @dev Picks the venue from env:
///   - AAVE_POOL set   -> AaveV3Adapter (needs AAVE_ATOKEN too; Aave chains only)
///   - AAVE_POOL unset -> ReserveStrategy (chain-agnostic hold; works on Arc)
///
/// Env:
///   VAULT_ADDRESS  the deployed CorridorVault (required)
///   AAVE_POOL      optional Aave V3 Pool; when set, deploys the Aave adapter
///   AAVE_ATOKEN    the aToken for the vault asset (required iff AAVE_POOL set)
///
/// The vault asset is read from the vault itself, so the adapter can never be
/// registered against the wrong asset.
///
/// Example (Arc testnet, allowed):
///   VAULT_ADDRESS=0x… forge script script/DeployAndRegisterStrategy.s.sol \
///     --rpc-url $RPC --broadcast
contract DeployAndRegisterStrategy is Script {
    function run() external {
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        CorridorVault vault = CorridorVault(vaultAddr);
        address asset = vault.asset();
        address pool = vm.envOr("AAVE_POOL", address(0));

        vm.startBroadcast();
        address adapter;
        if (pool != address(0)) {
            address aToken = vm.envAddress("AAVE_ATOKEN");
            adapter = address(new AaveV3Adapter(asset, pool, aToken, vaultAddr));
        } else {
            adapter = address(new ReserveStrategy(asset, vaultAddr));
        }
        vault.addStrategy(adapter);
        vm.stopBroadcast();

        console2.log("Strategy adapter", adapter);
        console2.log("  asset         ", asset);
        console2.log("  registered on ", vaultAddr);
        console2.log("  kind          ", pool != address(0) ? "AaveV3Adapter" : "ReserveStrategy");
    }
}
