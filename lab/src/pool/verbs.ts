import type { Hex } from "viem";
import type { HexAddress } from "../addressbook/types.ts";
import type { Envelope } from "../consent/eip712.ts";
import type { PackageMods } from "../deal/types.ts";
import { writeContractTx } from "../verbs/chain.ts";
import { poolAbi } from "./abi.ts";

function toHa(env: Envelope) {
  return {
    terms: {
      holder: env.terms.holder,
      controller: env.terms.controller,
      provider: env.terms.provider,
      token: env.terms.token,
      principal: env.terms.principal,
      fiatDuration: env.terms.fiatDuration,
      releaseDuration: env.terms.releaseDuration,
      disputeDuration: env.terms.disputeDuration,
      arbitrationDuration: env.terms.arbitrationDuration,
      packageIds: env.terms.packageIds,
    },
    nonce: env.nonce,
    deadline: env.deadline,
  };
}

export async function poolDeposit(args: {
  rpcUrl: string;
  chainId: number;
  pool: HexAddress;
  pk: string;
  amount: bigint;
}): Promise<Hex> {
  return writeContractTx({
    ...args,
    address: args.pool,
    abi: poolAbi,
    functionName: "deposit",
    functionArgs: [args.amount],
  });
}

export async function poolAuthorize(args: {
  rpcUrl: string;
  chainId: number;
  pool: HexAddress;
  pk: string;
  ha: Envelope;
  /// Every module the signed `ha.terms.packageIds` refers to, exactly as the activation will require.
  /// `Pool.authorize` runs `Packages.resolve`, so a REPUTATION deal authorized with that slot empty reverts
  /// `UnknownPackage` instead of reserving no activation fee and leaving the vault short.
  mods: PackageMods;
}): Promise<Hex> {
  return writeContractTx({
    ...args,
    address: args.pool,
    abi: poolAbi,
    functionName: "authorize",
    functionArgs: [toHa(args.ha), args.mods],
  });
}

export async function poolUnlock(args: {
  rpcUrl: string;
  chainId: number;
  pool: HexAddress;
  pk: string;
  nonce: bigint;
}): Promise<Hex> {
  return writeContractTx({
    ...args,
    address: args.pool,
    abi: poolAbi,
    functionName: "unlock",
    functionArgs: [args.nonce],
  });
}

export async function poolReconcile(args: {
  rpcUrl: string;
  chainId: number;
  pool: HexAddress;
  pk: string;
  nonce: bigint;
  providerNonce: bigint;
  controllerNonce: bigint;
}): Promise<Hex> {
  return writeContractTx({
    ...args,
    address: args.pool,
    abi: poolAbi,
    functionName: "reconcile",
    functionArgs: [args.nonce, args.providerNonce, args.controllerNonce],
  });
}
