// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPassport} from "./IPassport.sol";

/// @dev Kernel verbs `reserve` / `unlock` / `slash` / `burn`. Deposit/withdraw are the subject's.
interface IBondVault {
    function packageId() external view returns (bytes32);
    function passport() external view returns (IPassport);
    function sink() external view returns (address);
    function available(bytes32 subject, address token) external view returns (uint256);
    function locked(bytes32 subject, address token) external view returns (uint256);
    function reserve(bytes32 subject, address token, bytes32 dealId, uint256 principal) external;
    function unlock(bytes32 subject, address token, bytes32 dealId) external;
    function slash(
        bytes32 loser,
        bytes32 winner,
        address token,
        bytes32 dealId,
        address winnerSigning,
        address controller
    ) external;
    function burn(bytes32 subjectA, bytes32 subjectB, address token, bytes32 dealId) external;
}
