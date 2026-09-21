// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {PackageId} from "../libraries/PackageId.sol";
import {IPassport} from "./interfaces/IPassport.sol";
import {IReputation} from "./interfaces/IReputation.sol";
import {IAccountVerifier} from "./interfaces/IAccountVerifier.sol";
import {IClaimVerifier} from "./interfaces/IClaimVerifier.sol";
import {IPrepareAdmitVerifier} from "./interfaces/IPrepareAdmitVerifier.sol";
import {IPrivatePassport} from "./interfaces/IPrivatePassport.sol";
import {IPrivateReputation} from "./interfaces/IPrivateReputation.sol";
import {PoseidonTree} from "./PoseidonTree.sol";

/// @title PrivateReputation
/// @notice Hidden-account package: registers accounts, carries the activation edge and the terminal
///         delta of the private world (PLURISWAP.md §3.15.3–3.15.5), behind the kernel's `IReputation`.
/// @dev The account IS the leaf: nothing here can read a balance, a tier or a history — the contract
///      only manages the tree, the nullifiers, the prepare buffers and the pending deltas. The cap
///      arithmetic (`inFlight + principal <= cap`, tier in-circuit) is proven by `prepare_admit`, not
///      checked here. It also carries the fee policy, because the kernel binds a reputation package
///      to `PackageId.reputation(module, fee policy)`: a different fee is a different package.
///
///      Flow (PLURISWAP.md §3.15.4–3.15.5):
///      * `prepare` (activation bundle, same tx as `Escrow.activate`): verifies the transition proof,
///        checks the wallet's EIP-712 consent over `(dealId, dealSubject, module, deadline)`, burns
///        `nullRep(v)` — which serializes concurrent prepares against the same account by version —
///        and inserts the new leaf NOW, so a failed activation reverts both with the tx. The buffer
///        holds exactly what `admit` must match.
///      * `admit` (kernel, operator-only): matches `(token, principal)` against the buffer, reads the
///        passport's prepared subject and cross-checks it, then DELETES the buffer. That delete kills
///        the cap replay: without a fresh prepare there is no second deal against the same transition.
///      * `notifyTerminal` (kernel, operator-only, try/retry): writes `pending[subject] = (kind,
///        principal, token)` and nothing else — the subject is the kernel's per-deal snapshot, so
///        records cannot collide across deals. A second record for the same subject fails closed
///        (the same human on both ends of one deal is pathological; the account punishes itself).
///      * `claim` (user or relayer, proof-gated): applies the terminal delta — verifies the binding
///        `dealSubject = Poseidon(sk_id, dealId)`, membership of the current leaf and the delta
///        arithmetic in-circuit — burns `nullRep(v)`, inserts the delta leaf, marks `claimed`. The
///        delta is atomic (§3.15.5): not claiming the penalty means never releasing the inFlight.
///      `admit` accepts at most one vault: the bound `bondsVault` of the deployment (§3.15.6) — a
///      counterparty signs a BONDS deal trusting that the lock exists, so a foreign vault under
///      this same reputation is refused. The bond column of the cap is proven in-circuit by
///      `prepare_admit` (with `lockCommit`); the lock itself is `reserve`'s to enforce, in the vault.
///      A mock behind any of the verifier interfaces is not privacy.
contract PrivateReputation is IReputation, IPrivateReputation, EIP712 {
    /// @dev EIP-712 type of the wallet consent that pins a dealSubject under a wallet for one deal.
    bytes32 internal constant PREPARE_TYPEHASH =
        keccak256("PrivatePrepare(bytes32 dealId,bytes32 dealSubject,address module,uint256 deadline)");

    /// @dev Account tree depth, PLURISWAP.md §3.15.3. Enforced at construction: a private reputation
    ///      is only ever wired to a depth-32 accounts tree (depth 20 is the notes tree of F3).
    uint256 public constant TREE_DEPTH = 32;

    /// @dev What `admit` must match before the kernel's activation is allowed to consume the prepare.
    struct PreparedAdmit {
        bytes32 dealSubject;
        address token;
        uint256 principal;
        uint256 deadline;
    }

    /// @dev The terminal delta owed to a deal subject, as the kernel reported it (PLURISWAP.md §3.15.5).
    struct Pending {
        IReputation.Close kind;
        address token;
        uint256 principal;
    }

    IPassport public immutable passport;
    PoseidonTree public immutable accountTree;
    IAccountVerifier public immutable accountVerifier;
    IPrepareAdmitVerifier public immutable admitVerifier;
    IClaimVerifier public immutable claimVerifier;
    address public immutable feeRecipient;
    uint256 public immutable activationFee;
    uint256 public immutable completionFee;
    uint256 public immutable contestBps;
    uint256 public immutable contestFloor;
    address public immutable operator;
    /// @dev The private vault this reputation admits (F3 binding, §3.15.6). Zero in a vault-less
    ///      deployment: a deal that selects BONDS then fails closed in `admit`. The binding is the
    ///      reputation's own address (its `packageId` pins it), so a user signing this reputation
    ///      knows the only vault whose locks can ever back its deals.
    address public immutable bondsVault;
    bytes32 public immutable packageId;

    mapping(bytes32 => bool) public registeredHn;
    mapping(address => PreparedAdmit) public preparedAdmit;
    mapping(bytes32 => Pending) public pending;
    mapping(bytes32 => bool) public claimed;

    event AccountRegistered(bytes32 indexed hn, bytes32 leaf0, uint256 index);
    event ReputationPrepared(address indexed wallet, bytes32 dealSubject, bytes32 newLeaf, uint256 deadline);
    event Admitted(address indexed wallet, bytes32 indexed subject, address token, uint256 principal);
    event TerminalPending(bytes32 indexed subject, IReputation.Close kind, address token, uint256 principal);
    event DeltaClaimed(bytes32 indexed dealSubject, bytes32 indexed dealId, bytes32 newLeaf);

    error ZeroAddress();
    error BadFee();
    error BadTreeDepth();
    error Unauthorized();
    error HumanityNotProven();
    error AlreadyRegistered();
    error AccountNotVerified();
    error PrepareExpired();
    error UnknownRoot();
    error AdmitProofFailed();
    error ClaimProofFailed();
    error InvalidWalletSignature();
    error NoPrepare();
    error PrepareMismatch();
    error PeerMismatch();
    error UnsupportedVault();
    error AlreadyPending();
    error AlreadyClaimed();
    error NothingToClaim();

    constructor(
        IPassport passport_,
        PoseidonTree accountTree_,
        IAccountVerifier accountVerifier_,
        IPrepareAdmitVerifier admitVerifier_,
        IClaimVerifier claimVerifier_,
        address feeRecipient_,
        uint256 activationFee_,
        uint256 completionFee_,
        uint256 contestBps_,
        uint256 contestFloor_,
        address operator_,
        address bondsVault_
    ) EIP712("PluriSwap", "1") {
        if (
            address(passport_) == address(0) || address(accountTree_) == address(0)
                || address(accountVerifier_) == address(0) || address(admitVerifier_) == address(0)
                || address(claimVerifier_) == address(0) || feeRecipient_ == address(0) || operator_ == address(0)
        ) {
            revert ZeroAddress();
        }
        if (contestBps_ > 10_000) revert BadFee();
        if (accountTree_.depth() != TREE_DEPTH) revert BadTreeDepth();
        passport = passport_;
        accountTree = accountTree_;
        accountVerifier = accountVerifier_;
        admitVerifier = admitVerifier_;
        claimVerifier = claimVerifier_;
        feeRecipient = feeRecipient_;
        activationFee = activationFee_;
        completionFee = completionFee_;
        contestBps = contestBps_;
        contestFloor = contestFloor_;
        operator = operator_;
        bondsVault = bondsVault_;
        packageId = PackageId.reputation(
            address(this), feeRecipient_, activationFee_, completionFee_, contestBps_, contestFloor_
        );
    }

    // ------------------------------------------------------------------ register (F1)

    /// @notice Registers the initial leaf of an account. Must run in the same tx as, and after,
    ///         `PrivatePassport.register` with the same `hn`: one human, one account.
    function register(bytes calldata proof, bytes32 hn, bytes32 leaf0) external {
        if (registeredHn[hn]) revert AlreadyRegistered();
        if (!IPrivatePassport(address(passport)).humanitySpent(hn)) revert HumanityNotProven();
        if (!accountVerifier.verifyAccount(proof, hn, leaf0)) revert AccountNotVerified();
        registeredHn[hn] = true;
        (uint256 index,) = accountTree.insert(leaf0);
        emit AccountRegistered(hn, leaf0, index);
    }

    // ------------------------------------------------------------------ activation edge (F2)

    /// @notice Buffers one admission for the activation bundle: verifies the transition proof, checks
    ///         the wallet's consent, burns `nullRep(v)` and inserts the new leaf — all in the
    ///         activation tx, so a failed `activate` reverts it whole. Permissionless: the proof and
    ///         the signature are the authority, the relayer is anyone.
    function prepare(
        address wallet,
        bytes32 dealId,
        bytes32 dealSubject,
        bytes32 newLeaf,
        bytes32 nullRep,
        address token,
        uint256 principal,
        bytes32 lockCommit,
        bytes32 repRoot,
        uint256 deadline,
        bytes calldata proof,
        bytes calldata walletSig
    ) external {
        if (block.timestamp > deadline) revert PrepareExpired();
        if (!accountTree.isKnownRoot(repRoot)) revert UnknownRoot();
        if (!admitVerifier.verifyAdmit(dealSubject, newLeaf, nullRep, token, principal, lockCommit, repRoot, proof)) {
            revert AdmitProofFailed();
        }
        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(PREPARE_TYPEHASH, dealId, dealSubject, address(this), deadline)));
        if (!SignatureChecker.isValidSignatureNow(wallet, digest, walletSig)) revert InvalidWalletSignature();
        // Burn the version nullifier before inserting: concurrent prepares against the same account
        // serialize here, and a replayed transition dies before it can grow the tree.
        accountTree.spend(nullRep);
        accountTree.insert(newLeaf);
        preparedAdmit[wallet] = PreparedAdmit(dealSubject, token, principal, deadline);
        emit ReputationPrepared(wallet, dealSubject, newLeaf, deadline);
    }

    /// @inheritdoc IReputation
    function admit(address wallet, address token, uint256 principal, address vault) external returns (bytes32 subject) {
        if (msg.sender != operator) revert Unauthorized();
        // The F3 binding (§3.15.6): a vault-less deal (vault == 0) or THE bound private vault —
        // nothing else. A counterparty signs a BONDS deal trusting that the lock exists; a foreign
        // vault under this same reputation would fake that protection.
        if (vault != address(0) && vault != bondsVault) revert UnsupportedVault();
        PreparedAdmit memory p = preparedAdmit[wallet];
        if (p.dealSubject == 0 || block.timestamp > p.deadline) revert NoPrepare();
        if (p.token != token || p.principal != principal) revert PrepareMismatch();
        // The kernel's identify answer and the admission proof must name the same subject: this is
        // the cross-check that stops a passport prepare and an admit prepare from different accounts
        // being stapled together under one wallet.
        subject = passport.identify(wallet);
        if (subject != p.dealSubject) revert PeerMismatch();
        delete preparedAdmit[wallet];
        emit Admitted(wallet, subject, token, principal);
    }

    // ------------------------------------------------------------------ terminal edge (F2)

    /// @inheritdoc IReputation
    function notifyTerminal(bytes32 subject, address token, uint256 principal, IReputation.Close kind) external {
        if (msg.sender != operator) revert Unauthorized();
        if (claimed[subject]) revert AlreadyClaimed();
        if (pending[subject].token != address(0)) revert AlreadyPending();
        pending[subject] = Pending(kind, token, principal);
        emit TerminalPending(subject, kind, token, principal);
    }

    /// @notice Applies the terminal delta of one deal subject: verifies the claim proof against the
    ///         pending record, burns the version nullifier, inserts the delta leaf and marks the
    ///         subject claimed. The proof is the only authority — the caller is anyone.
    function claim(
        bytes32 dealId,
        bytes32 dealSubject,
        bytes32 newLeaf,
        bytes32 nullRep,
        bytes32 repRoot,
        bytes calldata proof
    ) external {
        if (claimed[dealSubject]) revert AlreadyClaimed();
        Pending memory p = pending[dealSubject];
        if (p.token == address(0)) revert NothingToClaim();
        if (!accountTree.isKnownRoot(repRoot)) revert UnknownRoot();
        if (!claimVerifier.verifyClaim(
                dealId, dealSubject, newLeaf, nullRep, p.kind, p.token, p.principal, repRoot, proof
            )) {
            revert ClaimProofFailed();
        }
        accountTree.spend(nullRep);
        accountTree.insert(newLeaf);
        claimed[dealSubject] = true;
        delete pending[dealSubject];
        emit DeltaClaimed(dealSubject, dealId, newLeaf);
    }

    /// @notice EIP-712 domain of the prepare consent, mirroring the kernel's read surface.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ------------------------------------------------------------------ fee policy

    /// @inheritdoc IReputation
    function invoiceActivation() external view returns (uint256 amount, address recipient) {
        return (activationFee, feeRecipient);
    }

    /// @inheritdoc IReputation
    function invoiceCompletion() external view returns (uint256 amount, address recipient) {
        return (completionFee, feeRecipient);
    }

    /// @inheritdoc IReputation
    function invoiceContest(uint256 principal) external view returns (uint256 amount, address recipient) {
        return (_contestDue(principal), feeRecipient);
    }

    /// @dev Same curve as the public reputation: 1% of `principal` when `contestBps == 100`, never
    ///      below `contestFloor`. Zero bps is a flat floor (free if the floor is also 0).
    function _contestDue(uint256 principal) internal view returns (uint256) {
        if (contestBps == 0) return contestFloor;
        uint256 pct = principal * contestBps / 10_000;
        return pct < contestFloor ? contestFloor : pct;
    }
}
