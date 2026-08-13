// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {PackageId} from "./PackageId.sol";

/// @dev Testnet adapter: address → subject. Not Human Passport.
contract PassportMock {
    error NoPassport();

    bytes32 public immutable packageId;
    mapping(address wallet => bytes32 subject) public subjectOf;

    constructor() {
        packageId = PackageId.passport(address(this));
    }

    function setHuman(address wallet, bytes32 subject) external {
        subjectOf[wallet] = subject;
    }

    function identify(address wallet) external view returns (bytes32 subject) {
        subject = subjectOf[wallet];
        if (subject == bytes32(0)) revert NoPassport();
    }
}
