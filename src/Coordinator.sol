// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICoordinator} from "./interfaces/ICoordinator.sol";
import {
    ModuleBinding,
    TerminalAllocation,
    TerminalPlanContext,
    TerminalRecord
} from "./libraries/DealTypes.sol";
import {TerminalPlanning} from "./libraries/TerminalPlanning.sol";
import {
    Unauthorized,
    ZeroAddress,
    InvalidChainId,
    ModuleCodehashMismatch,
    ModuleBindingMismatch
} from "./libraries/CoreErrors.sol";

/// @notice Module admission registry plus immutable static planning per MANDATORY_CORE.md §8.3.
/// @dev Admitted tuples may change only for future deals; active snapshots are immutable.
///      Planning helpers are pure and MUST NOT read `_allowed` or `owner`.
contract Coordinator is ICoordinator {
    uint64 public immutable chainId;
    address public immutable escrow;
    address public immutable owner;

    mapping(bytes32 => bool) internal _allowed;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(uint64 chainId_, address escrow_, address owner_) {
        if (block.chainid > type(uint64).max) revert InvalidChainId();
        if (block.chainid != uint256(chainId_)) revert InvalidChainId();
        if (escrow_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        chainId = chainId_;
        escrow = escrow_;
        owner = owner_;
    }

    function _key(ModuleBinding memory b) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                b.role,
                b.module,
                b.runtimeCodeHash,
                b.policyHash,
                b.manifestHash,
                b.apiId,
                b.moduleTermsHash,
                b.capabilityMask
            )
        );
    }

    function isAllowed(ModuleBinding calldata binding) external view returns (bool) {
        return _allowed[_key(binding)];
    }

    /// @notice Pure deal-terminal planner for Core settlement and off-chain verification.
    /// @dev Does not read admission state or owner; cannot rewrite active obligations.
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
        )
    {
        return TerminalPlanning.plan(
            chainId_,
            protocolVersion_,
            escrow_,
            ledger_,
            dealId,
            TerminalPlanContext({
                token: token,
                principal: principal,
                completionFee: completionFee,
                holderReceiver: holderReceiver,
                providerReceiver: providerReceiver,
                completionFeeRecipient: completionFeeRecipient,
                termsHash: termsHash,
                modulesHash: modulesHash,
                custodyBoundaryId: custodyBoundaryId
            }),
            terminalState,
            outcome,
            providerBps,
            evidenceHash,
            terminatedAt
        );
    }

    function allow(ModuleBinding calldata binding) external onlyOwner {
        _validateBinding(binding);
        _allowed[_key(binding)] = true;
        emit ModuleAllowed(binding);
    }

    function disallow(ModuleBinding calldata binding) external onlyOwner {
        _validateBinding(binding);
        _allowed[_key(binding)] = false;
        emit ModuleDisallowed(binding);
    }

    function _validateBinding(ModuleBinding calldata binding) internal view {
        if (binding.module == address(0)) revert ZeroAddress();
        if (
            binding.role > 7 || binding.runtimeCodeHash == bytes32(0)
                || binding.policyHash == bytes32(0)
        ) {
            revert ModuleBindingMismatch();
        }
        if (binding.manifestHash == bytes32(0) || binding.apiId == bytes32(0)) {
            revert ModuleBindingMismatch();
        }
        if (binding.module.codehash != binding.runtimeCodeHash) revert ModuleCodehashMismatch();
    }
}
