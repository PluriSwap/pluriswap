import { type Address, type Hex, keccak256, encodeAbiParameters, parseAbiParameters, concat, toHex } from 'viem'
import {
  type DealTerms,
  type FundingSpec,
  type FundingAuth,
  type ResolutionAuth,
  type TerminalRecord,
  type TerminalAllocation,
  PositionKind,
} from './types'

// ── Typehashes (mirror of DealHashing.sol) ───────────────────────────────────

const DEAL_TERMS_TYPEHASH = keccak256(
  toHex('DealTerms(address holder,address provider,address holderReceiver,address providerReceiver,address token,bytes32 principalFundingHash,bytes32 activationFeeFundingHash,bytes32 tokenRiskHash,bytes32 custodyBoundaryId,uint256 principal,uint256 activationFee,address activationFeeRecipient,uint256 completionFee,address completionFeeRecipient,uint256 nonce,uint64 createExpiry,uint64 fiatDuration,uint64 releaseDuration,uint64 disputeDuration,uint16 disputeTimeoutProviderBps,bytes32 fiatCurrency,uint256 fiatAmount,bytes32 paymentMethod,bytes32 payeeCommitment,bytes32 paymentReferenceCommitment,uint32 profileFlags,bytes32 packageSelectionHash,bytes32 packageContestTermsHash,bytes32 poolAuthorityHash,bytes32 arbitrationTermsHash,bytes32 reservationsHash,bytes32 modulesHash,bytes32 extensionsHash)')
)

const FUNDING_SPEC_TYPEHASH = keccak256(
  toHex('FundingSpec(uint8 purpose,uint8 sourceMode,address token,uint256 amount,address source,bytes32 sourcePositionId,address authority)')
)

const FUNDING_AUTH_TYPEHASH = keccak256(
  toHex('FundingAuth(bytes32 termsHash,bytes32 fundingSpecHash,uint8 purpose,address authority,uint256 nonce,uint64 expiry)')
)

const RESOLUTION_TYPEHASH = keccak256(
  toHex('ResolutionAuth(bytes32 dealId,uint8 action,uint256 resolutionNonce,uint64 expiry,uint16 providerShareBps,uint8 operatorFaultCode,bytes32 operatorFaultEvidenceHash,bytes32 reservationDispositionsHash,bytes32 extensionsHash)')
)

const DEAL_ID_TYPEHASH = keccak256(
  toHex('PluriSwapDealId(uint64 chainId,uint32 protocolVersion,address escrow,bytes32 termsHash,address holder,address provider,uint256 nonce)')
)

const TERMINAL_RECORD_TYPEHASH = keccak256(
  toHex('PluriSwapTerminalRecord(uint64 chainId,uint32 protocolVersion,address escrow,address ledger,bytes32 dealId,uint8 terminalState,uint8 outcome,uint8 operatorFaultCode,bytes32 operatorFaultEvidenceHash,address token,uint256 principal,uint256 holderSideReturn,uint256 providerGross,uint256 providerNet,uint256 completionCollected,uint256 operatorFeePaid,uint256 operatorFeeUnlocked,address holderReceiver,address providerReceiver,address completionFeeRecipient,address operatorFeeRecipient,address operatorFeeReturnReceiver,bytes32 termsHash,bytes32 modulesHash,bytes32 evidenceHash,bytes32 reservationsHash,bytes32 reservationDispositionsHash,uint64 terminatedAt)')
)

const POSITION_ID_V1_TYPEHASH = keccak256(
  toHex('PluriSwapPositionIdV1(bytes32 custodyBoundaryId,uint8 kind,bytes32 sourceId,bytes32 terminalHash,address beneficiary)')
)

const CUSTODY_BOUNDARY_TYPEHASH = keccak256(
  toHex('PluriSwapCustodyBoundary(uint64 chainId,uint32 protocolVersion,address ledger,address token)')
)

// ── Hash functions ───────────────────────────────────────────────────────────

export function hashFundingSpec(spec: FundingSpec): Hex {
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters('bytes32, uint8, uint8, address, uint256, address, bytes32, address'),
      [
        FUNDING_SPEC_TYPEHASH,
        spec.purpose,
        spec.sourceMode,
        spec.token,
        spec.amount,
        spec.source,
        spec.sourcePositionId,
        spec.authority,
      ]
    )
  )
}

export function hashFundingAuth(auth: FundingAuth): Hex {
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters('bytes32, bytes32, bytes32, uint8, address, uint256, uint64'),
      [
        FUNDING_AUTH_TYPEHASH,
        auth.termsHash,
        auth.fundingSpecHash,
        auth.purpose,
        auth.authority,
        auth.nonce,
        auth.expiry,
      ]
    )
  )
}

