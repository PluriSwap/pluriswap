import { type Address, type Hex } from 'viem'
import {
  type TerminalRecord,
  type TerminalAllocation,
  type TerminalPlanContext,
  PositionKind,
} from './types'
import { positionId, hashTerminalRecord } from './hashing'

// ── Settlement Math (mirror of SettlementMath.sol) ───────────────────────────

function split(principal: bigint, providerBps: number): [bigint, bigint] {
  const providerGross = (principal * BigInt(providerBps)) / 10_000n
  const holderGross = principal - providerGross
  return [holderGross, providerGross]
}

function completionCollected(completionFee: bigint, providerGross: bigint): bigint {
  if (completionFee > providerGross) return providerGross
  return completionFee
}

// ── Terminal Planning (mirror of TerminalPlanning.sol) ───────────────────────

export interface TerminalPlanResult {
  terminalRecord: TerminalRecord
  terminalHash: Hex
  allocations: TerminalAllocation[]
}

export function planDealTerminal(
  chainId: bigint,
  protocolVersion: number,
  escrow: Address,
  ledger: Address,
  dealId: Hex,
  ctx: TerminalPlanContext,
  terminalState: number,
  outcome: number,
  providerBps: number,
  evidenceHash: Hex,
  terminatedAt: bigint
): TerminalPlanResult {
  const [holderGross, providerGross] = split(ctx.principal, providerBps)
  const completionCollectedAmt = completionCollected(ctx.completionFee, providerGross)
  const providerNet = providerGross - completionCollectedAmt

  const terminalRecord: TerminalRecord = {
    chainId,
    protocolVersion,
    escrow,
    ledger,
    dealId,
    terminalState,
    outcome,
    operatorFaultCode: 0,
    operatorFaultEvidenceHash: '0x0000000000000000000000000000000000000000000000000000000000000000',
    token: ctx.token,
    principal: ctx.principal,
    holderSideReturn: holderGross,
    providerGross,
    providerNet,
    completionCollected: completionCollectedAmt,
    operatorFeePaid: 0n,
    operatorFeeUnlocked: 0n,
    holderReceiver: ctx.holderReceiver,
    providerReceiver: ctx.providerReceiver,
    completionFeeRecipient: ctx.completionFeeRecipient,
    operatorFeeRecipient: '0x0000000000000000000000000000000000000000',
    operatorFeeReturnReceiver: '0x0000000000000000000000000000000000000000',
    termsHash: ctx.termsHash,
    modulesHash: ctx.modulesHash,
    evidenceHash,
    reservationsHash: '0x0000000000000000000000000000000000000000000000000000000000000000',
    reservationDispositionsHash: '0x0000000000000000000000000000000000000000000000000000000000000000',
    terminatedAt,
  }

  const terminalHash = hashTerminalRecord(terminalRecord)

  // Coalesce allocations
  const planned: { beneficiary: Address; amount: bigint }[] = []
  const appendOrCoalesce = (beneficiary: Address, amount: bigint) => {
    if (amount === 0n) return
    const existing = planned.find((p) => p.beneficiary.toLowerCase() === beneficiary.toLowerCase())
    if (existing) {
      existing.amount += amount
    } else {
      planned.push({ beneficiary, amount })
    }
  }

  appendOrCoalesce(ctx.holderReceiver, holderGross)
  appendOrCoalesce(ctx.providerReceiver, providerNet)
  appendOrCoalesce(ctx.completionFeeRecipient, completionCollectedAmt)

  const allocations: TerminalAllocation[] = planned.map((p) => ({
    beneficiary: p.beneficiary,
    amount: p.amount,
    positionId: positionId(
      ctx.custodyBoundaryId,
      PositionKind.DealTerminal,
      dealId,
      terminalHash,
      p.beneficiary
    ),
  }))

  return { terminalRecord, terminalHash, allocations }
}
