// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PackageId} from "./PackageId.sol";
import {PassportMock} from "./PassportMock.sol";

contract Reputation {
    error CapExceeded();
    error InFlightUnderflow();

    enum Close {
        Peaceful,
        Silent,
        Stalemate,
        ArbWin,
        ArbLoss
    }

    struct Stat {
        uint32 successCount;
        uint32 penalty;
        uint256 volume;
    }

    PassportMock public immutable passport;
    address public immutable feeRecipient;
    uint256 public immutable activationFee;
    bytes32 public immutable packageId;

    mapping(bytes32 subject => mapping(address token => uint256 amount)) public inFlight;
    mapping(bytes32 subject => mapping(address token => Stat)) internal _stat;

    constructor(PassportMock passport_, address feeRecipient_, uint256 activationFee_) {
        passport = passport_;
        feeRecipient = feeRecipient_;
        activationFee = activationFee_;
        packageId = PackageId.reputation(address(this), feeRecipient_, activationFee_);
    }

    function admit(address wallet, address token, uint256 principal, bool withBond) external returns (bytes32 subject) {
        subject = passport.identify(wallet);
        uint256 next = inFlight[subject][token] + principal;
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

    function _capTokens(uint256 sc, bool withBond, uint8 decimals) internal pure returns (uint256) {
        if (sc >= 100) return type(uint256).max;
        uint256 tokens;
        if (sc >= 50) tokens = withBond ? 5000 : 2000;
        else if (sc >= 25) tokens = withBond ? 1500 : 1000;
        else if (sc >= 10) tokens = withBond ? 700 : 500;
        else tokens = withBond ? 400 : 250;
        return tokens * 10 ** uint256(decimals);
    }

    function notifyTerminal(address wallet, address token, uint256 principal, Close kind) external {
        bytes32 subject = passport.identify(wallet);
        uint256 inf = inFlight[subject][token];
        if (principal > inf) revert InFlightUnderflow();
        inFlight[subject][token] = inf - principal;
        Stat storage s = _stat[subject][token];
        if (kind == Close.Peaceful) {
            s.successCount += 1;
            s.volume += principal;
        } else if (kind == Close.Stalemate) {
            s.penalty += 5;
        } else if (kind == Close.ArbLoss) {
            s.penalty += 15;
        }
    }
}
