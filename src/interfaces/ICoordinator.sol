// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ModuleBinding, TerminalAllocation, TerminalRecord} from "../libraries/DealTypes.sol";

interface ICoordinator {
    function isAllowed(ModuleBinding calldata binding) external view returns (bool);
    function allow(ModuleBinding calldata binding) external;
    function disallow(ModuleBinding calldata binding) external;

    function planDealTerminal(
        uint64 chainId_,
        uint32 protocolVersion_,
        address escrow_,
        address ledger_,
        bytes32 dealId,
        address token,
        uint256 principal,
        uint256 completionFee,
        address holderReceiver,
        address providerReceiver,
        address completionFeeRecipient,
        bytes32 termsHash,
        bytes32 modulesHash,
        bytes32 custodyBoundaryId,
        uint8 terminalState,
        uint8 outcome,
        uint16 providerBps,
        bytes32 evidenceHash,
        uint64 terminatedAt
    )
        external
        pure
        returns (
            TerminalRecord memory terminalRecord,
            bytes32 terminalHash,
            TerminalAllocation[] memory allocations
        );

    event ModuleAllowed(ModuleBinding binding);
    event ModuleDisallowed(ModuleBinding binding);
}
