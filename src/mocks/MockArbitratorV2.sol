// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IArbitrableV2, IArbitratorV2} from "../packages/interfaces/IKlerosV2.sol";

/// @dev Local stand-in for KlerosCore. Tests call `giveRuling`; they never wait on jurors.
contract MockArbitratorV2 is IArbitratorV2 {
    error InsufficientFee();
    error UnknownDispute();

    uint256 public cost;
    uint256 public nextId;
    mapping(uint256 disputeId => address) public arbitrableOf;

    constructor(uint256 cost_) {
        cost = cost_;
    }

    receive() external payable {}

    function arbitrationCost(bytes calldata) external view returns (uint256) {
        return cost;
    }

    function createDispute(uint256, bytes calldata) external payable returns (uint256 disputeID) {
        if (msg.value < cost) revert InsufficientFee();
        disputeID = nextId++;
        arbitrableOf[disputeID] = msg.sender;
        emit DisputeCreation(disputeID, IArbitrableV2(msg.sender));
    }

    function giveRuling(uint256 disputeId, uint256 ruling) external {
        address arbitrable = arbitrableOf[disputeId];
        if (arbitrable == address(0)) revert UnknownDispute();
        emit Ruling(IArbitrableV2(arbitrable), disputeId, ruling);
        IArbitrableV2(arbitrable).rule(disputeId, ruling);
    }
}
