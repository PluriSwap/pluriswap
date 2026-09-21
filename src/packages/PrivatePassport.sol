// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IHumanityVerifier} from "./interfaces/IHumanityVerifier.sol";
import {IPrivatePassport} from "./interfaces/IPrivatePassport.sol";

/// @title PrivatePassport
/// @notice Humanity gate of the private packages: one human anchor, one hn, one account
///         (PLURISWAP.md §3.15.3).
/// @dev The proof is the only identification — no wallet is read, stored or emitted. `hn`
///      (= Poseidon(anchor, registryId)) is a nullifier: registering burns it forever, so the
///      same anchor can never open a second account; two disjoint anchors are two accounts,
///      the same sybil line as the on-chain Passport adapters. A failed proof marks nothing.
///      F2 fills `identify` from the prepare buffer; `register` is all F1 needs. A mock
///      behind `IHumanityVerifier` is not privacy.
contract PrivatePassport is IPrivatePassport {
    IHumanityVerifier public immutable humanityVerifier;

    mapping(bytes32 => bool) public spentHumanity;

    event HumanityRegistered(bytes32 indexed hn);

    error ZeroVerifier();
    error HumanAlreadySpent();
    error HumanityNotVerified();

    constructor(IHumanityVerifier verifier_) {
        if (address(verifier_) == address(0)) revert ZeroVerifier();
        humanityVerifier = verifier_;
    }

    /// @notice Burns a humanity nullifier. Runs in the same bundle tx as
    ///         `PrivateReputation.register` with the same `hn`.
    function register(bytes calldata proof, bytes32 hn) external {
        if (spentHumanity[hn]) revert HumanAlreadySpent();
        if (!humanityVerifier.verifyHumanity(proof, hn)) revert HumanityNotVerified();
        spentHumanity[hn] = true;
        emit HumanityRegistered(hn);
    }

    /// @notice Read side for `PrivateReputation.register`: has this hn been proven before?
    function humanitySpent(bytes32 hn) external view returns (bool) {
        return spentHumanity[hn];
    }
}
