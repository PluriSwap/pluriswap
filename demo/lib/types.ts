import { type Address, type Hex } from 'viem'

// ── Deal States ──────────────────────────────────────────────────────────────
export const DealState = {
  None: 0,
  Funded: 1,
  FiatSent: 2,
  Disputed: 3,
  ArbitrationActive: 4,
  Released: 16,
  ResolvedSplit: 17,
  ResolvedByDisputeTimeout: 18,
  Cancelled: 19,
  ResolvedByArbitration: 20,
  Stalemate: 21,
} as const
export type DealState = (typeof DealState)[keyof typeof DealState]

// ── Outcomes ─────────────────────────────────────────────────────────────────
export const Outcome = {
  Invalid: 0,
  VoluntaryRelease: 1,
  CosignedRelease: 2,
  PaymentProofRelease: 3,
  TimeoutClaim: 4,
  ProviderCancel: 5,
  FiatTimeoutCancel: 6,
  MutualCancel: 7,
  MutualSplit: 8,
  ArbitrationHolderWin: 9,
  ArbitrationProviderWin: 10,
  ArbitrationRefused: 11,
  ArbitrationTimeout: 12,
  DisputeTimeout: 13,
} as const
export type Outcome = (typeof Outcome)[keyof typeof Outcome]

// ── Resolution Actions ───────────────────────────────────────────────────────
export const ResolutionAction = {
  Invalid: 0,
  MutualCancel: 1,
  CosignedRelease: 2,
  Split: 3,
} as const
export type ResolutionAction = (typeof ResolutionAction)[keyof typeof ResolutionAction]

// ── Funding ──────────────────────────────────────────────────────────────────
export const FundingPurpose = {
  Principal: 1,
  ActivationFee: 2,
} as const

export const FundingSourceMode = {
  WalletPull: 1,
  LedgerPosition: 2,
} as const

// ── Position Kinds ───────────────────────────────────────────────────────────
export const PositionKind = {
  ActiveDeal: 1,
  ActivationFee: 2,
  DealTerminal: 3,
  Reservation: 4,
  ReservationTerminal: 5,
} as const

// ── Reconciliation ───────────────────────────────────────────────────────────
export const ReconciliationStatus = {
  Unchanged: 0,
  SurplusQuarantined: 1,
  QuarantineLossAbsorbed: 3,
  DeficitCheckpointed: 4,
} as const

export const PayoutResultCode = {
  HealthyPartial: 1,
  HealthyFull: 2,
  DeficitPaid: 3,
  ZeroPayable: 4,
  DeficitClaimRequired: 5,
  ReconciliationOnly: 6,
} as const

export const BoundaryMode = {
  Healthy: 0,
  Deficit: 1,
} as const

// ── Structs ──────────────────────────────────────────────────────────────────
export interface DealTerms {
  holder: Address
  provider: Address
  holderReceiver: Address
  providerReceiver: Address
  token: Address
  principalFundingHash: Hex
  activationFeeFundingHash: Hex
  tokenRiskHash: Hex
  custodyBoundaryId: Hex
  principal: bigint
  activationFee: bigint
  activationFeeRecipient: Address
  completionFee: bigint
  completionFeeRecipient: Address
  nonce: bigint
  createExpiry: bigint
  fiatDuration: bigint
  releaseDuration: bigint
  disputeDuration: bigint
  disputeTimeoutProviderBps: number
  fiatCurrency: Hex
  fiatAmount: bigint
  paymentMethod: Hex
  payeeCommitment: Hex
  paymentReferenceCommitment: Hex
  profileFlags: number
  packageSelectionHash: Hex
  packageContestTermsHash: Hex
  poolAuthorityHash: Hex
  arbitrationTermsHash: Hex
  reservationsHash: Hex
  modulesHash: Hex
  extensionsHash: Hex
}

export interface FundingSpec {
  purpose: number
  sourceMode: number
  token: Address
  amount: bigint
  source: Address
  sourcePositionId: Hex
  authority: Address
}

export interface FundingAuth {
  termsHash: Hex
  fundingSpecHash: Hex
  purpose: number
  authority: Address
  nonce: bigint
  expiry: bigint
}

export interface ResolutionAuth {
  dealId: Hex
  action: number
  resolutionNonce: bigint
  expiry: bigint
  providerShareBps: number
  operatorFaultCode: number
  operatorFaultEvidenceHash: Hex
  reservationDispositionsHash: Hex
  extensionsHash: Hex
}

