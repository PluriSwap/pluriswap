// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IDisputeTemplateRegistry} from "../packages/interfaces/IDisputeTemplateRegistry.sol";

contract MockTemplateRegistry is IDisputeTemplateRegistry {
    uint256 public nextId = 1;
    string public lastTag;
    string public lastData;
    string public lastMappings;

    function setDisputeTemplate(
        string calldata templateTag,
        string calldata templateData,
        string calldata templateDataMappings
    ) external returns (uint256 templateId) {
        lastTag = templateTag;
        lastData = templateData;
        lastMappings = templateDataMappings;
        templateId = nextId;
        nextId = nextId + 1;
    }
}
