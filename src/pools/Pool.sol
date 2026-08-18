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
    function settlementOf(bytes32 dealId) external view returns (Status status, uint256 holderAmt, uint256 providerAmt);
}

contract Pool {
    using SafeERC20 for IERC20;

    bytes4 internal constant MAGIC = 0x1626ba7e;
    uint256 internal constant MIN_FIRST = 1e6;
    uint256 internal constant BPS_DENOM = 10_000;

    enum Life {
        NONE,
        ACTIVE,
        DEFICIENT,
        RUNOFF,
        WINDING_DOWN,
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
    error Duplicate();
    error FirstDepositTooSmall();
    error InsufficientShares();
    error RedeemExceedsIdle();
    error BadFee();
    error IsSponsor();
    error EmptySponsors();
    error EmptyDepositors();
    error OpenHasDepositors();
    error ZeroNav();

    struct Auth {
        bytes32 digest;
        DealTerms terms;
        uint256 deadline;
        address controller;
        uint256 fee;
        bool exists;
        bool unlocked;
        bool reconciled;
    }

    bool public initialized;
    address public token;
    address public escrow;
    Life public life;
    bool public openDeposits;
    uint16 public controllerFeeBps;
    uint256 public idle;
    uint256 public locked;
    uint256 public consumed;
    uint256 public credits;
    uint256 public totalShares;

    mapping(address account => bool) public sponsors;
    mapping(address account => bool) public designated;
    mapping(address account => bool) public allowedDepositor;
    mapping(address account => uint256) public sharesOf;
    mapping(uint256 nonce => Auth) public auths;
    mapping(bytes32 digest => uint256 nonce) public nonceOf;

    Settlement.Store internal payables;

    constructor() {
        initialized = true;
    }

    function initialize(
        address[] calldata sponsors_,
        address token_,
        address escrow_,
        address[] calldata controllers_,
        bool openDeposits_,
        address[] calldata depositors_,
        uint16 controllerFeeBps_
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (token_ == address(0) || escrow_ == address(0)) revert BadTerms();
        if (sponsors_.length == 0) revert EmptySponsors();
        if (controllerFeeBps_ > BPS_DENOM) revert BadFee();
        if (openDeposits_) {
            if (depositors_.length != 0) revert OpenHasDepositors();
        } else if (depositors_.length == 0) {
            revert EmptyDepositors();
        }
        _unique(sponsors_);
        if (!openDeposits_) _unique(depositors_);

        initialized = true;
        token = token_;
        escrow = escrow_;
        openDeposits = openDeposits_;
        controllerFeeBps = controllerFeeBps_;
        life = Life.ACTIVE;

        for (uint256 i; i < sponsors_.length; i++) {
            sponsors[sponsors_[i]] = true;
        }
        for (uint256 i; i < controllers_.length; i++) {
            address c = controllers_[i];
            if (c == address(0) || sponsors[c]) revert BadTerms();
            designated[c] = true;
        }
        if (!openDeposits_) {
            for (uint256 i; i < depositors_.length; i++) {
                allowedDepositor[depositors_[i]] = true;
            }
        }
    }

    function isAgent(address account) public view returns (bool) {
        return sponsors[account] || designated[account];
    }

    function nav() public view returns (uint256) {
        return idle + credits + locked;
    }

    function controllerCredit(address account) external view returns (uint256) {
        return Settlement.creditOf(payables, token, account);
    }

    function setController(address controller, bool allowed) external {
        if (!sponsors[msg.sender]) revert Unauthorized();
        if (sponsors[controller] || controller == address(0)) revert IsSponsor();
        designated[controller] = allowed;
    }

    function setControllerFeeBps(uint16 bps) external {
        if (!sponsors[msg.sender]) revert Unauthorized();
        if (bps > BPS_DENOM) revert BadFee();
        controllerFeeBps = bps;
    }

    function deposit(uint256 amount) external {
        if (life != Life.ACTIVE && life != Life.DEFICIENT) revert WrongLife();
        if (!openDeposits && !allowedDepositor[msg.sender]) revert Unauthorized();
        if (amount == 0) revert BadTerms();

        uint256 onHand = IERC20(token).balanceOf(address(this)) + IEscrowView(escrow).creditOf(token, address(this));
        uint256 accounted = idle + credits;
        uint256 hole = onHand < accounted ? accounted - onHand : 0;
        uint256 invest = amount > hole ? amount - hole : 0;

        uint256 minted;
        if (invest != 0) {
            if (totalShares == 0) {
                if (invest < MIN_FIRST) revert FirstDepositTooSmall();
                minted = invest;
            } else {
                uint256 n = nav();
                if (n == 0) revert ZeroNav();
                minted = invest * totalShares / n;
                if (minted == 0) revert FirstDepositTooSmall();
            }
        }

        Settlement.pullExact(token, msg.sender, amount);
        idle += invest;
        sharesOf[msg.sender] += minted;
        totalShares += minted;
        _sync();
    }

    function redeem(uint256 sharesIn) external {
        if (life != Life.ACTIVE && life != Life.RUNOFF && life != Life.WINDING_DOWN) revert WrongLife();
        if (sharesIn == 0 || sharesIn > sharesOf[msg.sender]) revert InsufficientShares();
        uint256 n = nav();
        uint256 assetsOut = sharesIn * n / totalShares;
        if (assetsOut > idle) revert RedeemExceedsIdle();
        if (assetsOut == 0) revert InsufficientShares();

        sharesOf[msg.sender] -= sharesIn;
        totalShares -= sharesIn;
        idle -= assetsOut;
        IERC20(token).safeTransfer(msg.sender, assetsOut);
        _maybeClose();
        _sync();
    }

    function withdrawCredit() external {
        Settlement.withdraw(payables, token, msg.sender);
    }

    function sync() external {
        _sync();
    }

    function startRunoff() external {
        if (!sponsors[msg.sender]) revert Unauthorized();
        if (life != Life.ACTIVE && life != Life.DEFICIENT) revert WrongLife();
        life = Life.RUNOFF;
    }

    function endRunoff() external {
        if (!sponsors[msg.sender]) revert Unauthorized();
        if (life != Life.RUNOFF) revert WrongLife();
        if (locked != 0) revert StillLive();
        life = totalShares == 0 ? Life.CLOSED : Life.ACTIVE;
    }

    function windDown() external {
        if (!sponsors[msg.sender]) revert Unauthorized();
        if (life != Life.ACTIVE && life != Life.DEFICIENT && life != Life.RUNOFF) revert WrongLife();
        life = Life.WINDING_DOWN;
        _maybeClose();
    }

    function authorize(HolderAuthorization calldata ha) external {
        _sync();
        if (life != Life.ACTIVE) revert WrongLife();
        DealTerms calldata t = ha.terms;
        if (t.holder != address(this) || t.token != token || t.principal == 0) revert BadTerms();
        if (!isAgent(t.controller)) revert Unauthorized();
        if (msg.sender != t.controller && !sponsors[msg.sender]) revert Unauthorized();
        if (block.timestamp > ha.deadline) revert DeadlineActive();
        if (IEscrowView(escrow).used(address(this), ha.nonce)) revert NonceConsumed();
        Auth storage a = auths[ha.nonce];
        if (a.exists && !a.unlocked && !a.reconciled) revert AuthExists();

        uint256 fee = t.principal * uint256(controllerFeeBps) / BPS_DENOM;
        if (idle < t.principal + fee) revert InsufficientIdle();

        bytes32 digest = _digest(ha);
        idle -= t.principal + fee;
        locked += t.principal + fee;
        a.digest = digest;
        a.terms = t;
        a.deadline = ha.deadline;
        a.controller = t.controller;
        a.fee = fee;
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
        uint256 amt = a.terms.principal + a.fee;
        locked -= amt;
        idle += amt;
        _maybeClose();
        _sync();
    }

    function reconcile(uint256 nonce, uint256 providerNonce, uint256 controllerNonce) external {
        Auth storage a = auths[nonce];
        if (!a.exists || a.unlocked || a.reconciled) revert NoAuth();
        if (!IEscrowView(escrow).used(address(this), nonce)) revert StillLive();
        bytes32 id =
            Consent.dealId(IEscrowView(escrow).domainSeparator(), a.terms, nonce, providerNonce, controllerNonce);
        (Status st, uint256 returned,) = IEscrowView(escrow).settlementOf(id);
        if (!_terminal(st)) revert StillLive();
        if (returned > a.terms.principal) revert BadReturn();
        uint256 onHand = _onHand();
        uint256 accounted = idle + credits;
        if (onHand < accounted + returned) revert BadReturn();

        a.reconciled = true;
        delete nonceOf[a.digest];
        locked -= a.terms.principal + a.fee;
        consumed += a.terms.principal - returned;
        idle += returned;
        if (returned < a.terms.principal && a.fee != 0) {
            consumed += a.fee;
            Settlement.creditThenTryPush(payables, token, a.controller, a.fee);
        } else {
            idle += a.fee;
        }
        _maybeClose();
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
        if (life != Life.ACTIVE && life != Life.DEFICIENT) return;
        if (_onHand() < idle + credits) life = Life.DEFICIENT;
        else if (life == Life.DEFICIENT) life = Life.ACTIVE;
    }

    function _maybeClose() internal {
        if (life != Life.RUNOFF && life != Life.WINDING_DOWN) return;
        if (locked == 0 && totalShares == 0) life = Life.CLOSED;
    }

    function _terminal(Status s) internal pure returns (bool) {
        return s == Status.RELEASED || s == Status.RESOLVED_SPLIT || s == Status.STALEMATE || s == Status.CANCELLED
            || s == Status.RESOLVED_BY_ARBITRATION;
    }

    function _unique(address[] calldata xs) internal pure {
        for (uint256 i; i < xs.length; i++) {
            if (xs[i] == address(0)) revert BadTerms();
            for (uint256 j; j < i; j++) {
                if (xs[i] == xs[j]) revert Duplicate();
            }
        }
    }
}
