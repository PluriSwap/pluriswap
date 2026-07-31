// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Creation-code identities used by CoreDeployer's staged child deployment.
/// @dev These values are generated from the exact Foundry build and are checked in CI.
library CoreArtifactConstants {
    bytes32 internal constant CREDIT_LEDGER_CREATION_CODE_HASH =
        0x7489f0018365c8417f08d8ad765b586c4a711a8d0c686a0345cebf8243c29418;
    uint256 internal constant CREDIT_LEDGER_CREATION_CODE_LENGTH = 19_477;

    bytes32 internal constant COORDINATOR_CREATION_CODE_HASH =
        0xc1978650312c29677b1d4812c4f14c90bc1cd74af0efbf18dc601685b3ba9163;
    uint256 internal constant COORDINATOR_CREATION_CODE_LENGTH = 4_969;

    bytes32 internal constant CORE_ESCROW_CREATION_CODE_HASH =
        0x2b6e1874c85c22a18d9e7e0be4131723a69751064f53a8c120d0be44f8ae559c;
    uint256 internal constant CORE_ESCROW_CREATION_CODE_LENGTH = 24_572;
}
