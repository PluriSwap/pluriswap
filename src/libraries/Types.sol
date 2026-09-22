// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

enum Status {
    NONE,
    FUNDED,
    FIAT_SENT,
    DISPUTED,
    RELEASED,
    RESOLVED_SPLIT,
    STALEMATE,
    CANCELLED,
    ARBITRATION_ACTIVE,
    RESOLVED_BY_ARBITRATION,
    CLAIMED,
    /// @dev The Controller opened a fight and neither settled nor escalated it before the clock ran
    ///      out. Principal to the Provider in full. Appended, so every value below keeps its number:
    ///      a stored `Status` is read by pools, the lab and indexers.
    ABANDONED
}

struct DealTerms {
    address holder;
    address controller;
    address provider;
    address token;
    uint256 principal;
    uint256 fiatDuration;
    uint256 releaseDuration;
    uint256 disputeDuration;
    uint256 arbitrationDuration;
    bytes32[] packageIds;
}

struct HolderAuthorization {
    DealTerms terms;
    uint256 nonce;
    uint256 deadline;
}

struct ProviderAgreement {
    DealTerms terms;
    uint256 nonce;
    uint256 deadline;
}

struct ControllerAcceptance {
    DealTerms terms;
    uint256 nonce;
    uint256 deadline;
}

struct MutualCancel {
    bytes32 dealId;
    uint256 nonce;
    uint256 deadline;
}

struct CoSignedRelease {
    bytes32 dealId;
    uint256 nonce;
    uint256 deadline;
}

struct MutualSplit {
    bytes32 dealId;
    uint16 providerBps;
    uint256 nonce;
    uint256 deadline;
}

/// @dev Calldata of `activate`, not in the EIP-712 digest. One slot per kind.
struct PackageMods {
    address passport;
    address reputation;
    address bonds;
    address zk;
    address court;
}

/// @dev What the kernel does with the bond locks at a terminal. `HolderWins` moves the Provider's lock to the
///      Holder; `ProviderWins` the reverse. `Burn` sends both to the sink. Money only moves with a proven side.
enum BondAction {
    Unlock,
    Burn,
    HolderWins,
    ProviderWins
}

/// @dev Kernel storage for one deal. Read through `IEscrow`, written only by `Escrow`.
struct Deal {
    Status status;
    DealTerms terms;
    uint256 activatedAt;
    uint256 fiatSentAt;
    uint256 disputedAt;
    uint256 arbitrationOpenedAt;
    bytes32 subjectH;
    bytes32 subjectP;
    uint8 pkgs;
    /// Terminal outcome, stored so the post-terminal package calls can be retried after `_close`. Not
    /// derivable from `status`: STALEMATE alone maps to three different (close, bondAction) pairs, and
    /// RESOLVED_BY_ARBITRATION to two, depending on who won and which clock ran out.
    uint8 closeH;
    uint8 closeP;
    uint8 bondAction;
    /// `Packages.POST_*` bits still owed. Zero once every post-terminal call has either succeeded or been
    /// abandoned because the module drifted away from its signed id.
    uint8 postPending;
    /// Set after the contest-open invoice is taken (or skipped at fee 0). `openDisputed` and `openCourt`
    /// from `FIAT_SENT` share the moment: entering the fight costs once.
    bool contestPaid;
    PackageMods mods;
    uint256 holderAmt;
    uint256 providerAmt;
}

/// @dev Clock origins snapshotted by the kernel. Deadlines are origin + duration on `DealTerms`.
struct DealClocks {
    uint256 activatedAt;
    uint256 fiatSentAt;
    uint256 disputedAt;
    uint256 arbitrationOpenedAt;
}

/// @dev The seven statuses `_close` writes. One list so the official pool and the kernel cannot drift.
function isTerminal(Status s) pure returns (bool) {
    return s == Status.RELEASED || s == Status.RESOLVED_SPLIT || s == Status.STALEMATE || s == Status.CANCELLED
        || s == Status.RESOLVED_BY_ARBITRATION || s == Status.CLAIMED || s == Status.ABANDONED;
}
