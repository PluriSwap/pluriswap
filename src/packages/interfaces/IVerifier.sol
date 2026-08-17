// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Kernel verb `verifyProof` talks to this V only.
interface IVerifier {
    function verify(bytes calldata proof) external view returns (bytes32 dealId, bytes32 paymentNullifier);
}
