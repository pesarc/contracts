// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {PredictionMarket} from "../src/prediction-market/PredictionMarket.sol";

/// @notice Seeds curated African + global event markets onto the ALREADY-DEPLOYED
///         Arc PredictionMarket — the "Polymarket for Africa" catalogue. Markets
///         span four themes: African elections & politics, sports (AFCON /
///         football), macro & prices, and global events for African punters.
///
///         Every market here is **Attested**: a curator (the protocol owner, who
///         is also the attestor) proposes the realized value after close, subject
///         to the on-chain dispute window. Yes/No questions are encoded as
///         `comparator = GreaterOrEqual, threshold = 1` — the attestor proposes 1
///         for YES and 0 for NO, and `_compare` returns YES iff value >= 1.
///
/// Idempotency: this APPENDS markets (createMarket increments marketCount). Run
/// it ONCE per environment. Re-running creates duplicates.
///
/// Env:
///   PRIVATE_KEY              owner + attestor key (owns the deployed market).
///   ARC_PREDICTION_MARKET    the deployed PredictionMarket address.
///   ARC_TOKEN_NGN            cNGN collateral address (stake/settle currency).
///
/// Run (Arc mainnet):
///   forge script script/SeedArcMarkets.s.sol --rpc-url arc --broadcast --slow
contract SeedArcMarkets is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        PredictionMarket market = PredictionMarket(vm.envAddress("ARC_PREDICTION_MARKET"));
        address cngn = vm.envAddress("ARC_TOKEN_NGN");

        uint64 nowTs = uint64(block.timestamp);
        uint256 startCount = market.marketCount();

        vm.startBroadcast(pk);

        // --- African elections & politics ---
        _yesNo(
            market,
            cngn,
            deployer,
            "Will Nigeria's CBN cut the benchmark rate (MPR) before 31 Dec 2026?",
            nowTs + 80 days,
            nowTs + 95 days,
            keccak256("CBN-MPR-CUT-2026")
        );
        _yesNo(
            market,
            cngn,
            deployer,
            "Will the incumbent ruling party win Nigeria's 2027 presidential election?",
            nowTs + 365 days,
            nowTs + 380 days,
            keccak256("NG-PRES-2027")
        );

        // --- Sports (AFCON / football) ---
        _yesNo(
            market,
            cngn,
            deployer,
            "Will Nigeria's Super Eagles qualify for the 2026 FIFA World Cup?",
            nowTs + 60 days,
            nowTs + 75 days,
            keccak256("NG-WC2026-QUALIFY")
        );
        _yesNo(
            market,
            cngn,
            deployer,
            "Will an African player finish as the 2026/27 English Premier League top scorer?",
            nowTs + 250 days,
            nowTs + 265 days,
            keccak256("EPL-TOPSCORER-AFRICAN-2627")
        );

        // --- Macro & prices ---
        _yesNo(
            market,
            cngn,
            deployer,
            "Will USD/NGN close above 1600 at year-end 2026?",
            nowTs + 90 days,
            nowTs + 100 days,
            keccak256("USDNGN-YE2026-GT1600")
        );
        _yesNo(
            market,
            cngn,
            deployer,
            "Will petrol (PMS) exceed 1000 naira per litre nationwide before 30 Jun 2027?",
            nowTs + 250 days,
            nowTs + 265 days,
            keccak256("NG-PMS-GT1000-2027")
        );

        // --- Global events (for African punters) ---
        _yesNo(
            market,
            cngn,
            deployer,
            "Will Bitcoin trade above $150,000 before 31 Dec 2026?",
            nowTs + 90 days,
            nowTs + 95 days,
            keccak256("BTC-GT150K-2026")
        );
        _yesNo(
            market,
            cngn,
            deployer,
            "Will Ethereum trade above $6,000 before 30 Jun 2027?",
            nowTs + 250 days,
            nowTs + 265 days,
            keccak256("ETH-GT6K-2027")
        );

        vm.stopBroadcast();

        console2.log("== Seeded African + global markets on Arc ==");
        console2.log("chainid:", block.chainid);
        console2.log("PredictionMarket:", address(market));
        console2.log("markets before:", startCount);
        console2.log("markets after: ", market.marketCount());
    }

    /// @dev Create a binary (Yes/No) Attested market. The owner is the attestor;
    ///      a bond backs the proposal + dispute game. Yes iff attested value >= 1.
    function _yesNo(
        PredictionMarket market,
        address collateral,
        address attestor,
        string memory question,
        uint64 closeTime,
        uint64 resolveTime,
        bytes32 feedRef
    ) internal {
        market.createMarket(
            question,
            collateral,
            closeTime,
            resolveTime,
            2 days, // dispute window
            attestor, // curator/attestor
            100e18, // bond (cNGN)
            PredictionMarket.Source({
                kind: PredictionMarket.SourceKind.Attested,
                tokenIn: address(0),
                tokenOut: address(0),
                twapWindow: 0,
                comparator: PredictionMarket.Comparator.GreaterOrEqual,
                threshold: 1,
                feedRef: feedRef
            })
        );
    }
}
