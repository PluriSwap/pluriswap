import type { Hex } from "viem";
import type { HexAddress } from "../addressbook/types.ts";
import type { Envelope } from "../consent/eip712.ts";
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
  /// The REPUTATION module named by `ha.terms.packageIds`, or the zero address for a deal that has none.
  /// `Pool.authorize` has no overload that defaults it: an unreserved activation fee either fails the
  /// activation or is paid out of another authorization's share of the aggregate allowance and never booked.
  reputation: HexAddress;
}): Promise<Hex> {
  return writeContractTx({
    ...args,
    address: args.pool,
    abi: poolAbi,
    functionName: "authorize",
    functionArgs: [toHa(args.ha), args.reputation],
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
