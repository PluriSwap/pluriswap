import { decodeAbiParameters } from "viem";
import { describe, expect, it } from "vitest";
import { encodeMockProof } from "./proof.ts";

describe("encodeMockProof", () => {
  it("round-trips dealId and nullifier as VerifierMock would abi.decode", () => {
    const dealId = "0x1111111111111111111111111111111111111111111111111111111111111111";
    const nullifier = "0x2222222222222222222222222222222222222222222222222222222222222222";
    const proof = encodeMockProof(dealId, nullifier);
    const [d, n] = decodeAbiParameters(
      [{ type: "bytes32" }, { type: "bytes32" }],
      proof,
    );
    expect(d).toBe(dealId);
    expect(n).toBe(nullifier);
  });
});
