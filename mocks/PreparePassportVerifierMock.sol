// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPreparePassportVerifier} from "../src/packages/interfaces/IPreparePassportVerifier.sol";

/// @dev Stand-in for the prepare_passport circuit. Proof is abi.encode(bool ok). NOT A PROOF:
///      a passing mock says nothing about account ownership or privacy.
contract PreparePassportVerifierMock is IPreparePassportVerifier {
    function verifyPassport(bytes32, bytes32, bytes calldata proof) external pure returns (bool) {
        return abi.decode(proof, (bool));
    }
}
