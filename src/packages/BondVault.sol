// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PackageId} from "../libraries/PackageId.sol";
import {IPassport} from "./interfaces/IPassport.sol";
import {IBondVault} from "./interfaces/IBondVault.sol";
import {Settlement} from "../libraries/Settlement.sol";

/// @notice Skin in the game, keyed by Passport subject and token. Locks 10% of principal per side per deal.
/// @dev Only the operator (the escrow) moves locks. A slash always pays the winning side's signing address:
///      the party that was wronged is the one compensated. Burns go to the sink and are reserved for a dispute
///      both sides let expire without resolving.
contract BondVault is IBondVault {
    using SafeERC20 for IERC20;

    error InsufficientAvailable();
    error Unauthorized();
    error LockExists();
    error LockTooSmall();
    error NoLock();
    error ZeroAddress();

    event Deposited(bytes32 indexed subject, address indexed token, address from, uint256 amount);
    event Withdrawn(bytes32 indexed subject, address indexed token, address to, uint256 amount);
    event Reserved(bytes32 indexed subject, address indexed token, bytes32 indexed dealId, uint256 amount);
    event Unlocked(bytes32 indexed subject, address indexed token, bytes32 indexed dealId, uint256 amount);
    event Slashed(
        bytes32 indexed loser, bytes32 indexed winner, address indexed token, bytes32 dealId, address to, uint256 amount
    );
    event Burned(
        bytes32 indexed subjectA, bytes32 indexed subjectB, address indexed token, bytes32 dealId, uint256 amount
    );

    address public immutable operator;
    address public immutable sink;
    IPassport public immutable passport;
    bytes32 public immutable packageId;

    mapping(bytes32 subject => mapping(address token => uint256 amount)) public deposited;
    mapping(bytes32 subject => mapping(address token => uint256 amount)) public locked;
    mapping(bytes32 subject => mapping(bytes32 dealId => uint256 amount)) public lockOf;

    constructor(address operator_, address sink_, IPassport passport_) {
        if (operator_ == address(0) || sink_ == address(0) || address(passport_) == address(0)) revert ZeroAddress();
        operator = operator_;
        sink = sink_;
        passport = passport_;
        packageId = PackageId.bonds(address(this), sink_);
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert Unauthorized();
        _;
    }

    function available(bytes32 subject, address token) public view returns (uint256) {
        return deposited[subject][token] - locked[subject][token];
    }

    function deposit(bytes32 subject, address token, uint256 amount) external {
        Settlement.pullExact(token, msg.sender, amount);
        deposited[subject][token] += amount;
        emit Deposited(subject, token, msg.sender, amount);
    }

    function withdraw(bytes32 subject, address token, uint256 amount) external {
        if (passport.identify(msg.sender) != subject) revert Unauthorized();
        if (amount > available(subject, token)) revert InsufficientAvailable();
        deposited[subject][token] -= amount;
        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(subject, token, msg.sender, amount);
    }

    function reserve(bytes32 subject, address token, bytes32 dealId, uint256 principal) external onlyOperator {
        if (principal == 0) revert LockTooSmall();
        if (lockOf[subject][dealId] != 0) revert LockExists();
        uint256 lockAmount = (principal + 9) / 10;
        if (lockAmount * 10 < principal) revert LockTooSmall();
        if (lockAmount > available(subject, token)) revert InsufficientAvailable();
        lockOf[subject][dealId] = lockAmount;
        locked[subject][token] += lockAmount;
        emit Reserved(subject, token, dealId, lockAmount);
    }

    function unlock(bytes32 subject, address token, bytes32 dealId) external onlyOperator {
        uint256 amount = _takeLock(subject, token, dealId);
        emit Unlocked(subject, token, dealId, amount);
    }

    /// @dev The loser's lock goes to `to`, the winner's signing address. The winner's own lock is released.
    function slash(bytes32 loser, bytes32 winner, address token, bytes32 dealId, address to) external onlyOperator {
        uint256 loserLock = _takeLock(loser, token, dealId);
        uint256 winnerLock = _takeLock(winner, token, dealId);
        deposited[loser][token] -= loserLock;
        IERC20(token).safeTransfer(to, loserLock);
        emit Unlocked(winner, token, dealId, winnerLock);
        emit Slashed(loser, winner, token, dealId, to, loserLock);
    }

    function burn(bytes32 subjectA, bytes32 subjectB, address token, bytes32 dealId) external onlyOperator {
        uint256 a = _takeLock(subjectA, token, dealId);
        uint256 b = _takeLock(subjectB, token, dealId);
        deposited[subjectA][token] -= a;
        deposited[subjectB][token] -= b;
        IERC20(token).safeTransfer(sink, a + b);
        emit Burned(subjectA, subjectB, token, dealId, a + b);
    }

    function _takeLock(bytes32 subject, address token, bytes32 dealId) internal returns (uint256 amount) {
        amount = lockOf[subject][dealId];
        if (amount == 0) revert NoLock();
        delete lockOf[subject][dealId];
        locked[subject][token] -= amount;
    }
}
