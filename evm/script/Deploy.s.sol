// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {TestStable} from "../src/TestStable.sol";
import {IntentMatcher} from "../src/IntentMatcher.sol";
import {RealizedRateOracle} from "../src/RealizedRateOracle.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";

/// @notice Deploys the StableArc local-currency settlement stack for the Celo
///         "Agents at Work" hackathon.
///
/// The stack has zero chain-specific dependencies — no bridge, no AMM, no
/// external oracle — so it drops onto Celo (where cNGN/cGHS/cKES are native and
/// gas is payable in stablecoins) unchanged.
///
/// Deploys: RealizedRateOracle + IntentMatcher (wired), and three test local
/// stables so the agent has currencies to move on testnet. On mainnet these
/// are replaced by Celo's real native stables.
///
/// Env: PRIVATE_KEY, optional SOLVER_ADDRESS (the settlement agent's key).
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address solver = vm.envOr("SOLVER_ADDRESS", deployer);

        vm.startBroadcast(pk);

        RealizedRateOracle oracle = new RealizedRateOracle(deployer);
        IntentMatcher matcher = new IntentMatcher(deployer);
        matcher.setSolver(solver, true);
        matcher.setRateOracle(oracle);
        oracle.setRecorder(address(matcher), true);

        // Test local stables (18-dec, open mint) so the agent can move money
        // on testnet. Mirror Celo's real native stables 1:1 in role.
        TestStable cngn = new TestStable("Celo Naira (test)", "cNGN");
        TestStable cghs = new TestStable("Celo Cedi (test)", "cGHS");
        TestStable ckes = new TestStable("Celo Shilling (test)", "cKES");
        cngn.mint(deployer, 1_000_000_000e18);
        cghs.mint(deployer, 1_000_000_000e18);
        ckes.mint(deployer, 1_000_000_000e18);

        // FX/macro prediction & hedge market — resolves off the same
        // RealizedRateOracle (no external feed), fee 1% to the deployer treasury.
        PredictionMarket market = new PredictionMarket(deployer, address(oracle), deployer, 100);

        vm.stopBroadcast();

        console2.log("== StableArc on Celo ==");
        console2.log("RealizedRateOracle:", address(oracle));
        console2.log("IntentMatcher:", address(matcher));
        console2.log("cNGN:", address(cngn));
        console2.log("cGHS:", address(cghs));
        console2.log("cKES:", address(ckes));
        console2.log("PredictionMarket:", address(market));
        console2.log("-- .env for the agent --");
        console2.log("NEXT_PUBLIC_CELO_INTENT_MATCHER=%s", address(matcher));
        console2.log("NEXT_PUBLIC_CELO_REALIZED_ORACLE=%s", address(oracle));
        console2.log("NEXT_PUBLIC_CELO_PREDICTION_MARKET=%s", address(market));
        console2.log("NEXT_PUBLIC_CELO_TOKEN_NGN=%s", address(cngn));
        console2.log("NEXT_PUBLIC_CELO_TOKEN_GHS=%s", address(cghs));
        console2.log("NEXT_PUBLIC_CELO_TOKEN_KES=%s", address(ckes));
    }
}
