// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Kernel verbs `openCourt` / `readRuling`. 0=none, 1=holder, 2=provider, 3=stalemate.
interface ICourt {
    function packageId() external view returns (bytes32);
    function openCourt(bytes32 dealId, address controller) external payable;
    function readRuling(bytes32 dealId) external view returns (uint8);
}
