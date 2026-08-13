// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Minimal Kleros V2 surfaces the adapter actually calls. Full IERC20 fee overloads are unused.
interface IArbitratorV2 {
    event DisputeCreation(uint256 indexed _disputeID, IArbitrableV2 indexed _arbitrable);
    event Ruling(IArbitrableV2 indexed _arbitrable, uint256 indexed _disputeID, uint256 _ruling);

    function createDispute(uint256 _numberOfChoices, bytes calldata _extraData)
        external
        payable
        returns (uint256 disputeID);

    function arbitrationCost(bytes calldata _extraData) external view returns (uint256 cost);
}

interface IArbitrableV2 {
    event DisputeRequest(
        IArbitratorV2 indexed _arbitrator,
        uint256 indexed _arbitratorDisputeID,
        uint256 _externalDisputeID,
        uint256 _templateId,
        string _templateUri
    );
    event Ruling(IArbitratorV2 indexed _arbitrator, uint256 indexed _disputeID, uint256 _ruling);

    function rule(uint256 _disputeID, uint256 _ruling) external;
}
