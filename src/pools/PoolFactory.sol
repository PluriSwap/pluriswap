// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Pool} from "./Pool.sol";

contract PoolFactory {
    event PoolCreated(address indexed pool, address token, address escrow, bool openDeposits);

    address public immutable implementation;
    bytes32 public immutable officialCodehash;

    constructor() {
        implementation = address(new Pool());
        officialCodehash = keccak256(
            abi.encodePacked(hex"363d3d373d3d3d363d73", bytes20(implementation), hex"5af43d82803e903d91602b57fd5bf3")
        );
    }

    function createPool(
        address[] calldata sponsors,
        address token,
        address escrow,
        address[] calldata controllers,
        bool openDeposits,
        address[] calldata depositors,
        uint16 controllerFeeBps
    ) external returns (address pool) {
        pool = Clones.clone(implementation);
        Pool(pool).initialize(sponsors, token, escrow, controllers, openDeposits, depositors, controllerFeeBps);
        emit PoolCreated(pool, token, escrow, openDeposits);
    }

    function isOfficial(address pool) external view returns (bool) {
        return pool.codehash == officialCodehash;
    }
}
