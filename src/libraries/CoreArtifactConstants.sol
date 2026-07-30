// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Creation-code identities used by CoreDeployer's staged child deployment.
/// @dev These values are generated from the exact Foundry build and are checked in CI.
library CoreArtifactConstants {
    bytes32 internal constant CREDIT_LEDGER_CREATION_CODE_HASH =
        0xd64e9324b340a8b3d2447f8f9a5a60d173ecac037da19ced4ee902acd4d44328;
    uint256 internal constant CREDIT_LEDGER_CREATION_CODE_LENGTH = 21_300;

    bytes32 internal constant COORDINATOR_CREATION_CODE_HASH =
        0x57122013f68a7c4870d63899da3b35d1707029f42902059c4c9e7a787717733d;
    uint256 internal constant COORDINATOR_CREATION_CODE_LENGTH = 1_513;

    bytes32 internal constant CORE_ESCROW_CREATION_CODE_HASH =
        0xa9c7a018a9a655b3b5d9b28930d63a4a5f75d4f2ed5851f677586412b02a8c96;
    uint256 internal constant CORE_ESCROW_CREATION_CODE_LENGTH = 25_396;
}
