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
error InvalidTokenList();
error InvalidPayoutAction();
error InvalidAmount();

// ── Module ────────────────────────────────────────────────────────────────────
error ModuleNotAllowed();
error ModuleCodehashMismatch();
error ModuleBindingMismatch();

// ── Positions ─────────────────────────────────────────────────────────────────
error PositionNotFound();
error PositionAlreadyExists();
error PositionAlreadyConsumed();
error PositionNotActive();
error PositionNotClaimable();
error PositionNotSplittable();
error InvalidPositionKind();
error PositionIdCollision();

// ── Reconciliation / deficit ──────────────────────────────────────────────────
error ReconciliationFailed(uint8 status);
error BoundaryInDeficit();
error DeficitNotActive();
error QuarantineInsufficient();
error InvalidRecoveryAmount();
error RecoveryExceedsGap();

// ── Terminal record ───────────────────────────────────────────────────────────
error TerminalRecordMismatch();
error DuplicateSettlement();

// ── Deployment / manifest ─────────────────────────────────────────────────────
error ManifestMismatch();
error InvalidChildInitCode();
error DeploymentAlreadyFinalized();
error CrowdfundGated();
error InvalidChainId();
