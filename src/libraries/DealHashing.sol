// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    DealTerms,
    ModuleBinding,
    ResolutionAuth,
    FundingSpec,
    FundingAuth,
    TerminalRecord
} from "./DealTypes.sol";

/// @notice EIP-712 hashing for all typed structs per MANDATORY_CORE.md §§6.2-6.7, §11.2, §3.3.
library DealHashing {
    // ── Typehashes ────────────────────────────────────────────────────────────

    bytes32 constant DEAL_TERMS_TYPEHASH = keccak256(
        "DealTerms(address holder,address provider,address holderReceiver,address providerReceiver,address token,bytes32 principalFundingHash,bytes32 activationFeeFundingHash,bytes32 tokenRiskHash,bytes32 custodyBoundaryId,uint256 principal,uint256 activationFee,address activationFeeRecipient,uint256 completionFee,address completionFeeRecipient,uint256 nonce,uint64 createExpiry,uint64 fiatDuration,uint64 releaseDuration,uint64 disputeDuration,uint16 disputeTimeoutProviderBps,bytes32 fiatCurrency,uint256 fiatAmount,bytes32 paymentMethod,bytes32 payeeCommitment,bytes32 paymentReferenceCommitment,uint32 profileFlags,bytes32 packageSelectionHash,bytes32 packageContestTermsHash,bytes32 poolAuthorityHash,bytes32 arbitrationTermsHash,bytes32 reservationsHash,bytes32 modulesHash,bytes32 extensionsHash)"
    );

    bytes32 constant FUNDING_SPEC_TYPEHASH = keccak256(
        "FundingSpec(uint8 purpose,uint8 sourceMode,address token,uint256 amount,address source,bytes32 sourcePositionId,address authority)"
    );

    bytes32 constant FUNDING_AUTH_TYPEHASH = keccak256(
        "FundingAuth(bytes32 termsHash,bytes32 fundingSpecHash,uint8 purpose,address authority,uint256 nonce,uint64 expiry)"
    );

    bytes32 constant MODULE_BINDING_TYPEHASH = keccak256(
        "ModuleBinding(uint8 role,address module,bytes32 runtimeCodeHash,bytes32 policyHash,bytes32 manifestHash,bytes32 apiId,bytes32 moduleTermsHash,uint32 capabilityMask)"
    );

    bytes32 constant RESOLUTION_TYPEHASH = keccak256(
        "ResolutionAuth(bytes32 dealId,uint8 action,uint256 resolutionNonce,uint64 expiry,uint16 providerShareBps,uint8 operatorFaultCode,bytes32 operatorFaultEvidenceHash,bytes32 reservationDispositionsHash,bytes32 extensionsHash)"
    );

    bytes32 constant DEAL_ID_TYPEHASH = keccak256(
        "PluriSwapDealId(uint64 chainId,uint32 protocolVersion,address escrow,bytes32 termsHash,address holder,address provider,uint256 nonce)"
    );

    bytes32 constant TERMINAL_RECORD_TYPEHASH = keccak256(
        "PluriSwapTerminalRecord(uint64 chainId,uint32 protocolVersion,address escrow,address ledger,bytes32 dealId,uint8 terminalState,uint8 outcome,uint8 operatorFaultCode,bytes32 operatorFaultEvidenceHash,address token,uint256 principal,uint256 holderSideReturn,uint256 providerGross,uint256 providerNet,uint256 completionCollected,uint256 operatorFeePaid,uint256 operatorFeeUnlocked,address holderReceiver,address providerReceiver,address completionFeeRecipient,address operatorFeeRecipient,address operatorFeeReturnReceiver,bytes32 termsHash,bytes32 modulesHash,bytes32 evidenceHash,bytes32 reservationsHash,bytes32 reservationDispositionsHash,uint64 terminatedAt)"
    );

    bytes32 constant POSITION_ID_V1_TYPEHASH = keccak256(
        "PluriSwapPositionIdV1(bytes32 custodyBoundaryId,uint8 kind,bytes32 sourceId,bytes32 terminalHash,address beneficiary)"
    );

    bytes32 constant CUSTODY_BOUNDARY_TYPEHASH = keccak256(
        "PluriSwapCustodyBoundary(uint64 chainId,uint32 protocolVersion,address ledger,address token)"
    );

    // ── Hash functions ─────────────────────────────────────────────────────────

    function hashFundingSpec(FundingSpec memory f) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                FUNDING_SPEC_TYPEHASH,
                f.purpose,
                f.sourceMode,
                f.token,
                f.amount,
                f.source,
                f.sourcePositionId,
                f.authority
            )
        );
    }

    function hashFundingAuth(FundingAuth memory a) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                FUNDING_AUTH_TYPEHASH,
                a.termsHash,
                a.fundingSpecHash,
                a.purpose,
                a.authority,
                a.nonce,
                a.expiry
            )
        );
    }

    function hashModuleBinding(ModuleBinding memory m) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                MODULE_BINDING_TYPEHASH,
                m.role,
                m.module,
                m.runtimeCodeHash,
                m.policyHash,
                m.manifestHash,
                m.apiId,
                m.moduleTermsHash,
                m.capabilityMask
            )
        );
    }

    /// @dev Sorted/unique bindings; zero count → bytes32(0).
    function modulesHash(ModuleBinding[] memory bindings) internal pure returns (bytes32) {
        if (bindings.length == 0) return bytes32(0);
        bytes32[] memory hashes = new bytes32[](bindings.length);
        for (uint256 i; i < bindings.length; ++i) {
            hashes[i] = hashModuleBinding(bindings[i]);
        }
        return keccak256(abi.encodePacked(hashes));
    }

    function extensionsHash(bytes memory extensions) internal pure returns (bytes32) {
        if (extensions.length == 0) return bytes32(0);
        return keccak256(extensions);
    }

    function hashDealTerms(DealTerms memory t) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                DEAL_TERMS_TYPEHASH,
                t.holder,
                t.provider,
                t.holderReceiver,
                t.providerReceiver,
                t.token,
                t.principalFundingHash,
                t.activationFeeFundingHash,
                t.tokenRiskHash,
                t.custodyBoundaryId,
                t.principal,
                t.activationFee,
                t.activationFeeRecipient,
                t.completionFee,
                t.completionFeeRecipient,
                t.nonce,
                t.createExpiry,
                t.fiatDuration,
                t.releaseDuration,
                t.disputeDuration,
                t.disputeTimeoutProviderBps,
                t.fiatCurrency,
                t.fiatAmount,
                t.paymentMethod,
                t.payeeCommitment,
                t.paymentReferenceCommitment,
                t.profileFlags,
                t.packageSelectionHash,
                t.packageContestTermsHash,
                t.poolAuthorityHash,
                t.arbitrationTermsHash,
                t.reservationsHash,
                t.modulesHash,
                t.extensionsHash
            )
        );
    }

    function hashDealId(
        uint64 chainId_,
        uint32 protocolVersion_,
        address escrow,
        bytes32 termsHash,
        address holder,
        address provider,
        uint256 nonce
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                DEAL_ID_TYPEHASH,
                chainId_,
                protocolVersion_,
                escrow,
                termsHash,
                holder,
                provider,
                nonce
            )
        );
    }

    function hashResolution(ResolutionAuth memory a) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                RESOLUTION_TYPEHASH,
                a.dealId,
                a.action,
                a.resolutionNonce,
                a.expiry,
                a.providerShareBps,
                a.operatorFaultCode,
                a.operatorFaultEvidenceHash,
                a.reservationDispositionsHash,
                a.extensionsHash
            )
        );
    }

    function hashTerminalRecord(TerminalRecord memory r) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                TERMINAL_RECORD_TYPEHASH,
                r.chainId,
                r.protocolVersion,
                r.escrow,
                r.ledger,
                r.dealId,
                r.terminalState,
                r.outcome,
                r.operatorFaultCode,
                r.operatorFaultEvidenceHash,
                r.token,
                r.principal,
                r.holderSideReturn,
                r.providerGross,
                r.providerNet,
                r.completionCollected,
                r.operatorFeePaid,
                r.operatorFeeUnlocked,
                r.holderReceiver,
                r.providerReceiver,
                r.completionFeeRecipient,
                r.operatorFeeRecipient,
                r.operatorFeeReturnReceiver,
                r.termsHash,
                r.modulesHash,
                r.evidenceHash,
                r.reservationsHash,
                r.reservationDispositionsHash,
                r.terminatedAt
            )
        );
    }

    function positionId(
        bytes32 custodyBoundaryId_,
        uint8 kind,
        bytes32 sourceId,
        bytes32 terminalHash_,
        address beneficiary
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                POSITION_ID_V1_TYPEHASH,
                custodyBoundaryId_,
                kind,
                sourceId,
                terminalHash_,
                beneficiary
            )
        );
    }

    function custodyBoundaryId(
        uint64 chainId_,
        uint32 protocolVersion_,
        address ledger,
        address token
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(CUSTODY_BOUNDARY_TYPEHASH, chainId_, protocolVersion_, ledger, token)
        );
    }

    function digest(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
