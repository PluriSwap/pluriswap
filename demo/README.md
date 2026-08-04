# PluriSwap Core Demo

Interactive frontend for testing the PluriSwap Mandatory Core protocol against a local Anvil node.

## Quick Start

### 1. Start Anvil

```bash
anvil --chain-id 31337
```

### 2. Compile contracts

```bash
forge build
```

### 3. Deploy to Anvil

```bash
cd demo
npm run deploy:local
```

This deploys:
- `MockERC20` (test token)
- `CoreDeployer` (factory)
- `CreditLedger`, `Coordinator`, `CoreEscrow` (triad)

It also mints 10,000 MOCK tokens to Anvil accounts #0 and #1, and writes `demo/.env.local` with the deployed addresses.

### 4. Start the frontend

```bash
cd demo
npm run dev
```

Open http://localhost:3000

## Usage

### Connect
- Use Anvil account #0 (Holder) or #1 (Provider)
- Or paste any Anvil private key

### Create a Deal (Holder)
1. Fill in principal, fees, durations
2. Preview settlement split
3. Click "Create Deal"
4. Provider counter-signs (switch to Provider account)
5. Deal is activated, tokens locked in Ledger

### Provider Actions
- **Mark Fiat Sent** — starts release timer
- **Cancel** (before fiat sent) — returns principal to holder

### Holder Actions
- **Release to Provider** — settles deal, provider gets paid
- **Open Dispute** — starts dispute timer
- **Claim Timeout** — after release deadline, claim funds

### Dispute
- After dispute deadline, anyone can trigger **Dispute Timeout**
- Splits principal according to `disputeTimeoutProviderBps`

### Withdraw
- Go to "Your Positions"
- Click "Withdraw" on any matured position
- Tokens transferred to your wallet

### Time Travel
- Use "+1 hour", "+1 day", "+1 week" to fast-forward Anvil time
- Use "Mine block" to trigger a new block

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│   CoreEscrow    │────▶│  CreditLedger   │────▶│   MockERC20     │
│  (state machine)│     │  (vault/positions)│   │  (test token)   │
└─────────────────┘     └─────────────────┘     └─────────────────┘
         │
         ▼
┌─────────────────┐
│   Coordinator   │
│  (planner only) │
└─────────────────┘
```

## Files

- `app/` — Next.js App Router pages
- `components/` — React components
- `lib/hashing.ts` — EIP-712 hashing (mirror of `DealHashing.sol`)
- `lib/planner.ts` — Terminal planning (mirror of `TerminalPlanning.sol`)
- `lib/types.ts` — TypeScript types (mirror of `DealTypes.sol`)
- `lib/contracts.ts` — Addresses, ABIs, Anvil helpers
- `scripts/deploy-local.mjs` — Deploy to Anvil

## Tests

The repo includes 6 E2E test scenarios in `test/EndToEnd.t.sol`:

| Scenario | Path |
|---|---|
| Happy Path | activate → markFiatSent → holderRelease → withdraw |
| Fiat Timeout | activate → warp → fiatTimeoutCancel → withdraw |
| Dispute Timeout | activate → markFiatSent → openDispute → warp → disputeTimeout → withdraw |
| Cosigned Release | activate → markFiatSent → mutualResolve → withdraw |
| Mutual Split | activate → markFiatSent → openDispute → mutualResolve(Split) → withdraw |
| Fees | activate with fees → markFiatSent → holderRelease → withdraw all |

Run: `forge test --match-contract EndToEndTest -vvv`
