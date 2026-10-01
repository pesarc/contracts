// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CorridorVault} from "../src/liquidity/CorridorVault.sol";

/// @notice Unregister a strategy adapter from a CorridorVault (owner only).
/// @dev The vault requires the adapter to hold nothing (`totalAssets() == 0`), so
///      deallocate it fully first if it has funds. The broadcaster must be the
///      vault owner. Use it to drop a stale or mistakenly-registered market.
///
/// Env:
///   VAULT_ADDRESS     the CorridorVault
///   STRATEGY_ADDRESS  the adapter to remove
///
///   VAULT_ADDRESS=0x… STRATEGY_ADDRESS=0x… forge script script/RemoveStrategy.s.sol:RemoveStrategy \
///     --rpc-url $RPC --broadcast --interactive
contract RemoveStrategy is Script {
    function run() external {
        address vault = vm.envAddress("VAULT_ADDRESS");
        address strategy = vm.envAddress("STRATEGY_ADDRESS");

        vm.startBroadcast();
        CorridorVault(vault).removeStrategy(strategy);
        vm.stopBroadcast();

        console2.log("Removed strategy", strategy);
        console2.log("  from vault    ", vault);
    }
}
