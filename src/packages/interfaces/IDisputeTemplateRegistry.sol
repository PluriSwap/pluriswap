// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Kleros V2 DisputeTemplateRegistry. Permissionless `setDisputeTemplate`.
interface IDisputeTemplateRegistry {
    function setDisputeTemplate(
        string calldata templateTag,
        string calldata templateData,
        string calldata templateDataMappings
    ) external returns (uint256 templateId);
}
