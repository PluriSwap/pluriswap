// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICreditLedger} from "./interfaces/ICreditLedger.sol";
import {
    FundingSpec,
    FundingAuth,
    PositionPayoutAuth,
    PositionPayoutResult,
    TerminalAllocation
} from "./libraries/DealTypes.sol";
import {ZeroAddress, Unauthorized, DeficitNotImplemented} from "./libraries/CoreErrors.sol";

/// @notice Stub: sole-vault CreditLedger. Full implementation in Wave 2.
contract CreditLedger is ICreditLedger {
    address public immutable escrow;
    uint64 public immutable chainId;
    bytes32 public immutable DOMAIN_SEPARATOR;

    constructor(address escrow_, uint64 chainId_) {
        if (escrow_ == address(0)) revert ZeroAddress();
        escrow = escrow_;
        chainId = chainId_;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes("PluriSwapCreditLedger")),
                keccak256(bytes("2")),
                uint256(chainId_),
                address(this)
            )
        );
    }

    receive() external payable { revert(); }
    fallback() external payable { revert(); }

    function preflightValueAction(address[] calldata tokens)
        external
        returns (uint8[] memory)
    {
        if (msg.sender != escrow) revert Unauthorized();
        uint8[] memory statuses = new uint8[](tokens.length);
        return statuses; // all UNCHANGED (0) in stub
    }

    function fundDealAndReservations(
        bytes32, address, uint256, uint256, address,
        FundingSpec calldata, FundingSpec calldata,
        FundingAuth calldata, FundingAuth calldata,
        bytes calldata, bytes calldata
    ) external {
        revert("CreditLedger: not implemented (Wave 2)");
    }

    function settleDealAndReservations(
        bytes32, address, bytes32, TerminalAllocation[] calldata
    ) external {
        revert("CreditLedger: not implemented (Wave 2)");
    }

    function withdrawPosition(bytes32, uint256)
        external
        returns (PositionPayoutResult memory)
    {
        revert("CreditLedger: not implemented (Wave 2)");
    }

    function withdrawPositionTo(PositionPayoutAuth calldata, bytes calldata)
        external
        returns (PositionPayoutResult memory)
    {
        revert("CreditLedger: not implemented (Wave 2)");
    }

    function checkpointBoundary(address) external {
        revert("CreditLedger: not implemented (Wave 2)");
    }

    function depositRecovery(address, address, uint256) external {
        revert DeficitNotImplemented();
    }

    function claimRecovery(bytes32, uint256)
        external
        returns (PositionPayoutResult memory)
    {
        revert DeficitNotImplemented();
    }

    function claimRecoveryTo(PositionPayoutAuth calldata, bytes calldata)
        external
        returns (PositionPayoutResult memory)
    {
        revert DeficitNotImplemented();
    }

    // ── Stub views ─────────────────────────────────────────────────────────────
    function boundaryMode(address) external view returns (uint8) { return 0; }
    function accountedAssets(address) external view returns (uint256) { return 0; }
    function nominalOutstanding(address) external view returns (uint256) { return 0; }
    function quarantinedSurplus(address) external view returns (uint256) { return 0; }
    function inDeficit(address) external view returns (bool) { return false; }
    function positionExists(bytes32) external view returns (bool) { return false; }
    function positionNominal(bytes32) external view returns (uint256) { return 0; }
    function positionBeneficiary(bytes32) external view returns (address) { return address(0); }
    function positionKind(bytes32) external view returns (uint8) { return 0; }
    function positionConsumed(bytes32) external view returns (bool) { return false; }
}
