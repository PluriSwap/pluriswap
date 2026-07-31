// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {DealHashing} from "./DealHashing.sol";
import {SettlementMath} from "./SettlementMath.sol";
import {
    PositionKind,
    TerminalAllocation,
    TerminalPlanContext,
    TerminalRecord
} from "./DealTypes.sol";

/// @notice Pure terminal planning: splits, terminal record, and coalesced allocations.
/// @dev No storage reads and no Ledger/Escrow callbacks. Embedded only in Coordinator so
///      CoreEscrow stays under EIP-170 while Ledger remains custody-only.
library TerminalPlanning {
    function plan(
        uint64 chainId,
        uint32 protocolVersion,
        address escrow,
        address ledger,
        bytes32 dealId,
        TerminalPlanContext memory ctx,
        uint8 terminalState,
        uint8 outcome,
        uint16 providerBps,
        bytes32 evidenceHash,
        uint64 terminatedAt
    )
        internal
        pure
        returns (
            TerminalRecord memory terminalRecord,
            bytes32 terminalHash,
            TerminalAllocation[] memory allocations
        )
    {
        (uint256 holderGross, uint256 providerGross) =
            SettlementMath.split(ctx.principal, providerBps);
        uint256 completionCollected =
            SettlementMath.completionCollected(ctx.completionFee, providerGross);
        uint256 providerNet;
        unchecked {
            providerNet = providerGross - completionCollected;
        }

        terminalRecord = TerminalRecord({
            chainId: chainId,
            protocolVersion: protocolVersion,
            escrow: escrow,
            ledger: ledger,
            dealId: dealId,
            terminalState: terminalState,
            outcome: outcome,
            operatorFaultCode: 0,
            operatorFaultEvidenceHash: bytes32(0),
            token: ctx.token,
            principal: ctx.principal,
            holderSideReturn: holderGross,
            providerGross: providerGross,
            providerNet: providerNet,
            completionCollected: completionCollected,
            operatorFeePaid: 0,
            operatorFeeUnlocked: 0,
            holderReceiver: ctx.holderReceiver,
            providerReceiver: ctx.providerReceiver,
            completionFeeRecipient: ctx.completionFeeRecipient,
            operatorFeeRecipient: address(0),
            operatorFeeReturnReceiver: address(0),
            termsHash: ctx.termsHash,
            modulesHash: ctx.modulesHash,
            evidenceHash: evidenceHash,
            reservationsHash: bytes32(0),
            reservationDispositionsHash: bytes32(0),
            terminatedAt: terminatedAt
        });
        terminalHash = DealHashing.hashTerminalRecord(terminalRecord);

        TerminalAllocation[3] memory planned;
        uint256 count = 0;
        count = _appendOrCoalesce(planned, count, ctx.holderReceiver, holderGross);
        count = _appendOrCoalesce(planned, count, ctx.providerReceiver, providerNet);
        count = _appendOrCoalesce(planned, count, ctx.completionFeeRecipient, completionCollected);

        allocations = new TerminalAllocation[](count);
        for (uint256 i; i < count; ++i) {
            allocations[i] = TerminalAllocation({
                beneficiary: planned[i].beneficiary,
                amount: planned[i].amount,
                positionId: DealHashing.positionId(
                    ctx.custodyBoundaryId,
                    PositionKind.DealTerminal,
                    dealId,
                    terminalHash,
                    planned[i].beneficiary
                )
            });
        }
    }

    function _appendOrCoalesce(
        TerminalAllocation[3] memory planned,
        uint256 count,
        address beneficiary,
        uint256 amount
    ) private pure returns (uint256) {
        if (amount == 0) return count;
        for (uint256 i; i < count; ++i) {
            if (planned[i].beneficiary != beneficiary) continue;
            planned[i].amount += amount;
            return count;
        }
        planned[count] =
            TerminalAllocation({beneficiary: beneficiary, amount: amount, positionId: bytes32(0)});
        return count + 1;
    }
}
