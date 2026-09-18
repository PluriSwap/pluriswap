// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {DealTerms, HolderAuthorization, PackageMods, Status} from "../libraries/Types.sol";
import {Consent} from "../libraries/Consent.sol";
import {Settlement} from "../libraries/Settlement.sol";
import {IEscrow} from "../interfaces/IEscrow.sol";
import {IReputation} from "../packages/interfaces/IReputation.sol";
import {PackageId} from "../libraries/PackageId.sol";
import {Packages} from "../libraries/Packages.sol";

contract Pool is ReentrancyGuardTransient {
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
        uint256 activationFee;
        uint256 contestReserve;
        bool exists;
        bool unlocked;
        bool reconciled;
        bool activated;
        bool recognized;
    }

    bool public initialized;
    address public token;
    address public escrow;
    Life public life;
    bool public openDeposits;
    uint16 public controllerFeeBps;
    /// @dev When true, `authorize` reserves the contest-open due and `reconcile` pays it to the Controller
    ///      if they opened a fight (they already paid the kernel from their wallet). When false, the
    ///      Controller eats that cost — their skin in the game.
    bool public reimburseContest;
    /// @dev When true, the reserved Controller fee is paid even if the Holder got the whole principal back.
    ///      When false (default), a full refund returns the reserve to idle: no trade, no desk cut.
    bool public payControllerOnFullReturn;
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
    mapping(uint256 nonce => uint256 indexPlusOne) internal liveAt;
    uint256[] internal liveNonces;

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

    /// @dev Holder-gross already terminal sits in `credits` (or is previewed here via `dealOf`).
    function nav() public view returns (uint256) {
        (uint256 idle_, uint256 credits_, uint256 locked_) = _books();
        return idle_ + credits_ + locked_;
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

    function setReimburseContest(bool on) external {
        if (!sponsors[msg.sender]) revert Unauthorized();
        reimburseContest = on;
    }

    function setPayControllerOnFullReturn(bool on) external {
        if (!sponsors[msg.sender]) revert Unauthorized();
        payControllerOnFullReturn = on;
    }

    function deposit(uint256 amount) external nonReentrant {
        _recognizeLive();
        if (life != Life.ACTIVE && life != Life.DEFICIENT) revert WrongLife();
        if (!openDeposits && !allowedDepositor[msg.sender]) revert Unauthorized();
        if (amount == 0) revert BadTerms();

        uint256 onHand = IERC20(token).balanceOf(address(this)) + IEscrow(escrow).creditOf(token, address(this));
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

    function redeem(uint256 sharesIn) external nonReentrant {
        _recognizeLive();
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

    function withdrawCredit() external nonReentrant {
        Settlement.withdraw(payables, token, msg.sender);
    }

    function sync() external nonReentrant {
        _recognizeLive();
        _sync();
    }

    function startRunoff() external {
        if (!sponsors[msg.sender]) revert Unauthorized();
        if (life != Life.ACTIVE && life != Life.DEFICIENT) revert WrongLife();
        life = Life.RUNOFF;
    }

    function endRunoff() external nonReentrant {
        if (!sponsors[msg.sender]) revert Unauthorized();
        if (life != Life.RUNOFF) revert WrongLife();
        _recognizeLive();
        if (locked != 0) revert StillLive();
        life = totalShares == 0 ? Life.CLOSED : Life.ACTIVE;
    }

    function windDown() external {
        if (!sponsors[msg.sender]) revert Unauthorized();
        if (life != Life.ACTIVE && life != Life.DEFICIENT && life != Life.RUNOFF) revert WrongLife();
        life = Life.WINDING_DOWN;
        _maybeClose();
    }

    /// @dev Reserve pool capital for a deal the Controller is about to activate. `mods` must name every module
    ///      the signed `ha.terms.packageIds` refers to, exactly as `Escrow.activate` will require: the pool
    ///      runs the same `Packages.resolve`, so a deal that carries REPUTATION cannot be authorized as if it
    ///      did not. That matters because `Packages.engage` pulls the activation fee from the Holder -- this
    ///      pool -- on top of the principal, and `_refreshApprove` sizes the escrow allowance as the exact sum
    ///      of `principal + activationFee` over live auths. An auth that reserved no fee either cannot
    ///      activate, or spends another auth's share of that aggregate allowance and leaves the vault short.
    ///      Resolving here turns that from an accounting repair into an impossible state.
    ///      Core-only deals pass an all-zero `PackageMods`, which `resolve` accepts against empty `packageIds`.
    function authorize(HolderAuthorization calldata ha, PackageMods calldata mods) external nonReentrant {
        _authorize(ha, mods);
    }

    function isValidSignature(bytes32 digest, bytes memory) external view returns (bytes4) {
        uint256 nonce = nonceOf[digest];
        Auth storage a = auths[nonce];
        if (!a.exists || a.unlocked || a.reconciled || a.digest != digest) return bytes4(0);
        // POOLS.md: only ACTIVE validates digests; kick cuts pending auths (future-only vs live deals).
        if (life != Life.ACTIVE) return bytes4(0);
        if (!isAgent(a.controller)) return bytes4(0);
        return MAGIC;
    }

    function unlock(uint256 nonce) external nonReentrant {
        _recognizeLive();
        Auth storage a = auths[nonce];
        if (!a.exists || a.unlocked || a.reconciled) revert NoAuth();
        if (IEscrow(escrow).used(address(this), nonce)) revert NonceConsumed();
        if (block.timestamp <= a.deadline) revert DeadlineActive();
        a.unlocked = true;
        delete nonceOf[a.digest];
        uint256 amt = a.terms.principal + a.fee + a.activationFee + a.contestReserve;
        locked -= amt;
        idle += amt;
        _popLive(nonce);
        _refreshApprove();
        _maybeClose();
        _sync();
    }

    function reconcile(uint256 nonce, uint256 providerNonce, uint256 controllerNonce) external nonReentrant {
        _recognizeLive();
        Auth storage a = auths[nonce];
        if (!a.exists || a.unlocked || a.reconciled) revert NoAuth();
        if (!IEscrow(escrow).used(address(this), nonce)) revert StillLive();
        bytes32 id = Consent.dealId(IEscrow(escrow).domainSeparator(), a.terms, nonce, providerNonce, controllerNonce);
        (Status st, uint256 returned,) = IEscrow(escrow).settlementOf(id);
        if (!_terminal(st)) revert StillLive();
        if (returned > a.terms.principal) revert BadReturn();
        if (!a.recognized) _applyTerminal(a, returned);

        uint256 onHand = _onHand();
        if (onHand < idle + credits) revert BadReturn();

        a.reconciled = true;
        delete nonceOf[a.digest];
        credits -= returned;
        locked -= a.fee;
        consumed += a.terms.principal - returned;
        idle += returned;
        bool feeEarned = a.fee != 0 && (returned < a.terms.principal || payControllerOnFullReturn);
        if (feeEarned) {
            consumed += a.fee;
            Settlement.creditThenTryPush(payables, token, a.controller, a.fee);
        } else {
            idle += a.fee;
        }
        if (a.contestReserve != 0) {
            locked -= a.contestReserve;
            if (IEscrow(escrow).contestPaid(id)) {
                consumed += a.contestReserve;
                Settlement.creditThenTryPush(payables, token, a.controller, a.contestReserve);
            } else {
                idle += a.contestReserve;
            }
        }
        _popLive(nonce);
        _refreshApprove();
        _maybeClose();
        _sync();
    }

    function _authorize(HolderAuthorization calldata ha, PackageMods calldata mods) internal {
        _recognizeLive();
        if (life != Life.ACTIVE) revert WrongLife();
        DealTerms calldata t = ha.terms;
        if (t.holder != address(this) || t.token != token || t.principal == 0) revert BadTerms();
        if (!isAgent(t.controller)) revert Unauthorized();
        if (msg.sender != t.controller && !sponsors[msg.sender]) revert Unauthorized();
        if (block.timestamp > ha.deadline) revert DeadlineActive();
        if (IEscrow(escrow).used(address(this), ha.nonce)) revert NonceConsumed();
        Auth storage a = auths[ha.nonce];
        if (a.exists && !a.unlocked && !a.reconciled) revert AuthExists();

        // The kernel's own resolution, run before anything is reserved. Every signed id must be matched to a
        // named module, so `mods.reputation == address(0)` on a deal that carries REPUTATION reverts here
        // instead of becoming an unpriced reservation. Fail closed while nothing has moved yet.
        Packages.resolve(t.packageIds, mods);

        uint256 fee = t.principal * uint256(controllerFeeBps) / BPS_DENOM;
        uint256 actFee = mods.reputation == address(0) ? 0 : _activationFee(t, mods.reputation);
        uint256 contest = (reimburseContest && mods.reputation != address(0)) ? _contestDue(t, mods.reputation) : 0;
        if (idle < t.principal + fee + actFee + contest) revert InsufficientIdle();

        bytes32 digest = _digest(ha);
        idle -= t.principal + fee + actFee + contest;
        locked += t.principal + fee + actFee + contest;
        a.digest = digest;
        a.terms = t;
        a.deadline = ha.deadline;
        a.controller = t.controller;
        a.fee = fee;
        a.activationFee = actFee;
        a.contestReserve = contest;
        a.exists = true;
        a.unlocked = false;
        a.reconciled = false;
        a.activated = false;
        a.recognized = false;
        nonceOf[digest] = ha.nonce;
        _pushLive(ha.nonce);
        _refreshApprove();
    }

    /// @dev The activation fee to reserve. `Packages.resolve` has already proved this module hashes to a
    ///      signed id, so recomputing it here is a second line of defence rather than the first: it catches a
    ///      module that answers `feeRecipient`/`activationFee`/`completionFee` differently between the two
    ///      reads inside this same transaction. PERM-03 lets anyone publish a module, so that is not
    ///      hypothetical. `BadTerms` here means the reservation would not match what the kernel will pull.
    function _activationFee(DealTerms calldata t, address reputation) internal view returns (uint256) {
        if (reputation == address(0)) return 0;
        IReputation r = IReputation(reputation);
        bytes32 id = PackageId.reputation(
            reputation, r.feeRecipient(), r.activationFee(), r.completionFee(), r.contestBps(), r.contestFloor()
        );
        bytes32[] calldata ids = t.packageIds;
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == id) return r.activationFee();
        }
        revert BadTerms();
    }

    function _contestDue(DealTerms calldata t, address reputation) internal view returns (uint256) {
        if (reputation == address(0)) return 0;
        IReputation r = IReputation(reputation);
        bytes32 id = PackageId.reputation(
            reputation, r.feeRecipient(), r.activationFee(), r.completionFee(), r.contestBps(), r.contestFloor()
        );
        bytes32[] calldata ids = t.packageIds;
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == id) return Packages.contestDue(t.principal, r.contestBps(), r.contestFloor());
        }
        revert BadTerms();
    }

    function _digest(HolderAuthorization calldata ha) internal view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(IEscrow(escrow).domainSeparator(), Consent.hashHolderAuthorization(ha));
    }

    function _onHand() internal view returns (uint256) {
        return IERC20(token).balanceOf(address(this)) + IEscrow(escrow).creditOf(token, address(this));
    }

    function _books() internal view returns (uint256 idle_, uint256 credits_, uint256 locked_) {
        idle_ = idle;
        credits_ = credits;
        locked_ = locked;
        IEscrow kernel = IEscrow(escrow);
        uint256 n = liveNonces.length;
        for (uint256 i; i < n; i++) {
            uint256 nonce = liveNonces[i];
            Auth storage a = auths[nonce];
            if (a.unlocked || a.reconciled) continue;
            bytes32 id = kernel.dealOf(address(this), nonce);
            if (id == 0) continue;
            if (!a.activated) locked_ -= a.activationFee;
            if (a.recognized) continue;
            (Status st, uint256 returned,) = kernel.settlementOf(id);
            if (!_terminal(st)) continue;
            locked_ -= a.terms.principal;
            credits_ += returned;
        }
    }

    function _recognizeLive() internal {
        IEscrow kernel = IEscrow(escrow);
        uint256 n = liveNonces.length;
        bool dirty;
        for (uint256 i; i < n; i++) {
            uint256 nonce = liveNonces[i];
            Auth storage a = auths[nonce];
            if (a.unlocked || a.reconciled) continue;
            bytes32 id = kernel.dealOf(address(this), nonce);
            if (id == 0) continue;
            if (!a.activated) {
                // There is deliberately no repair branch for an unreserved activation fee. `authorize` runs
                // `Packages.resolve` and `_activationFee` re-binds the policy to a signed id, and
                // `Packages.engage` re-binds again before it pulls, so what was reserved and what the kernel
                // takes cannot diverge. A shortfall here would mean one of those three checks is broken, and
                // `_sync` is the net that reports it rather than this loop papering over it.
                if (a.activationFee != 0) {
                    locked -= a.activationFee;
                    consumed += a.activationFee;
                }
                a.activated = true;
                dirty = true;
            }
            if (a.recognized) continue;
            (Status st, uint256 returned,) = kernel.settlementOf(id);
            if (!_terminal(st)) continue;
            _applyTerminal(a, returned);
            dirty = true;
        }
        if (dirty) _refreshApprove();
    }

    function _applyTerminal(Auth storage a, uint256 returned) internal {
        locked -= a.terms.principal;
        credits += returned;
        a.recognized = true;
    }

    function _refreshApprove() internal {
        uint256 need;
        IEscrow kernel = IEscrow(escrow);
        uint256 n = liveNonces.length;
        for (uint256 i; i < n; i++) {
            uint256 nonce = liveNonces[i];
            Auth storage a = auths[nonce];
            if (a.unlocked || a.reconciled || a.activated) continue;
            if (kernel.used(address(this), nonce)) continue;
            need += a.terms.principal + a.activationFee;
        }
        IERC20(token).forceApprove(escrow, need);
    }

    function _pushLive(uint256 nonce) internal {
        if (liveAt[nonce] != 0) return;
        liveNonces.push(nonce);
        liveAt[nonce] = liveNonces.length;
    }

    function _popLive(uint256 nonce) internal {
        uint256 i = liveAt[nonce];
        if (i == 0) return;
        uint256 last = liveNonces[liveNonces.length - 1];
        liveNonces[i - 1] = last;
        liveAt[last] = i;
        liveNonces.pop();
        delete liveAt[nonce];
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
            || s == Status.RESOLVED_BY_ARBITRATION || s == Status.CLAIMED;
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
