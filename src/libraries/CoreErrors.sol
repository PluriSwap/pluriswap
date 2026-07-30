// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ── Activation / consent ──────────────────────────────────────────────────────
error InvalidSignature();
error Expired();
error NonceUsed();
error InvalidTerms();
error InvalidBps();
error ZeroAddress();
error SelfReceiver();
error DealExists();

// ── State / timing ────────────────────────────────────────────────────────────
error InvalidState();
error InvalidTiming();
error Unauthorized();
error TerminalDeal();
error ProfileNotSelected();

// ── Token / funding ───────────────────────────────────────────────────────────
error ExactTransferFailed();
error FundingSpecMismatch();
error FundingAuthInvalid();
error InvalidFundingMode();
error FundingFailed();

// ── Module ────────────────────────────────────────────────────────────────────
error ModuleNotAllowed();
error ModuleCodehashMismatch();
error ModuleBindingMismatch();

// ── Positions ─────────────────────────────────────────────────────────────────
error PositionNotFound();
error PositionAlreadyExists();
error PositionConsumed();
error PositionNotActive();
error PositionNotClaimable();
error PositionNotSplittable();
error InvalidPositionKind();
error PositionIdCollision();

// ── Reconciliation / deficit ──────────────────────────────────────────────────
error ReconciliationFailed(uint8 status);
error BoundaryInDeficit();
error QuarantineInsufficient();
error DeficitNotImplemented();

// ── Terminal record ───────────────────────────────────────────────────────────
error TerminalRecordMismatch();
error DuplicateSettlement();

// ── Deployment / manifest ─────────────────────────────────────────────────────
error ManifestMismatch();
error CrowdfundGated();
error InvalidChainId();
