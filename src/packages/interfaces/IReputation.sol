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
        ArbLoss
    }

    function packageId() external view returns (bytes32);
    function passport() external view returns (IPassport);
    function feeRecipient() external view returns (address);
    function activationFee() external view returns (uint256);
    function completionFee() external view returns (uint256);
    function contestFee() external view returns (uint256);
    function invoiceActivation() external view returns (uint256 amount, address recipient);
    function invoiceCompletion() external view returns (uint256 amount, address recipient);
    function invoiceContest() external view returns (uint256 amount, address recipient);
    function admit(address wallet, address token, uint256 principal, address vault) external returns (bytes32 subject);
    /// @dev `subject` is the Core snapshot (`IEscrow.subjects`), not a live `identify`.
    function notifyTerminal(bytes32 subject, address token, uint256 principal, Close kind) external;
}
