// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICoreEscrow} from "./interfaces/ICoreEscrow.sol";
import {ICreditLedger} from "./interfaces/ICreditLedger.sol";
import {ICoordinator} from "./interfaces/ICoordinator.sol";
import {
    Deal,
    DealTerms,
    FundingSpec,
    FundingAuth,
    ResolutionAction,
    ResolutionAuth,
    TerminalRecord
} from "./libraries/DealTypes.sol";
import {ZeroAddress, InvalidTerms} from "./libraries/CoreErrors.sol";

/// @notice Stub: tokenless CoreEscrow. Full implementation in Wave 3.
contract CoreEscrow is ICoreEscrow {
    bytes32 private constant _DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    uint64 public immutable chainId;
    uint32 public immutable protocolVersion;
    bytes32 public immutable charterHash;
    bytes32 public immutable techSpecHash;
    ICreditLedger public immutable ledger;
    ICoordinator public immutable coordinator;
    bytes32 public immutable DOMAIN_SEPARATOR;
    bytes32 public immutable manifestHash;

    constructor(
        uint64 chainId_,
        uint32 protocolVersion_,
        bytes32 charterHash_,
        bytes32 techSpecHash_,
        address ledger_,
        address coordinator_,
        bytes32 manifestHash_
    ) {
        if (ledger_ == address(0) || coordinator_ == address(0)) revert ZeroAddress();
        if (ledger_ == coordinator_ || ledger_ == address(this) || coordinator_ == address(this)) {
            revert InvalidTerms();
        }
        chainId = chainId_;
        protocolVersion = protocolVersion_;
        charterHash = charterHash_;
        techSpecHash = techSpecHash_;
        ledger = ICreditLedger(ledger_);
        coordinator = ICoordinator(coordinator_);
        manifestHash = manifestHash_;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                _DOMAIN_TYPEHASH,
                keccak256(bytes("PluriSwap")),
                keccak256(bytes("2")),
                uint256(chainId_),
                address(this)
            )
        );
    }

    receive() external payable { revert(); }
    fallback() external payable { revert(); }

    // ── Stub entrypoints (Wave 3) ──────────────────────────────────────────────

    function activate(
        DealTerms calldata, FundingSpec calldata, FundingSpec calldata,
        FundingAuth calldata, FundingAuth calldata,
        bytes calldata, bytes calldata, bytes calldata, bytes calldata
    ) external returns (bytes32) {
        revert("CoreEscrow: not implemented (Wave 3)");
    }

    function markFiatSent(bytes32) external { revert("CoreEscrow: not implemented (Wave 3)"); }
    function providerCancel(bytes32) external { revert("CoreEscrow: not implemented (Wave 3)"); }
    function fiatTimeoutCancel(bytes32) external { revert("CoreEscrow: not implemented (Wave 3)"); }
    function holderRelease(bytes32) external { revert("CoreEscrow: not implemented (Wave 3)"); }
    function claim(bytes32) external { revert("CoreEscrow: not implemented (Wave 3)"); }
    function openDispute(bytes32, bytes calldata) external { revert("CoreEscrow: not implemented (Wave 3)"); }
    function disputeTimeout(bytes32) external { revert("CoreEscrow: not implemented (Wave 3)"); }

    function mutualResolve(bytes32, ResolutionAuth calldata, bytes calldata, bytes calldata)
        external
    {
        revert("CoreEscrow: not implemented (Wave 3)");
    }

    function submitPaymentProof(bytes32, bytes calldata) external pure { revert("CoreEscrow: not implemented (Wave 3)"); }
    function openArbitration(bytes32, bytes calldata) external payable { revert("CoreEscrow: not implemented (Wave 3)"); }
    function submitArbitrationRuling(bytes32, bytes calldata) external pure { revert("CoreEscrow: not implemented (Wave 3)"); }
    function arbitrationTimeout(bytes32) external pure { revert("CoreEscrow: not implemented (Wave 3)"); }

    // ── Stub views ─────────────────────────────────────────────────────────────

    function getDeal(bytes32) external view returns (Deal memory) {
        revert("CoreEscrow: not implemented (Wave 3)");
    }

    function dealState(bytes32) external view returns (uint8) {
        revert("CoreEscrow: not implemented (Wave 3)");
    }

    function termsHashOf(bytes32) external view returns (bytes32) {
        revert("CoreEscrow: not implemented (Wave 3)");
    }

    function getTerminalRecord(bytes32) external view returns (TerminalRecord memory) {
        revert("CoreEscrow: not implemented (Wave 3)");
    }

    function getTerminalHash(bytes32) external view returns (bytes32) {
        revert("CoreEscrow: not implemented (Wave 3)");
    }

    function usedHolderNonce(address, uint256) external view returns (bool) { return false; }
    function usedResolutionNonce(bytes32, ResolutionAction, uint256) external view returns (bool) { return false; }
}
