// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Content-addressed package identity. New package = new kind, same DealTerms typehash.
library PackageId {
    bytes32 internal constant BONDS_KIND = keccak256("PluriSwap.Package.BONDS");
    bytes32 internal constant PASSPORT_KIND = keccak256("PluriSwap.Package.PASSPORT");
    bytes32 internal constant REPUTATION_KIND = keccak256("PluriSwap.Package.REPUTATION");
    bytes32 internal constant ARBITRATION_KIND = keccak256("PluriSwap.Package.ARBITRATION");
    uint16 public constant BOND_LOCK_BPS = 1000;

    function bonds(address vault, address sink) public pure returns (bytes32) {
        return keccak256(abi.encode(BONDS_KIND, vault, sink, BOND_LOCK_BPS));
    }

    function passport(address adapter) public pure returns (bytes32) {
        return keccak256(abi.encode(PASSPORT_KIND, adapter));
    }

    function reputation(address module, address feeRecipient, uint256 activationFee, uint256 completionFee)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(REPUTATION_KIND, module, feeRecipient, activationFee, completionFee));
    }

    function arbitration(address adapter, address tribunal, uint256 courtFee) public pure returns (bytes32) {
        return keccak256(abi.encode(ARBITRATION_KIND, adapter, tribunal, courtFee));
    }

    /// @dev Same kind as `arbitration`. Third word is keccak(extraData) so court/jurors/kit bind the id
    ///      without baking a stale ETH `arbitrationCost`.
    function kleros(address adapter, address arbitrator, bytes calldata extraData) public pure returns (bytes32) {
        return arbitration(adapter, arbitrator, uint256(keccak256(extraData)));
    }
}
