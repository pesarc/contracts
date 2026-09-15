// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {PredictionMarket} from "../src/PredictionMarket.sol";
import {TestStable} from "../src/TestStable.sol";

/// @notice Deploys ONLY the PredictionMarket against the already-deployed
///         RealizedRateOracle + cNGN, and seeds the three launch markets
///         (USD/NGN close, PMS petrol, CPI). Leaves the existing settlement
///         stack (oracle, matcher, tokens) untouched.
///
/// Env:
///   CELO_AGENT_PK                    deployer key (owner + treasury + attestor)
///   NEXT_PUBLIC_CELO_REALIZED_ORACLE existing oracle address
///   NEXT_PUBLIC_CELO_TOKEN_NGN       existing cNGN address (collateral)
contract DeployPredictionMarket is Script {
    function run() external {
        uint256 pk = vm.envUint("CELO_AGENT_PK");
        address deployer = vm.addr(pk);
        address oracle = vm.envAddress("NEXT_PUBLIC_CELO_REALIZED_ORACLE");
        address cngn = vm.envAddress("NEXT_PUBLIC_CELO_TOKEN_NGN");

        vm.startBroadcast(pk);

        // A test USD stable so the USD/NGN oracle pair has a real address on
        // testnet (mainnet swaps in the real USD-referenced leg). Open mint.
        TestStable cusd = new TestStable("US Dollar (test)", "cUSD");

        // Market resolves off the same RealizedRateOracle — fee 1% to treasury.
        PredictionMarket market = new PredictionMarket(deployer, oracle, deployer, 100);

        uint64 nowTs = uint64(block.timestamp);

        // #1 — USD/NGN monthly close >= 1600 (Oracle: RealizedRateOracle TWAP).
        market.createMarket(
            "USD/NGN monthly close >= 1600?",
            cngn,
            nowTs + 110 days, // close (~late Dec)
            nowTs + 113 days, // resolve
            1 hours, // short safety window on a deterministic oracle
            address(0),
            0,
            PredictionMarket.Source({
                kind: PredictionMarket.SourceKind.Oracle,
                tokenIn: address(cusd),
                tokenOut: cngn,
                twapWindow: 1 days,
                comparator: PredictionMarket.Comparator.GreaterOrEqual,
                threshold: 1600e18,
                feedRef: keccak256("USD/NGN")
            })
        );

        // #2 — PMS pump price >= 1000/litre (Attested: NMDPRA/NNPC + dispute).
        market.createMarket(
            "PMS pump price >= 1000 in December?",
            cngn,
            nowTs + 100 days,
            nowTs + 116 days,
            2 days,
            deployer, // attestor (curator, testnet)
            1000e18, // bond
            PredictionMarket.Source({
                kind: PredictionMarket.SourceKind.Attested,
                tokenIn: address(0),
                tokenOut: address(0),
                twapWindow: 0,
                comparator: PredictionMarket.Comparator.GreaterOrEqual,
                threshold: 1000,
                feedRef: keccak256("NMDPRA-PMS")
            })
        );

        // #3 — Nigeria CPI inflation stays under 30% (Attested: NBS + dispute).
        market.createMarket(
            "Nigeria CPI inflation stays under 30% (Dec)?",
            cngn,
            nowTs + 120 days,
            nowTs + 125 days,
            2 days,
            deployer,
            1000e18,
            PredictionMarket.Source({
                kind: PredictionMarket.SourceKind.Attested,
                tokenIn: address(0),
                tokenOut: address(0),
                twapWindow: 0,
                comparator: PredictionMarket.Comparator.LessThan,
                threshold: 30, // "under 30%"
                feedRef: keccak256("NBS-CPI")
            })
        );

        vm.stopBroadcast();

        console2.log("== StableArc PredictionMarket on Celo ==");
        console2.log("PredictionMarket:", address(market));
        console2.log("cUSD (test):", address(cusd));
        console2.log("markets seeded:", market.marketCount());
        console2.log("-- .env --");
        console2.log("NEXT_PUBLIC_CELO_PREDICTION_MARKET=%s", address(market));
        console2.log("NEXT_PUBLIC_CELO_TOKEN_USD=%s", address(cusd));
    }
}
