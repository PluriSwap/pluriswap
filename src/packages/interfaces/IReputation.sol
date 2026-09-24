// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPassport} from "./IPassport.sol";

/// @dev Kernel verbs `admit` / `invoice*` / `notifyTerminal`.
interface IReputation {
    enum Close {
        Peaceful,
        Silent,
        Stalemate,
        ArbWin,
        ArbLoss,
        Deadlock // a dispute in a deal with no tribunal, left to its clock by both sides
    }

    function packageId() external view returns (bytes32);
    function passport() external view returns (IPassport);
    function feeRecipient() external view returns (address);
    function activationFee() external view returns (uint256);
    function completionFee() external view returns (uint256);
    function contestBps() external view returns (uint256);
    function contestFloor() external view returns (uint256);
    function invoiceActivation() external view returns (uint256 amount, address recipient);
    function invoiceCompletion() external view returns (uint256 amount, address recipient);
    function invoiceContest(uint256 principal) external view returns (uint256 amount, address recipient);
    /// @dev `dealId` lets a module key its own state per deal — the private module uses it to check
    ///      that the two sides of one activation agreed on the same counterparty (§3.14.7 anti-farming).
    function admit(address wallet, bytes32 dealId, address token, uint256 principal, address vault)
        external
        returns (bytes32 subject);
    /// @dev `subject` is the Core snapshot (`IEscrow.subjects`), not a live `identify`; `counterparty`
    ///      is the other side's snapshot. Reputation that measures counterparties has to know who the
    ///      counterparty WAS: credit is once per pair, penalties are every time (§3.14.7).
    function notifyTerminal(bytes32 subject, bytes32 counterparty, address token, uint256 principal, Close kind)
        external;
}
