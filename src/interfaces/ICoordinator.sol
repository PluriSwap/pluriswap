// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ModuleBinding} from "../libraries/DealTypes.sol";

interface ICoordinator {
    /// @notice Check if a complete module binding tuple is admitted.
    function isAllowed(ModuleBinding calldata binding) external view returns (bool);

    /// @notice Admit a complete module binding tuple for future activations.
    function allow(ModuleBinding calldata binding) external;

    /// @notice Remove a complete module binding tuple for future activations.
    function disallow(ModuleBinding calldata binding) external;

    event ModuleAllowed(ModuleBinding binding);
    event ModuleDisallowed(ModuleBinding binding);
}
