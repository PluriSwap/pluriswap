// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IVerifier} from "../packages/interfaces/IVerifier.sol";

/// @dev Stand-in for circuit V. Proof is abi.encode(dealId, paymentNullifier).
contract VerifierMock is IVerifier {
    function verify(bytes calldata proof) external pure returns (bytes32 dealId, bytes32 paymentNullifier) {
        (dealId, paymentNullifier) = abi.decode(proof, (bytes32, bytes32));
    }
}
