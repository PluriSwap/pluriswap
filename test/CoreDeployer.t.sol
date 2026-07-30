// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CoreDeployer} from "../src/CoreDeployer.sol";
import {CoreEscrow} from "../src/CoreEscrow.sol";
import {CreditLedger} from "../src/CreditLedger.sol";
import {Coordinator} from "../src/Coordinator.sol";
import {CoreArtifactConstants} from "../src/libraries/CoreArtifactConstants.sol";
import {CoreManifestOffchain} from "../src/libraries/DealTypes.sol";
import {
    DeploymentAlreadyFinalized,
    InvalidChildInitCode,
    InvalidTerms,
    ManifestMismatch,
    Unauthorized
} from "../src/libraries/CoreErrors.sol";

contract CoreDeployerTest is Test {
    address internal constant OWNER = address(0xCAFE);
    address internal constant OPERATOR = address(0xBEEF);
    address internal constant OTHER = address(0xD00D);

    function test_constructorLeavesTriadUninitialized() public {
        CoreDeployer deployer = _newDeployer(1);

        assertFalse(deployer.triadDeployed());
        assertEq(address(deployer.ledger()), _createAddress(address(deployer), 1));
        assertEq(address(deployer.coordinator()), _createAddress(address(deployer), 2));
        assertEq(address(deployer.escrow()), _createAddress(address(deployer), 3));
        assertEq(address(deployer.ledger()).code.length, 0);
        assertEq(address(deployer.coordinator()).code.length, 0);
        assertEq(address(deployer.escrow()).code.length, 0);
    }

    function test_deployTriadCreatesExactlyThreeChildren() public {
        CoreDeployer deployer = _newDeployer(1);
        (
            bytes memory ledgerInitCode,
            bytes memory coordinatorInitCode,
            bytes memory escrowInitCode
        ) = _initCodes(deployer);

        vm.prank(OPERATOR);
        (address deployedLedger, address deployedCoordinator, address deployedEscrow) =
            deployer.deployTriad(ledgerInitCode, coordinatorInitCode, escrowInitCode);

        assertTrue(deployer.triadDeployed());
        assertEq(deployedLedger, address(deployer.ledger()));
        assertEq(deployedCoordinator, address(deployer.coordinator()));
        assertEq(deployedEscrow, address(deployer.escrow()));
        assertGt(deployedLedger.code.length, 0);
        assertGt(deployedCoordinator.code.length, 0);
        assertGt(deployedEscrow.code.length, 0);
        assertEq(_createAddress(address(deployer), 4).code.length, 0);
        assertEq(CreditLedger(payable(deployedLedger)).escrow(), deployedEscrow);
        assertEq(Coordinator(deployedCoordinator).escrow(), deployedEscrow);
        assertEq(address(CoreEscrow(payable(deployedEscrow)).ledger()), deployedLedger);
        assertEq(address(CoreEscrow(payable(deployedEscrow)).coordinator()), deployedCoordinator);
        assertEq(CoreEscrow(payable(deployedEscrow)).manifestHash(), deployer.manifestHash());
    }

    function test_deployTriadRejectsUnauthorizedOperator() public {
        CoreDeployer deployer = _newDeployer(1);
        (
            bytes memory ledgerInitCode,
            bytes memory coordinatorInitCode,
            bytes memory escrowInitCode
        ) = _initCodes(deployer);

        vm.expectRevert(Unauthorized.selector);
        vm.prank(OTHER);
        deployer.deployTriad(ledgerInitCode, coordinatorInitCode, escrowInitCode);
    }

    function test_deployTriadRejectsReplay() public {
        CoreDeployer deployer = _newDeployer(1);
        (
            bytes memory ledgerInitCode,
            bytes memory coordinatorInitCode,
            bytes memory escrowInitCode
        ) = _initCodes(deployer);

        vm.startPrank(OPERATOR);
        deployer.deployTriad(ledgerInitCode, coordinatorInitCode, escrowInitCode);
        vm.expectRevert(DeploymentAlreadyFinalized.selector);
        deployer.deployTriad(ledgerInitCode, coordinatorInitCode, escrowInitCode);
        vm.stopPrank();
    }

    function test_deployTriadValidatesAllInitcodeBeforeCreate() public {
        CoreDeployer deployer = _newDeployer(1);
        (
            bytes memory ledgerInitCode,
            bytes memory coordinatorInitCode,
            bytes memory escrowInitCode
        ) = _initCodes(deployer);
        bytes memory tamperedLedgerInitCode = abi.encodePacked(ledgerInitCode, bytes1(0x01));

        vm.expectRevert(InvalidChildInitCode.selector);
        vm.prank(OPERATOR);
        deployer.deployTriad(tamperedLedgerInitCode, coordinatorInitCode, escrowInitCode);

        assertFalse(deployer.triadDeployed());
        assertEq(address(deployer.ledger()).code.length, 0);
        assertEq(address(deployer.coordinator()).code.length, 0);
        assertEq(address(deployer.escrow()).code.length, 0);
    }

    function test_deployTriadRejectsWrongConstructorArguments() public {
        CoreDeployer deployer = _newDeployer(1);
        (bytes memory ledgerInitCode,, bytes memory escrowInitCode) = _initCodes(deployer);
        bytes memory wrongCoordinatorInitCode = abi.encodePacked(
            type(Coordinator).creationCode,
            abi.encode(deployer.chainId(), address(deployer.escrow()), OTHER)
        );

        vm.expectRevert(InvalidChildInitCode.selector);
        vm.prank(OPERATOR);
        deployer.deployTriad(ledgerInitCode, wrongCoordinatorInitCode, escrowInitCode);
    }

    function test_deployTriadRollsBackIfCreateCollides() public {
        CoreDeployer deployer = _newDeployer(1);
        (
            bytes memory ledgerInitCode,
            bytes memory coordinatorInitCode,
            bytes memory escrowInitCode
        ) = _initCodes(deployer);
        vm.etch(address(deployer.coordinator()), hex"6000");

        vm.expectRevert(ManifestMismatch.selector);
        vm.prank(OPERATOR);
        deployer.deployTriad(ledgerInitCode, coordinatorInitCode, escrowInitCode);

        assertFalse(deployer.triadDeployed());
        assertEq(address(deployer.ledger()).code.length, 0);
    }

    function test_methodSpecificFactoryHashRules() public {
        _newDeployer(1);
        _newDeployer(2);

        CoreManifestOffchain memory methodOneWithFactory = _offchain(1);
        methodOneWithFactory.factoryArtifactHash = bytes32(uint256(99));
        vm.expectRevert(ManifestMismatch.selector);
        new CoreDeployer(
            1, 2, keccak256("charter"), keccak256("tech"), OWNER, OPERATOR, methodOneWithFactory
        );

        CoreManifestOffchain memory methodTwoWithoutFactory = _offchain(2);
        methodTwoWithoutFactory.factoryArtifactHash = bytes32(0);
        vm.expectRevert(ManifestMismatch.selector);
        new CoreDeployer(
            2, 2, keccak256("charter"), keccak256("tech"), OWNER, OPERATOR, methodTwoWithoutFactory
        );
    }

    function test_invalidDeploymentMethodRejects() public {
        vm.expectRevert(InvalidTerms.selector);
        new CoreDeployer(
            3, 2, keccak256("charter"), keccak256("tech"), OWNER, OPERATOR, _offchain(1)
        );
    }

    function test_creationCodeConstantsMatchBuild() public pure {
        assertEq(
            keccak256(type(CreditLedger).creationCode),
            CoreArtifactConstants.CREDIT_LEDGER_CREATION_CODE_HASH
        );
        assertEq(
            keccak256(type(Coordinator).creationCode),
            CoreArtifactConstants.COORDINATOR_CREATION_CODE_HASH
        );
        assertEq(
            keccak256(type(CoreEscrow).creationCode),
            CoreArtifactConstants.CORE_ESCROW_CREATION_CODE_HASH
        );
        assertEq(
            type(CreditLedger).creationCode.length,
            CoreArtifactConstants.CREDIT_LEDGER_CREATION_CODE_LENGTH
        );
        assertEq(
            type(Coordinator).creationCode.length,
            CoreArtifactConstants.COORDINATOR_CREATION_CODE_LENGTH
        );
        assertEq(
            type(CoreEscrow).creationCode.length,
            CoreArtifactConstants.CORE_ESCROW_CREATION_CODE_LENGTH
        );
    }

    function test_coreDeployerInitcodeFitsEip3860() public pure {
        assertLt(type(CoreDeployer).creationCode.length, 49_152);
    }

    function _newDeployer(uint8 method) internal returns (CoreDeployer) {
        return new CoreDeployer(
            method, 2, keccak256("charter"), keccak256("tech"), OWNER, OPERATOR, _offchain(method)
        );
    }

    function _offchain(uint8 method) internal pure returns (CoreManifestOffchain memory offchain) {
        offchain = CoreManifestOffchain({
            buildHash: bytes32(uint256(1)),
            deploymentMethodHash: bytes32(uint256(2)),
            coreDeployerArtifactHash: bytes32(uint256(3)),
            factoryArtifactHash: method == 1 ? bytes32(0) : bytes32(uint256(4)),
            ledgerArtifactHash: bytes32(uint256(5)),
            coordinatorArtifactHash: bytes32(uint256(6)),
            escrowArtifactHash: bytes32(uint256(7)),
            capabilityHash: bytes32(uint256(8)),
            governanceHash: bytes32(uint256(9)),
            verificationHash: bytes32(uint256(10)),
            predecessorManifestHash: bytes32(0)
        });
    }

    function _initCodes(CoreDeployer deployer)
        internal
        view
        returns (
            bytes memory ledgerInitCode,
            bytes memory coordinatorInitCode,
            bytes memory escrowInitCode
        )
    {
        ledgerInitCode = abi.encodePacked(
            type(CreditLedger).creationCode,
            abi.encode(address(deployer.escrow()), deployer.chainId())
        );
        coordinatorInitCode = abi.encodePacked(
            type(Coordinator).creationCode,
            abi.encode(deployer.chainId(), address(deployer.escrow()), deployer.coordinatorOwner())
        );
        escrowInitCode = abi.encodePacked(
            type(CoreEscrow).creationCode,
            abi.encode(
                deployer.chainId(),
                deployer.protocolVersion(),
                deployer.charterHash(),
                deployer.techSpecHash(),
                address(deployer.ledger()),
                address(deployer.coordinator()),
                deployer.manifestHash()
            )
        );
    }

    function _createAddress(address creator, uint8 nonce) internal pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), creator, bytes1(nonce)))
                )
            )
        );
    }
}
