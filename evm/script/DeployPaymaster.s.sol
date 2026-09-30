// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {VerifyingPaymaster} from "../src/paymaster/VerifyingPaymaster.sol";

/// @notice Deploys Pesarc's in-house ERC-4337 VerifyingPaymaster on Arc (USDC is
///         the native gas token), then stakes it and funds its EntryPoint deposit
///         so it can actually sponsor UserOperations. This is OUR gasless infra:
///         a bundler (Pimlico, free) relays; THIS paymaster pays, signed by our
///         off-chain /api/paymaster service key. No third-party sponsorship policy.
///
/// Amounts are native-USDC (18-dec) wei. Deposit pays for sponsored gas; stake is
/// the ERC-4337 reputation bond bundlers require. Both are recoverable by the
/// owner (withdrawTo / unlockStake+withdrawStake).
///
/// Env:
///   PRIVATE_KEY         deployer = paymaster owner (holds USDC for gas + funding).
///   PAYMASTER_SIGNER    verifyingSigner address (the /api/paymaster service key's
///                       address; NOT the deployer — keep the signer keyless of funds).
///   ENTRY_POINT         (optional) EntryPoint v0.7; defaults to the canonical addr.
///   PM_STAKE            (optional) stake wei; default 1e18 (1 USDC).
///   PM_DEPOSIT          (optional) deposit wei; default 1e18 (1 USDC).
///   PM_UNSTAKE_DELAY    (optional) unstake delay secs; default 86400 (1 day).
///
/// Run (Arc mainnet):
///   forge script script/DeployPaymaster.s.sol --rpc-url arc --broadcast --slow
contract DeployPaymaster is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address signer = vm.envAddress("PAYMASTER_SIGNER");
        IEntryPoint entryPoint =
            IEntryPoint(vm.envOr("ENTRY_POINT", address(0x0000000071727De22E5E9d8BAf0edAc6f37da032)));
        uint256 stake = vm.envOr("PM_STAKE", uint256(1e18));
        uint256 deposit = vm.envOr("PM_DEPOSIT", uint256(1e18));
        uint32 unstakeDelay = uint32(vm.envOr("PM_UNSTAKE_DELAY", uint256(86400)));

        vm.startBroadcast(pk);

        VerifyingPaymaster paymaster = new VerifyingPaymaster(entryPoint, signer);
        paymaster.addStake{value: stake}(unstakeDelay);
        paymaster.deposit{value: deposit}();

        vm.stopBroadcast();

        console2.log("== Pesarc VerifyingPaymaster on Arc ==");
        console2.log("chainid:", block.chainid);
        console2.log("EntryPoint:", address(entryPoint));
        console2.log("VerifyingPaymaster:", address(paymaster));
        console2.log("verifyingSigner:", signer);
        console2.log("staked (wei):", stake);
        console2.log("deposit (wei):", paymaster.getDeposit());
        console2.log("-- .env --");
        console2.log(string.concat("NEXT_PUBLIC_INHOUSE_PAYMASTER_ADDRESS=", vm.toString(address(paymaster))));
    }
}
