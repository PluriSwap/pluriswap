// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Kernel verbs `openCourt` / `readRuling`. 0=none, 1=holder, 2=provider, 3=stalemate.
///      `packageBinding` is the policy the kernel hashes with `PackageId.arbitration`.
interface ICourt {
    function packageId() external view returns (bytes32);
    function packageBinding() external view returns (address partner, uint256 key);
    /// @dev Flat, in the deal token, from the opener's wallet, once per deal (PLURISWAP.md §3.14.6).
    ///      A deal that carries a tribunal must cost something to fight in even without a reputation
    ///      package: otherwise freezing is free for whoever can freeze. Both getters enter the
    ///      `packageId`, so a different price is a different package and the parties signed it.
    function contestFee() external view returns (uint256);
    function feeRecipient() external view returns (address);
    function openCourt(bytes32 dealId, address controller) external payable;
    function readRuling(bytes32 dealId) external view returns (uint8);
}
