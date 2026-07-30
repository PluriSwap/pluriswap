// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICoordinator} from "./interfaces/ICoordinator.sol";
import {ModuleBinding} from "./libraries/DealTypes.sol";
import {
    Unauthorized,
    ZeroAddress,
    InvalidChainId,
    ModuleCodehashMismatch,
    ModuleBindingMismatch
} from "./libraries/CoreErrors.sol";

/// @notice Module admission registry for future activations per MANDATORY_CORE.md §8.3.
/// @dev Admitted tuples may change only for future deals; active snapshots are immutable.
contract Coordinator is ICoordinator {
    uint64 public immutable chainId;
    address public immutable escrow;
    address public owner;

    mapping(bytes32 => bool) internal _allowed;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(uint64 chainId_, address escrow_, address owner_) {
        if (escrow_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        if (chainId_ != uint64(block.chainid)) revert InvalidChainId();
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
