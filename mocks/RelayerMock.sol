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
import {PrivateBondVault} from "../src/packages/PrivateBondVault.sol";

/// @dev Stand-in for the activation relayer of the private bundle (PLURISWAP.md §3.15.4): the
///      prepares and `activate` must land in ONE tx, so a failed activation reverts the tree
///      inserts and the nullifiers with it. Composition order: passport -> vault -> reputation ->
///      activate. Pass the zero vault for a PASSPORT+REPUTATION deal; the bond pieces of the sides
///      are then ignored. NOT the real relayer: no fees, no liveness, no censorship resistance —
///      only the bundle.
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
        // Bond pieces (F3): read only when the deal selects BONDS.
        bytes32 lockCommit;
        bytes32 changeNote;
        bytes32 nullBond;
        bytes bondProof;
        bytes bondSig;
    }

    function activatePrivate(
        Escrow escrow,
        PrivatePassport passport,
        PrivateReputation reputation,
        PrivateBondVault vault,
        HolderAuthorization calldata ha,
        bytes calldata holderSig,
        ProviderAgreement calldata pa,
        bytes calldata providerSig,
        ControllerAcceptance calldata ca,
        bytes calldata controllerSig,
        PackageMods calldata mods,
        bytes32 dealId,
        Side calldata h,
        Side calldata p,
        /// @dev The §3.14.7 pair tag: one value for the deal, proven by both sides' admit proofs and
        ///      matched by the module when it admits the second of them.
        bytes32 pairTag
    ) external returns (bytes32 id) {
        uint256 deadline = ha.deadline;
        address token = ha.terms.token;
        uint256 principal = ha.terms.principal;
        bool bonded = address(vault) != address(0);
        // The lock the vault will write for this principal (§3.14.5): public, so the relayer
        // composes the split proof's public input from the deal terms alone.
        uint256 lockAmount = (principal + 9) / 10;
        // Each prepare references the tree root it was proven against: read the current root at
        // each call (the inserts move it forward within the bundle).
        passport.prepare(
            h.wallet, dealId, h.dealSubject, reputation.accountTree().root(), deadline, h.passportProof, h.passportSig
        );
        passport.prepare(
            p.wallet, dealId, p.dealSubject, reputation.accountTree().root(), deadline, p.passportProof, p.passportSig
        );
        if (bonded) {
            vault.prepare(
                h.wallet,
                dealId,
                h.dealSubject,
                token,
                lockAmount,
                h.lockCommit,
                h.changeNote,
                h.nullBond,
                vault.bondRoot(),
                deadline,
                h.bondProof,
                h.bondSig
            );
            vault.prepare(
                p.wallet,
                dealId,
                p.dealSubject,
                token,
                lockAmount,
                p.lockCommit,
                p.changeNote,
                p.nullBond,
                vault.bondRoot(),
                deadline,
                p.bondProof,
                p.bondSig
            );
        }
        // Both sides in one call: nothing is inserted between them, so both proofs were built
        // against the SAME root — they can be produced in parallel, off-chain — and the two account
        // leaves go into the tree together (§3.14.7's `insertMany`, 891k measured).
        reputation.prepareBoth(
            dealId,
            PrivateReputation.Side({
                wallet: h.wallet,
                dealSubject: h.dealSubject,
                newLeaf: h.newLeaf,
                nullRep: h.nullRep,
                lockCommit: bonded ? h.lockCommit : bytes32(0),
                proof: h.admitProof,
                walletSig: h.admitSig
            }),
            PrivateReputation.Side({
                wallet: p.wallet,
                dealSubject: p.dealSubject,
                newLeaf: p.newLeaf,
                nullRep: p.nullRep,
                lockCommit: bonded ? p.lockCommit : bytes32(0),
                proof: p.admitProof,
                walletSig: p.admitSig
            }),
            token,
            principal,
            reputation.accountTree().root(),
            pairTag,
            deadline
        );
        return escrow.activate(ha, holderSig, pa, providerSig, ca, controllerSig, mods);
    }
}
