// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {DealTerms, HolderAuthorization, Status} from "../libraries/Types.sol";
import {Consent} from "../libraries/Consent.sol";
import {Settlement} from "../libraries/Settlement.sol";

interface IEscrowView {
    function domainSeparator() external view returns (bytes32);
    function used(address signer, uint256 nonce) external view returns (bool);
    function status(bytes32 dealId) external view returns (Status);
    function creditOf(address token, address beneficiary) external view returns (uint256);
}

contract Pool {
    using SafeERC20 for IERC20;

    bytes4 internal constant MAGIC = 0x1626ba7e;

    enum Life {
        NONE,
        ACTIVE,
        DEFICIENT,
        CLOSING,
        CLOSED
    }

    error AlreadyInitialized();
    error Unauthorized();
    error WrongLife();
    error BadTerms();
    error InsufficientIdle();
    error AuthExists();
    error NoAuth();
    error StillLive();
    error NonceConsumed();
    error DeadlineActive();
    error BadReturn();

    struct Auth {
        bytes32 digest;
        DealTerms terms;
        uint256 deadline;
        address controller;
        bool exists;
        bool unlocked;
        bool reconciled;
    }

    bool public initialized;
    address public owner;
    address public token;
    address public escrow;
    Life public life;
    uint256 public idle;
    uint256 public locked;
    uint256 public consumed;
    uint256 public credits;

    mapping(address controller => bool allowed) public controllers;
    mapping(uint256 nonce => Auth) public auths;
    mapping(bytes32 digest => uint256 nonce) public nonceOf;

    constructor() {
        initialized = true;
    }

    function initialize(address owner_, address token_, address escrow_, address[] calldata controllers_) external {
        if (initialized) revert AlreadyInitialized();
        if (owner_ == address(0) || token_ == address(0) || escrow_ == address(0)) revert BadTerms();
        initialized = true;
        owner = owner_;
        token = token_;
        escrow = escrow_;
        life = Life.ACTIVE;
        for (uint256 i; i < controllers_.length; i++) {
            controllers[controllers_[i]] = true;
        }
    }

    function setController(address controller, bool allowed) external {
        if (msg.sender != owner) revert Unauthorized();
        controllers[controller] = allowed;
    }

    function deposit(uint256 amount) external {
        if (msg.sender != owner) revert Unauthorized();
        if (life == Life.CLOSED) revert WrongLife();
        Settlement.pullExact(token, msg.sender, amount);
        idle += amount;
        _sync();
    }

    function withdraw(uint256 amount) external {
        if (msg.sender != owner) revert Unauthorized();
        if (amount > idle) revert InsufficientIdle();
        idle -= amount;
        IERC20(token).safeTransfer(owner, amount);
        _sync();
    }

    function sync() external {
        _sync();
    }

    function close() external {
        if (msg.sender != owner) revert Unauthorized();
        if (life != Life.ACTIVE && life != Life.DEFICIENT) revert WrongLife();
        life = Life.CLOSING;
    }

    function finalize() external {
        if (msg.sender != owner) revert Unauthorized();
        if (life != Life.CLOSING) revert WrongLife();
        if (locked != 0) revert StillLive();
        life = Life.CLOSED;
    }

    function authorize(HolderAuthorization calldata ha) external {
        _sync();
        if (life != Life.ACTIVE) revert WrongLife();
        DealTerms calldata t = ha.terms;
        if (t.holder != address(this) || t.token != token || t.principal == 0) revert BadTerms();
        if (!controllers[t.controller]) revert Unauthorized();
        if (msg.sender != t.controller && msg.sender != owner) revert Unauthorized();
        if (block.timestamp > ha.deadline) revert DeadlineActive();
        if (IEscrowView(escrow).used(address(this), ha.nonce)) revert NonceConsumed();
        Auth storage a = auths[ha.nonce];
        if (a.exists && !a.unlocked && !a.reconciled) revert AuthExists();
        if (idle < t.principal) revert InsufficientIdle();

        bytes32 digest = _digest(ha);
        idle -= t.principal;
        locked += t.principal;
        a.digest = digest;
        a.terms = t;
        a.deadline = ha.deadline;
        a.controller = t.controller;
        a.exists = true;
        a.unlocked = false;
        a.reconciled = false;
        nonceOf[digest] = ha.nonce;
        IERC20(token).forceApprove(escrow, type(uint256).max);
    }

    function isValidSignature(bytes32 digest, bytes memory) external view returns (bytes4) {
        uint256 nonce = nonceOf[digest];
        Auth storage a = auths[nonce];
        if (!a.exists || a.unlocked || a.reconciled || a.digest != digest) return bytes4(0);
        if (life == Life.CLOSED) return bytes4(0);
        return MAGIC;
    }

    function unlock(uint256 nonce) external {
        Auth storage a = auths[nonce];
        if (!a.exists || a.unlocked || a.reconciled) revert NoAuth();
        if (IEscrowView(escrow).used(address(this), nonce)) revert NonceConsumed();
        if (block.timestamp <= a.deadline) revert DeadlineActive();
        a.unlocked = true;
        delete nonceOf[a.digest];
        locked -= a.terms.principal;
        idle += a.terms.principal;
        _sync();
    }

    function reconcile(uint256 nonce, uint256 providerNonce, uint256 controllerNonce, uint256 returned) external {
        Auth storage a = auths[nonce];
        if (!a.exists || a.unlocked || a.reconciled) revert NoAuth();
        if (msg.sender != owner && msg.sender != a.controller) revert Unauthorized();
        if (!IEscrowView(escrow).used(address(this), nonce)) revert StillLive();
        bytes32 id =
            Consent.dealId(IEscrowView(escrow).domainSeparator(), a.terms, nonce, providerNonce, controllerNonce);
        if (!_terminal(IEscrowView(escrow).status(id))) revert StillLive();
        if (returned > a.terms.principal) revert BadReturn();
        uint256 onHand = _onHand();
        uint256 accounted = idle + credits;
        if (onHand < accounted + returned) revert BadReturn();

        a.reconciled = true;
        delete nonceOf[a.digest];
        locked -= a.terms.principal;
        consumed += a.terms.principal - returned;
        idle += returned;
        _sync();
    }

    function _digest(HolderAuthorization calldata ha) internal view returns (bytes32) {
        return
            MessageHashUtils.toTypedDataHash(IEscrowView(escrow).domainSeparator(), Consent.hashHolderAuthorization(ha));
    }

    function _onHand() internal view returns (uint256) {
        return IERC20(token).balanceOf(address(this)) + IEscrowView(escrow).creditOf(token, address(this));
    }

    function _sync() internal {
        if (life == Life.CLOSING || life == Life.CLOSED) return;
        if (_onHand() < idle + credits) life = Life.DEFICIENT;
        else if (life == Life.DEFICIENT) life = Life.ACTIVE;
    }

    function _terminal(Status s) internal pure returns (bool) {
        return s == Status.RELEASED || s == Status.RESOLVED_SPLIT || s == Status.STALEMATE || s == Status.CANCELLED
            || s == Status.RESOLVED_BY_ARBITRATION;
    }
}
