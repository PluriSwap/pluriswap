// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {CoreDeployer} from "../src/CoreDeployer.sol";
import {CoreEscrow} from "../src/CoreEscrow.sol";
import {CreditLedger} from "../src/CreditLedger.sol";
import {Coordinator} from "../src/Coordinator.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {DealHashing} from "../src/libraries/DealHashing.sol";
import {
    DealState,
    DealTerms,
    FundingAuth,
    FundingPurpose,
    FundingSourceMode,
    FundingSpec,
    Outcome,
    PositionKind,
    ReconciliationStatus
} from "../src/libraries/DealTypes.sol";
import {CoreDeploymentIntentOffchain} from "../src/libraries/ManifestTypes.sol";

/// @notice Exact payload and cardinality checks for canonical Core/Ledger events.
contract CanonicalEventsTest is Test {
    uint256 internal constant HOLDER_PK = 0xA11CE;
    uint256 internal constant PROVIDER_PK = 0xB0B;

    CoreDeployer internal deployer;
    CoreEscrow internal escrow;
    CreditLedger internal ledger;
    MockERC20 internal token;
    address internal holder;
    address internal provider;

    function setUp() public {
        holder = vm.addr(HOLDER_PK);
        provider = vm.addr(PROVIDER_PK);
        (deployer, ledger, escrow) = _deploy();
        token = new MockERC20();
    }

    function test_dealActivated_exactPayloadAndCardinality() public {
        DealTerms memory terms = _terms(100e18);
        terms.nonce = 1;
        vm.recordLogs();
        (bytes32 dealId,) = _activatePrepared(terms, 1, 2);

        Vm.Log[] memory logs =
            _filter(address(escrow), "DealActivated(bytes32,address,address,address,uint256)");
        assertEq(logs.length, 1);
        assertEq(logs[0].topics.length, 4);
        assertEq(logs[0].topics[1], dealId);
        assertEq(address(uint160(uint256(logs[0].topics[2]))), holder);
        assertEq(address(uint160(uint256(logs[0].topics[3]))), provider);
        (address emittedToken, uint256 principal) = abi.decode(logs[0].data, (address, uint256));
        assertEq(emittedToken, address(token));
        assertEq(principal, 100e18);
    }

    function test_fiatSentAndDealClosed_exactPayloadAndCardinality() public {
        bytes32 dealId = _activate(100e18, 1, 1, 2);

        vm.recordLogs();
        vm.prank(provider);
        escrow.markFiatSent(dealId);
        Vm.Log[] memory fiatLogs = _filter(address(escrow), "FiatSent(bytes32)");
        assertEq(fiatLogs.length, 1);
        assertEq(fiatLogs[0].topics.length, 2);
        assertEq(fiatLogs[0].topics[1], dealId);
        assertEq(fiatLogs[0].data.length, 0);

        vm.recordLogs();
        vm.prank(holder);
        escrow.holderRelease(dealId);
        Vm.Log[] memory closed = _filter(address(escrow), "DealClosed(bytes32,uint8,uint8,bytes32)");
        assertEq(closed.length, 1);
        assertEq(closed[0].topics.length, 2);
        assertEq(closed[0].topics[1], dealId);
        (uint8 terminalState, uint8 outcome, bytes32 terminalHash) =
            abi.decode(closed[0].data, (uint8, uint8, bytes32));
        assertEq(terminalState, DealState.Released);
        assertEq(outcome, Outcome.VoluntaryRelease);
        assertEq(terminalHash, escrow.getTerminalHash(dealId));
        assertTrue(terminalHash != bytes32(0));
    }

    function test_ledgerFundingSettlementRecoveryEvents_exactPayloads() public {
        DealTerms memory terms = _terms(100e18);
        terms.nonce = 1;
        (bytes32 dealId,) = _activatePrepared(terms, 1, 2);
        bytes32 activePosition = DealHashing.positionId(
            DealHashing.custodyBoundaryId(ledger.chainId(), 2, address(ledger), address(token)),
            PositionKind.ActiveDeal,
            dealId,
            bytes32(0),
            address(0)
        );
        assertTrue(ledger.positionExists(activePosition));
        assertEq(ledger.positionNominal(activePosition), 100e18);

        vm.prank(provider);
        escrow.markFiatSent(dealId);
        vm.prank(holder);
        escrow.holderRelease(dealId);

        bytes32 terminalHash = escrow.getTerminalHash(dealId);
        bytes32 terminalPosition = DealHashing.positionId(
            DealHashing.custodyBoundaryId(ledger.chainId(), 2, address(ledger), address(token)),
            PositionKind.DealTerminal,
            dealId,
            terminalHash,
            provider
        );
        assertTrue(ledger.positionExists(terminalPosition));
        assertEq(ledger.positionKind(terminalPosition), PositionKind.DealTerminal);
        assertEq(ledger.positionNominal(terminalPosition), 100e18);
        assertTrue(ledger.positionConsumed(activePosition));

        token.burn(address(ledger), 40e18);
        assertEq(
            ledger.checkpointBoundary(address(token)), ReconciliationStatus.DeficitCheckpointed
        );

        token.mint(address(this), 10e18);
        token.approve(address(ledger), 10e18);
        vm.expectEmit(true, false, false, true, address(ledger));
        emit RecoveryDeposited(address(token), 10e18);
        ledger.depositRecovery(address(token), 10e18);

        vm.expectEmit(true, false, false, true, address(ledger));
        emit RecoveryClaimed(terminalPosition, provider, 5e18);
        ledger.claimRecovery(terminalPosition, 5e18);
        assertEq(token.balanceOf(provider), 5e18);
    }

    event RecoveryDeposited(address indexed token, uint256 amount);
    event RecoveryClaimed(bytes32 indexed positionId, address to, uint256 amount);

    function test_manifestComputed_exactPayload() public {
        vm.recordLogs();
        CoreDeployer fresh = new CoreDeployer(
            2,
            2,
            keccak256("charter"),
            keccak256("tech"),
            address(this),
            address(this),
            CoreDeploymentIntentOffchain({
                buildHash: bytes32(uint256(1)),
                plannedDeploymentMethodHash: bytes32(uint256(2)),
                coreDeployerCreationCodeHash: bytes32(uint256(3)),
                factoryCreationCodeHash: bytes32(uint256(4)),
                ledgerCreationCodeHash: bytes32(uint256(5)),
                coordinatorCreationCodeHash: bytes32(uint256(6)),
                escrowCreationCodeHash: bytes32(uint256(7)),
                capabilityHash: bytes32(uint256(8)),
                governanceHash: bytes32(uint256(9)),
                predecessorIntentHash: bytes32(0)
            })
        );
        Vm.Log[] memory logs =
            _filter(address(fresh), "IntentComputed(bytes32,address,address,address)");
        assertEq(logs.length, 1);
        assertEq(logs[0].topics.length, 4);
        assertEq(logs[0].topics[1], fresh.intentHash());
        assertEq(address(uint160(uint256(logs[0].topics[2]))), address(fresh.ledger()));
        assertEq(address(uint160(uint256(logs[0].topics[3]))), address(fresh.coordinator()));
        assertEq(abi.decode(logs[0].data, (address)), address(fresh.escrow()));
    }

    function _filter(address emitter, string memory signature)
        internal
        returns (Vm.Log[] memory matched)
    {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic0 = keccak256(bytes(signature));
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == emitter && logs[i].topics.length > 0
                    && logs[i].topics[0] == topic0
            ) ++count;
        }
        matched = new Vm.Log[](count);
        uint256 next;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == emitter && logs[i].topics.length > 0
                    && logs[i].topics[0] == topic0
            ) {
                matched[next] = logs[i];
                unchecked {
                    ++next;
                }
            }
        }
    }

    function _terms(uint256 principal) internal view returns (DealTerms memory t) {
        t.holder = holder;
        t.provider = provider;
        t.holderReceiver = holder;
        t.providerReceiver = provider;
        t.token = address(token);
        t.principal = principal;
        t.nonce = 1;
        t.createExpiry = uint64(block.timestamp + 1 days);
        t.fiatDuration = 1 hours;
        t.releaseDuration = 1 hours;
        t.disputeDuration = 1 hours;
        t.disputeTimeoutProviderBps = 5_000;
        t.fiatCurrency = keccak256("USD");
        t.fiatAmount = 1000e18;
        t.paymentMethod = keccak256("SEPA");
        t.custodyBoundaryId =
            DealHashing.custodyBoundaryId(escrow.chainId(), 2, address(ledger), address(token));
    }

    function _activate(
        uint256 principal,
        uint256 termsNonce,
        uint256 principalFundingNonce,
        uint256 feeFundingNonce
    ) internal returns (bytes32 dealId) {
        DealTerms memory terms = _terms(principal);
        terms.nonce = termsNonce;
        (dealId,) = _activatePrepared(terms, principalFundingNonce, feeFundingNonce);
    }

    function _activatePrepared(
        DealTerms memory terms,
        uint256 principalFundingNonce,
        uint256 feeFundingNonce
    ) internal returns (bytes32 dealId, uint8 status) {
        FundingSpec memory principalSpec = FundingSpec({
            purpose: FundingPurpose.Principal,
            sourceMode: FundingSourceMode.WalletPull,
            token: address(token),
            amount: terms.principal,
            source: holder,
            sourcePositionId: bytes32(0),
            authority: holder
        });
        FundingSpec memory feeSpec = FundingSpec({
            purpose: FundingPurpose.ActivationFee,
            sourceMode: FundingSourceMode.WalletPull,
            token: address(token),
            amount: 0,
            source: holder,
            sourcePositionId: bytes32(0),
            authority: holder
        });
        bytes32 principalSpecHash = DealHashing.hashFundingSpec(principalSpec);
        terms.principalFundingHash = principalSpecHash;
        bytes32 termsHash = DealHashing.hashDealTerms(terms);
        FundingAuth memory principalAuth = FundingAuth({
            termsHash: termsHash,
            fundingSpecHash: principalSpecHash,
            purpose: FundingPurpose.Principal,
            authority: holder,
            nonce: principalFundingNonce,
            expiry: uint64(block.timestamp + 1 days)
        });
        FundingAuth memory feeAuth = FundingAuth({
            termsHash: termsHash,
            fundingSpecHash: bytes32(0),
            purpose: FundingPurpose.ActivationFee,
            authority: holder,
            nonce: feeFundingNonce,
            expiry: uint64(block.timestamp + 1 days)
        });
        token.mint(holder, terms.principal);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);
        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(
            HOLDER_PK,
            DealHashing.digest(
                ledger.DOMAIN_SEPARATOR(), DealHashing.hashFundingAuth(principalAuth)
            )
        );
        (uint8 v2, bytes32 r2, bytes32 s2) =
            vm.sign(HOLDER_PK, DealHashing.digest(escrow.DOMAIN_SEPARATOR(), termsHash));
        (uint8 v3, bytes32 r3, bytes32 s3) =
            vm.sign(PROVIDER_PK, DealHashing.digest(escrow.DOMAIN_SEPARATOR(), termsHash));
        return escrow.activate(
            terms,
            principalSpec,
            feeSpec,
            principalAuth,
            feeAuth,
            abi.encodePacked(r1, s1, v1),
            new bytes(0),
            abi.encodePacked(r2, s2, v2),
            abi.encodePacked(r3, s3, v3)
        );
    }

    function _deploy()
        internal
        returns (
            CoreDeployer deployedDeployer,
            CreditLedger deployedLedger,
            CoreEscrow deployedEscrow
        )
    {
        deployedDeployer = new CoreDeployer(
            2,
            2,
            keccak256("charter"),
            keccak256("tech"),
            address(this),
            address(this),
            CoreDeploymentIntentOffchain({
                buildHash: bytes32(uint256(1)),
                plannedDeploymentMethodHash: bytes32(uint256(2)),
                coreDeployerCreationCodeHash: bytes32(uint256(3)),
                factoryCreationCodeHash: bytes32(uint256(4)),
                ledgerCreationCodeHash: bytes32(uint256(5)),
                coordinatorCreationCodeHash: bytes32(uint256(6)),
                escrowCreationCodeHash: bytes32(uint256(7)),
                capabilityHash: bytes32(uint256(8)),
                governanceHash: bytes32(uint256(9)),
                predecessorIntentHash: bytes32(0)
            })
        );
        bytes memory ledgerInitCode = abi.encodePacked(
            type(CreditLedger).creationCode,
            abi.encode(
                address(deployedDeployer.escrow()),
                address(deployedDeployer.coordinator()),
                deployedDeployer.chainId()
            )
        );
        bytes memory coordinatorInitCode = abi.encodePacked(
            type(Coordinator).creationCode,
            abi.encode(
                deployedDeployer.chainId(), address(deployedDeployer.escrow()), address(this)
            )
        );
        bytes memory escrowInitCode = abi.encodePacked(
            type(CoreEscrow).creationCode,
            abi.encode(
                deployedDeployer.chainId(),
                deployedDeployer.protocolVersion(),
                deployedDeployer.charterHash(),
                deployedDeployer.techSpecHash(),
                address(deployedDeployer.ledger()),
                address(deployedDeployer.coordinator()),
                deployedDeployer.intentHash()
            )
        );
        deployedDeployer.deployTriad(ledgerInitCode, coordinatorInitCode, escrowInitCode);
        deployedLedger = deployedDeployer.ledger();
        deployedEscrow = deployedDeployer.escrow();
    }
}
