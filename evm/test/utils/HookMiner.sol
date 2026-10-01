// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library HookMiner {
    error HookAddressNotFound();

    function computeCreate2(
        address deployer,
        bytes32 salt,
        bytes32 initCodeHash
    ) internal pure returns (address addr) {
        bytes32 h = keccak256(
            abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)
        );
        addr = address(uint160(uint256(h)));
    }

    function findSalt(
        address deployer,
        bytes32 initCodeHash,
        uint160 requiredFlags,
        uint256 maxAttempts
    ) internal pure returns (bytes32 salt, address hookAddress) {
        uint160 mask = uint160((1 << 14) - 1);

        for (uint256 i = 0; i < maxAttempts; i++) {
            salt = bytes32(i);
            hookAddress = computeCreate2(deployer, salt, initCodeHash);
            if ((uint160(hookAddress) & mask) == requiredFlags)
                return (salt, hookAddress);
        }

        revert HookAddressNotFound();
    }
}
