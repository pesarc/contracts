// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Deploys a Hyperbridge cross-chain token pair for a testnet proof: a
// WrappedHyperFungibleToken on the HOME chain (Base Sepolia) that locks a plain
// ERC20, and a HyperFungibleToken on the REMOTE chain (Arbitrum Sepolia) that
// mints/burns the cross-chain representation. Run in three steps (home -> remote
// -> wire home) because the two contracts live on different chains and must
// register each other as peers.
//
//   forge script script/DeployHyperToken.s.sol --sig "deployHome()"  --rpc-url <base-sepolia>  --broadcast
//   WRAPPED_ADDR=0x.. forge script ... --sig "deployRemote()" --rpc-url <arb-sepolia> --broadcast
//   WRAPPED_ADDR=0x.. HFT_ADDR=0x.. forge script ... --sig "wireHome()" --rpc-url <base-sepolia> --broadcast
//
// Host + dispatcher are the same deterministic addresses on both testnets
// (docs.hyperbridge.network contract addresses).

import "forge-std/Script.sol";
import {WrappedHyperFungibleToken} from "@hyperbridge/core/apps/WrappedHyperFungibleToken.sol";
import {HyperFungibleToken} from "@hyperbridge/core/apps/HyperFungibleToken.sol";
import {StateMachine} from "@hyperbridge/core/libraries/StateMachine.sol";
import {TestStable} from "../src/tokens/TestStable.sol";

contract DeployHyperToken is Script {
    address constant HOST = 0x9AA003594d59C62EE17A73A569Fd7B1DbdBd71E1;
    address constant DISPATCHER = 0x2B332088275Bc9E3C26D81B2975de2483320C181;
    uint256 constant BASE_SEPOLIA = 84532;
    uint256 constant ARB_SEPOLIA = 421614;

    /// Step 1 on Base Sepolia: underlying ERC20 + wrapped token + configure.
    function deployHome() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        vm.startBroadcast(pk);
        TestStable underlying = new TestStable("Test cNGN", "tcNGN");
        underlying.mint(me, 1_000_000e18);
        WrappedHyperFungibleToken wrapped = new WrappedHyperFungibleToken(me);
        wrapped.configure(
            WrappedHyperFungibleToken.WrappedConfigOptions({
                host: HOST,
                dispatcher: DISPATCHER,
                underlying: address(underlying),
                isWeth: false
            })
        );
        vm.stopBroadcast();
        console.log("UNDERLYING", address(underlying));
        console.log("WRAPPED", address(wrapped));
    }

    /// Step 2 on Arbitrum Sepolia: remote HFT + configure + peer to the home wrapped.
    function deployRemote() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        address wrapped = vm.envAddress("WRAPPED_ADDR");
        vm.startBroadcast(pk);
        HyperFungibleToken hft = new HyperFungibleToken("Test cNGN", "tcNGN", me);
        hft.configure(HyperFungibleToken.ConfigOptions({host: HOST, dispatcher: DISPATCHER}));
        hft.addChain(StateMachine.evm(BASE_SEPOLIA), abi.encodePacked(wrapped));
        vm.stopBroadcast();
        console.log("HFT", address(hft));
    }

    /// Step 3 on Base Sepolia: peer the home wrapped back to the remote HFT.
    function wireHome() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address wrapped = vm.envAddress("WRAPPED_ADDR");
        address hft = vm.envAddress("HFT_ADDR");
        vm.startBroadcast(pk);
        WrappedHyperFungibleToken(payable(wrapped)).addChain(
            StateMachine.evm(ARB_SEPOLIA),
            abi.encodePacked(hft)
        );
        vm.stopBroadcast();
    }
}
