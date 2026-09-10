import { expect, it } from "vitest";
import { parseDeploymentFile } from "../addressbook/load.ts";
import { isHexBytes32 } from "./types.ts";

it("collects *DealId labels only from the matching escrow set", () => {
  const core = parseDeploymentFile("sepolia.json", {
    chainId: 421614,
    escrow: "0x9b00D29E1c4B6D9F206D28aE767461d6D060499E",
    releasedDealId: "0x41a5306ebd5a36649655d60c43d5fef98e6bff1fc2e005b18b6a9eb8013c6162",
    cancelledDealId: "0xe9a0b756ed3f0322b163e1b14038ffedb922ddb17c2581c6af9db0cab9b6877a",
  });
  const packaged = parseDeploymentFile("sepolia-packages.json", {
    chainId: 421614,
    escrow: "0xed094F54b5e0d4812ECD9c99720A0e5a669071F8",
    zkDealId: "0x11c4f5df5c80e1eb5b0d135d7a856d892435f7fa2c6f1a23276551770bf2bc75",
  });
  const from = (set: typeof core) =>
    Object.entries(set.labels).filter(([k, v]) => /dealid$/i.test(k) && isHexBytes32(v));
  expect(from(core).map(([k]) => k).sort()).toEqual(["cancelledDealId", "releasedDealId"]);
  expect(from(packaged).map(([k]) => k)).toEqual(["zkDealId"]);
  expect(from(core).every(([, v]) => v !== from(packaged)[0]?.[1])).toBe(true);
});
