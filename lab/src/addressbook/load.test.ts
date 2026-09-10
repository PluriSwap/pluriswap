import { describe, expect, it } from "vitest";
import { parseDeploymentFile, recintosFromSets } from "./load.ts";

const sepoliaCore = {
  chainId: 421614,
  escrow: "0x9b00D29E1c4B6D9F206D28aE767461d6D060499E",
  testToken: "0x3E9a38A25d1A02126Ffe07f1B4d076196952d667",
  releasedDealId: "0x41a5306ebd5a36649655d60c43d5fef98e6bff1fc2e005b18b6a9eb8013c6162",
};

const sepoliaPackages = {
  chainId: 421614,
  escrow: "0xed094F54b5e0d4812ECD9c99720A0e5a669071F8",
  testToken: "0x3E9a38A25d1A02126Ffe07f1B4d076196952d667",
  passport: "0xCAD1300DbF23D65B97DD556e8bffC0873D15387a",
};

const sepoliaPaths = {
  chainId: 421614,
  escrow: "0x1Ab09F49431f952f22F29f54Dc2284F75640325E",
  testToken: "0x2F975ee29b62f33155851c2BF317fE3b2395b265",
};

const sepoliaPool = {
  chainId: 421614,
  escrow: "0x9b00D29E1c4B6D9F206D28aE767461d6D060499E",
  testToken: "0x3E9a38A25d1A02126Ffe07f1B4d076196952d667",
  pool: "0xcDC26A02540f4C0b422E8eC59fF3f2a9",
};

const sepoliaKlerosLive = {
  chainId: 421614,
  adapter: "0xB623f158bE5d91bA067Cd83C341b2C671B69E578",
  dealId: "0x8f97baa86e62c11872eab66046f699dac33e0427444fe234bcd1d06387b8ce2c",
  klerosCore: "0xE8442307d36e9bf6aB27F1A009F95CE8E11C3479",
};

const poolFactory = {
  chainId: 421614,
  factory: "0xB42d034C56217827Df5F5B622835D68496A53B28",
  implementation: "0x9B0eB05C0243541Ae75D3AA25b6f81a69a16f86e",
  officialCodehash: "0x0b93fd958c73b82407c483b42d52a653ac58afe75ed302172c4713db4bb89193",
};

describe("parseDeploymentFile", () => {
  it("promotes a JSON with escrow to a Recinto set and keeps testToken on that file", () => {
    const set = parseDeploymentFile("sepolia.json", sepoliaCore);
    expect(set.isRecinto).toBe(true);
    expect(set.escrow).toBe("0x9b00D29E1c4B6D9F206D28aE767461d6D060499E");
    expect(set.testToken).toBe("0x3E9a38A25d1A02126Ffe07f1B4d076196952d667");
    expect(set.labels.releasedDealId).toMatch(/^0x41a5/);
  });

  it("does not promote sepolia-kleros.json (live dispute, no escrow)", () => {
    const set = parseDeploymentFile("sepolia-kleros.json", sepoliaKlerosLive);
    expect(set.isRecinto).toBe(false);
    expect(set.escrow).toBeNull();
    expect(set.labels.klerosCore).toBeTruthy();
  });

  it("does not promote pool-factory JSON (no escrow)", () => {
    const set = parseDeploymentFile("sepolia-pool-factory.json", poolFactory);
    expect(set.isRecinto).toBe(false);
    expect(set.escrow).toBeNull();
    expect(set.labels.factory).toBeTruthy();
  });
});

describe("recintosFromSets", () => {
  it("collapses files that share (chainId, escrow) and never merges testToken across files", () => {
    const sets = [
      parseDeploymentFile("sepolia.json", sepoliaCore),
      parseDeploymentFile("sepolia-packages.json", sepoliaPackages),
      parseDeploymentFile("sepolia-paths.json", sepoliaPaths),
      parseDeploymentFile("sepolia-pool.json", sepoliaPool),
      parseDeploymentFile("sepolia-kleros.json", sepoliaKlerosLive),
      parseDeploymentFile("sepolia-pool-factory.json", poolFactory),
    ];
    const recintos = recintosFromSets(sets);
    expect(recintos).toHaveLength(3);

    const core = recintos.find((r) => r.escrow === "0x9b00D29E1c4B6D9F206D28aE767461d6D060499E");
    expect(core?.sources.sort()).toEqual(["sepolia-pool.json", "sepolia.json"].sort());

    const paths = recintos.find((r) => r.escrow === "0x1Ab09F49431f952f22F29f54Dc2284F75640325E");
    expect(paths?.testTokens).toEqual([
      { sourceFile: "sepolia-paths.json", token: "0x2F975ee29b62f33155851c2BF317fE3b2395b265" },
    ]);

    const packaged = recintos.find((r) => r.escrow === "0xed094F54b5e0d4812ECD9c99720A0e5a669071F8");
    expect(packaged?.testTokens[0]?.token).toBe("0x3E9a38A25d1A02126Ffe07f1B4d076196952d667");
    expect(packaged?.testTokens[0]?.token).not.toBe(paths?.testTokens[0]?.token);
  });
});
