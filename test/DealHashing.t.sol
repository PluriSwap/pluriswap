// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DealHashing} from "../src/libraries/DealHashing.sol";
import {
    DealTerms,
    ModuleBinding,
    FundingSpec,
    FundingAuth,
    ResolutionAuth,
    TerminalRecord
} from "../src/libraries/DealTypes.sol";

contract DealHashingTest is Test {
    function _emptyTerms() internal pure returns (DealTerms memory t) {
        t.holder = address(1);
        t.provider = address(2);
        t.holderReceiver = address(3);
        t.providerReceiver = address(4);
        t.token = address(5);
        t.principal = 100e18;
        t.nonce = 1;
        t.createExpiry = 1_700_000_000;
        t.fiatDuration = 3600;
        t.releaseDuration = 3600;
        t.disputeDuration = 3600;
        t.disputeTimeoutProviderBps = 5000;
        // All hash fields default to bytes32(0) for Core-only
    }

    function test_hashDealTerms_deterministic_nonzero() public pure {
        bytes32 h = DealHashing.hashDealTerms(_emptyTerms());
        assertNotEq(h, bytes32(0));
        // Deterministic
        assertEq(h, DealHashing.hashDealTerms(_emptyTerms()));
    }

    function test_hashDealTerms_deterministic() public pure {
        assertEq(
            DealHashing.hashDealTerms(_emptyTerms()),
            DealHashing.hashDealTerms(_emptyTerms())
        );
    }

    function test_extensionsHash_empty_isZero() public pure {
        assertEq(DealHashing.extensionsHash(""), bytes32(0));
    }

    function test_extensionsHash_nonempty() public pure {
        bytes32 h = DealHashing.extensionsHash("test");
        assertEq(h, keccak256("test"));
    }

    function test_modulesHash_empty_isZero() public pure {
        ModuleBinding[] memory empty;
        assertEq(DealHashing.modulesHash(empty), bytes32(0));
    }

    function test_modulesHash_nonempty() public pure {
        ModuleBinding[] memory bindings = new ModuleBinding[](1);
        bindings[0] = ModuleBinding({
            role: 0,
            module: address(0x1234),
            runtimeCodeHash: bytes32(uint256(1)),
            policyHash: bytes32(uint256(2)),
            manifestHash: bytes32(uint256(3)),
            apiId: bytes32(uint256(4)),
            moduleTermsHash: bytes32(uint256(5)),
            capabilityMask: 1
        });
        bytes32 h = DealHashing.modulesHash(bindings);
        assertNotEq(h, bytes32(0));
    }

    function test_hashFundingSpec_deterministic() public pure {
        FundingSpec memory f = FundingSpec({
            purpose: 1,
            sourceMode: 1,
            token: address(5),
            amount: 100e18,
            source: address(1),
            sourcePositionId: bytes32(0),
            authority: address(1)
        });
        assertEq(DealHashing.hashFundingSpec(f), DealHashing.hashFundingSpec(f));
    }

    function test_hashFundingAuth_deterministic() public pure {
        FundingAuth memory a = FundingAuth({
            termsHash: bytes32(uint256(1)),
            fundingSpecHash: bytes32(uint256(2)),
            purpose: 1,
            authority: address(1),
            nonce: 1,
            expiry: 1_700_000_000
        });
        assertEq(DealHashing.hashFundingAuth(a), DealHashing.hashFundingAuth(a));
    }

    function test_hashResolution_deterministic() public pure {
        ResolutionAuth memory r = ResolutionAuth({
            dealId: bytes32(uint256(1)),
            action: 0,
            resolutionNonce: 1,
            expiry: 1_700_000_000,
            providerShareBps: 0,
            extensionsHash: bytes32(0)
        });
        assertEq(DealHashing.hashResolution(r), DealHashing.hashResolution(r));
    }

    function test_positionId_deterministic() public pure {
        bytes32 id = DealHashing.positionId(
            bytes32(uint256(1)), // custodyBoundaryId
            1,                   // kind = DEAL
            bytes32(uint256(2)), // sourceId = dealId
            bytes32(0),           // terminalHash = zero for active
            address(0)            // beneficiary = zero for DEAL
        );
        assertEq(id, DealHashing.positionId(
            bytes32(uint256(1)), 1, bytes32(uint256(2)), bytes32(0), address(0)
        ));
    }

    function test_custodyBoundaryId_deterministic() public pure {
        address ledger = address(0x1234);
        address token = address(0x5678);
        address otherToken = address(0x9ABC);
        bytes32 id = DealHashing.custodyBoundaryId(1, 2, ledger, token);
        assertEq(id, DealHashing.custodyBoundaryId(1, 2, ledger, token));
        // Different token → different boundary
        assertFalse(id == DealHashing.custodyBoundaryId(1, 2, ledger, otherToken));
    }

    function test_hashTerminalRecord_deterministic() public pure {
        TerminalRecord memory r = TerminalRecord({
            chainId: 1,
            protocolVersion: 2,
            escrow: address(0xE5C1),
            ledger: address(0x1ED),
            dealId: bytes32(uint256(1)),
            terminalState: 16, // Released
            outcome: 1,        // VoluntaryRelease
            operatorFaultCode: 0,
            operatorFaultEvidenceHash: bytes32(0),
            token: address(0x70C),
            principal: 100e18,
            holderSideReturn: 0,
            providerGross: 100e18,
            providerNet: 97e18,
            completionCollected: 3e18,
            operatorFeePaid: 0,
            operatorFeeUnlocked: 0,
            holderReceiver: address(0x1111),
            providerReceiver: address(0x2222),
            completionFeeRecipient: address(0xFEE),
            operatorFeeRecipient: address(0),
            operatorFeeReturnReceiver: address(0),
            termsHash: bytes32(uint256(1)),
            modulesHash: bytes32(0),
            evidenceHash: bytes32(0),
            reservationsHash: bytes32(0),
            reservationDispositionsHash: bytes32(0),
            terminatedAt: 1_700_000_000
        });
        assertEq(DealHashing.hashTerminalRecord(r), DealHashing.hashTerminalRecord(r));
    }
}
