// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPrivatePassport} from "./interfaces/IPrivatePassport.sol";
import {IAccountVerifier} from "./interfaces/IAccountVerifier.sol";
import {PoseidonTree} from "./PoseidonTree.sol";

/// @title PrivateReputation
/// @notice Hidden-account package: registers the initial leaf of an account into its Poseidon
///         tree (PLURISWAP.md §3.15.3).
/// @dev The account IS the leaf: `leaf0 = Poseidon(S, 0, 0, 0, 0, token, salt, 0)` — `S` never
///      goes on-chain in the clear. `hn` is the humanity nullifier burned by
///      `PrivatePassport.register` in the same bundle tx; this contract checks the burn before
///      trusting the account proof, which pins the bundle order passport -> reputation. The
///      tree is deployed here and owned by this contract, so `register` is the only writer.
///      F2 adds prepare/admit/claim on top of this state. A mock behind `IAccountVerifier`
///      is not privacy.
contract PrivateReputation {
    IPrivatePassport public immutable passport;
    IAccountVerifier public immutable accountVerifier;
    PoseidonTree public immutable accountTree;

    /// @dev Account tree depth, PLURISWAP.md §3.15.3: depth 32.
    uint256 public constant TREE_DEPTH = 32;

    mapping(bytes32 => bool) public registeredHn;

    event AccountRegistered(bytes32 indexed hn, bytes32 leaf0, uint256 index);

    error ZeroPassport();
    error ZeroVerifier();
    error HumanityNotProven();
    error AlreadyRegistered();
    error AccountNotVerified();

    constructor(IPrivatePassport passport_, IAccountVerifier verifier_) {
        if (address(passport_) == address(0)) revert ZeroPassport();
        if (address(verifier_) == address(0)) revert ZeroVerifier();
        passport = passport_;
        accountVerifier = verifier_;
        accountTree = new PoseidonTree(uint8(TREE_DEPTH));
    }

    /// @notice Registers the initial leaf of an account. Must run in the same tx as, and
    ///         after, `PrivatePassport.register` with the same `hn`: one human, one account.
    function register(bytes calldata proof, bytes32 hn, bytes32 leaf0) external {
        if (registeredHn[hn]) revert AlreadyRegistered();
        if (!passport.humanitySpent(hn)) revert HumanityNotProven();
        if (!accountVerifier.verifyAccount(proof, hn, leaf0)) revert AccountNotVerified();
        registeredHn[hn] = true;
        (uint256 index,) = accountTree.insert(leaf0);
        emit AccountRegistered(hn, leaf0, index);
    }
}
