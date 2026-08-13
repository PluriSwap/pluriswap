// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Content-addressed package identity. New package = new kind, same DealTerms typehash.
library PackageId {
    bytes32 internal constant BONDS_KIND = keccak256("PluriSwap.Package.BONDS");
    bytes32 internal constant PASSPORT_KIND = keccak256("PluriSwap.Package.PASSPORT");
    bytes32 internal constant REPUTATION_KIND = keccak256("PluriSwap.Package.REPUTATION");
    uint16 public constant BOND_LOCK_BPS = 1000;

    function bonds(address vault, address sink) public pure returns (bytes32) {
        return keccak256(abi.encode(BONDS_KIND, vault, sink, BOND_LOCK_BPS));
    }

    function passport(address adapter) public pure returns (bytes32) {
        return keccak256(abi.encode(PASSPORT_KIND, adapter));
    }

    function reputation(address module, address feeRecipient, uint256 activationFee) public pure returns (bytes32) {
        return keccak256(abi.encode(REPUTATION_KIND, module, feeRecipient, activationFee));
    }
}
