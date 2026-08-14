// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PackageId} from "./PackageId.sol";
import {IPassport} from "./interfaces/IPassport.sol";
import {Settlement} from "../libraries/Settlement.sol";

contract BondVault {
    using SafeERC20 for IERC20;

    error InsufficientAvailable();
    error Unauthorized();
    error LockExists();
    error LockTooSmall();
    error ControllerIsNotWinner();
    error NoLock();

    address public immutable operator;
    address public immutable sink;
    IPassport public immutable passport;
    bytes32 public immutable packageId;

    mapping(bytes32 subject => mapping(address token => uint256 amount)) public deposited;
    mapping(bytes32 subject => mapping(address token => uint256 amount)) public locked;
    mapping(bytes32 subject => mapping(bytes32 dealId => uint256 amount)) public lockOf;

    constructor(address operator_, address sink_, IPassport passport_) {
        operator = operator_;
        sink = sink_;
        passport = passport_;
        packageId = PackageId.bonds(address(this), sink_);
    }

    function available(bytes32 subject, address token) public view returns (uint256) {
        return deposited[subject][token] - locked[subject][token];
    }

    function deposit(bytes32 subject, address token, uint256 amount) external {
        Settlement.pullExact(token, msg.sender, amount);
        deposited[subject][token] += amount;
    }

    function withdraw(bytes32 subject, address token, uint256 amount) external {
        if (passport.identify(msg.sender) != subject) revert Unauthorized();
        if (amount > available(subject, token)) revert InsufficientAvailable();
        deposited[subject][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function reserve(bytes32 subject, address token, bytes32 dealId, uint256 principal) external {
        if (msg.sender != operator) revert Unauthorized();
        if (principal == 0) revert LockTooSmall();
        if (lockOf[subject][dealId] != 0) revert LockExists();
        uint256 lockAmount = (principal + 9) / 10;
        if (lockAmount * 10 < principal) revert LockTooSmall();
        if (lockAmount > available(subject, token)) revert InsufficientAvailable();
        lockOf[subject][dealId] = lockAmount;
        locked[subject][token] += lockAmount;
    }

    function unlock(bytes32 subject, address token, bytes32 dealId) external {
        if (msg.sender != operator) revert Unauthorized();
        _takeLock(subject, token, dealId);
    }

    function slash(
        bytes32 loser,
        bytes32 winner,
        address token,
        bytes32 dealId,
        address winnerSigning,
        address controller
    ) external {
        if (msg.sender != operator) revert Unauthorized();
        if (winnerSigning == controller) revert ControllerIsNotWinner();
        uint256 loserLock = _takeLock(loser, token, dealId);
        _takeLock(winner, token, dealId);
        deposited[loser][token] -= loserLock;
        IERC20(token).safeTransfer(winnerSigning, loserLock);
    }

    function burn(bytes32 subjectA, bytes32 subjectB, address token, bytes32 dealId) external {
        if (msg.sender != operator) revert Unauthorized();
        uint256 a = _takeLock(subjectA, token, dealId);
        uint256 b = _takeLock(subjectB, token, dealId);
        deposited[subjectA][token] -= a;
        deposited[subjectB][token] -= b;
        IERC20(token).safeTransfer(sink, a + b);
    }

    function _takeLock(bytes32 subject, address token, bytes32 dealId) internal returns (uint256 amount) {
        amount = lockOf[subject][dealId];
        if (amount == 0) revert NoLock();
        delete lockOf[subject][dealId];
        locked[subject][token] -= amount;
    }
}
