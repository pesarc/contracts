// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

/// @title TestStable — a testnet local-currency stablecoin
/// @notice Open-mint 18-decimal ERC-20 standing in for a real Celo native
///         stable (cNGN / cGHS / cKES) on testnet, so the agent has currencies
///         to move. **Testnet only** — open mint means anyone can print it.
///         On mainnet these are replaced by Celo's real native stables and the
///         agent code is unchanged.
contract TestStable is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    /// @notice Anyone can mint — testnet faucet behaviour, never for mainnet.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
