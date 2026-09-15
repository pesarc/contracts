// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {AgentSessionKeys} from "../src/AgentSessionKeys.sol";

/// @notice Deploys AgentSessionKeys and (optionally) grants the deployer a demo
///         session so the app's "Agent budget" reads a live cap. Chain-agnostic.
///
/// Env:
///   DEPLOYER_PK   deployer key (also owner + demo agent key)
///   GRANT_TOKEN   (optional) ERC-20 to meter the demo session; 0x0 = deploy only
///   GRANT_CAP     (optional) demo cap in wei (default 50_000e18)
contract DeployAgentSessionKeys is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(pk);
        address token = vm.envOr("GRANT_TOKEN", address(0));
        uint128 cap = uint128(vm.envOr("GRANT_CAP", uint256(50_000e18)));

        vm.startBroadcast(pk);
        AgentSessionKeys keys = new AgentSessionKeys(deployer);
        if (token != address(0)) {
            keys.grantSession(deployer, token, cap, uint64(block.timestamp + 365 days));
        }
        vm.stopBroadcast();

        console2.log("== AgentSessionKeys ==");
        console2.log("AgentSessionKeys:", address(keys));
        console2.log("owner / demo agent key:", deployer);
        console2.log("-- .env --");
        console2.log("NEXT_PUBLIC_CELO_AGENT_SESSION_KEYS=%s", address(keys));
        console2.log("NEXT_PUBLIC_CELO_AGENT_KEY=%s", deployer);
    }
}
