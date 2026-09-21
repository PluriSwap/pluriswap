// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPrepareBondVerifier} from "../src/packages/interfaces/IPrepareBondVerifier.sol";

/// @dev Mock behind the frozen `IPrepareBondVerifier`: decodes the proof as the verdict. A passing
///      mock is not a proof.
contract PrepareBondVerifierMock is IPrepareBondVerifier {
    function verifyBond(
        bytes32,
        bytes32,
        address,
        uint256,
        bytes32,
        bytes32,
        bytes32,
        bytes32,
        bytes calldata proof
    ) external pure returns (bool) {
        return abi.decode(proof, (bool));
    }
}
