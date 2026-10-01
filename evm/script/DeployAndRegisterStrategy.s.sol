// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {CorridorVault} from "../src/liquidity/CorridorVault.sol";
import {ReserveStrategy} from "../src/liquidity/ReserveStrategy.sol";
import {AaveV3Adapter} from "../src/liquidity/AaveV3Adapter.sol";
import {ERC4626Strategy} from "../src/liquidity/ERC4626Strategy.sol";

interface IAToken {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}

/// @notice Deploy a strategy adapter for a CorridorVault AND register it in one
///         transaction, so the vault has a market to allocate into. The broadcaster
///         MUST be the vault owner (addStrategy is onlyOwner).
///
/// @dev Venue selection, in order:
///   1. AAVE_POOL + AAVE_ATOKEN env set        -> AaveV3Adapter (explicit override)
///   2. a built-in Aave V3 market for this chain -> AaveV3Adapter (auto)
///   3. otherwise                               -> ReserveStrategy (works everywhere,
///                                                 incl. Arc)
///
/// Safety: whenever an Aave market is used, the aToken's UNDERLYING_ASSET_ADDRESS
/// is read on-chain and MUST equal the vault's asset. If it doesn't (e.g. a
/// native-vs-bridged USDC mismatch), the script falls back to ReserveStrategy
/// rather than registering an adapter against the wrong token. The vault asset is
/// always read from the vault, never passed in.
///
/// Built-in Aave V3 markets use NATIVE USDC, from the Aave Address Book
/// (bgd-labs/aave-address-book). Arc has no Aave, so it uses ReserveStrategy.
///
/// Env:
///   VAULT_ADDRESS  the deployed CorridorVault (required)
///   AAVE_POOL      optional override of the Aave V3 Pool
///   AAVE_ATOKEN    optional override of the aToken (required iff AAVE_POOL set)
contract DeployAndRegisterStrategy is Script {
    /// Built-in Aave V3 (Pool, native-USDC aToken) per chain id, or (0,0) if none.
    function _aaveMarket(uint256 id) internal pure returns (address pool, address aToken) {
        // --- mainnet ---
        if (id == 1) return (0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2, 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c); // Ethereum
        if (id == 8453) {
            return (0xA238Dd80C259a72e81d7e4664a9801593F98d1c5, 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB); // Base
        }
        if (id == 42161) {
            return (0x794a61358D6845594F94dc1DB02A252b5b4814aD, 0x724dc807b04555b71ed48a6896b6F41593b8C637); // Arbitrum (USDCn)
        }
        if (id == 10) return (0x794a61358D6845594F94dc1DB02A252b5b4814aD, 0x38d693cE1dF5AaDF7bC62595A37D667aD57922e5); // Optimism (USDCn)
        if (id == 137) return (0x794a61358D6845594F94dc1DB02A252b5b4814aD, 0xA4D94019934D8333Ef880ABFFbF2FDd611C762BD); // Polygon (USDCn)
        // --- testnet ---
        if (id == 84532) {
            return (0x8bAB6d1b75f19e9eD9fCe8b9BD338844fF79aE27, 0x10F1A9D11CDf50041f3f8cB7191CBE2f31750ACC); // Base Sepolia
        }
        if (id == 421614) {
            return (0xBfC91D59fdAA134A4ED45f7B584cAf96D7792Eff, 0x460b97BD498E1157530AEb3086301d5225b91216); // Arbitrum Sepolia
        }
        return (address(0), address(0));
    }

    function run() external {
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");
        CorridorVault vault = CorridorVault(vaultAddr);
        address asset = vault.asset();

        // Resolve the Aave market: explicit env override, else the built-in map.
        address pool = vm.envOr("AAVE_POOL", address(0));
        address aToken = vm.envOr("AAVE_ATOKEN", address(0));
        if (pool == address(0)) {
            (pool, aToken) = _aaveMarket(block.chainid);
        }

        // Only use Aave if its aToken is for THIS vault's asset.
        bool useAave = false;
        if (pool != address(0) && aToken != address(0)) {
            try IAToken(aToken).UNDERLYING_ASSET_ADDRESS() returns (address underlying) {
                useAave = underlying == asset;
                if (!useAave) {
                    console2.log("Aave aToken underlying", underlying, "!= vault asset; using ReserveStrategy");
                }
            } catch {
                console2.log("Could not read aToken underlying; using ReserveStrategy");
            }
        }

        // An ERC-4626 venue (VAULT_ERC4626) takes top priority — this is how the
        // Goldgard hook's SafetyModule (gSAFE), Morpho, or any 4626 market plugs
        // in. Its asset must match the vault's (the adapter constructor enforces).
        address erc4626 = vm.envOr("VAULT_ERC4626", address(0));

        vm.startBroadcast();
        address adapter;
        string memory kind;
        if (erc4626 != address(0)) {
            adapter = address(new ERC4626Strategy(asset, erc4626, vaultAddr));
            kind = "ERC4626Strategy";
        } else if (useAave) {
            adapter = address(new AaveV3Adapter(asset, pool, aToken, vaultAddr));
            kind = "AaveV3Adapter";
        } else {
            adapter = address(new ReserveStrategy(asset, vaultAddr));
            kind = "ReserveStrategy";
        }
        vault.addStrategy(adapter);
        vm.stopBroadcast();

        console2.log("Strategy adapter", adapter);
        console2.log("  asset         ", asset);
        console2.log("  registered on ", vaultAddr);
        console2.log("  kind          ", kind);
    }
}
