import { createPublicClient, hashDomain, http, isAddress, type Hex } from "viem";
import { EIP712_NAME, EIP712_VERSION, type HexAddress, type HexBytes32 } from "../addressbook/types.ts";
import { iescrowAbi } from "./iescrow.ts";

export type RecintoProbe = {
  rpcChainId: number | null;
  domainSeparator: HexBytes32 | null;
  expectedDomainSeparator: HexBytes32 | null;
  domainMatches: boolean | null;
  codePresent: boolean | null;
  error: string | null;
};

export function expectedDomainSeparator(chainId: number, escrow: HexAddress): HexBytes32 {
  return hashDomain({
    domain: {
      name: EIP712_NAME,
      version: EIP712_VERSION,
      chainId: BigInt(chainId),
      verifyingContract: escrow,
    },
    types: {
      EIP712Domain: [
        { name: "name", type: "string" },
        { name: "version", type: "string" },
        { name: "chainId", type: "uint256" },
        { name: "verifyingContract", type: "address" },
      ],
    },
  }) as HexBytes32;
}

export async function probeRecinto(rpcUrl: string, escrow: string): Promise<RecintoProbe> {
  const empty: RecintoProbe = {
    rpcChainId: null,
    domainSeparator: null,
    expectedDomainSeparator: null,
    domainMatches: null,
    codePresent: null,
    error: null,
  };
  if (!rpcUrl.trim()) return { ...empty, error: "RPC vacío" };
  if (!isAddress(escrow)) return { ...empty, error: "escrow no es una address" };

  try {
    const client = createPublicClient({ transport: http(rpcUrl) });
    const rpcChainId = await client.getChainId();
    const expected = expectedDomainSeparator(rpcChainId, escrow as HexAddress);
    const bytecode = await client.getCode({ address: escrow as HexAddress });
    const codePresent = Boolean(bytecode && bytecode !== "0x");
    if (!codePresent) {
      return {
        rpcChainId,
        domainSeparator: null,
        expectedDomainSeparator: expected,
        domainMatches: false,
        codePresent: false,
        error: "sin bytecode en esta chain",
      };
    }
    const domainSeparator = (await client.readContract({
      address: escrow as HexAddress,
      abi: iescrowAbi,
      functionName: "domainSeparator",
    })) as Hex;
    const live = domainSeparator as HexBytes32;
    return {
      rpcChainId,
      domainSeparator: live,
      expectedDomainSeparator: expected,
      domainMatches: live.toLowerCase() === expected.toLowerCase(),
      codePresent: true,
      error: null,
    };
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return { ...empty, error: message };
  }
}
