// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ModuleRole} from "../libraries/DealTypes.sol";

interface ICoordinator {
    function isAllowed(
        ModuleRole role,
        address module,
        bytes32 codehash,
        bytes32 policyHash
    ) external view returns (bool);

    function allow(ModuleRole role, address module, bytes32 codehash, bytes32 policyHash)
        external;

    function disallow(ModuleRole role, address module, bytes32 codehash, bytes32 policyHash)
        external;

    event ModuleAllowed(
        ModuleRole indexed role, address indexed module, bytes32 codehash, bytes32 policyHash
    );
    event ModuleDisallowed(
        ModuleRole indexed role, address indexed module, bytes32 codehash, bytes32 policyHash
    );
}
