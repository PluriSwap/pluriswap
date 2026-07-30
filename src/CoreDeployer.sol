// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CoreEscrow} from "./CoreEscrow.sol";
import {CreditLedger} from "./CreditLedger.sol";
import {Coordinator} from "./Coordinator.sol";
import {DealHashing} from "./libraries/DealHashing.sol";
import {CoreArtifactConstants} from "./libraries/CoreArtifactConstants.sol";
import {CoreManifestOffchain} from "./libraries/DealTypes.sol";
import {
    DeploymentAlreadyFinalized,
    InvalidChainId,
    InvalidChildInitCode,
    InvalidTerms,
    ManifestMismatch,
    Unauthorized,
    ZeroAddress
} from "./libraries/CoreErrors.sol";

/// @notice Computes the Mandatory Core identity and creates its three children.
/// @dev Child deployment is staged so CoreDeployer initcode does not embed the triad's
///      creation bytecode. The finalization call remains atomic and CoreDeployer is
///      permanently inert after it succeeds.
contract CoreDeployer {
    uint8 public constant DIRECT_CORE_DEPLOYER = 1;
    uint8 public constant CREATE2_FACTORY_CORE_DEPLOYER = 2;

    CreditLedger public immutable ledger;
    Coordinator public immutable coordinator;
    CoreEscrow public immutable escrow;
    bytes32 public immutable manifestHash;
    uint64 public immutable chainId;
    uint32 public immutable protocolVersion;
    uint8 public immutable deploymentMethod;
    bytes32 public immutable charterHash;
    bytes32 public immutable techSpecHash;
    address public immutable coordinatorOwner;
    address public immutable deploymentOperator;

    bool public triadDeployed;

    constructor(
        uint8 deploymentMethod_,
        uint32 protocolVersion_,
        bytes32 charterHash_,
        bytes32 techSpecHash_,
        address coordinatorOwner_,
        address deploymentOperator_,
        CoreManifestOffchain memory offchain
    ) {
        if (
            (deploymentMethod_ != DIRECT_CORE_DEPLOYER
                    && deploymentMethod_ != CREATE2_FACTORY_CORE_DEPLOYER) || protocolVersion_ != 2
                || charterHash_ == bytes32(0) || techSpecHash_ == bytes32(0)
        ) {
            revert InvalidTerms();
        }
        if (coordinatorOwner_ == address(0) || deploymentOperator_ == address(0)) {
            revert ZeroAddress();
        }
        if (block.chainid > type(uint64).max) revert InvalidChainId();
        if (
            offchain.buildHash == bytes32(0) || offchain.deploymentMethodHash == bytes32(0)
                || offchain.coreDeployerArtifactHash == bytes32(0)
                || offchain.ledgerArtifactHash == bytes32(0)
                || offchain.coordinatorArtifactHash == bytes32(0)
                || offchain.escrowArtifactHash == bytes32(0)
                || offchain.capabilityHash == bytes32(0) || offchain.governanceHash == bytes32(0)
                || offchain.verificationHash == bytes32(0)
        ) revert ManifestMismatch();
        if (deploymentMethod_ == DIRECT_CORE_DEPLOYER
                ? offchain.factoryArtifactHash != bytes32(0)
                : offchain.factoryArtifactHash == bytes32(0)) revert ManifestMismatch();

        uint64 chainId_ = uint64(block.chainid);
        address ledgerPredicted = _createAddress(address(this), 1);
        address coordinatorPredicted = _createAddress(address(this), 2);
        address escrowPredicted = _createAddress(address(this), 3);
        if (
            ledgerPredicted == address(0) || coordinatorPredicted == address(0)
                || escrowPredicted == address(0) || ledgerPredicted == coordinatorPredicted
                || ledgerPredicted == escrowPredicted || coordinatorPredicted == escrowPredicted
        ) revert ManifestMismatch();

        bytes32 manifestHash_ = DealHashing.hashCoreManifest(
            chainId_,
            protocolVersion_,
            charterHash_,
            techSpecHash_,
            address(this),
            ledgerPredicted,
            coordinatorPredicted,
            escrowPredicted,
            offchain
        );
        if (manifestHash_ == bytes32(0)) revert ManifestMismatch();

        ledger = CreditLedger(payable(ledgerPredicted));
        coordinator = Coordinator(coordinatorPredicted);
        escrow = CoreEscrow(payable(escrowPredicted));
        manifestHash = manifestHash_;
        chainId = chainId_;
        protocolVersion = protocolVersion_;
        deploymentMethod = deploymentMethod_;
        charterHash = charterHash_;
        techSpecHash = techSpecHash_;
        coordinatorOwner = coordinatorOwner_;
        deploymentOperator = deploymentOperator_;

        emit ManifestComputed(manifestHash_, ledgerPredicted, coordinatorPredicted, escrowPredicted);
    }

    /// @notice Atomically creates Ledger, Coordinator, and Escrow in CREATE order.
    /// @dev All initcode and constructor arguments are validated before the first CREATE.
    function deployTriad(
        bytes calldata ledgerInitCode,
        bytes calldata coordinatorInitCode,
        bytes calldata escrowInitCode
    )
        external
        returns (address deployedLedger, address deployedCoordinator, address deployedEscrow)
    {
        if (msg.sender != deploymentOperator) {
            revert Unauthorized();
        }
        if (triadDeployed) revert DeploymentAlreadyFinalized();

        _validateInitCode(
            ledgerInitCode,
            CoreArtifactConstants.CREDIT_LEDGER_CREATION_CODE_LENGTH,
            CoreArtifactConstants.CREDIT_LEDGER_CREATION_CODE_HASH,
            abi.encode(address(escrow), chainId)
        );
        _validateInitCode(
            coordinatorInitCode,
            CoreArtifactConstants.COORDINATOR_CREATION_CODE_LENGTH,
            CoreArtifactConstants.COORDINATOR_CREATION_CODE_HASH,
            abi.encode(chainId, address(escrow), coordinatorOwner)
        );
        _validateInitCode(
            escrowInitCode,
            CoreArtifactConstants.CORE_ESCROW_CREATION_CODE_LENGTH,
            CoreArtifactConstants.CORE_ESCROW_CREATION_CODE_HASH,
            abi.encode(
                chainId,
                protocolVersion,
                charterHash,
                techSpecHash,
                address(ledger),
                address(coordinator),
                manifestHash
            )
        );

        deployedLedger = _create(ledgerInitCode);
        deployedCoordinator = _create(coordinatorInitCode);
        deployedEscrow = _create(escrowInitCode);
        if (
            deployedLedger != address(ledger) || deployedCoordinator != address(coordinator)
                || deployedEscrow != address(escrow)
        ) revert ManifestMismatch();
        if (
            deployedLedger.code.length == 0 || deployedCoordinator.code.length == 0
                || deployedEscrow.code.length == 0
        ) revert ManifestMismatch();

        if (
            CreditLedger(payable(deployedLedger)).escrow() != deployedEscrow
                || Coordinator(deployedCoordinator).escrow() != deployedEscrow
                || address(CoreEscrow(payable(deployedEscrow)).ledger()) != deployedLedger
                || address(CoreEscrow(payable(deployedEscrow)).coordinator()) != deployedCoordinator
                || CoreEscrow(payable(deployedEscrow)).manifestHash() != manifestHash
        ) revert ManifestMismatch();

        triadDeployed = true;
        emit TriadDeployed(
            keccak256(ledgerInitCode),
            keccak256(coordinatorInitCode),
            keccak256(escrowInitCode),
            deployedLedger,
            deployedCoordinator,
            deployedEscrow
        );
    }

    function _validateInitCode(
        bytes calldata initCode,
        uint256 creationCodeLength,
        bytes32 creationCodeHash,
        bytes memory constructorArgs
    ) private pure {
        if (initCode.length != creationCodeLength + constructorArgs.length) {
            revert InvalidChildInitCode();
        }
        if (keccak256(initCode[:creationCodeLength]) != creationCodeHash) {
            revert InvalidChildInitCode();
        }
        if (keccak256(initCode[creationCodeLength:]) != keccak256(constructorArgs)) {
            revert InvalidChildInitCode();
        }
    }

    function _create(bytes calldata initCode) private returns (address deployed) {
        bytes memory initCodeMemory = initCode;
        assembly ("memory-safe") {
            deployed := create(0, add(initCodeMemory, 0x20), mload(initCodeMemory))
        }
        if (deployed == address(0)) revert ManifestMismatch();
    }

    function _createAddress(address deployer, uint8 nonce) private pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(nonce)))
                )
            )
        );
    }

    event ManifestComputed(
        bytes32 indexed manifestHash,
        address indexed ledger,
        address indexed coordinator,
        address escrow
    );

    event TriadDeployed(
        bytes32 indexed ledgerInitCodeHash,
        bytes32 indexed coordinatorInitCodeHash,
        bytes32 indexed escrowInitCodeHash,
        address ledger,
        address coordinator,
        address escrow
    );
}
