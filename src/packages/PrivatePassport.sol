// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {PackageId} from "../libraries/PackageId.sol";
import {IPassport} from "./interfaces/IPassport.sol";
import {IHumanityVerifier} from "./interfaces/IHumanityVerifier.sol";
import {IBundleVerifier} from "./interfaces/IBundleVerifier.sol";
import {IPrivatePassport} from "./interfaces/IPrivatePassport.sol";
import {PoseidonTree} from "./PoseidonTree.sol";

/// @title PrivatePassport
/// @notice Humanity gate and deal-subject oracle of the private packages (PLURISWAP.md §3.15.3–3.15.4).
/// @dev Two verbs, two proofs, no wallets read:
///      * `register` burns a humanity nullifier (`hn = Poseidon(anchor, registryId)`): one human
///        anchor, one account, forever. Two disjoint anchors are two accounts — the same sybil line
///        as the on-chain Passport adapters.
///      * `prepare` buffers `preparedPassport[wallet] = dealSubject` for the activation bundle, gated
///        by the `prepare_passport` proof ("I know the `sk_id` behind `dealSubject = Poseidon(sk_id,
///        dealId)`, and its account leaf sits in a live tree") and by the wallet's EIP-712 signature
///        over `(dealId, dealSubject, module, deadline)`. Without that signature a compositor could
///        hang A's subject under B's wallet: cap lending, foreign penalties (PLURISWAP.md §3.15.4).
///      The kernel reads the buffer through `identify` (view, IPassport): it answers the prepared
///      subject while the buffer is live, `NoPassport` otherwise — admission fails closed. `identify`
///      cannot consume the buffer, so a PASSPORT-only private deal never burns it; reusing a stale
///      prepare links two dealSubjects — a privacy leak, not a funds leak (accepted limitation,
///      PLURISWAP.md §3.15.4). The reputation module's `admit` is what consumes the admission side.
///      A mock behind any of the verifier interfaces is not privacy.
contract PrivatePassport is IPrivatePassport, IPassport, EIP712 {
    /// @dev EIP-712 type of the wallet consent that pins a dealSubject under a wallet for one deal.
    bytes32 internal constant PREPARE_TYPEHASH =
        keccak256("PrivatePrepare(bytes32 dealId,bytes32 dealSubject,address module,uint256 deadline)");

    /// @dev One live prepare per wallet: the subject the kernel will read for the next activation.
    struct Prepared {
        bytes32 dealSubject;
        uint256 deadline;
    }

    PoseidonTree public immutable accountTree;
    IHumanityVerifier public immutable humanityVerifier;
    /// @dev The shared verifier of §3.15.4: one proof per side, read by all three modules. Immutable,
    ///      and the module's address IS its `packageId`, so consenting to the package is consenting to
    ///      this verifier — exactly the relationship the per-module verifier had.
    IBundleVerifier public immutable bundleVerifier;

    mapping(bytes32 => bool) public spentHumanity;
    mapping(address => Prepared) public preparedPassport;

    event HumanityRegistered(bytes32 indexed hn);
    event PassportPrepared(address indexed wallet, bytes32 dealSubject, uint256 deadline);

    error ZeroAddress();
    error HumanAlreadySpent();
    error HumanityNotVerified();
    error PrepareExpired();
    error UnknownRoot();
    error PassportProofFailed();
    error InvalidWalletSignature();

    constructor(PoseidonTree accountTree_, IHumanityVerifier humanityVerifier_, IBundleVerifier bundleVerifier_)
        EIP712("PluriSwap", "1")
    {
        if (
            address(accountTree_) == address(0) || address(humanityVerifier_) == address(0)
                || address(bundleVerifier_) == address(0)
        ) {
            revert ZeroAddress();
        }
        accountTree = accountTree_;
        humanityVerifier = humanityVerifier_;
        bundleVerifier = bundleVerifier_;
    }

    // ------------------------------------------------------------------ register (F1)

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

    // ------------------------------------------------------------------ kernel edge (F2)

    /// @inheritdoc IPassport
    function identify(address wallet) external view returns (bytes32 subject) {
        Prepared memory p = preparedPassport[wallet];
        if (p.dealSubject == 0 || block.timestamp > p.deadline) revert NoPassport();
        return p.dealSubject;
    }

    /// @inheritdoc IPassport
    function packageId() external view returns (bytes32) {
        return PackageId.passport(address(this));
    }

    /// @notice EIP-712 domain of the prepare consent, mirroring the kernel's read surface.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice Buffers `dealSubject` under `wallet` for the activation bundle (same tx as
    ///         `Escrow.activate`, PLURISWAP.md §3.15.4). Permissionless: the relayer is anyone;
    ///         the proof and the wallet signature are the authority. A later prepare overwrites an
    ///         earlier one for the same wallet — latest wins, both were wallet-signed.
    /// @notice Buffers one side's identification for the activation bundle.
    ///
    /// @dev Since 2026-09-23 the proof is not this module's own: one side of a bundle is ONE
    ///      `prepare_side` proof covering passport, admission and split together (§3.15.4), verified
    ///      once by the shared `BundleVerifier`. What this module does is ask whether exactly these
    ///      inputs were proven in this transaction, and then enforce the part that is its own — that
    ///      the subject it is about to answer `identify` with is the subject that was proven, under a
    ///      root the tree still accepts.
    ///
    ///      The trust is the same in kind as before (a module has always trusted the verifier its
    ///      `packageId` names) and narrower in scope than it looks: a ticket is keyed by the hash of
    ///      the inputs, so it can never satisfy a call about different values.
    function prepare(
        IBundleVerifier.BundleInputs calldata inputs,
        address wallet,
        uint256 deadline,
        bytes calldata walletSig
    ) external {
        if (block.timestamp > deadline) revert PrepareExpired();
        if (!accountTree.isKnownRoot(inputs.repRoot)) revert UnknownRoot();
        if (!bundleVerifier.wasProven(inputs)) revert PassportProofFailed();
        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(PREPARE_TYPEHASH, inputs.dealId, inputs.dealSubject, address(this), deadline))
        );
        if (!SignatureChecker.isValidSignatureNow(wallet, digest, walletSig)) revert InvalidWalletSignature();
        preparedPassport[wallet] = Prepared(inputs.dealSubject, deadline);
        emit PassportPrepared(wallet, inputs.dealSubject, deadline);
    }
}
