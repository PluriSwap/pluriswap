// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CoreEscrow} from "./CoreEscrow.sol";
import {CreditLedger} from "./CreditLedger.sol";
import {Coordinator} from "./Coordinator.sol";

/// @notice Deploys the Mandatory Core triad. Full manifest in Wave 4.
contract CoreDeployer {
    CreditLedger public immutable ledger;
    Coordinator public immutable coordinator;
    CoreEscrow public immutable escrow;
    bytes32 public immutable manifestHash;

    constructor(
        uint32 protocolVersion,
        bytes32 charterHash,
        bytes32 techSpecHash,
        address coordinatorOwner
    ) {
        if (coordinatorOwner == address(0)) revert();

        uint64 chainId_ = uint64(block.chainid);
        address escrowPredicted = _createAddress(address(this), 3);

        ledger = new CreditLedger(escrowPredicted, chainId_);
        coordinator = new Coordinator(chainId_, escrowPredicted, coordinatorOwner);
        escrow = new CoreEscrow(
            chainId_,
            protocolVersion,
            charterHash,
            techSpecHash,
            address(ledger),
            address(coordinator),
            bytes32(0) // manifestHash — Wave 4 will compute the real hash
        );

        require(address(escrow) == escrowPredicted, "CoreDeployer: escrow address mismatch");
        require(address(ledger) == _createAddress(address(this), 1), "CoreDeployer: ledger mismatch");
        require(
            address(coordinator) == _createAddress(address(this), 2),
            "CoreDeployer: coordinator mismatch"
        );

        manifestHash = bytes32(0); // Wave 4
    }

    function _createAddress(address deployer, uint8 nonce) private pure returns (address) {
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(nonce))
                    )
                )
            )
        );
    }
}
