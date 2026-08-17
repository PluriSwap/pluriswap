// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PackageId} from "./PackageId.sol";
import {ICourt} from "./interfaces/ICourt.sol";
import {Settlement} from "../libraries/Settlement.sol";

contract ArbitrationMock is ICourt {
    using SafeERC20 for IERC20;

    error Unauthorized();
    error AlreadyOpen();
    error NotOpen();
    error InvalidRuling();
    error DeadlineNotDue();

    enum Ruling {
        None,
        HolderWin,
        ProviderWin,
        Stalemate
    }

    address public immutable tribunal;
    address public immutable feeToken;
    address public immutable operator;
    uint256 public immutable courtFee;
    uint256 public immutable duration;
    bytes32 public immutable packageId;

    mapping(bytes32 dealId => address controller) public controllerOf;
    mapping(bytes32 dealId => uint256 openedAt) public openedAt;
    mapping(bytes32 dealId => Ruling ruling) public rulingOf;

    constructor(address tribunal_, address feeToken_, uint256 courtFee_, uint256 duration_, address operator_) {
        tribunal = tribunal_;
        feeToken = feeToken_;
        courtFee = courtFee_;
        duration = duration_;
        operator = operator_;
        packageId = PackageId.arbitration(address(this), tribunal_, courtFee_);
    }

    function open(bytes32 dealId, address controller) external {
        if (msg.sender != controller) revert Unauthorized();
        _open(dealId, controller);
    }

    function openCourt(bytes32 dealId, address controller) external payable {
        if (operator == address(0) || msg.sender != operator) revert Unauthorized();
        _open(dealId, controller);
    }

    function readRuling(bytes32 dealId) external view returns (uint8) {
        return uint8(rulingOf[dealId]);
    }

    function _open(bytes32 dealId, address controller) internal {
        if (controllerOf[dealId] != address(0)) revert AlreadyOpen();
        Settlement.pullExact(feeToken, controller, courtFee);
        IERC20(feeToken).safeTransfer(tribunal, courtFee);
        controllerOf[dealId] = controller;
        openedAt[dealId] = block.timestamp;
    }

    function submitRuling(bytes32 dealId, Ruling ruling) external {
        if (controllerOf[dealId] == address(0)) revert NotOpen();
        if (rulingOf[dealId] != Ruling.None) revert AlreadyOpen();
        if (ruling == Ruling.None) revert InvalidRuling();
        rulingOf[dealId] = ruling;
    }

    function forceTimeout(bytes32 dealId) external {
        if (controllerOf[dealId] == address(0)) revert NotOpen();
        if (rulingOf[dealId] != Ruling.None) revert AlreadyOpen();
        if (block.timestamp < openedAt[dealId] + duration) revert DeadlineNotDue();
        rulingOf[dealId] = Ruling.Stalemate;
    }
}
