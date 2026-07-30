// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DealTerms, ModuleIdentity, ResolutionAuth} from "./DealTypes.sol";

library DealHashing {
    bytes32 internal constant DEAL_TERMS_TYPEHASH = keccak256(
        "DealTerms(address holder,address provider,address holderReceiver,address providerReceiver,address token,bytes32 tokenRiskHash,bytes32 custodyBoundaryId,uint256 principal,uint256 activationFee,address activationFeeRecipient,uint256 completionFee,address completionFeeRecipient,uint256 nonce,uint64 createExpiry,uint64 fiatDuration,uint64 releaseDuration,uint64 disputeDuration,uint16 disputeTimeoutProviderBps,bytes32 fiatCurrency,uint256 fiatAmount,bytes32 paymentMethod,bytes32 payeeCommitment,bytes32 paymentReferenceCommitment,uint32 profileFlags,bytes32 packageId,bytes32 packageHash,bytes32 modulesHash,bytes32 extensionsHash)"
    );

    bytes32 internal constant RESOLUTION_TYPEHASH = keccak256(
        "ResolutionAuth(bytes32 dealId,uint8 action,uint256 resolutionNonce,uint64 expiry,uint16 providerShareBps,bytes32 extensionsHash)"
    );

    function modulesHash(ModuleIdentity[] memory modules) internal pure returns (bytes32) {
        return keccak256(abi.encode(modules));
    }

    function extensionsHash(bytes memory extensions) internal pure returns (bytes32) {
        if (extensions.length == 0) return bytes32(0);
        return keccak256(extensions);
    }

    function hashDealTerms(DealTerms memory t) internal pure returns (bytes32) {
        bytes32 mods = modulesHash(t.modules);
        bytes32 exts = extensionsHash(t.extensions);
        return keccak256(
            abi.encode(
                DEAL_TERMS_TYPEHASH,
                t.holder,
                t.provider,
                t.holderReceiver,
                t.providerReceiver,
                t.token,
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
                t.packageId,
                t.packageHash,
                mods,
                exts
            )
        );
    }

    function hashResolution(ResolutionAuth memory auth) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                RESOLUTION_TYPEHASH,
                auth.dealId,
                uint8(auth.action),
                auth.resolutionNonce,
                auth.expiry,
                auth.providerShareBps,
                extensionsHash(auth.extensions)
            )
        );
    }

    function digest(bytes32 domainSeparator, bytes32 structHash) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
