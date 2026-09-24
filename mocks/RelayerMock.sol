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
import {IBundleVerifier} from "../src/packages/interfaces/IBundleVerifier.sol";
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
        /// @dev One proof for the whole side (§3.15.4). The three signatures stay three: each
        ///      module has its own EIP-712 domain, and consent is per module, not per proof.
        bytes sideProof;
        bytes passportSig;
        bytes admitSig;
        // Bond pieces (F3): read only when the deal selects BONDS.
        bytes32 lockCommit;
        bytes32 changeNote;
        bytes32 nullBond;
        bytes bondSig;
    }

    error BundleFailed();

    /// @dev One side's public inputs, assembled from the deal's own terms and the side's commitments.
    ///      Everything here is either public already or something the side is about to have written
    ///      for it, which is why the relayer can compose it without knowing a single secret.
    function _inputs(
        Side calldata side,
        bytes32 dealId,
        HolderAuthorization calldata ha,
        bytes32 pairTag,
        bytes32 repRoot,
        bytes32 bondRoot
    ) internal pure returns (IBundleVerifier.BundleInputs memory) {
        bool bonded = bondRoot != bytes32(0);
        return IBundleVerifier.BundleInputs({
            dealSubject: side.dealSubject,
            dealId: dealId,
            token: ha.terms.token,
            principal: ha.terms.principal,
            repRoot: repRoot,
            newLeaf: side.newLeaf,
            nullRep: side.nullRep,
            pairTag: pairTag,
            lockCommit: bonded ? side.lockCommit : bytes32(0),
            lockAmount: bonded ? (ha.terms.principal + 9) / 10 : 0,
            changeNote: bonded ? side.changeNote : bytes32(0),
            nullBond: bonded ? side.nullBond : bytes32(0),
            bondRoot: bondRoot
        });
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
        bytes32 pairTag,
        IBundleVerifier bundleVerifier
    ) external returns (bytes32 id) {
        uint256 deadline = ha.deadline;
        bool bonded = address(vault) != address(0);

        // ONE proof per side (§3.15.4): the shared verifier checks it once and leaves a ticket, and
        // the three modules read the ticket instead of each verifying its own. That is what takes a
        // two-sided activation from six proofs and 53,824 bytes of calldata down to two and 19,200.
        bytes32 repRoot = reputation.accountTree().root();
        bytes32 bondRoot = bonded ? vault.bondRoot() : bytes32(0);
        IBundleVerifier.BundleInputs memory hi = _inputs(h, dealId, ha, pairTag, repRoot, bondRoot);
        IBundleVerifier.BundleInputs memory pi = _inputs(p, dealId, ha, pairTag, repRoot, bondRoot);
        if (!bundleVerifier.verify(hi, h.sideProof)) revert BundleFailed();
        if (!bundleVerifier.verify(pi, p.sideProof)) revert BundleFailed();

        passport.prepare(hi, h.wallet, deadline, h.passportSig);
        passport.prepare(pi, p.wallet, deadline, p.passportSig);
        if (bonded) {
            vault.prepareBoth(hi, h.wallet, h.bondSig, pi, p.wallet, p.bondSig, deadline);
        }
        // Both sides in one call: nothing is inserted between them, so both proofs were built against
        // the SAME root — they can be produced in parallel, off-chain — and the two account leaves go
        // into the tree together (`insertMany`, 891k measured).
        reputation.prepareBoth(
            PrivateReputation.Side({inputs: hi, wallet: h.wallet, walletSig: h.admitSig}),
            PrivateReputation.Side({inputs: pi, wallet: p.wallet, walletSig: p.admitSig}),
            deadline
        );
        return escrow.activate(ha, holderSig, pa, providerSig, ca, controllerSig, mods);
    }
}
