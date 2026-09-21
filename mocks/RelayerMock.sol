// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods
} from "../src/libraries/Types.sol";
import {Escrow} from "../src/Escrow.sol";
import {PrivatePassport} from "../src/packages/PrivatePassport.sol";
import {PrivateReputation} from "../src/packages/PrivateReputation.sol";

/// @dev Stand-in for the activation relayer of the private bundle (PLURISWAP.md §3.15.4): the
///      prepares and `activate` must land in ONE tx, so a failed activation reverts the tree
///      inserts and the nullifiers with it. Composition order: passport -> reputation -> activate.
///      NOT the real relayer: no fees, no liveness, no censorship resistance — only the bundle.
contract RelayerMock {
    /// @dev One deal side's pieces of the activation bundle.
    struct Side {
        address wallet;
        bytes32 dealSubject;
        bytes32 newLeaf;
        bytes32 nullRep;
        bytes passportProof;
        bytes admitProof;
        bytes passportSig;
        bytes admitSig;
    }

    function activatePrivate(
        Escrow escrow,
        PrivatePassport passport,
        PrivateReputation reputation,
        HolderAuthorization calldata ha,
        bytes calldata holderSig,
        ProviderAgreement calldata pa,
        bytes calldata providerSig,
        ControllerAcceptance calldata ca,
        bytes calldata controllerSig,
        PackageMods calldata mods,
        bytes32 dealId,
        Side calldata h,
        Side calldata p
    ) external returns (bytes32 id) {
        uint256 deadline = ha.deadline;
        address token = ha.terms.token;
        uint256 principal = ha.terms.principal;
        // Each prepare references the tree root it was proven against: read the current root at
        // each call (the admit inserts move it forward within the bundle).
        passport.prepare(
            h.wallet, dealId, h.dealSubject, reputation.accountTree().root(), deadline, h.passportProof, h.passportSig
        );
        reputation.prepare(
            h.wallet,
            dealId,
            h.dealSubject,
            h.newLeaf,
            h.nullRep,
            token,
            principal,
            bytes32(0), // lockCommit: the private vault arrives in F3
            reputation.accountTree().root(),
            deadline,
            h.admitProof,
            h.admitSig
        );
        passport.prepare(
            p.wallet, dealId, p.dealSubject, reputation.accountTree().root(), deadline, p.passportProof, p.passportSig
        );
        reputation.prepare(
            p.wallet,
            dealId,
            p.dealSubject,
            p.newLeaf,
            p.nullRep,
            token,
            principal,
            bytes32(0),
            reputation.accountTree().root(),
            deadline,
            p.admitProof,
            p.admitSig
        );
        return escrow.activate(ha, holderSig, pa, providerSig, ca, controllerSig, mods);
    }
}
