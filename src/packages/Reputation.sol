// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PackageId} from "../libraries/PackageId.sol";
import {IPassport} from "./interfaces/IPassport.sol";
import {IReputation} from "./interfaces/IReputation.sol";
import {IBondVault} from "./interfaces/IBondVault.sol";

contract Reputation is IReputation {
    error CapExceeded();
    error InFlightUnderflow();
    error InsufficientBond();
    error ZeroAddress();
    error Unauthorized();
    error BadFee();

    struct Stat {
        uint32 successCount;
        uint32 penalty;
        uint256 volume;
    }

    /// @dev The rate window of §3.14.7: how much credit a subject has already taken this epoch.
    struct Rate {
        uint64 epoch;
        uint64 credits;
    }

    /// @dev One epoch of the rate limit, and how many credited deals fit in it. The cap sits far above
    ///      any honest retail trader (sixteen NEW counterparties in a day) and only bites automated
    ///      bursts: it cannot stop a patient farmer, it turns a weekend into a year.
    uint256 internal constant EPOCH = 1 days;
    uint64 internal constant MAX_CREDITS_PER_EPOCH = 16;

    IPassport public immutable passport;
    address public immutable operator;
    address public immutable feeRecipient;
    uint256 public immutable activationFee;
    uint256 public immutable completionFee;
    uint256 public immutable contestBps;
    uint256 public immutable contestFloor;
    bytes32 public immutable packageId;

    mapping(bytes32 subject => mapping(address token => uint256 amount)) public inFlight;
    mapping(bytes32 subject => mapping(address token => Stat)) internal _stat;
    /// @dev Who has already vouched for this subject by trading with it. Public on purpose: the public
    ///      layer's subjects are wallet-derived and already visible, so hiding the pair here would buy
    ///      nothing. The PRIVATE layer cannot use a map at all — it would publish the trading graph —
    ///      and proves the same rule inside the circuit against a per-account tree (§3.15.5).
    mapping(bytes32 subject => mapping(bytes32 counterparty => bool)) public credited;
    mapping(bytes32 subject => Rate) internal _rate;

    constructor(
        IPassport passport_,
        address feeRecipient_,
        uint256 activationFee_,
        uint256 completionFee_,
        uint256 contestBps_,
        uint256 contestFloor_,
        address operator_
    ) {
        if (address(passport_) == address(0) || feeRecipient_ == address(0) || operator_ == address(0)) {
            revert ZeroAddress();
        }
        if (contestBps_ > 10_000) revert BadFee();
        passport = passport_;
        feeRecipient = feeRecipient_;
        activationFee = activationFee_;
        completionFee = completionFee_;
        contestBps = contestBps_;
        contestFloor = contestFloor_;
        operator = operator_;
        packageId = PackageId.reputation(
            address(this), feeRecipient_, activationFee_, completionFee_, contestBps_, contestFloor_
        );
    }

    function invoiceActivation() external view returns (uint256 amount, address recipient) {
        return (activationFee, feeRecipient);
    }

    function invoiceCompletion() external view returns (uint256 amount, address recipient) {
        return (completionFee, feeRecipient);
    }

    function invoiceContest(uint256 principal) external view returns (uint256 amount, address recipient) {
        return (_contestDue(principal), feeRecipient);
    }

    /// @dev 1% of `principal` when `contestBps == 100`, never below `contestFloor`. Zero bps is a flat floor
    ///      (free if the floor is also 0).
    function _contestDue(uint256 principal) internal view returns (uint256) {
        if (contestBps == 0) return contestFloor;
        uint256 pct = principal * contestBps / 10_000;
        return pct < contestFloor ? contestFloor : pct;
    }

    function stats(bytes32 subject, address token)
        external
        view
        returns (uint32 successCount, uint32 penalty, uint256 volume)
    {
        Stat storage s = _stat[subject][token];
        return (s.successCount, s.penalty, s.volume);
    }

    function admit(address wallet, bytes32, address token, uint256 principal, address vault) external returns (bytes32 subject) {
        if (msg.sender != operator) revert Unauthorized();
        subject = passport.identify(wallet);
        uint256 next = inFlight[subject][token] + principal;
        bool withBond = vault != address(0);
        if (withBond) _requireBondCoverage(IBondVault(vault), subject, token, principal, next);
        if (next > cap(subject, token, withBond)) revert CapExceeded();
        inFlight[subject][token] = next;
    }

    function cap(bytes32 subject, address token, bool withBond) public view returns (uint256) {
        return _capTokens(score(subject, token), withBond, IERC20Metadata(token).decimals());
    }

    function score(bytes32 subject, address token) public view returns (uint256) {
        Stat storage s = _stat[subject][token];
        uint256 unit = 250 * 10 ** uint256(IERC20Metadata(token).decimals());
        uint256 raw = uint256(s.successCount) + s.volume / unit;
        return raw > s.penalty ? raw - s.penalty : 0;
    }

    /// @dev T5's unbounded column is the BOND one (2026-09-23): unlimited exposure requires a live
    ///      lock, so at §3.14.5's 10% it is always 10% backed. Without bond the ladder tops at 5.000.
    function _capTokens(uint256 sc, bool withBond, uint8 decimals) internal pure returns (uint256) {
        if (sc >= 100 && withBond) return type(uint256).max;
        uint256 tokens;
        if (sc >= 100) tokens = 5000;
        else if (sc >= 50) tokens = withBond ? 5000 : 2000;
        else if (sc >= 25) tokens = withBond ? 1500 : 1000;
        else if (sc >= 10) tokens = withBond ? 700 : 500;
        else tokens = withBond ? 400 : 250;
        return tokens * 10 ** uint256(decimals);
    }

    function _requireBondCoverage(IBondVault vault, bytes32 subject, address token, uint256 principal, uint256 next)
        internal
        view
    {
        uint256 lockAmount = (principal + 9) / 10;
        if (lockAmount * 10 < principal) revert InsufficientBond();
        if (vault.available(subject, token) < lockAmount) revert InsufficientBond();
        if ((vault.locked(subject, token) + lockAmount) * 10 < next) revert InsufficientBond();
    }

    /// @dev Credit is once per COUNTERPARTY; penalties are every time. The asymmetry is the same one
    ///      the disclosure layer has (§3.15.7's floors and ceiling) read from the other end: what is
    ///      good about you counts once per person who vouched for it by trading with you, what went
    ///      wrong counts always.
    ///
    ///      This is what prices the farm. The anti-sybil root limits how many identities exist, never
    ///      how many times two of them trade with each other — so a pair used to buy an unbounded
    ///      ladder for the cost of fees. Now a closed cluster SATURATES: each member can be credited
    ///      by each other member exactly once, so a clique of k tops out near its own size and the
    ///      climb is paid in identities, which is where the Passport actually bites.
    ///
    ///      What it costs honest users, stated: a repeat customer stops building your reputation after
    ///      the first deal. That is deliberate — this number measures BREADTH, how many distinct people
    ///      have transacted with you, not how busy you are with the ones you already trust.
    function notifyTerminal(
        bytes32 subject,
        bytes32 counterparty,
        address token,
        uint256 principal,
        IReputation.Close kind
    ) external {
        if (msg.sender != operator) revert Unauthorized();
        uint256 inf = inFlight[subject][token];
        if (principal > inf) revert InFlightUnderflow();
        inFlight[subject][token] = inf - principal;
        Stat storage s = _stat[subject][token];
        if (kind == IReputation.Close.Peaceful) {
            if (_creditable(subject, counterparty)) {
                s.successCount += 1;
                s.volume += principal;
            }
        } else if (kind == IReputation.Close.Stalemate) {
            s.penalty += 5;
        } else if (kind == IReputation.Close.ArbLoss) {
            s.penalty += 15;
        }
    }

    /// @dev True exactly once per (subject, counterparty), and at most `MAX_CREDITS_PER_EPOCH` times
    ///      per epoch. Burns the pair either way: a deal that arrives over the rate limit does not get
    ///      to come back for its credit later, or the limit would only be a delay.
    function _creditable(bytes32 subject, bytes32 counterparty) internal returns (bool) {
        if (credited[subject][counterparty]) return false;
        credited[subject][counterparty] = true;
        Rate storage r = _rate[subject];
        uint64 epoch = uint64(block.timestamp / EPOCH);
        if (r.epoch != epoch) {
            r.epoch = epoch;
            r.credits = 0;
        }
        if (r.credits >= MAX_CREDITS_PER_EPOCH) return false;
        r.credits += 1;
        return true;
    }
}
