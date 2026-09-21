// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PackageId} from "../libraries/PackageId.sol";
import {Settlement} from "../libraries/Settlement.sol";
import {IPassport} from "./interfaces/IPassport.sol";
import {IBondVault} from "./interfaces/IBondVault.sol";
import {IPrivateReputation} from "./interfaces/IPrivateReputation.sol";
import {IDepositVerifier} from "./interfaces/IDepositVerifier.sol";
import {IPrepareBondVerifier} from "./interfaces/IPrepareBondVerifier.sol";
import {IReabsorbVerifier} from "./interfaces/IReabsorbVerifier.sol";
import {IWithdrawVerifier} from "./interfaces/IWithdrawVerifier.sol";
import {PoseidonTree} from "./PoseidonTree.sol";

/// @title PrivateBondVault
/// @notice Skin in the game of the private packages (PLURISWAP.md §3.15.6), behind the kernel's
///         `IBondVault`: same verbs the public vault answers, none of the per-subject reads.
/// @dev Value lives in notes (`note = Poseidon(sk_id, token, amount, salt)`, never in the clear),
///      earmarking lives in public deal-scoped lock records. The kernel edge is exactly
///      `IBondVault`: `passport()` for the peer check, `sink()` for the burned id, `reserve` in
///      `engage`, `unlock`/`slash`/`burn` in `runPostTerminal`. `available`/`locked` are the
///      public vault's reads; here they fail closed (`HiddenBalances`) — a per-subject aggregate
///      would link every deal of one subject, and the bond column of the cap is proven in-circuit
///      by `prepare_admit`, not read here.
///
///      Flow (PLURISWAP.md §3.15.4, §3.15.6):
///      * `deposit(token, amount, note, proof)`: the only place fresh value enters the notes. The
///        proof pins the note to the public amount; the wallet and the amount are public exactly
///        as in the public vault, the note's owner is not.
///      * `prepare` (activation bundle, same tx as `Escrow.activate`): the split proof burns the
///        source note (`nullBond`), inserts the change note NOW — a failed activation reverts the
///        split with the tx — and buffers `preparedBond[dealId][dealSubject] = (token, lockAmount,
///        lockCommit)` behind the wallet's EIP-712 consent. `lockAmount` is a public input and
///        `reserve` cross-checks it against §3.14.5: a split that under-covers its own lock would
///        leave the vault insolvent the day that lock is slashed.
///      * `reserve` (kernel, operator-only): consumes the buffer and writes the public lock
///        record. No prepare, no activation — the deal fails closed.
///      * `unlock` (kernel, peaceful): marks the lock released. The tokens stay parked until the
///        owner reabsorbs them — `reabsorb` is gated by `reputation.claimed(dealSubject)`: without
///        the terminal delta the lock does not come back (§3.15.5: the delta is atomic).
///      * `slash` (kernel, ruled): the loser's lock tokens go to the winner's signing address and
///        the loser's record is consumed; the winner's own lock is released for a later reabsorb.
///      * `burn` (kernel, stalemate): both locks to the immutable sink.
///      * `reabsorb(dealId, ...)`: proof-gated merge of a released lock back into a fresh note.
///      * `withdraw(token, dest, amount, changeNote, ...)`: proof of note ownership, no
///        `passport.identify` — the proof replaces the identification, so the vault has no
///        liveness dependency on any passport decoder.
///
///      Solvency: notes are only created by a deposit (proof-pinned to the pulled amount), by a
///      split's change note (conservation-bounded in-circuit), or by a reabsorb (exactly the
///      released record's amount, which the split covered); tokens only leave by withdraw (note
///      value), slash or burn (the record's amount). A prepare that is never reserved strands the
///      lockCommit's value in the vault — over-collateralized, the owner's own loss, never
///      anyone else's.
///
///      Peers: `passport()` satisfies the kernel's peer check; `reputation` is immutable for the
///      reabsorb gating (bound by address via `packageId`, same trust as the sink — PLURISWAP.md
///      §3.15.6). The binding is reciprocal: `PrivateReputation` carries this vault's address and
///      refuses any other in `admit`, because a counterparty signs a BONDS deal trusting that the
///      lock exists — a foreign vault under the same reputation would fake that protection.
///      A mock behind any of the verifier interfaces is not privacy.
contract PrivateBondVault is IBondVault, EIP712 {
    using SafeERC20 for IERC20;

    /// @dev EIP-712 type of the wallet consent that pins a dealSubject under a wallet for one deal.
    bytes32 internal constant PREPARE_TYPEHASH =
        keccak256("PrivatePrepare(bytes32 dealId,bytes32 dealSubject,address module,uint256 deadline)");

    /// @dev Notes tree depth (PLURISWAP.md §3.15.3: 20 is the notes tree, 32 the accounts tree).
    ///      Self-deployed in the constructor: the vault is the only reader and writer of notes, so
    ///      unlike the accounts tree there is no wiring circle to break with a predicted address.
    uint8 internal constant NOTES_DEPTH = 20;

    /// @dev One live bond prepare per (deal, subject): exactly what `reserve` must match before the
    ///      kernel's activation is allowed to write the lock.
    struct PreparedBond {
        address token;
        uint256 lockAmount;
        bytes32 lockCommit;
    }

    /// @dev The public lock record, deal-scoped (PLURISWAP.md §3.15.6). `amount == 0` means "no
    ///      lock" — `reserve` rejects a zero principal, so a live record is never zero. `released`
    ///      marks a lock the kernel let go of; the tokens stay parked until the owner reabsorbs.
    struct Lock {
        address token;
        uint256 amount;
        bytes32 lockCommit;
        bool released;
    }

    IPassport public immutable passport;
    IPrivateReputation public immutable reputation;
    address public immutable sink;
    address public immutable operator;
    IDepositVerifier public immutable depositVerifier;
    IPrepareBondVerifier public immutable bondVerifier;
    IReabsorbVerifier public immutable reabsorbVerifier;
    IWithdrawVerifier public immutable withdrawVerifier;
    PoseidonTree public immutable notesTree;
    bytes32 public immutable packageId;

    mapping(bytes32 dealId => mapping(bytes32 subject => PreparedBond)) public preparedBond;
    mapping(bytes32 dealId => mapping(bytes32 subject => Lock)) public lockOf;

    event Deposited(address indexed token, address indexed from, uint256 amount);
    event BondPrepared(
        bytes32 indexed dealId, bytes32 indexed subject, bytes32 lockCommit, uint256 lockAmount, bytes32 changeNote
    );
    event Reserved(bytes32 indexed dealId, bytes32 indexed subject, address token, uint256 amount);
    event Unlocked(bytes32 indexed dealId, bytes32 indexed subject, address token, uint256 amount);
    event Slashed(
        bytes32 indexed dealId, bytes32 indexed loser, bytes32 indexed winner, address token, address to, uint256 amount
    );
    event Burned(
        bytes32 indexed dealId, bytes32 indexed subjectA, bytes32 indexed subjectB, address token, uint256 amount
    );
    event Reabsorbed(bytes32 indexed dealId, bytes32 indexed subject, bytes32 newNote, uint256 amount);
    event Withdrawn(address indexed token, address indexed dest, uint256 amount, bytes32 changeNote);

    error ZeroAddress();
    error ZeroAmount();
    error Unauthorized();
    error HiddenBalances();
    error PrepareExpired();
    error UnknownRoot();
    error DepositProofFailed();
    error BondProofFailed();
    error ReabsorbProofFailed();
    error WithdrawProofFailed();
    error InvalidWalletSignature();
    error NoPrepare();
    error PrepareMismatch();
    error LockExists();
    error LockTooSmall();
    error NoLock();
    error NotReleased();
    error ClaimRequired();

    constructor(
        IPassport passport_,
        IPrivateReputation reputation_,
        address sink_,
        address operator_,
        IDepositVerifier depositVerifier_,
        IPrepareBondVerifier bondVerifier_,
        IReabsorbVerifier reabsorbVerifier_,
        IWithdrawVerifier withdrawVerifier_
    ) EIP712("PluriSwap", "1") {
        if (
            address(passport_) == address(0) || address(reputation_) == address(0) || sink_ == address(0)
                || operator_ == address(0) || address(depositVerifier_) == address(0)
                || address(bondVerifier_) == address(0) || address(reabsorbVerifier_) == address(0)
                || address(withdrawVerifier_) == address(0)
        ) {
            revert ZeroAddress();
        }
        passport = passport_;
        reputation = reputation_;
        sink = sink_;
        operator = operator_;
        depositVerifier = depositVerifier_;
        bondVerifier = bondVerifier_;
        reabsorbVerifier = reabsorbVerifier_;
        withdrawVerifier = withdrawVerifier_;
        notesTree = new PoseidonTree(NOTES_DEPTH, address(this));
        packageId = PackageId.bonds(address(this), sink_);
    }

    // ------------------------------------------------------------------ kernel edge (IBondVault)

    // `packageId`, `passport` and `sink` answer through their public-immutable getters, exactly as
    // in the public vault: the auto-getters satisfy the interface, no explicit wrappers.

    /// @inheritdoc IBondVault
    /// @dev No per-subject reads exist here: a subject-scoped aggregate would link every deal of
    ///      one subject. The bond column of the cap is proven in-circuit by `prepare_admit`.
    function available(bytes32, address) external pure returns (uint256) {
        revert HiddenBalances();
    }

    /// @inheritdoc IBondVault
    /// @dev Same as `available`: the public vault's reads are not this vault's language.
    function locked(bytes32, address) external pure returns (uint256) {
        revert HiddenBalances();
    }

    /// @inheritdoc IBondVault
    /// @dev Consumes `preparedBond[dealId][subject]` and writes the public lock record. The deal's
    ///      activation fails closed without a matching split: no prepare, no lock, no deal.
    function reserve(bytes32 subject, address token, bytes32 dealId, uint256 principal) external {
        if (msg.sender != operator) revert Unauthorized();
        if (principal == 0) revert LockTooSmall();
        PreparedBond memory p = preparedBond[dealId][subject];
        if (p.lockCommit == 0) revert NoPrepare();
        if (lockOf[dealId][subject].amount != 0) revert LockExists();
        // The split must have been proven for exactly this deal's token and §3.14.5 lock: a
        // foreign pair would write a lock the source note never covered.
        uint256 lockAmount = (principal + 9) / 10;
        if (p.token != token || p.lockAmount != lockAmount) revert PrepareMismatch();
        lockOf[dealId][subject] = Lock(token, lockAmount, p.lockCommit, false);
        delete preparedBond[dealId][subject];
        emit Reserved(dealId, subject, token, lockAmount);
    }

    /// @inheritdoc IBondVault
    /// @dev Marks the lock released; the tokens stay parked until the owner reabsorbs them
    ///      (gated by the terminal claim). Strict: a second unlock finds no live lock, which is
    ///      exactly the kernel's retry semantics — a succeeded bit is never retried.
    function unlock(bytes32 subject, address token, bytes32 dealId) external {
        if (msg.sender != operator) revert Unauthorized();
        Lock memory l = lockOf[dealId][subject];
        if (l.amount == 0 || l.released) revert NoLock();
        lockOf[dealId][subject].released = true;
        emit Unlocked(dealId, subject, token, l.amount);
    }

    /// @inheritdoc IBondVault
    /// @dev The loser's lock tokens go to the winner's signing address and the loser's record is
    ///      consumed (never reabsorbable); the winner's own lock is released for a later reabsorb,
    ///      like any peaceful one.
    function slash(bytes32 loser, bytes32 winner, address token, bytes32 dealId, address to) external {
        if (msg.sender != operator) revert Unauthorized();
        uint256 loserAmount = _consume(loser, dealId);
        Lock memory w = lockOf[dealId][winner];
        if (w.amount == 0 || w.released) revert NoLock();
        lockOf[dealId][winner].released = true;
        IERC20(token).safeTransfer(to, loserAmount);
        emit Unlocked(dealId, winner, token, w.amount);
        emit Slashed(dealId, loser, winner, token, to, loserAmount);
    }

    /// @inheritdoc IBondVault
    /// @dev Both locks to the immutable sink — a stalemate's price for letting the fight expire.
    function burn(bytes32 subjectA, bytes32 subjectB, address token, bytes32 dealId) external {
        if (msg.sender != operator) revert Unauthorized();
        uint256 a = _consume(subjectA, dealId);
        uint256 b = _consume(subjectB, dealId);
        IERC20(token).safeTransfer(sink, a + b);
        emit Burned(dealId, subjectA, subjectB, token, a + b);
    }

    // ------------------------------------------------------------------ vault edge (the subject's)

    /// @notice Root of the notes tree, for proofs composed off-chain.
    function bondRoot() external view returns (bytes32) {
        return notesTree.root();
    }

    /// @notice EIP-712 domain of the prepare consent, mirroring the kernel's read surface.
    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    /// @notice The only place fresh value enters the notes world: pulls `amount` from the depositor
    ///         and inserts `note`, proof-pinned to the public amount. The wallet and the amount are
    ///         public exactly as in the public vault; the note's owner is not.
    function deposit(address token, uint256 amount, bytes32 note, bytes calldata proof) external {
        if (amount == 0) revert ZeroAmount();
        if (!depositVerifier.verifyDeposit(token, amount, note, proof)) revert DepositProofFailed();
        Settlement.pullExact(token, msg.sender, amount);
        notesTree.insert(note);
        emit Deposited(token, msg.sender, amount);
    }

    /// @notice Splits a note for one deal's lock, inside the activation bundle: burns the source
    ///         note, inserts the change note NOW (a failed activation reverts the split with the
    ///         tx), and buffers `(token, lockAmount, lockCommit)` for `reserve`. Permissionless:
    ///         the proof and the wallet signature are the authority, the relayer is anyone.
    ///         A later split for the same (deal, subject) overwrites an earlier one — latest wins,
    ///         both were wallet-signed; the orphaned lock value is stranded in the vault
    ///         (over-collateralized, the owner's own loss, never anyone else's).
    function prepare(
        address wallet,
        bytes32 dealId,
        bytes32 dealSubject,
        address token,
        uint256 lockAmount,
        bytes32 lockCommit,
        bytes32 changeNote,
        bytes32 nullBond,
        bytes32 bondRoot_,
        uint256 deadline,
        bytes calldata proof,
        bytes calldata walletSig
    ) external {
        if (block.timestamp > deadline) revert PrepareExpired();
        if (!notesTree.isKnownRoot(bondRoot_)) revert UnknownRoot();
        if (!bondVerifier.verifyBond(
                dealSubject, dealId, token, lockAmount, lockCommit, changeNote, nullBond, bondRoot_, proof
            )) {
            revert BondProofFailed();
        }
        bytes32 digest =
            _hashTypedDataV4(keccak256(abi.encode(PREPARE_TYPEHASH, dealId, dealSubject, address(this), deadline)));
        if (!SignatureChecker.isValidSignatureNow(wallet, digest, walletSig)) revert InvalidWalletSignature();
        // Burn the source note before inserting the change: a replayed split dies before it can
        // grow the tree, and concurrent splits against the same note serialize here.
        notesTree.spend(nullBond);
        notesTree.insert(changeNote);
        preparedBond[dealId][dealSubject] = PreparedBond(token, lockAmount, lockCommit);
        emit BondPrepared(dealId, dealSubject, lockCommit, lockAmount, changeNote);
    }

    /// @notice Merges a released lock back into a fresh note: the proof binds the account behind
    ///         `dealSubject`, the stored `lockCommit` and the exact record amount. Gated by the
    ///         terminal claim — without the delta the lock does not come back. Permissionless.
    function reabsorb(bytes32 dealId, bytes32 dealSubject, bytes32 newNote, bytes32 nullBond, bytes calldata proof)
        external
    {
        Lock memory l = lockOf[dealId][dealSubject];
        if (l.amount == 0) revert NoLock();
        if (!l.released) revert NotReleased();
        if (!reputation.claimed(dealSubject)) revert ClaimRequired();
        if (!reabsorbVerifier.verifyReabsorb(
                dealId, dealSubject, l.token, l.amount, l.lockCommit, newNote, nullBond, proof
            )) {
            revert ReabsorbProofFailed();
        }
        notesTree.spend(nullBond);
        notesTree.insert(newNote);
        delete lockOf[dealId][dealSubject];
        emit Reabsorbed(dealId, dealSubject, newNote, l.amount);
    }

    /// @notice Spends a note to `dest` — the proof replaces `passport.identify`, so this never
    ///         touches the passport and never links the note to any wallet. `changeNote == 0`
    ///         consumes the note whole; otherwise the remainder lives on as the change note.
    function withdraw(
        address token,
        address dest,
        uint256 amount,
        bytes32 changeNote,
        bytes32 nullBond,
        bytes32 bondRoot_,
        bytes calldata proof
    ) external {
        if (amount == 0) revert ZeroAmount();
        if (dest == address(0)) revert ZeroAddress();
        if (!notesTree.isKnownRoot(bondRoot_)) revert UnknownRoot();
        if (!withdrawVerifier.verifyWithdraw(token, dest, amount, changeNote, nullBond, bondRoot_, proof)) {
            revert WithdrawProofFailed();
        }
        notesTree.spend(nullBond);
        if (changeNote != 0) notesTree.insert(changeNote);
        IERC20(token).safeTransfer(dest, amount);
        emit Withdrawn(token, dest, amount, changeNote);
    }

    /// @dev Takes a Reserved lock for good (slash's loser, burn's both): the record is deleted,
    ///      the amount returned. A released or missing lock is not takeable — the kernel's
    ///      terminals are one-shot, so anything else here is a bug or an attack, and it fails
    ///      closed.
    function _consume(bytes32 subject, bytes32 dealId) private returns (uint256 amount) {
        Lock memory l = lockOf[dealId][subject];
        if (l.amount == 0 || l.released) revert NoLock();
        delete lockOf[dealId][subject];
        return l.amount;
    }
}
