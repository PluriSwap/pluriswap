// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICreditLedger} from "./interfaces/ICreditLedger.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IERC1271} from "./interfaces/IERC1271.sol";
import {ExactERC20} from "./libraries/ExactERC20.sol";
import {
    DeficitActive,
    Expired,
    InsufficientCredit,
    InvalidSignature,
    NonceUsed,
    SelfReceiver,
    Unauthorized,
    ZeroAddress
} from "./libraries/CoreErrors.sol";

contract CreditLedger is ICreditLedger {
    using ExactERC20 for IERC20;

    bytes32 private constant _TYPE_HASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private constant _NAME_HASH = keccak256(bytes("PluriSwapCreditLedger"));
    bytes32 private constant _VERSION_HASH = keccak256(bytes("2"));
    bytes32 private constant _WITHDRAW_TYPEHASH = keccak256(
        "CreditWithdrawAuth(address token,address beneficiary,address to,uint256 amount,uint256 nonce,uint64 expiry)"
    );

    address public immutable escrow;
    uint64 public immutable chainId;
    bytes32 public immutable DOMAIN_SEPARATOR;

    mapping(address token => mapping(address beneficiary => uint256)) internal _credits;
    mapping(address token => uint256) internal _liabilities;
    mapping(address token => bool) internal _inDeficit;
    mapping(address token => uint256) internal _totalRecoveryUnits;
    mapping(address token => uint256) internal _cumulativeDistributable;
    mapping(address token => mapping(address beneficiary => uint256)) internal _units;
    mapping(address token => mapping(address beneficiary => uint256)) internal _claimed;
    mapping(address beneficiary => mapping(uint256 nonce => bool)) internal _withdrawNonceUsed;

    uint256 private _locked = 1;

    modifier nonReentrant() {
        require(_locked == 1, "REENTRANCY");
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier onlyEscrow() {
        if (msg.sender != escrow) revert Unauthorized();
        _;
    }

    constructor(address escrow_, uint64 chainId_) {
        if (escrow_ == address(0)) revert ZeroAddress();
        escrow = escrow_;
        chainId = chainId_;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(_TYPE_HASH, _NAME_HASH, _VERSION_HASH, uint256(chainId_), address(this))
        );
    }

    receive() external payable {
        revert();
    }

    fallback() external payable {
        revert();
    }

    function credit(bytes32 dealId, address token, address beneficiary, uint256 amount)
        external
        onlyEscrow
        nonReentrant
    {
        if (token == address(0) || beneficiary == address(0)) revert ZeroAddress();
        if (beneficiary == address(this) || beneficiary == escrow) revert SelfReceiver();
        if (_inDeficit[token]) revert DeficitActive();
        if (amount == 0) return;

        _credits[token][beneficiary] += amount;
        _liabilities[token] += amount;
        emit Credited(dealId, token, beneficiary, amount);
    }

    function withdraw(address token, address beneficiary) external nonReentrant {
        _withdraw(token, beneficiary, beneficiary, _credits[token][beneficiary]);
    }

    function withdrawTo(
        address token,
        address beneficiary,
        address to,
        uint256 amount,
        uint256 nonce,
        uint64 expiry,
        bytes calldata signature
    ) external nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this) || to == escrow) revert SelfReceiver();
        if (uint64(block.timestamp) >= expiry) revert Expired();
        if (_withdrawNonceUsed[beneficiary][nonce]) revert NonceUsed();

        bytes32 structHash = keccak256(
            abi.encode(_WITHDRAW_TYPEHASH, token, beneficiary, to, amount, nonce, expiry)
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        _verifySigner(beneficiary, digest, signature);

        _withdrawNonceUsed[beneficiary][nonce] = true;

        uint256 creditBal = _credits[token][beneficiary];
        uint256 pay = amount == type(uint256).max ? creditBal : amount;
        _withdraw(token, beneficiary, to, pay);
    }

    function claimRecovery(address token, address beneficiary) external nonReentrant {
        if (!_inDeficit[token]) revert InsufficientCredit();
        uint256 units = _units[token][beneficiary];
        if (units == 0) revert InsufficientCredit();

        uint256 totalUnits = _totalRecoveryUnits[token];
        uint256 entitled =
            (_cumulativeDistributable[token] * units) / totalUnits;
        uint256 already = _claimed[token][beneficiary];
        if (entitled <= already) revert InsufficientCredit();
        uint256 pay = entitled - already;

        _claimed[token][beneficiary] = entitled;
        IERC20(token).pushExact(beneficiary, pay);
        emit RecoveryClaimed(token, beneficiary, pay);
    }

    function reallocateRecovery(
        bytes32 dealId,
        address token,
        address fromBeneficiary,
        address toBeneficiary,
        uint256 units
    ) external onlyEscrow nonReentrant {
        if (!_inDeficit[token]) revert DeficitActive();
        if (toBeneficiary == address(0)) revert ZeroAddress();
        if (toBeneficiary == address(this) || toBeneficiary == escrow) revert SelfReceiver();
        if (_units[token][fromBeneficiary] < units) revert InsufficientCredit();

        _units[token][fromBeneficiary] -= units;
        _units[token][toBeneficiary] += units;
        emit RecoveryReallocated(dealId, token, fromBeneficiary, toBeneficiary, units);
    }

    /// @dev Called internally before ordinary withdraw when assets < liabilities.
    function _enterDeficitIfNeeded(address token) internal {
        if (_inDeficit[token]) return;
        uint256 assets = IERC20(token).balanceOf(address(this));
        uint256 liab = _liabilities[token];
        if (assets >= liab) return;

        _inDeficit[token] = true;
        _totalRecoveryUnits[token] = liab;
        _cumulativeDistributable[token] = assets;
        // Per-beneficiary units are snapshotted lazily in `_ensureUnits` (credit → units).
        emit DeficitEntered(token, liab, assets);
    }

    function _ensureUnits(address token, address beneficiary) internal {
        if (!_inDeficit[token]) return;
        if (_units[token][beneficiary] > 0 || _credits[token][beneficiary] == 0) return;
        uint256 c = _credits[token][beneficiary];
        _units[token][beneficiary] = c;
        _credits[token][beneficiary] = 0;
    }

    function _withdraw(address token, address beneficiary, address to, uint256 amount) internal {
        if (amount == 0) revert InsufficientCredit();
        _enterDeficitIfNeeded(token);
        if (_inDeficit[token]) {
            _ensureUnits(token, beneficiary);
            revert DeficitActive();
        }

        uint256 bal = _credits[token][beneficiary];
        if (bal < amount) revert InsufficientCredit();

        _credits[token][beneficiary] = bal - amount;
        _liabilities[token] -= amount;
        IERC20(token).pushExact(to, amount);
        emit Withdrawn(token, beneficiary, to, amount);
    }

    function _verifySigner(address expected, bytes32 digest, bytes calldata signature) internal view {
        if (expected.code.length > 0) {
            bytes4 magic = IERC1271(expected).isValidSignature(digest, signature);
            if (magic != 0x1626ba7e) revert InvalidSignature();
            return;
        }
        if (signature.length != 65) revert InvalidSignature();
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 32))
            v := byte(0, calldataload(add(signature.offset, 64)))
        }
        address signer = ecrecover(digest, v, r, s);
        if (signer == address(0) || signer != expected) revert InvalidSignature();
    }

    function creditOf(address token, address beneficiary) external view returns (uint256) {
        return _credits[token][beneficiary];
    }

    function liabilityOf(address token) external view returns (uint256) {
        return _liabilities[token];
    }

    function assetsOf(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function inDeficit(address token) external view returns (bool) {
        return _inDeficit[token];
    }

    function recoveryUnits(address token, address beneficiary) external view returns (uint256) {
        return _units[token][beneficiary];
    }

    function recoveryClaimed(address token, address beneficiary) external view returns (uint256) {
        return _claimed[token][beneficiary];
    }
}
