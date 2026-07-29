// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICoordinator} from "./interfaces/ICoordinator.sol";
import {ModuleRole} from "./libraries/DealTypes.sol";
import {Unauthorized, ZeroAddress} from "./libraries/CoreErrors.sol";

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
        chainId = chainId_;
        escrow = escrow_;
        owner = owner_;
    }

    function _key(ModuleRole role, address module, bytes32 codehash, bytes32 policyHash)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(role, module, codehash, policyHash));
    }

    function isAllowed(ModuleRole role, address module, bytes32 codehash, bytes32 policyHash)
        external
        view
        returns (bool)
    {
        return _allowed[_key(role, module, codehash, policyHash)];
    }

    function allow(ModuleRole role, address module, bytes32 codehash, bytes32 policyHash)
        external
        onlyOwner
    {
        if (module == address(0)) revert ZeroAddress();
        _allowed[_key(role, module, codehash, policyHash)] = true;
        emit ModuleAllowed(role, module, codehash, policyHash);
    }

    function disallow(ModuleRole role, address module, bytes32 codehash, bytes32 policyHash)
        external
        onlyOwner
    {
        _allowed[_key(role, module, codehash, policyHash)] = false;
        emit ModuleDisallowed(role, module, codehash, policyHash);
    }
}
