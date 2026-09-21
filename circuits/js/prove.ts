// The proof-fixture generator of the private layer (PLURISWAP.md §3.15.9): runs the pinned
// toolchain (nargo + bb, see circuits/README.md) end to end for the circuits of the current
// phase and writes, per circuit:
//
//   * crates/<circuit>/Prover.toml      — the witness, from the registry and prepare
//                                         sections of test/fixtures/vectors.json (all
//                                         keccak-derived inputs REDUCED mod p: nargo
//                                         rejects raw values >= p, so the prover boundary
//                                         is where the pinned mod-p rule reduces);
//   * test/fixtures/proofs/<name>.json — {"proof_with_public_inputs": <bare hex of proof ||
//                                         public_inputs>} (the exact blob the adapters split;
//                                         BARE hex because vm.parseJsonBytes prepends its
//                                         own "0x" — a prefixed value double-prefixes and
//                                         fails to parse);
//   * verifiers/src/<C>.sol              — the bb-generated optimized Honk verifier, its
//                                         contract renamed per circuit (two generated files
//                                         cannot both declare `HonkVerifier` in one solc
//                                         invocation), COMMITTED in the self-contained
//                                         `verifiers/` project (via_ir off — the generated
//                                         dispatchers do not compile under the main tree's
//                                         via_ir, and the main tree needs it);
//   * test/fixtures/verifiers/<name>.json — {"initcode": <bare hex>} — the verifier INITCODE,
//                                         extracted from the verifiers project artifact. The
//                                         adapters deploy from it; nothing in the main build
//                                         links the generated contracts.
//
// Every step asserts success (bb verify natively, contract renames, artifact extraction):
// a fixture that would silently drift is worse than no fixture. Committed outputs mean CI
// never needs this toolchain. The witness, public inputs, verifier contracts and initcode
// are byte-deterministic across runs; the PROOF itself is not (fresh ZK blinding per
// prove — each run's fixture is a different valid proof of the same statement).
//
// Run: bun circuits:prove

import { execSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { P, modP } from "./lib/fields.ts";

const REPO = join(import.meta.dir, "../..");
const CIRCUITS = join(REPO, "circuits");
const BIN = join(process.env.HOME ?? "", ".pluri-zk/bin");

// ---------------------------------------------------------------- the circuits (one row each)

type Circuit = {
  /** nargo package name (crates/<name>) */
  name: string;
  /** the Solidity verifier contract this circuit's vk generates (file and contract) */
  contract: string;
  /** public input count in the proof blob (order = the circuit's pub signature order) */
  pubs: number;
  /** Prover.toml content, from the vectors fixture (reduced where keccak-derived) */
  proverToml: (v: Vectors) => string;
};

type RegistryVectors = {
  depth: number;
  registry_id: string;
  hsk: string;
  identity_commitment: string;
  empty_root: string;
  siblings: string[];
  indices: number[];
  root: string;
  sample_hn: string;
  sample_sk_id: string;
  sample_s: string;
  sample_leaf0: string;
};

type PrepareVectors = {
  depth: number;
  decimals: string;
  principal: string;
  token: string;
  sk_id: string;
  deal_id: string;
  salt: string;
  new_salt: string;
  s: string;
  leaf0: string;
  siblings: string[];
  indices: number[];
  root: string;
  deal_subject: string;
  null_rep: string;
  new_leaf: string;
  score: string;
  cap: string;
};

type Vectors = { registry: RegistryVectors; prepare: PrepareVectors };

const CIRCUIT_LIST: Circuit[] = [
  {
    name: "register_humanity",
    contract: "RegisterHumanityVerifier",
    pubs: 3,
    proverToml: (v) =>
      toml([
        `h_n = ${str(v.registry.sample_hn)}`,
        `root = ${str(v.registry.root)}`,
        `registry_id = ${str(modP(BigInt(v.registry.registry_id)))}`,
        `hsk = ${str(modP(BigInt(v.registry.hsk)))}`,
        `siblings = [${v.registry.siblings.map(str).join(", ")}]`,
        `indices = [${v.registry.indices.join(", ")}]`,
      ]),
  },
  {
    name: "register_account",
    contract: "RegisterAccountVerifier",
    pubs: 3,
    proverToml: (v) =>
      toml([
        `h_n = ${str(v.registry.sample_hn)}`,
        `leaf0 = ${str(v.registry.sample_leaf0)}`,
        `registry_id = ${str(modP(BigInt(v.registry.registry_id)))}`,
        `hsk = ${str(modP(BigInt(v.registry.hsk)))}`,
        `sk_id = ${str(v.registry.sample_sk_id)}`,
      ]),
  },
  {
    name: "prepare_passport",
    contract: "PreparePassportVerifier",
    pubs: 2,
    proverToml: (v) =>
      toml([
        `subject = ${str(v.prepare.deal_subject)}`,
        `rep_root = ${str(v.prepare.root)}`,
        `sk_id = ${str(v.prepare.sk_id)}`,
        `deal_id = ${str(modP(BigInt(v.prepare.deal_id)))}`,
        // The account's current leaf is the registered genesis leaf0: all counters zero,
        // token zero, salt = the reduced hsk, version zero.
        `count = "0"`,
        `volume = "0"`,
        `penalty = "0"`,
        `in_flight = "0"`,
        `leaf_token = "0"`,
        `salt = ${str(modP(BigInt(v.prepare.salt)))}`,
        `version = "0"`,
        `siblings = [${v.prepare.siblings.map(str).join(", ")}]`,
        `indices = [${v.prepare.indices.join(", ")}]`,
      ]),
  },
  {
    name: "prepare_admit",
    contract: "PrepareAdmitVerifier",
    pubs: 8,
    proverToml: (v) =>
      toml([
        `subject = ${str(v.prepare.deal_subject)}`,
        `new_leaf = ${str(v.prepare.new_leaf)}`,
        `nullifier = ${str(v.prepare.null_rep)}`,
        `token = ${str(v.prepare.token)}`,
        `principal = ${str(v.prepare.principal)}`,
        // V2 has no vault: the base cap column, lockCommit identically zero.
        `lock_commit = "0"`,
        `rep_root = ${str(v.prepare.root)}`,
        `decimals = ${str(v.prepare.decimals)}`,
        `sk_id = ${str(v.prepare.sk_id)}`,
        `deal_id = ${str(modP(BigInt(v.prepare.deal_id)))}`,
        `count = "0"`,
        `volume = "0"`,
        `penalty = "0"`,
        `in_flight = "0"`,
        `leaf_token = "0"`,
        `salt = ${str(modP(BigInt(v.prepare.salt)))}`,
        `version = "0"`,
        `new_salt = ${str(modP(BigInt(v.prepare.new_salt)))}`,
        `siblings = [${v.prepare.siblings.map(str).join(", ")}]`,
        `indices = [${v.prepare.indices.join(", ")}]`,
      ]),
  },
];

// ---------------------------------------------------------------- shell + toml helpers

function sh(cwd: string, command: string): string {
  const env = { ...process.env, PATH: `${BIN}:${process.env.PATH ?? ""}` };
  return execSync(command, { cwd, env, stdio: ["ignore", "pipe", "pipe"] }).toString();
}

function toml(lines: string[]): string {
  return lines.join("\n") + "\n";
}

function str(x: bigint | string): string {
  return `"${x}"`;
}

function hex(bytes: Buffer): string {
  // Bare hex, no "0x": forge's vm.parseJsonBytes prepends its own prefix — a prefixed
  // value double-prefixes and fails to parse (the same quirk the pilot hit).
  return bytes.toString("hex");
}

// ---------------------------------------------------------------- main

function main() {
  const vectors = JSON.parse(readFileSync(join(REPO, "test/fixtures/vectors.json"), "utf8")) as Vectors;

  console.log("compiling circuits...");
  sh(CIRCUITS, "nargo compile");
  for (const circuit of CIRCUIT_LIST) {
    console.log(`=== ${circuit.name} ===`);
    writeFileSync(join(CIRCUITS, "crates", circuit.name, "Prover.toml"), circuit.proverToml(vectors));
    sh(join(CIRCUITS, "crates", circuit.name), "nargo execute");

    const vkDir = join(CIRCUITS, "target", `${circuit.name}_vk`);
    const proofDir = join(CIRCUITS, "target", `${circuit.name}_proof`);
    const bytecode = join(CIRCUITS, "target", `${circuit.name}.json`);
    const witness = join(CIRCUITS, "target", `${circuit.name}.gz`);
    sh(CIRCUITS, `bb write_vk -b ${bytecode} -o ${vkDir} -t evm`);
    sh(CIRCUITS, `bb prove -b ${bytecode} -w ${witness} -k ${join(vkDir, "vk")} -o ${proofDir} -t evm`);
    const verified = sh(
      CIRCUITS,
      `bb verify -k ${join(vkDir, "vk")} -p ${join(proofDir, "proof")} -i ${join(proofDir, "public_inputs")} -t evm 2>&1`,
    );
    if (!verified.includes("Proof verified successfully")) {
      throw new Error(`${circuit.name}: bb verify did not pass`);
    }
    console.log(`  bb verify: ok`);

    // The proof fixture: exactly the blob an adapter splits (proof || public inputs).
    const proof = readFileSync(join(proofDir, "proof"));
    const pubs = readFileSync(join(proofDir, "public_inputs"));
    const expectedPubs = circuit.pubs * 32;
    if (pubs.length !== expectedPubs) {
      throw new Error(`${circuit.name}: expected ${expectedPubs} public input bytes, got ${pubs.length}`);
    }
    const fixtureDir = join(REPO, "test/fixtures/proofs");
    mkdirSync(fixtureDir, { recursive: true });
    const fixture = { proof_with_public_inputs: hex(Buffer.concat([proof, pubs])) };
    writeFileSync(
      join(fixtureDir, `${circuit.name}.json`),
      JSON.stringify(fixture, null, 2) + "\n",
    );
    console.log(`  proof fixture: ${pubs.length} bytes of public inputs (== ${circuit.pubs} Field elements)`);

    // The verifier contract: bb writes `HonkVerifier`/`IVerifier`; two circuits cannot both
    // declare those names in one solc run, so each file is renamed to its circuit's contract.
    const verifierPath = join(REPO, "verifiers", "src", `${circuit.contract}.sol`);
    sh(
      CIRCUITS,
      `bb write_solidity_verifier -k ${join(vkDir, "vk")} -o ${verifierPath} -t evm --optimized`,
    );
    renameVerifierContracts(verifierPath, circuit.contract);
    console.log(`  verifier: verifiers/src/${circuit.contract}.sol`);
  }

  // Initcode fixtures from the verifiers subproject (its own foundry.toml compiles the
  // generated contracts with via_ir off — see verifiers/foundry.toml).
  console.log("building the verifiers project...");
  sh(join(REPO, "verifiers"), "forge build");
  const initcodeDir = join(REPO, "test/fixtures/verifiers");
  mkdirSync(initcodeDir, { recursive: true });
  for (const circuit of CIRCUIT_LIST) {
    const artifact = join(
      REPO,
      "verifiers",
      "out",
      `${circuit.contract}.sol`,
      `${circuit.contract}.json`,
    );
    if (!existsSync(artifact)) {
      throw new Error(`the verifiers project did not produce ${artifact}`);
    }
    const object = JSON.parse(readFileSync(artifact, "utf8")).bytecode.object;
    if (typeof object !== "string" || object.length === 0) {
      throw new Error(`${circuit.contract}: no initcode in artifact`);
    }
    writeFileSync(
      join(initcodeDir, `${circuit.name}.json`),
      JSON.stringify({ initcode: object }, null, 2) + "\n" // artifact object is bare hex,
    );
    console.log(`  initcode: test/fixtures/verifiers/${circuit.name}.json`);
  }
  console.log("done.");
}

/** Rename the generated `HonkVerifier`/`IVerifier` to this circuit's own names (in place). */
function renameVerifierContracts(path: string, contract: string): void {
  const generated = readFileSync(path, "utf8");
  const renamed = generated
    .replaceAll("HonkVerifier", contract)
    .replaceAll("IVerifier", `I${contract}`);
  if (renamed === generated) {
    throw new Error(`${path}: no contract names found to rename`);
  }
  writeFileSync(path, renamed);
}

main();
