// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";

/// @dev Chain ids the deploy scripts branch on. Shared base so pickers can be mixed into one script.
abstract contract ChainIds is Script {
    uint256 internal constant ARBITRUM_ONE = 42161;
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;
    uint256 internal constant ANVIL = 31337;
}
