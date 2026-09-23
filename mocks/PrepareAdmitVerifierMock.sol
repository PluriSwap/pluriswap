// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPrepareAdmitVerifier} from "../src/packages/interfaces/IPrepareAdmitVerifier.sol";

/// @dev Stand-in for the prepare_admit circuit. Proof is abi.encode(bool ok). NOT A PROOF:
///      a passing mock says nothing about the cap, the tier or the account.
contract PrepareAdmitVerifierMock is IPrepareAdmitVerifier {
    function verifyAdmit(
        bytes32,
        bytes32,
        bytes32,
        address,
        uint256,
        bytes32,
        bytes32,
        bytes32,
        bytes calldata proof
    ) external pure returns (bool) {
        return abi.decode(proof, (bool));
    }
}
