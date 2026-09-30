// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CorridorVault} from "../src/liquidity/CorridorVault.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

/// @notice Deploy a CorridorVault for one asset (USDC) on the active chain.
/// @dev Env:
///   VAULT_ASSET     the ERC-20 the vault accepts (USDC). Falls back to
///                   USDC_ADDRESS, then the Arc native-USDC predeploy.
///   VAULT_NAME      ERC-20 name  (default "Pesarc Corridor USDC")
///   VAULT_SYMBOL    ERC-20 symbol (default "pcUSDC")
///   VAULT_OPERATOR  the solver allowed to borrow/repay inventory (optional;
///                   defaults to the deployer)
///   FEE_RECIPIENT   where performance-fee shares mint (default: deployer)
///
/// Example (testnet, allowed):
///   VAULT_ASSET=0x… forge script script/DeployCorridorVault.s.sol \
///     --rpc-url $RPC --broadcast
contract DeployCorridorVault is Script {
    function run() external {
        address deployer = msg.sender;
        address asset = vm.envOr(
            "VAULT_ASSET",
            vm.envOr("USDC_ADDRESS", address(0x3600000000000000000000000000000000000000))
        );
        string memory name_ = vm.envOr("VAULT_NAME", string("Pesarc Corridor USDC"));
        string memory symbol_ = vm.envOr("VAULT_SYMBOL", string("pcUSDC"));
        address operator = vm.envOr("VAULT_OPERATOR", deployer);
        address feeRecipient = vm.envOr("FEE_RECIPIENT", deployer);

        vm.startBroadcast();
        CorridorVault vault = new CorridorVault(IERC20(asset), name_, symbol_, deployer, feeRecipient);
        vault.setOperator(operator);
        vm.stopBroadcast();

        console2.log("CorridorVault", address(vault));
        console2.log("  asset     ", asset);
        console2.log("  operator  ", operator);
        console2.log("  feeRecip  ", feeRecipient);
    }
}
