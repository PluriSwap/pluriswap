// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Status, DealTerms, PackageMods, DealClocks} from "../libraries/Types.sol";

/// @dev Read surface of the recinto. Packages, pools, and ramps import this.
///      Nobody writes deal state or moves principal through this interface.
interface IEscrow {
    function domainSeparator() external view returns (bytes32);

    function used(address signer, uint256 nonce) external view returns (bool);

    function dealOf(address signer, uint256 nonce) external view returns (bytes32);

    function status(bytes32 dealId) external view returns (Status);

    function terms(bytes32 dealId) external view returns (DealTerms memory);

    function clocks(bytes32 dealId) external view returns (DealClocks memory);

    function subjects(bytes32 dealId) external view returns (bytes32 holderSubject, bytes32 providerSubject);

    function modules(bytes32 dealId) external view returns (PackageMods memory);

    function kinds(bytes32 dealId) external view returns (uint8);

    function settlementOf(bytes32 dealId)
        external
        view
        returns (Status status_, uint256 holderAmt, uint256 providerAmt);

    function creditOf(address token, address beneficiary) external view returns (uint256);
}
