// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PredictionMarket} from "../src/PredictionMarket.sol";
import {IRealizedRateOracle} from "../src/PredictionMarket.sol";
import {TestStable} from "../src/TestStable.sol";

/// @dev Deterministic oracle stand-in so tests pin the realized rate directly.
///      The real RealizedRateOracle is covered by its own suite.
contract MockOracle is IRealizedRateOracle {
    mapping(bytes32 => uint256) public rate;
    mapping(bytes32 => bool) public present;

    function set(address a, address b, uint256 r) external {
        bytes32 k = keccak256(abi.encodePacked(a, b));
        rate[k] = r;
        present[k] = true;
    }

    function consult(address a, address b, uint32) external view returns (uint256) {
        return rate[keccak256(abi.encodePacked(a, b))];
    }

    function hasData(address a, address b) external view returns (bool) {
        return present[keccak256(abi.encodePacked(a, b))];
    }
}

contract PredictionMarketTest is Test {
    PredictionMarket pm;
    MockOracle oracle;
    TestStable cNGN;
    TestStable usd; // just an address for the oracle pair

    address owner = address(0xA11CE);
    address treasury = address(0x7EA5);
    address alice = address(0xA1);
    address bob = address(0xB0B);
    address carol = address(0xCA401);
    address attestor = address(0xA77E5);

    uint16 constant FEE_BPS = 200; // 2%

    function setUp() public {
        oracle = new MockOracle();
        cNGN = new TestStable("cNGN", "cNGN");
        usd = new TestStable("USD", "USD");
        vm.prank(owner);
        pm = new PredictionMarket(owner, address(oracle), treasury, FEE_BPS);

        for (uint256 i; i < 3; i++) {
            address u = [alice, bob, carol][i];
            cNGN.mint(u, 1_000_000e18);
            vm.prank(u);
            cNGN.approve(address(pm), type(uint256).max);
        }
        cNGN.mint(attestor, 1_000_000e18);
        vm.prank(attestor);
        cNGN.approve(address(pm), type(uint256).max);
    }

    // ---------------------------------------------------------------- helpers

    function _oracleMarket(uint256 threshold, PredictionMarket.Comparator cmp) internal returns (uint256 id) {
        PredictionMarket.Source memory s = PredictionMarket.Source({
            kind: PredictionMarket.SourceKind.Oracle,
            tokenIn: address(usd),
            tokenOut: address(cNGN),
            twapWindow: 1 days,
            comparator: cmp,
            threshold: threshold,
            feedRef: keccak256("USD/NGN")
        });
        vm.prank(owner);
        id = pm.createMarket(
            "USD/NGN monthly close >= 1600?",
            address(cNGN),
            uint64(block.timestamp + 7 days), // close
            uint64(block.timestamp + 7 days), // resolve
            0, // no dispute window: deterministic oracle
            address(0),
            0,
            s
        );
    }

    function _attestedMarket() internal returns (uint256 id) {
        PredictionMarket.Source memory s = PredictionMarket.Source({
            kind: PredictionMarket.SourceKind.Attested,
            tokenIn: address(0),
            tokenOut: address(0),
            twapWindow: 0,
            comparator: PredictionMarket.Comparator.GreaterOrEqual,
            threshold: 1000, // e.g. petrol price in naira
            feedRef: keccak256("NMDPRA-PMS")
        });
        vm.prank(owner);
        id = pm.createMarket(
            "PMS pump price >= 1000 in December?",
            address(cNGN),
            uint64(block.timestamp + 7 days),
            uint64(block.timestamp + 7 days),
            2 days, // dispute window
            attestor,
            5_000e18, // bond
            s
        );
    }

    // ---------------------------------------------------------------- tests

    function test_OracleResolveYes_ParimutuelPayoutWithFee() public {
        uint256 id = _oracleMarket(1600e18, PredictionMarket.Comparator.GreaterOrEqual);

        // Alice + Bob back YES (300k total), Carol backs NO (100k).
        vm.prank(alice);
        pm.stake(id, true, 200_000e18);
        vm.prank(bob);
        pm.stake(id, true, 100_000e18);
        vm.prank(carol);
        pm.stake(id, false, 100_000e18);

        // Naira slid past 1600 → YES.
        oracle.set(address(usd), address(cNGN), 1700e18);

        vm.warp(block.timestamp + 7 days);
        pm.proposeFromOracle(id);
        pm.finalize(id);

        PredictionMarket.Market memory m = pm.getMarket(id);
        assertEq(uint8(m.outcome), uint8(PredictionMarket.Outcome.Yes));

        // Fee = 2% of the 100k losing pool = 2k → treasury.
        assertEq(cNGN.balanceOf(treasury), 2_000e18);

        // Payout pool = 300k winners + (100k - 2k) = 398k, split by YES stake.
        uint256 aliceBefore = cNGN.balanceOf(alice);
        vm.prank(alice);
        pm.claim(id);
        // Alice had 2/3 of the YES pool → 398k * 2/3 = 265,333.33e18
        assertEq(cNGN.balanceOf(alice) - aliceBefore, uint256(398_000e18) * 200_000e18 / 300_000e18);

        uint256 bobBefore = cNGN.balanceOf(bob);
        vm.prank(bob);
        pm.claim(id);
        assertEq(cNGN.balanceOf(bob) - bobBefore, uint256(398_000e18) * 100_000e18 / 300_000e18);

        // Loser cannot claim; winner cannot double-claim.
        vm.prank(carol);
        vm.expectRevert(PredictionMarket.NothingToClaim.selector);
        pm.claim(id);
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.AlreadyClaimed.selector);
        pm.claim(id);
    }

    function test_OracleResolveNo_WithLessThanComparator() public {
        // "Inflation stays under 20%" style: YES iff value < threshold.
        uint256 id = _oracleMarket(1600e18, PredictionMarket.Comparator.LessThan);
        vm.prank(alice);
        pm.stake(id, true, 50_000e18);
        vm.prank(bob);
        pm.stake(id, false, 50_000e18);

        oracle.set(address(usd), address(cNGN), 1700e18); // >= threshold → NO wins
        vm.warp(block.timestamp + 7 days);
        pm.proposeFromOracle(id);
        pm.finalize(id);

        PredictionMarket.Market memory m = pm.getMarket(id);
        assertEq(uint8(m.outcome), uint8(PredictionMarket.Outcome.No));
    }

    function test_EmptyWinningSide_VoidsToRefund() public {
        uint256 id = _oracleMarket(1600e18, PredictionMarket.Comparator.GreaterOrEqual);
        // Everyone on NO, but YES wins → nobody to pay → void.
        vm.prank(alice);
        pm.stake(id, false, 100_000e18);
        oracle.set(address(usd), address(cNGN), 1700e18); // YES

        vm.warp(block.timestamp + 7 days);
        pm.proposeFromOracle(id);
        pm.finalize(id);

        PredictionMarket.Market memory m = pm.getMarket(id);
        assertEq(uint8(m.outcome), uint8(PredictionMarket.Outcome.Invalid));
        assertEq(cNGN.balanceOf(treasury), 0); // no fee on a void

        uint256 before = cNGN.balanceOf(alice);
        vm.prank(alice);
        pm.refund(id);
        assertEq(cNGN.balanceOf(alice) - before, 100_000e18);
    }

    function test_AttestedPropose_Finalize_NoDispute() public {
        uint256 id = _attestedMarket();
        vm.prank(alice);
        pm.stake(id, true, 10_000e18);
        vm.prank(bob);
        pm.stake(id, false, 10_000e18);

        vm.warp(block.timestamp + 7 days);
        uint256 attBefore = cNGN.balanceOf(attestor);
        vm.prank(attestor);
        pm.propose(id, PredictionMarket.Outcome.Yes); // posts 5k bond

        // Can't finalize while the window is open.
        vm.expectRevert(PredictionMarket.WindowOpen.selector);
        pm.finalize(id);

        vm.warp(block.timestamp + 2 days);
        pm.finalize(id);
        // Bond returned to the (correct) proposer.
        assertEq(cNGN.balanceOf(attestor), attBefore);

        PredictionMarket.Market memory m = pm.getMarket(id);
        assertEq(uint8(m.outcome), uint8(PredictionMarket.Outcome.Yes));
    }

    function test_AttestedDispute_ArbiterOverturns_DisputerTakesBonds() public {
        uint256 id = _attestedMarket();
        vm.prank(alice);
        pm.stake(id, true, 10_000e18);
        vm.prank(bob);
        pm.stake(id, false, 10_000e18);

        vm.warp(block.timestamp + 7 days);
        vm.prank(attestor);
        pm.propose(id, PredictionMarket.Outcome.Yes);

        uint256 carolBefore = cNGN.balanceOf(carol);
        vm.prank(carol);
        pm.dispute(id); // posts 5k bond

        // Arbiter rules NO (proposer was wrong) → disputer takes both bonds.
        vm.prank(owner);
        pm.resolveDispute(id, PredictionMarket.Outcome.No);

        assertEq(cNGN.balanceOf(carol), carolBefore + 5_000e18); // net +1 bond
        PredictionMarket.Market memory m = pm.getMarket(id);
        assertEq(uint8(m.outcome), uint8(PredictionMarket.Outcome.No));

        // NO side (bob) wins the pot.
        uint256 bobBefore = cNGN.balanceOf(bob);
        vm.prank(bob);
        pm.claim(id);
        // fee 2% of 10k loser pool = 200 → treasury; payout = 10k + 9.8k = 19.8k
        assertEq(cNGN.balanceOf(bob) - bobBefore, 19_800e18);
        assertEq(cNGN.balanceOf(treasury), 200e18);
    }

    function test_Reverts_StakeAfterClose_And_ProposeTooEarly() public {
        uint256 id = _oracleMarket(1600e18, PredictionMarket.Comparator.GreaterOrEqual);

        oracle.set(address(usd), address(cNGN), 1700e18);
        // Too early to propose.
        vm.expectRevert(PredictionMarket.TooEarly.selector);
        pm.proposeFromOracle(id);

        // Stake closes at closeTime.
        vm.warp(block.timestamp + 7 days);
        vm.prank(alice);
        vm.expectRevert(PredictionMarket.TradingClosed.selector);
        pm.stake(id, true, 1e18);
    }

    function test_ImpliedYesPrice_TracksPools() public {
        uint256 id = _oracleMarket(1600e18, PredictionMarket.Comparator.GreaterOrEqual);
        assertEq(pm.impliedYes1e18(id), 0.5e18); // no stake yet

        vm.prank(alice);
        pm.stake(id, true, 62e18);
        vm.prank(bob);
        pm.stake(id, false, 38e18);
        assertEq(pm.impliedYes1e18(id), 0.62e18); // 62¢ YES, matches the mock UI
    }

    function test_OnlyOwnerCreates_AndFeeCapEnforced() public {
        PredictionMarket.Source memory s;
        s.kind = PredictionMarket.SourceKind.Attested;
        vm.prank(alice);
        vm.expectRevert(); // Ownable: not owner
        pm.createMarket(
            "x", address(cNGN), uint64(block.timestamp + 1), uint64(block.timestamp + 1), 1 days, attestor, 1e18, s
        );

        vm.prank(owner);
        vm.expectRevert(PredictionMarket.BadParam.selector);
        pm.setFeeConfig(treasury, 1001); // > MAX_FEE_BPS
    }
}
