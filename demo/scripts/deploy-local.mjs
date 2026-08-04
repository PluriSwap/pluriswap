#!/usr/bin/env node
/**
 * Deploy PluriSwap Core to local Anvil and generate .env.local for the frontend.
 *
 * Prerequisites:
 *   1. Anvil running: anvil --chain-id 31337
 *   2. forge build (to compile contracts)
 *
 * Usage: node scripts/deploy-local.mjs
 */

import { createWalletClient, createPublicClient, http, parseEther, encodeDeployData } from 'viem'
import { privateKeyToAccount } from 'viem/accounts'
import { readFileSync, writeFileSync } from 'fs'
import { join, dirname } from 'path'
import { fileURLToPath } from 'url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const ROOT = join(__dirname, '..', '..')
const DEMO = join(__dirname, '..')

// Anvil account #0
const DEPLOYER_KEY = '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80'
const RPC_URL = 'http://localhost:8545'
const CHAIN_ID = 31337n

const account = privateKeyToAccount(DEPLOYER_KEY)
const publicClient = createPublicClient({ transport: http(RPC_URL) })
const walletClient = createWalletClient({ account, transport: http(RPC_URL) })

// Load compiled artifacts
function loadArtifact(name) {
  const path = join(ROOT, 'out', `${name}.sol`, `${name}.json`)
  const data = JSON.parse(readFileSync(path, 'utf8'))
  return { abi: data.abi, bytecode: data.bytecode.object }
}

async function deploy(name, args = []) {
  const { abi, bytecode } = loadArtifact(name)
  const hash = await walletClient.deployContract({
    abi,
    bytecode,
    args,
  })
  const receipt = await publicClient.waitForTransactionReceipt({ hash })
  console.log(`  ${name}: ${receipt.contractAddress}`)
  return receipt.contractAddress
}

async function main() {
  console.log('Deploying PluriSwap Core to Anvil...\n')

  // 1. Deploy MockERC20
  console.log('1. Deploying MockERC20...')
  const token = await deploy('MockERC20')

  // 2. Deploy CoreDeployer
  console.log('2. Deploying CoreDeployer...')
  const deployer = await deploy('CoreDeployer', [
    1, // DIRECT_CORE_DEPLOYER
    2, // protocolVersion
    '0x' + '63'.padStart(64, '0'), // charterHash
    '0x' + '64'.padStart(64, '0'), // techSpecHash
    account.address, // coordinatorOwner
    account.address, // deploymentOperator
    {
      buildHash: '0x' + '01'.padStart(64, '0'),
      plannedDeploymentMethodHash: '0x' + '02'.padStart(64, '0'),
      coreDeployerCreationCodeHash: '0x' + '03'.padStart(64, '0'),
      factoryCreationCodeHash: '0x' + '00'.padStart(64, '0'),
      ledgerCreationCodeHash: '0x' + '05'.padStart(64, '0'),
      coordinatorCreationCodeHash: '0x' + '06'.padStart(64, '0'),
      escrowCreationCodeHash: '0x' + '07'.padStart(64, '0'),
      capabilityHash: '0x' + '08'.padStart(64, '0'),
      governanceHash: '0x' + '09'.padStart(64, '0'),
      predecessorIntentHash: '0x' + '00'.padStart(64, '0'),
    },
  ])

  // 3. Read predicted addresses from deployer
  console.log('3. Reading predicted addresses...')
  const deployerAbi = loadArtifact('CoreDeployer').abi
  const [ledgerAddr, coordinatorAddr, escrowAddr, intentHash] = await Promise.all([
    publicClient.readContract({ address: deployer, abi: deployerAbi, functionName: 'ledger' }),
    publicClient.readContract({ address: deployer, abi: deployerAbi, functionName: 'coordinator' }),
    publicClient.readContract({ address: deployer, abi: deployerAbi, functionName: 'escrow' }),
    publicClient.readContract({ address: deployer, abi: deployerAbi, functionName: 'intentHash' }),
  ])
  console.log(`  Predicted Ledger: ${ledgerAddr}`)
  console.log(`  Predicted Coordinator: ${coordinatorAddr}`)
  console.log(`  Predicted Escrow: ${escrowAddr}`)

  // 4. Deploy triad via deployTriad
  console.log('4. Deploying triad...')
  const chainId = CHAIN_ID

  const ledgerInit = encodeDeployData({
    abi: loadArtifact('CreditLedger').abi,
    bytecode: loadArtifact('CreditLedger').bytecode,
    args: [escrowAddr, coordinatorAddr, chainId],
  })
  const coordinatorInit = encodeDeployData({
    abi: loadArtifact('Coordinator').abi,
    bytecode: loadArtifact('Coordinator').bytecode,
    args: [chainId, escrowAddr, account.address],
  })
  const escrowInit = encodeDeployData({
    abi: loadArtifact('CoreEscrow').abi,
    bytecode: loadArtifact('CoreEscrow').bytecode,
    args: [
      chainId,
      2, // protocolVersion
      '0x' + '63'.padStart(64, '0'),
      '0x' + '64'.padStart(64, '0'),
      ledgerAddr,
      coordinatorAddr,
      intentHash,
    ],
  })

  const hash = await walletClient.writeContract({
    address: deployer,
    abi: deployerAbi,
    functionName: 'deployTriad',
    args: [ledgerInit, coordinatorInit, escrowInit],
  })
  await publicClient.waitForTransactionReceipt({ hash })
  console.log('  Triad deployed!')

  // 5. Mint tokens to Anvil accounts
  console.log('5. Minting MOCK tokens...')
  const tokenAbi = loadArtifact('MockERC20').abi
  const accounts = [
    '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266',
    '0x70997970C51812dc3A010C7d01b50e0d17dc79C8',
  ]
  for (const acc of accounts) {
    const mintHash = await walletClient.writeContract({
      address: token,
      abi: tokenAbi,
      functionName: 'mint',
      args: [acc, parseEther('10000')],
    })
    await publicClient.waitForTransactionReceipt({ hash: mintHash })
    console.log(`  Minted 10,000 MOCK to ${acc}`)
  }

  // 6. Write .env.local
  console.log('6. Writing .env.local...')
  const envContent = `# Auto-generated by deploy-local.mjs
NEXT_PUBLIC_DEPLOYER_ADDRESS=${deployer}
NEXT_PUBLIC_ESCROW_ADDRESS=${escrowAddr}
NEXT_PUBLIC_LEDGER_ADDRESS=${ledgerAddr}
NEXT_PUBLIC_COORDINATOR_ADDRESS=${coordinatorAddr}
NEXT_PUBLIC_TOKEN_ADDRESS=${token}
NEXT_PUBLIC_CHAIN_ID=${CHAIN_ID}
NEXT_PUBLIC_RPC_URL=http://localhost:8545
`
  writeFileSync(join(DEMO, '.env.local'), envContent)
  console.log('  Written demo/.env.local')

  console.log('\n✅ Deployment complete!')
  console.log(`  Escrow: ${escrowAddr}`)
  console.log(`  Ledger: ${ledgerAddr}`)
  console.log(`  Token:  ${token}`)
  console.log('\nRun: cd demo && npm run dev')
}

main().catch(console.error)
