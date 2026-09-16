// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {TestStable} from "../src/tokens/TestStable.sol";
import {IntentMatcher} from "../src/settlement/IntentMatcher.sol";
import {RealizedRateOracle} from "../src/oracle/RealizedRateOracle.sol";
import {PredictionMarket} from "../src/prediction-market/PredictionMarket.sol";

/// @notice Deploys the Pesarc settlement + prediction-market stack to Circle's
///         Arc, where **USDC is the native gas token**. USDC is a predeploy at
///         0x3600000000000000000000000000000000000000 (same on testnet +
///         mainnet), so we don't mint a test USD leg — we reference native USDC
///         directly as the USD side of the FX market. The local stables
///         (cNGN/cGHS/cKES) are still TestStables until real local issuers land.
///
/// Works unchanged on Arc testnet and mainnet — the only difference is the RPC
/// and which env prefix the address lines are printed under.
///
/// Env:
///   PRIVATE_KEY    deployer key (owner + treasury + attestor). On Arc the
///                  deployer needs USDC for gas.
///   SOLVER_ADDRESS (optional) the settlement agent's key; defaults to deployer.
///   ARC_USDC       (optional) native USDC address; defaults to the predeploy.
///   ENV_PREFIX     (optional) "ARC" (mainnet, default) or "ARC_TESTNET".
///
/// Run:
///   forge script script/DeployArc.s.sol --rpc-url arc_testnet --broadcast \
///     --slow --private-key $PRIVATE_KEY
///   forge script script/DeployArc.s.sol --rpc-url arc --broadcast \
///     --slow --private-key $PRIVATE_KEY   # mainnet (ENV_PREFIX defaults to ARC)
contract DeployArc is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address solver = vm.envOr("SOLVER_ADDRESS", deployer);
        address usdc = vm.envOr("ARC_USDC", address(0x3600000000000000000000000000000000000000));
        string memory prefix = vm.envOr("ENV_PREFIX", string("ARC"));

        vm.startBroadcast(pk);

        // Settlement core — no bridge, no AMM, no external oracle.
        RealizedRateOracle oracle = new RealizedRateOracle(deployer);
        IntentMatcher matcher = new IntentMatcher(deployer);
        matcher.setSolver(solver, true);
        matcher.setRateOracle(oracle);
        oracle.setRecorder(address(matcher), true);

        // Local stables (18-dec, open mint) so the agent has currencies to move.
        TestStable cngn = new TestStable("Naira (test)", "cNGN");
        TestStable cghs = new TestStable("Cedi (test)", "cGHS");
        TestStable ckes = new TestStable("Shilling (test)", "cKES");
        cngn.mint(deployer, 1_000_000_000e18);
        cghs.mint(deployer, 1_000_000_000e18);
        ckes.mint(deployer, 1_000_000_000e18);

        // FX/macro prediction & hedge market — 1% fee to the deployer treasury.
        PredictionMarket market = new PredictionMarket(deployer, address(oracle), deployer, 100);

        uint64 nowTs = uint64(block.timestamp);

        // #1 — USD/NGN monthly close >= 1600 (Oracle: RealizedRateOracle TWAP).
        //      USD leg is native USDC; NGN leg + collateral is cNGN.
        market.createMarket(
            "USD/NGN monthly close >= 1600?",
            address(cngn),
            nowTs + 110 days,
            nowTs + 113 days,
            1 hours,
            address(0),
            0,
            PredictionMarket.Source({
                kind: PredictionMarket.SourceKind.Oracle,
                tokenIn: usdc,
                tokenOut: address(cngn),
                twapWindow: 1 days,
                comparator: PredictionMarket.Comparator.GreaterOrEqual,
                threshold: 1600e18,
                feedRef: keccak256("USD/NGN")
            })
        );

        // #2 — Nigeria CPI inflation stays under 30% (Attested: NBS + dispute).
        market.createMarket(
            "Nigeria CPI inflation stays under 30% (Dec)?",
            address(cngn),
            nowTs + 120 days,
            nowTs + 125 days,
            2 days,
            deployer, // attestor (curator)
            1000e18, // bond
            PredictionMarket.Source({
                kind: PredictionMarket.SourceKind.Attested,
                tokenIn: address(0),
                tokenOut: address(0),
                twapWindow: 0,
                comparator: PredictionMarket.Comparator.LessThan,
                threshold: 30,
                feedRef: keccak256("NBS-CPI")
            })
        );

        vm.stopBroadcast();

        console2.log("== Pesarc on Arc ==");
        console2.log("chainid:", block.chainid);
        console2.log("USDC (native predeploy):", usdc);
        console2.log("RealizedRateOracle:", address(oracle));
        console2.log("IntentMatcher:", address(matcher));
        console2.log("PredictionMarket:", address(market));
        console2.log("markets seeded:", market.marketCount());
        console2.log("-- .env (prefix: %s) --", prefix);
        console2.log(string.concat("NEXT_PUBLIC_", prefix, "_INTENT_MATCHER=", vm.toString(address(matcher))));
        console2.log(string.concat("NEXT_PUBLIC_", prefix, "_REALIZED_ORACLE=", vm.toString(address(oracle))));
        console2.log(string.concat("NEXT_PUBLIC_", prefix, "_PREDICTION_MARKET=", vm.toString(address(market))));
        console2.log(string.concat("NEXT_PUBLIC_", prefix, "_TOKEN_NGN=", vm.toString(address(cngn))));
        console2.log(string.concat("NEXT_PUBLIC_", prefix, "_TOKEN_GHS=", vm.toString(address(cghs))));
        console2.log(string.concat("NEXT_PUBLIC_", prefix, "_TOKEN_KES=", vm.toString(address(ckes))));
        console2.log(string.concat("NEXT_PUBLIC_", prefix, "_TOKEN_USD=", vm.toString(usdc)));
    }
}
