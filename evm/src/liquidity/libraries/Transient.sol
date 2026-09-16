// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Transient Storage Helpers
/// @notice Small wrappers around EIP-1153 transient storage opcodes used to
///         pass rebalance state across a single transaction.
library Transient {
    /// @notice Stores a uint256 in transient storage.
    function tstoreU256(bytes32 slot, uint256 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    /// @notice Loads a uint256 from transient storage.
    function tloadU256(bytes32 slot) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    /// @notice Stores an int256 in transient storage.
    function tstoreI256(bytes32 slot, int256 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    /// @notice Loads an int256 from transient storage.
    function tloadI256(bytes32 slot) internal view returns (int256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }
}
