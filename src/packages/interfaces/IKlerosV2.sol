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
    /// @dev Shape deployed on Arbitrum One / Sepolia today (subgraph `master`): the Court UI keys evidence and
    ///      the template by `_externalDisputeID` (PluriSwap emits `uint256(dealId)`).
    event DisputeRequest(
        IArbitratorV2 indexed _arbitrator,
        uint256 indexed _arbitratorDisputeID,
        uint256 _externalDisputeID,
        uint256 _templateId,
        string _templateUri
    );
    /// @dev Shape on Kleros `dev` (externalDisputeID dropped; evidence keyed by the arbitrator dispute id).
    ///      Emitted alongside the legacy one so the adapter survives the Kleros upgrade without a redeploy.
    event DisputeRequest(IArbitratorV2 indexed _arbitrator, uint256 indexed _arbitratorDisputeID, uint256 _templateId);
    event Ruling(IArbitratorV2 indexed _arbitrator, uint256 indexed _disputeID, uint256 _ruling);

    function rule(uint256 _disputeID, uint256 _ruling) external;
}
