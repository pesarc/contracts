// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {RealizedRateOracle} from "../src/oracle/RealizedRateOracle.sol";

/// @title  DeployCorridor — enable a new local-currency corridor (netting core)
/// @notice The IntentMatcher is generic over tokens, so a corridor "goes live"
///         for P2P netting the moment the RealizedRateOracle has a seed rate for
///         USDC <-> cXXX (both directions). This authorises the deployer as a
///         recorder and seeds that rate. The shallow USDC/cXXX pool fallback is
///         a separate step (needs Uniswap v4 core + GoldgardHook on the chain).
///
/// @dev    Run per corridor. Env:
///           PRIVATE_KEY        oracle owner (from the Arc deploy). Needs USDC for gas on Arc.
///           ORACLE_ADDRESS     RealizedRateOracle (Arc mainnet: 0x48484e904EA964a649D0c73666bA1E91d3Ca2349)
///           USDC_ADDRESS       USD leg (Arc native USDC predeploy: 0x3600000000000000000000000000000000000000)
///           CORRIDOR_TOKEN     the local stable, e.g. cGHS 0xb3387B3cCAd4ef68e0c348735daA1C306D17C004
///           RATE_PER_USD_MILLI local units per 1 USD, in THOUSANDTHS (avoids decimals):
///                              GHS 15.5 -> 15500, KES 155 -> 155000, NGN 1600 -> 1600000,
///                              UGX 3800 -> 3800000, TZS 2600 -> 2600000.
///
///         Seed a realistic mid-rate; realized settlements refine the TWAP from there.
contract DeployCorridor is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address oracleAddr = vm.envAddress("ORACLE_ADDRESS");
        address usdc = vm.envAddress("USDC_ADDRESS");
        address local = vm.envAddress("CORRIDOR_TOKEN");
        uint256 ratePerUsdMilli = vm.envUint("RATE_PER_USD_MILLI");
        require(ratePerUsdMilli > 0, "rate required");

        address deployer = vm.addr(pk);
        RealizedRateOracle oracle = RealizedRateOracle(oracleAddr);

        // rate1e18 = (local per USD) scaled to 1e18. ratePerUsdMilli is x1000.
        uint256 usdToLocal1e18 = (ratePerUsdMilli * 1e18) / 1000;
        // Inverse (USDC per local unit), scaled 1e18.
        uint256 localToUsd1e18 = (uint256(1000) * 1e18) / ratePerUsdMilli;

        vm.startBroadcast(pk);

        // Authorise this deployer to record realized rates (idempotent).
        oracle.setRecorder(deployer, true);

        // Seed both directions so consult() is accurate either way.
        oracle.record(usdc, local, usdToLocal1e18);
        oracle.record(local, usdc, localToUsd1e18);

        vm.stopBroadcast();

        console2.log("Corridor seeded on oracle:", oracleAddr);
        console2.log("  USDC:", usdc);
        console2.log("  local token:", local);
        console2.log("  USD -> local (1e18):", usdToLocal1e18);
        console2.log("  local -> USD (1e18):", localToUsd1e18);
        console2.log("Netting is now live for this pair via IntentMatcher.");
    }
}
