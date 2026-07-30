// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CoreEscrow} from "./CoreEscrow.sol";
import {CreditLedger} from "./CreditLedger.sol";
import {Coordinator} from "./Coordinator.sol";
import {DealHashing} from "./libraries/DealHashing.sol";
import {CoreManifestOffchain} from "./libraries/DealTypes.sol";
import {
    InvalidChainId,
    InvalidTerms,
    ManifestMismatch,
    ZeroAddress
} from "./libraries/CoreErrors.sol";

/// @notice Deploys the Mandatory Core triad and computes the immutable manifest hash per §13.
contract CoreDeployer {
    CreditLedger public immutable ledger;
    Coordinator public immutable coordinator;
    CoreEscrow public immutable escrow;
    bytes32 public immutable manifestHash;
    uint64 public immutable chainId;
    uint32 public immutable protocolVersion;
    bytes32 public immutable charterHash;
    bytes32 public immutable techSpecHash;

    constructor(
        uint32 protocolVersion_,
        bytes32 charterHash_,
        bytes32 techSpecHash_,
        address coordinatorOwner,
        CoreManifestOffchain memory offchain
    ) {
        if (protocolVersion_ != 2 || charterHash_ == bytes32(0) || techSpecHash_ == bytes32(0)) {
            revert InvalidTerms();
        }
        if (coordinatorOwner == address(0)) revert ZeroAddress();
        if (block.chainid > type(uint64).max) revert InvalidChainId();
        if (
            offchain.buildHash == bytes32(0) || offchain.deploymentMethodHash == bytes32(0)
                || offchain.coreDeployerArtifactHash == bytes32(0)
                || offchain.factoryArtifactHash == bytes32(0)
                || offchain.ledgerArtifactHash == bytes32(0)
                || offchain.coordinatorArtifactHash == bytes32(0)
                || offchain.escrowArtifactHash == bytes32(0)
                || offchain.capabilityHash == bytes32(0) || offchain.governanceHash == bytes32(0)
                || offchain.verificationHash == bytes32(0)
        ) revert ManifestMismatch();

        uint64 chainId_ = uint64(block.chainid);

        // Predict all addresses using CREATE nonce ordering
        address ledgerPredicted = _createAddress(address(this), 1);
        address coordinatorPredicted = _createAddress(address(this), 2);
        address escrowPredicted = _createAddress(address(this), 3);

        // Compute manifest hash from predicted addresses + off-chain fields
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

        // Deploy triad with real manifest hash
        ledger = new CreditLedger(escrowPredicted, chainId_);
        coordinator = new Coordinator(chainId_, escrowPredicted, coordinatorOwner);
        escrow = new CoreEscrow(
            chainId_,
            protocolVersion_,
            charterHash_,
            techSpecHash_,
            address(ledger),
            address(coordinator),
            manifestHash_
        );

        // Verify predicted addresses match
        require(address(escrow) == escrowPredicted, "CoreDeployer: escrow address mismatch");
        require(address(ledger) == ledgerPredicted, "CoreDeployer: ledger mismatch");
        require(address(coordinator) == coordinatorPredicted, "CoreDeployer: coordinator mismatch");
        if (
            address(ledger).code.length == 0 || address(coordinator).code.length == 0
                || address(escrow).code.length == 0
        ) {
            revert ManifestMismatch();
        }
        if (ledger.escrow() != address(escrow) || coordinator.escrow() != address(escrow)) {
            revert ManifestMismatch();
        }
        if (
            address(escrow.ledger()) != address(ledger)
                || address(escrow.coordinator()) != address(coordinator)
        ) {
            revert ManifestMismatch();
        }

        // Store immutables
        manifestHash = manifestHash_;
        chainId = chainId_;
        protocolVersion = protocolVersion_;
        charterHash = charterHash_;
        techSpecHash = techSpecHash_;

        emit ManifestComputed(manifestHash_, ledgerPredicted, coordinatorPredicted, escrowPredicted);
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
}