export interface Deal {
  state: number
  outcome: number
  holder: Address
  provider: Address
  holderReceiver: Address
  providerReceiver: Address
  token: Address
  principal: bigint
  activationFee: bigint
  activationFeeRecipient: Address
  completionFee: bigint
  completionFeeRecipient: Address
  disputeTimeoutProviderBps: bigint
  activatedAt: bigint
  fiatDeadline: bigint
  releaseDuration: bigint
  releaseDeadline: bigint
  disputeDuration: bigint
  disputeDeadline: bigint
  profileFlags: bigint
  termsHash: Hex
  custodyBoundaryId: Hex
  modulesHash: Hex
  terminalHash: Hex
}

export interface TerminalRecord {
  chainId: bigint
  protocolVersion: number
  escrow: Address
  ledger: Address
  dealId: Hex
  terminalState: number
  outcome: number
  operatorFaultCode: number
  operatorFaultEvidenceHash: Hex
  token: Address
  principal: bigint
  holderSideReturn: bigint
  providerGross: bigint
  providerNet: bigint
  completionCollected: bigint
  operatorFeePaid: bigint
  operatorFeeUnlocked: bigint
  holderReceiver: Address
  providerReceiver: Address
  completionFeeRecipient: Address
  operatorFeeRecipient: Address
  operatorFeeReturnReceiver: Address
  termsHash: Hex
  modulesHash: Hex
  evidenceHash: Hex
  reservationsHash: Hex
  reservationDispositionsHash: Hex
  terminatedAt: bigint
}

export interface TerminalAllocation {
  beneficiary: Address
  amount: bigint
  positionId: Hex
}

export interface PositionView {
  positionId: Hex
  exists: boolean
  consumed: boolean
  replaced: boolean
  replacementRoundingDust: bigint
  kind: number
  sourceId: Hex
  terminalHash: Hex
  beneficiary: Address
  token: Address
  components: {
    nominalUnits: bigint
    nominalRemaining: bigint
    paidAssets: bigint
    fundedEntitlement: bigint
    unfundedGap: bigint
  }
  deficitHistory: bigint
  deficitGeneration: bigint
  boundaryCheckpointId: Hex
  boundaryMode: number
}

export interface PositionPayoutResult {
  code: number
  reconciliationStatus: number
  positionId: Hex
  receiver: Address
  paidAmount: bigint
  nominalRemaining: bigint
}

export interface TerminalPlanContext {
  token: Address
  principal: bigint
  completionFee: bigint
  holderReceiver: Address
  providerReceiver: Address
  completionFeeRecipient: Address
  termsHash: Hex
  modulesHash: Hex
  custodyBoundaryId: Hex
}

// ── Role ─────────────────────────────────────────────────────────────────────
export type Role = 'holder' | 'provider'

// ── Helpers ──────────────────────────────────────────────────────────────────
export function isTerminal(state: number): boolean {
  return (
    state === DealState.Released ||
    state === DealState.ResolvedSplit ||
    state === DealState.ResolvedByDisputeTimeout ||
    state === DealState.Cancelled ||
    state === DealState.ResolvedByArbitration ||
    state === DealState.Stalemate
  )
}

export function stateLabel(state: number): string {
  const labels: Record<number, string> = {
    [DealState.None]: 'None',
    [DealState.Funded]: 'Funded',
    [DealState.FiatSent]: 'Fiat Sent',
    [DealState.Disputed]: 'Disputed',
    [DealState.ArbitrationActive]: 'Arbitration Active',
    [DealState.Released]: 'Released',
    [DealState.ResolvedSplit]: 'Resolved Split',
    [DealState.ResolvedByDisputeTimeout]: 'Dispute Timeout',
    [DealState.Cancelled]: 'Cancelled',
    [DealState.ResolvedByArbitration]: 'Resolved by Arbitration',
    [DealState.Stalemate]: 'Stalemate',
  }
  return labels[state] ?? `Unknown (${state})`
}

export function outcomeLabel(outcome: number): string {
  const labels: Record<number, string> = {
    [Outcome.Invalid]: 'Invalid',
    [Outcome.VoluntaryRelease]: 'Voluntary Release',
    [Outcome.CosignedRelease]: 'Cosigned Release',
    [Outcome.TimeoutClaim]: 'Timeout Claim',
    [Outcome.ProviderCancel]: 'Provider Cancel',
    [Outcome.FiatTimeoutCancel]: 'Fiat Timeout Cancel',
    [Outcome.MutualCancel]: 'Mutual Cancel',
    [Outcome.MutualSplit]: 'Mutual Split',
    [Outcome.DisputeTimeout]: 'Dispute Timeout',
  }
  return labels[outcome] ?? `Unknown (${outcome})`
}
