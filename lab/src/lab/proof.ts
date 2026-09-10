import { encodeAbiParameters, type Hex } from "viem";
import type { HexBytes32 } from "../addressbook/types.ts";

/** VerifierMock.verify: abi.decode(proof, (bytes32 dealId, bytes32 paymentNullifier)). Not a circuit. */
export function encodeMockProof(dealId: HexBytes32, nullifier: HexBytes32): Hex {
  return encodeAbiParameters(
    [{ type: "bytes32" }, { type: "bytes32" }],
    [dealId, nullifier],
  );
}