export function hashDealTerms(t: DealTerms): Hex {
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters(
        'bytes32, address, address, address, address, address, bytes32, bytes32, bytes32, bytes32, uint256, uint256, address, uint256, address, uint256, uint64, uint64, uint64, uint64, uint16, bytes32, uint256, bytes32, bytes32, bytes32, uint32, bytes32, bytes32, bytes32, bytes32, bytes32, bytes32, bytes32'
      ),
      [
        DEAL_TERMS_TYPEHASH,
        t.holder,
        t.provider,
        t.holderReceiver,
        t.providerReceiver,
        t.token,
        t.principalFundingHash,
        t.activationFeeFundingHash,
        t.tokenRiskHash,
        t.custodyBoundaryId,
        t.principal,
        t.activationFee,
        t.activationFeeRecipient,
        t.completionFee,
        t.completionFeeRecipient,
        t.nonce,
        t.createExpiry,
        t.fiatDuration,
        t.releaseDuration,
        t.disputeDuration,
        t.disputeTimeoutProviderBps,
        t.fiatCurrency,
        t.fiatAmount,
        t.paymentMethod,
        t.payeeCommitment,
        t.paymentReferenceCommitment,
        t.profileFlags,
        t.packageSelectionHash,
        t.packageContestTermsHash,
        t.poolAuthorityHash,
        t.arbitrationTermsHash,
        t.reservationsHash,
        t.modulesHash,
        t.extensionsHash,
      ]
    )
  )
}

export function hashDealId(
  chainId: bigint,
  protocolVersion: number,
  escrow: Address,
  termsHash: Hex,
  holder: Address,
  provider: Address,
  nonce: bigint
): Hex {
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters('bytes32, uint64, uint32, address, bytes32, address, address, uint256'),
      [DEAL_ID_TYPEHASH, chainId, protocolVersion, escrow, termsHash, holder, provider, nonce]
    )
  )
}

export function hashResolution(auth: ResolutionAuth): Hex {
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters(
        'bytes32, bytes32, uint8, uint256, uint64, uint16, uint8, bytes32, bytes32, bytes32'
      ),
      [
        RESOLUTION_TYPEHASH,
        auth.dealId,
        auth.action,
        auth.resolutionNonce,
        auth.expiry,
        auth.providerShareBps,
        auth.operatorFaultCode,
        auth.operatorFaultEvidenceHash,
        auth.reservationDispositionsHash,
        auth.extensionsHash,
      ]
    )
  )
}

export function hashTerminalRecord(r: TerminalRecord): Hex {
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters(
        'bytes32, uint64, uint32, address, address, bytes32, uint8, uint8, uint8, bytes32, address, uint256, uint256, uint256, uint256, uint256, uint256, uint256, address, address, address, address, address, bytes32, bytes32, bytes32, bytes32, bytes32, uint64'
      ),
      [
        TERMINAL_RECORD_TYPEHASH,
        r.chainId,
        r.protocolVersion,
        r.escrow,
        r.ledger,
        r.dealId,
        r.terminalState,
        r.outcome,
        r.operatorFaultCode,
        r.operatorFaultEvidenceHash,
        r.token,
        r.principal,
        r.holderSideReturn,
        r.providerGross,
        r.providerNet,
        r.completionCollected,
        r.operatorFeePaid,
        r.operatorFeeUnlocked,
        r.holderReceiver,
        r.providerReceiver,
        r.completionFeeRecipient,
        r.operatorFeeRecipient,
        r.operatorFeeReturnReceiver,
        r.termsHash,
        r.modulesHash,
        r.evidenceHash,
        r.reservationsHash,
        r.reservationDispositionsHash,
        r.terminatedAt,
      ]
    )
  )
}

export function positionId(
  custodyBoundaryId: Hex,
  kind: number,
  sourceId: Hex,
  terminalHash: Hex,
  beneficiary: Address
): Hex {
  return keccak256(
    encodeAbiParameters(
      parseAbiParameters('bytes32, bytes32, uint8, bytes32, bytes32, address'),
      [POSITION_ID_V1_TYPEHASH, custodyBoundaryId, kind, sourceId, terminalHash, beneficiary]
    )
  )
}

export function custodyBoundaryId(
  chainId: bigint,
  protocolVersion: number,
  ledger: Address,
  token: Address
): Hex {
  return keccak256(
    encodeAbiParameters(parseAbiParameters('bytes32, uint64, uint32, address, address'), [
      CUSTODY_BOUNDARY_TYPEHASH,
      chainId,
      protocolVersion,
      ledger,
      token,
    ])
  )
}

export function digest(domainSeparator: Hex, structHash: Hex): Hex {
  return keccak256(concat(['0x1901', domainSeparator, structHash]))
}

// ── EIP-712 Domain Separators ────────────────────────────────────────────────

const EIP712_DOMAIN_TYPEHASH = keccak256(
  toHex('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)')
)

export function escrowDomainSeparator(chainId: bigint, escrowAddress: Address): Hex {
  const nameHash = keccak256(toHex('PluriSwap'))
  const versionHash = keccak256(toHex('2'))
  return keccak256(
    encodeAbiParameters(parseAbiParameters('bytes32, bytes32, bytes32, uint256, address'), [
      EIP712_DOMAIN_TYPEHASH,
      nameHash,
      versionHash,
      chainId,
      escrowAddress,
    ])
  )
}

export function ledgerDomainSeparator(chainId: bigint, ledgerAddress: Address): Hex {
  const nameHash = keccak256(toHex('PluriSwapCreditLedger'))
  const versionHash = keccak256(toHex('2'))
  return keccak256(
    encodeAbiParameters(parseAbiParameters('bytes32, bytes32, bytes32, uint256, address'), [
      EIP712_DOMAIN_TYPEHASH,
      nameHash,
      versionHash,
      chainId,
      ledgerAddress,
    ])
  )
}
