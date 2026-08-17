// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackageId} from "./PackageId.sol";
import {IVerifier} from "./interfaces/IVerifier.sol";

/// @dev Isolated payment-proof package. Does not move escrow principal.
///      Only this V; another verifier is another packageId.
contract ZkMock {
    error WrongDealId();
    error NullifierUsed();

    IVerifier public immutable verifier;
    address public immutable feeRecipient;
    uint256 public immutable verifyFee;
    bytes32 public immutable packageId;

    mapping(bytes32 paymentNullifier => bool) public used;

    constructor(IVerifier verifier_, address feeRecipient_, uint256 verifyFee_) {
        verifier = verifier_;
        feeRecipient = feeRecipient_;
        verifyFee = verifyFee_;
        packageId = PackageId.zk(address(verifier_), feeRecipient_, verifyFee_);
    }

    function invoiceVerify() external view returns (uint256 amount, address recipient) {
        return (verifyFee, feeRecipient);
    }

    function verifyProof(bytes32 dealId, bytes calldata proof) external returns (bytes32 paymentNullifier) {
        bytes32 proofDealId;
        (proofDealId, paymentNullifier) = verifier.verify(proof);
        if (proofDealId != dealId) revert WrongDealId();
        if (used[paymentNullifier]) revert NullifierUsed();
        used[paymentNullifier] = true;
    }
}
