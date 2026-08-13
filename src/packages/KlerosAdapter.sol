// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IArbitrableV2, IArbitratorV2} from "./interfaces/IKlerosV2.sol";
import {PackageId} from "./PackageId.sol";

/// @dev Isolated Kleros V2 adapter. Does not move escrow principal.
///      Sepolia KlerosCore (proxy): 0xE8442307d36e9bf6aB27F1A009F95CE8E11C3479
///      Implements `IArbitrableV2.rule` without inheriting the interface: the `Ruling` event
///      name collides with the kernel ternary enum.
contract KlerosAdapter {
    error Unauthorized();
    error AlreadyOpen();
    error NotOpen();
    error AlreadyRuled();
    error InvalidRuling();
    error InsufficientFee();

    uint256 public constant CHOICES = 2;

    enum Ruling {
        None,
        HolderWin,
        ProviderWin,
        Stalemate
    }

    IArbitratorV2 public immutable arbitrator;
    uint256 public immutable templateId;
    bytes32 public immutable packageId;
    bytes public extraData;
    string public templateUri;

    mapping(bytes32 dealId => bool) public opened;
    mapping(bytes32 dealId => uint256) public disputeOf;
    mapping(uint256 disputeId => bytes32) public dealOf;
    mapping(uint256 disputeId => bool) public known;
    mapping(bytes32 dealId => Ruling) public rulingOf;

    constructor(address arbitrator_, bytes memory extraData_, uint256 templateId_, string memory templateUri_) {
        arbitrator = IArbitratorV2(arbitrator_);
        extraData = extraData_;
        templateId = templateId_;
        templateUri = templateUri_;
        packageId = PackageId.kleros(address(this), arbitrator_, extraData_);
    }

    function openCourt(bytes32 dealId, address controller) external payable {
        if (msg.sender != controller) revert Unauthorized();
        if (opened[dealId]) revert AlreadyOpen();
        uint256 cost = arbitrator.arbitrationCost(extraData);
        if (msg.value != cost) revert InsufficientFee();
        uint256 disputeId = arbitrator.createDispute{value: cost}(CHOICES, extraData);
        opened[dealId] = true;
        known[disputeId] = true;
        disputeOf[dealId] = disputeId;
        dealOf[disputeId] = dealId;
        emit IArbitrableV2.DisputeRequest(arbitrator, disputeId, uint256(dealId), templateId, templateUri);
    }

    function rule(uint256 disputeId, uint256 klerosRuling) external {
        if (msg.sender != address(arbitrator)) revert Unauthorized();
        if (!known[disputeId]) revert NotOpen();
        bytes32 dealId = dealOf[disputeId];
        if (rulingOf[dealId] != Ruling.None) revert AlreadyRuled();
        rulingOf[dealId] = _map(klerosRuling);
        emit IArbitrableV2.Ruling(arbitrator, disputeId, klerosRuling);
    }

    function readRuling(bytes32 dealId) external view returns (Ruling) {
        return rulingOf[dealId];
    }

    function _map(uint256 klerosRuling) internal pure returns (Ruling) {
        if (klerosRuling == 0) return Ruling.Stalemate;
        if (klerosRuling == 1) return Ruling.HolderWin;
        if (klerosRuling == 2) return Ruling.ProviderWin;
        revert InvalidRuling();
    }
}
