import { expect, it } from "vitest";
import { expectedDomainSeparator } from "./probe.ts";

it("hashDomain is 32 bytes and changes with verifyingContract", () => {
  const a = expectedDomainSeparator(421614, "0x9b00D29E1c4B6D9F206D28aE767461d6D060499E");
  const b = expectedDomainSeparator(421614, "0xed094F54b5e0d4812ECD9c99720A0e5a669071F8");
  const c = expectedDomainSeparator(31337, "0x9b00D29E1c4B6D9F206D28aE767461d6D060499E");
  expect(a).toMatch(/^0x[0-9a-f]{64}$/);
  expect(a).not.toBe(b);
  expect(a).not.toBe(c);
});
