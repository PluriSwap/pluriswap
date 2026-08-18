// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Pool} from "./Pool.sol";

contract PoolFactory {
    event PoolCreated(address indexed pool, address indexed owner, address token, address escrow);

    address public immutable implementation;
    bytes32 public immutable officialCodehash;

    constructor() {
        implementation = address(new Pool());
        officialCodehash = keccak256(
            abi.encodePacked(hex"363d3d373d3d3d363d73", bytes20(implementation), hex"5af43d82803e903d91602b57fd5bf3")
        );
    }

    function createPool(address owner, address token, address escrow, address[] calldata controllers)
        external
        returns (address pool)
    {
        pool = Clones.clone(implementation);
        Pool(pool).initialize(owner, token, escrow, controllers);
        emit PoolCreated(pool, owner, token, escrow);
    }

    function isOfficial(address pool) external view returns (bool) {
        return pool.codehash == officialCodehash;
    }
}
