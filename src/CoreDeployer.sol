// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CoreEscrow} from "./CoreEscrow.sol";
import {CreditLedger} from "./CreditLedger.sol";
import {Coordinator} from "./Coordinator.sol";

/// @notice Deploys the Mandatory Core triad in one CREATE2-friendly factory.
/// @dev Children are created with CREATE from this contract (nonces 1..3).
///      Deploy this factory with CREATE2 so its address — and thus all child
///      addresses — are deterministic from `salt` + constructor args.
contract CoreDeployer {
    CreditLedger public immutable ledger;
    Coordinator public immutable coordinator;
    CoreEscrow public immutable escrow;

    constructor(
        uint32 protocolVersion,
        bytes32 charterHash,
        bytes32 techSpecHash,
        address coordinatorOwner
    ) {
        if (coordinatorOwner == address(0)) revert();

        uint64 chainId_ = uint64(block.chainid);
        // First CREATE in this constructor uses nonce 1, second 2, third 3.
        address escrowPredicted = _createAddress(address(this), 3);

        ledger = new CreditLedger(escrowPredicted, chainId_);
        coordinator = new Coordinator(chainId_, escrowPredicted, coordinatorOwner);
        escrow = new CoreEscrow(
            chainId_,
            protocolVersion,
            charterHash,
            techSpecHash,
            address(ledger),
            address(coordinator)
        );

        require(address(escrow) == escrowPredicted, "CoreDeployer: escrow address mismatch");
        require(address(ledger) == _createAddress(address(this), 1), "CoreDeployer: ledger mismatch");
        require(
            address(coordinator) == _createAddress(address(this), 2), "CoreDeployer: coordinator mismatch"
        );
    }

    /// @dev CREATE address for `deployer` at `nonce` where 1 <= nonce <= 127.
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
