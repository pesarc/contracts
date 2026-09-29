// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {TestStable} from "../src/tokens/TestStable.sol";
import {IntentMatcher} from "../src/settlement/IntentMatcher.sol";
import {RealizedRateOracle} from "../src/oracle/RealizedRateOracle.sol";
import {PredictionMarket} from "../src/prediction-market/PredictionMarket.sol";

/// @notice Deploys the full Pesarc settlement + prediction-market stack to ANY
///         EVM chain in ONE broadcast: the RealizedRateOracle, the IntentMatcher,
///         the three local stables (cNGN/cGHS/cKES), the FX/macro PredictionMarket,
///         AND the seed USDC<->cXXX corridor rates so netting + swap + send price
///         and settle from block one. It is chain-agnostic — Arc is just the
///         default. The USD leg is the chain's real USDC (native predeploy on
///         Arc; the canonical Circle USDC ERC-20 on Arbitrum/Base/Optimism/
///         Polygon/Celo). The local stables stay TestStables until real local
///         issuers (cNGN, etc.) land per chain.
///
/// The only per-chain inputs are the RPC, the USDC address, and the env prefix —
/// everything else is identical, so `deploy-evm-chain.sh` just sets those three.
///
/// Env:
///   PRIVATE_KEY    deployer key (owner + treasury + attestor). Needs the chain's
///                  gas token: USDC on Arc, ETH on Arbitrum/Base/Optimism,
///                  MATIC/POL on Polygon, CELO on Celo.
///   SOLVER_ADDRESS (optional) the settlement agent's key; defaults to deployer.
///   USDC_ADDRESS   (optional) the chain's USDC. Falls back to ARC_USDC, then to
///                  the Arc native predeploy. MUST be set for non-Arc chains.
///   ARC_USDC       (optional, deprecated alias for USDC_ADDRESS).
///   ENV_PREFIX     (optional) "ARC" (default), "ARBITRUM", "BASE", "OPTIMISM",
///                  "POLYGON", "CELO", ... — the frontend env slot to print under.
///   RATE_NGN/RATE_GHS/RATE_KES (optional) local units per USD in THOUSANDTHS
///                  (NGN 1600 -> 1600000). Seeds both directions. Defaults are a
///                  sane mid-rate; set to the live rate on deploy day.
///
/// Run:
///   forge script script/DeployArc.s.sol --rpc-url arc --broadcast --slow
///   USDC_ADDRESS=0xaf88…5831 ENV_PREFIX=ARBITRUM \
///     forge script script/DeployArc.s.sol --rpc-url arbitrum --broadcast --slow
contract DeployArc is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address solver = vm.envOr("SOLVER_ADDRESS", deployer);
        // Prefer USDC_ADDRESS; fall back to the deprecated ARC_USDC; then the
        // Arc native-USDC predeploy (correct only on Arc — override elsewhere).
        address usdc = vm.envOr(
            "USDC_ADDRESS",
            vm.envOr("ARC_USDC", address(0x3600000000000000000000000000000000000000))
        );
        string memory prefix = vm.envOr("ENV_PREFIX", string("ARC"));

        // Corridor seed rates (local per USD, x1000). Defaults are sane mids.
        uint256 rateNgn = vm.envOr("RATE_NGN", uint256(1_600_000));
        uint256 rateGhs = vm.envOr("RATE_GHS", uint256(15_500));
        uint256 rateKes = vm.envOr("RATE_KES", uint256(155_000));

        vm.startBroadcast(pk);

        // Settlement core — no bridge, no AMM, no external oracle.
        RealizedRateOracle oracle = new RealizedRateOracle(deployer);
        IntentMatcher matcher = new IntentMatcher(deployer);
        matcher.setSolver(solver, true);
        matcher.setRateOracle(oracle);
        oracle.setRecorder(address(matcher), true);
        // Authorise the deployer to seed the mid-rates below.
        oracle.setRecorder(deployer, true);

        // Local stables (18-dec, open mint) so the agent has currencies to move.
        TestStable cngn = new TestStable("Naira (test)", "cNGN");
        TestStable cghs = new TestStable("Cedi (test)", "cGHS");
        TestStable ckes = new TestStable("Shilling (test)", "cKES");
        cngn.mint(deployer, 1_000_000_000e18);
        cghs.mint(deployer, 1_000_000_000e18);
        ckes.mint(deployer, 1_000_000_000e18);

        // Seed USDC<->cXXX both directions so consult() prices immediately and
        // the corridor is live for netting/swap/send without waiting for a first
        // realized settlement. realized rates refine the TWAP from here.
        _seedPair(oracle, usdc, address(cngn), rateNgn);
        _seedPair(oracle, usdc, address(cghs), rateGhs);
        _seedPair(oracle, usdc, address(ckes), rateKes);

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

        console2.log("== Pesarc settlement stack ==");
        console2.log("chainid:", block.chainid);
        console2.log("USDC (USD leg):", usdc);
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

    /// @dev Seed the USDC<->local rate both ways. `ratePerUsdMilli` is local
    ///      units per 1 USD, x1000 (NGN 1600 -> 1600000), mirroring DeployCorridor.
    function _seedPair(RealizedRateOracle oracle, address usdc, address local, uint256 ratePerUsdMilli)
        internal
    {
        require(ratePerUsdMilli > 0, "rate required");
        uint256 usdToLocal1e18 = (ratePerUsdMilli * 1e18) / 1000;
        uint256 localToUsd1e18 = (uint256(1000) * 1e18) / ratePerUsdMilli;
        oracle.record(usdc, local, usdToLocal1e18);
        oracle.record(local, usdc, localToUsd1e18);
    }
}
