// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

// Pesarc in-house VerifyingPaymaster (ERC-4337 EntryPoint v0.7).
//
// REFERENCE for the pesarc/contracts repo — copy it there to compile/deploy
// (it needs the eth-infinitism account-abstraction lib on the import path).
// It sponsors a UserOperation only when `verifyingSigner` (our off-chain
// /api/paymaster service) has signed a time-boxed sponsorship for it.
//
// getHash() MUST stay byte-identical to sdk/paymaster/verifying.ts:getSponsorHash
// so the off-chain signature recovers on-chain.
//
// ARC / ERC-7562 compliance (per circlefin/arc-node docs/erc-4337.md):
//   - _validatePaymasterUserOp is `view` and writes NO global storage during the
//     validation phase, and it carries NO `nonReentrant` guard — an unstaked
//     paymaster that writes global state (e.g. a reentrancy lock) in validation
//     is silently dropped by Pimlico/compliant bundlers. onlyEntryPoint (via
//     BasePaymaster) is sufficient; the EntryPoint never re-enters validation.
//   - Default solc >= 0.8.20 deploys fine on Arc (the old evmVersion:"paris" /
//     PUSH0 / single-immutable constraints were dropped after an Arc upgrade).
//   Put any reentrancy protection on postOp (execution phase), not validation.
//
// AUDIT REQUIRED before Arc mainnet. A bug here drains the paymaster deposit.

import {BasePaymaster} from "@account-abstraction/contracts/core/BasePaymaster.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {_packValidationData} from "@account-abstraction/contracts/core/Helpers.sol";
import {UserOperationLib} from "@account-abstraction/contracts/core/UserOperationLib.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract VerifyingPaymaster is BasePaymaster {
    using UserOperationLib for PackedUserOperation;

    /// Off-chain signer (the /api/paymaster service key).
    address public verifyingSigner;

    // paymasterAndData layout (v0.7): 20 paymaster | 16 verifGas | 16 postOpGas | data
    // data = 6 validUntil | 6 validAfter | 65 signature
    uint256 private constant VALID_TIMESTAMP_OFFSET = UserOperationLib.PAYMASTER_DATA_OFFSET;
    uint256 private constant SIGNATURE_OFFSET = VALID_TIMESTAMP_OFFSET + 12;

    constructor(IEntryPoint _entryPoint, address _verifyingSigner) BasePaymaster(_entryPoint) {
        verifyingSigner = _verifyingSigner;
    }

    function setSigner(address _signer) external onlyOwner {
        verifyingSigner = _signer;
    }

    /// The sponsorship hash — matches sdk/paymaster/verifying.ts:getSponsorHash.
    function getHash(PackedUserOperation calldata userOp, uint48 validUntil, uint48 validAfter)
        public
        view
        returns (bytes32)
    {
        (uint256 maxPriorityFeePerGas, uint256 maxFeePerGas) = _gasFees(userOp);
        return keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.callData),
                maxFeePerGas,
                maxPriorityFeePerGas,
                validUntil,
                validAfter,
                block.chainid,
                address(this)
            )
        );
    }

    function _validatePaymasterUserOp(PackedUserOperation calldata userOp, bytes32, uint256)
        internal
        view
        override
        returns (bytes memory context, uint256 validationData)
    {
        (uint48 validUntil, uint48 validAfter, bytes calldata signature) =
            _parsePaymasterAndData(userOp.paymasterAndData);

        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(getHash(userOp, validUntil, validAfter));
        bool ok = verifyingSigner == ECDSA.recover(hash, signature);
        // sigFailed => the op is rejected; validUntil/validAfter bound the window.
        return ("", _packValidationData(!ok, validUntil, validAfter));
    }

    function _parsePaymasterAndData(bytes calldata paymasterAndData)
        internal
        pure
        returns (uint48 validUntil, uint48 validAfter, bytes calldata signature)
    {
        validUntil = uint48(bytes6(paymasterAndData[VALID_TIMESTAMP_OFFSET:VALID_TIMESTAMP_OFFSET + 6]));
        validAfter = uint48(bytes6(paymasterAndData[VALID_TIMESTAMP_OFFSET + 6:SIGNATURE_OFFSET]));
        signature = paymasterAndData[SIGNATURE_OFFSET:];
    }

    function _gasFees(PackedUserOperation calldata userOp)
        internal
        pure
        returns (uint256 maxPriorityFeePerGas, uint256 maxFeePerGas)
    {
        bytes32 gasFees = userOp.gasFees;
        maxPriorityFeePerGas = uint256(uint128(bytes16(gasFees)));
        maxFeePerGas = uint256(uint128(uint256(gasFees)));
    }
}
