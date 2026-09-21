// Generates the canonical vectors of the private layer (PLURISWAP.md §3.15.3, amended by
// the canonical-encoding decision) from the JS twin, and with them:
//
//   * test/fixtures/vectors.json      — the cross-language parity vectors (Solidity + JS),
//   * circuits/crates/pluri_commitments/src/constants_p2.nr / constants_p3.nr
//                                    — the vendored circomlib Poseidon parameters (t=2, t=3),
//   * circuits/crates/pluri_commitments/src/vectors.nr
//                                    — the same vectors as Noir constants (nargo test).
//
// One pass, one source of truth: the JS twin computes every output, the fixture and the
// Noir constants are the same data. The zero gate — poseidon2(1,2) == the circomlib
// vector pinned in test/PoseidonTree.t.sol — is asserted here before anything is written.
//
// Run: bun circuits:vectors

import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import circomlibConstants from "../../node_modules/circomlibjs/src/poseidon_constants.json" with { type: "json" };
import { P, dec, field, keccak } from "./lib/fields.ts";
import { poseidon1, poseidon2 } from "./lib/poseidon.ts";
import * as c from "./lib/commitments.ts";
import { IncrementalPoseidonTree } from "./lib/merkle.ts";

const REPO = join(import.meta.dir, "../..");
const CIRCOM_T3_1_2 =
  7853200120776062878684798364095072458815029376092732009249414926327459813530n;

// ---------------------------------------------------------------- sample values (pinned, test-only)

const SK_ID = 0x1234c0ffee5678ba0987654321fedcbadeadbeefcafebabe0123456789abcdefn;
const ANCHOR = 0x1234567890abcdef1234567890abcdef12345678n; // 20-byte address
const REGISTRY_ID = BigInt(keccak("pluri:humanity-registry:v1"));
const DEAL_ID = BigInt(keccak("pluri:deal:1"));
const NOTE_SALT = BigInt(keccak("pluri:note-salt:1"));
const LEAF_SALT = BigInt(keccak("pluri:leaf-salt:1"));
const LOCK_SALT = BigInt(keccak("pluri:lock-salt:1"));
const HANDLE_SALT = BigInt(keccak("pluri:handle-salt:1"));
const TOKEN_ID = 97433442488726861213578988847752201310395502865n;
// 20 bytes of 0x11 — a synthetic token id for the vectors, not a real token contract.
const AMOUNT = 1_500_000_000n;
const LOCK_AMOUNT = 150_000_000n;
const PRINCIPAL = 1_000_000_000n;
const COUNT = 3n;
const VOLUME = 750_000_000_000n;
const PENALTY = 0n;
const IN_FLIGHT = 100_000_000n;
const VERSION = 1n;

const TREE_DEPTH = 8;

// The humanity registry of V1: a per-human secret (never enrolled in the clear), the
// registry domain id, and the depth-20 enrollment tree. Pinned like everything else.
const REGISTRY_HSK = BigInt(keccak("pluri:registry-hsk:1"));
const REGISTRY_DEPTH = 20;

async function main() {
  // ---------------------------------------------------------------- zero gate
  const zero = await poseidon2(1n, 2n);
  if (zero !== CIRCOM_T3_1_2) {
    throw new Error(`zero gate failed: poseidon2(1,2) = ${zero}`);
  }
  console.log("zero gate: poseidon2(1,2) == circomlib vector ✓");

  // ---------------------------------------------------------------- poseidon primitive vectors
  const t2Vectors = [
    { inputs: ["0"], output: dec(await poseidon1(0n)) },
    { inputs: [dec(SK_ID)], output: dec(await poseidon1(SK_ID)) },
  ];
  const t3Vectors = [
    { inputs: ["1", "2"], output: dec(zero) },
    { inputs: ["0", "0"], output: dec(await poseidon2(0n, 0n)) },
    // The mod-p rule, pinned as a vector: a value one below p is itself (no reduction needed),
    // the pairing with 2 exercises the high edge of the field.
    { inputs: [dec(P - 1n), "2"], output: dec(await poseidon2(P - 1n, 2n)) },
  ];

  // ---------------------------------------------------------------- builder vectors
  const s = await c.accountCommitment(SK_ID);
  const note = await c.noteBond(SK_ID, TOKEN_ID, AMOUNT, NOTE_SALT);
  const leaf = await c.leafRep(s, COUNT, VOLUME, PENALTY, IN_FLIGHT, TOKEN_ID, LEAF_SALT, VERSION);
  const builders = {
    s: { sk_id: dec(SK_ID), output: dec(s) },
    hn: { anchor: dec(ANCHOR), registry_id: dec(REGISTRY_ID), output: dec(await c.hn(ANCHOR, REGISTRY_ID)) },
    deal_subject: {
      sk_id: dec(SK_ID),
      deal_id: dec(DEAL_ID),
      output: dec(await c.dealSubject(SK_ID, DEAL_ID)),
    },
    null_rep: { sk_id: dec(SK_ID), version: dec(VERSION), output: dec(await c.nullRep(SK_ID, VERSION)) },
    null_bond: { sk_id: dec(SK_ID), note_salt: dec(NOTE_SALT), output: dec(await c.nullBond(SK_ID, NOTE_SALT)) },
    handle_commit: {
      sk_id: dec(SK_ID),
      handle_salt: dec(HANDLE_SALT),
      output: dec(await c.handleCommit(SK_ID, HANDLE_SALT)),
    },
    note_bond: {
      sk_id: dec(SK_ID),
      token: dec(TOKEN_ID),
      amount: dec(AMOUNT),
      salt: dec(NOTE_SALT),
      output: dec(note),
    },
    lock_commit: {
      sk_id: dec(SK_ID),
      deal_id: dec(DEAL_ID),
      lock_amount: dec(LOCK_AMOUNT),
      salt: dec(LOCK_SALT),
      output: dec(await c.lockCommit(SK_ID, DEAL_ID, LOCK_AMOUNT, LOCK_SALT)),
    },
    leaf_rep: {
      s: dec(s),
      count: dec(COUNT),
      volume: dec(VOLUME),
      penalty: dec(PENALTY),
      in_flight: dec(IN_FLIGHT),
      token: dec(TOKEN_ID),
      salt: dec(LEAF_SALT),
      version: dec(VERSION),
      output: dec(leaf),
    },
  };

  // ---------------------------------------------------------------- tree vectors
  const tree = await IncrementalPoseidonTree.create(TREE_DEPTH);
  const leaves = [s, note, leaf];
  const roots: string[] = [];
  for (const leafValue of leaves) {
    roots.push(dec(await tree.insert(leafValue)));
  }
  const memberships = leaves.map((_, i) => {
    const m = tree.proofOf(i);
    return {
      index: m.index.toString(10),
      leaf: dec(m.leaf),
      siblings: m.siblings.map(dec),
      indices: m.indices,
      root: dec(m.root),
    };
  });
  const treeVectors = {
    depth: TREE_DEPTH,
    empty_root: dec(tree.rootHistory()[0]),
    leaves: leaves.map(dec),
    roots,
    memberships,
  };

  // ---------------------------------------------------------------- registry vectors (V1)
  // The humanity registry (Semaphore-style, §3.15.3 "Registro"): one enrollment per Passport
  // anchor; the enrolled value is an identity commitment `PoseidonT2(hsk)` for a per-human
  // secret hsk the registry never learns. The register circuits prove membership of that
  // commitment in this depth-20 tree, and derive `hn = PoseidonT3(hsk, registryId)` from it —
  // the registry model's reading of the pinned formula (the anchor is revealed at enroll, so
  // deriving hn from the anchor would be enumerable; hsk stays secret, so hn does not leak it).
  // The account link: the initial leaf's salt IS the hsk (§3.15.9 register_account as-built),
  // binding the burned hn to the account leaf through the shared secret.
  const regTree = await IncrementalPoseidonTree.create(REGISTRY_DEPTH);
  const identityCommitment = await c.accountCommitment(REGISTRY_HSK);
  const regRoot = await regTree.insert(identityCommitment);
  const regProof = regTree.proofOf(0);
  const sampleHn = await c.hn(REGISTRY_HSK, REGISTRY_ID);
  const sampleS = await c.accountCommitment(SK_ID);
  const sampleLeaf0 = await c.leafRep(sampleS, 0n, 0n, 0n, 0n, 0n, REGISTRY_HSK, 0n);
  const registryVectors = {
    depth: REGISTRY_DEPTH,
    registry_id: dec(REGISTRY_ID),
    hsk: dec(REGISTRY_HSK),
    identity_commitment: dec(identityCommitment),
    empty_root: dec(regTree.rootHistory()[0]),
    siblings: regProof.siblings.map(dec),
    indices: regProof.indices,
    root: dec(regRoot),
    sample_hn: dec(sampleHn),
    sample_sk_id: dec(SK_ID),
    sample_s: dec(sampleS),
    sample_leaf0: dec(sampleLeaf0),
  };

  const vectors = {
    provenance: {
      generator: "circuits/js/vectors.ts (bun circuits:vectors)",
      note: "canonical vectors of PLURISWAP.md §3.15.3; parity pinned by the circomlib poseidonperm_x5_254_3 vector",
      field: dec(P),
    },
    poseidon: { t2: t2Vectors, t3: t3Vectors },
    tags: { rep: dec(c.TAG_REP), bond: dec(c.TAG_BOND), handle: dec(c.TAG_HANDLE) },
    builders,
    tree: treeVectors,
    registry: registryVectors,
  };

  // ---------------------------------------------------------------- write vectors.json
  const fixturePath = join(REPO, "test/fixtures/vectors.json");
  await mkdir(dirname(fixturePath), { recursive: true });
  await writeFile(fixturePath, JSON.stringify(vectors, null, 2) + "\n");
  console.log("wrote", fixturePath);

  // ---------------------------------------------------------------- write vendored Noir constants
  await writeNoirConstants();
  console.log("wrote vendored poseidon constants (constants_p2.nr, constants_p3.nr)");

  // ---------------------------------------------------------------- write vectors.nr
  const nr = renderNoirVectors(vectors, {
    SK_ID,
    ANCHOR,
    REGISTRY_ID,
    DEAL_ID,
    NOTE_SALT,
    LEAF_SALT,
    LOCK_SALT,
    HANDLE_SALT,
    TOKEN_ID,
    AMOUNT,
    LOCK_AMOUNT,
    COUNT,
    VOLUME,
    PENALTY,
    IN_FLIGHT,
    VERSION,
  });
  const nrPath = join(REPO, "circuits/crates/pluri_commitments/src/vectors.nr");
  await mkdir(dirname(nrPath), { recursive: true });
  await writeFile(nrPath, nr);
  console.log("wrote", nrPath);
}

async function writeNoirConstants() {
  // C and M are indexed by t-2 (circomlibjs poseidon_constants.json); M is row-major (m[i][j] = state'[i] from state[j]).
  const t2C = (circomlibConstants.C as string[])[0].map(toDec);
  const t2M = (circomlibConstants.M as string[][])[0].flat().map(toDec);
  const t3C = (circomlibConstants.C as string[])[1].map(toDec);
  const t3M = (circomlibConstants.M as string[][])[1].flat().map(toDec);

  const p2 = renderConstantsModule("constants_p2", 2, t2C, t2M, 56);
  const p3 = renderConstantsModule("constants_p3", 3, t3C, t3M, 57);
  const base = join(REPO, "circuits/crates/pluri_commitments/src");
  await mkdir(base, { recursive: true });
  await writeFile(join(base, "constants_p2.nr"), p2);
  await writeFile(join(base, "constants_p3.nr"), p3);
}

function toDec(x: string): string {
  return BigInt(x).toString(10);
}

function renderConstantsModule(name: string, t: number, c: string[], m: string[], roundsP: number): string {
  const lines = [
    `// Generated by \`bun circuits:vectors\` from circomlibjs poseidon_constants.json — DO NOT EDIT.`,
    `// ${name}: circomlib PoseidonT${t} round constants (C) and row-major MDS matrix (M) over BN254.`,
    `// ${8 + roundsP} rounds total (8 full + ${roundsP} partial); C layout is per-round, ${t} values per round.`,
    `// Same parameters as iden3/poseidon-solidity PoseidonT${t} and the circomlib PoseidonT${t} template.`,
    "",
    `pub global C: [Field; ${c.length}] = [`,
    ...c.map((v) => `    ${v},`),
    "];",
    "",
    `pub global M: [Field; ${m.length}] = [`,
    ...m.map((v) => `    ${v},`),
    "];",
    "",
  ];
  return lines.join("\n");
}

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

type Sample = {
  SK_ID: bigint;
  ANCHOR: bigint;
  REGISTRY_ID: bigint;
  DEAL_ID: bigint;
  NOTE_SALT: bigint;
  LEAF_SALT: bigint;
  LOCK_SALT: bigint;
  HANDLE_SALT: bigint;
  TOKEN_ID: bigint;
  AMOUNT: bigint;
  LOCK_AMOUNT: bigint;
  COUNT: bigint;
  VOLUME: bigint;
  PENALTY: bigint;
  IN_FLIGHT: bigint;
  VERSION: bigint;
};

function renderNoirVectors(
  v: {
    poseidon: { t3: { inputs: string[]; output: string }[] };
    builders: Record<string, Record<string, string>>;
    tree: { depth: number; empty_root: string; leaves: string[]; roots: string[]; memberships: { index: string; leaf: string; siblings: string[]; indices: number[]; root: string }[] };
  },
  s: Sample,
): string {
  const b = v.builders;
  const t = v.tree;
  const nr: string[] = [];
  nr.push("// Generated by `bun circuits:vectors` — DO NOT EDIT.");
  nr.push("// The canonical vectors of PLURISWAP.md §3.15.3 as Noir constants: same data as");
  nr.push("// test/fixtures/vectors.json, same pass, single source. Inputs are field elements");
  nr.push("// already reduced mod p (the pinned rule for keccak-derived IDs; the adapters reduce).");
  nr.push("");
  nr.push(`pub global SK_ID: Field = ${dec(s.SK_ID)};`);
  nr.push(`pub global ANCHOR: Field = ${dec(s.ANCHOR)};`);
  nr.push(`pub global REGISTRY_ID: Field = ${dec(field(dec(s.REGISTRY_ID)))};`);
  nr.push(`pub global DEAL_ID: Field = ${dec(field(dec(s.DEAL_ID)))};`);
  nr.push(`pub global NOTE_SALT: Field = ${dec(field(dec(s.NOTE_SALT)))};`);
  nr.push(`pub global LEAF_SALT: Field = ${dec(field(dec(s.LEAF_SALT)))};`);
  nr.push(`pub global LOCK_SALT: Field = ${dec(field(dec(s.LOCK_SALT)))};`);
  nr.push(`pub global HANDLE_SALT: Field = ${dec(field(dec(s.HANDLE_SALT)))};`);
  nr.push(`pub global TOKEN_ID: Field = ${dec(s.TOKEN_ID)};`);
  nr.push(`pub global AMOUNT: Field = ${dec(s.AMOUNT)};`);
  nr.push(`pub global LOCK_AMOUNT: Field = ${dec(s.LOCK_AMOUNT)};`);
  nr.push(`pub global COUNT: Field = ${dec(s.COUNT)};`);
  nr.push(`pub global VOLUME: Field = ${dec(s.VOLUME)};`);
  nr.push(`pub global PENALTY: Field = ${dec(s.PENALTY)};`);
  nr.push(`pub global IN_FLIGHT: Field = ${dec(s.IN_FLIGHT)};`);
  nr.push(`pub global VERSION: Field = ${dec(s.VERSION)};`);
  nr.push("");
  nr.push(`pub global ZERO_INPUT: [Field; 2] = [1, 2];`);
  nr.push(`pub global ZERO_EXPECTED: Field = ${v.poseidon.t3[0].output};`);
  nr.push(`pub global P2_BIG_A: Field = ${v.poseidon.t3[2].inputs[0]};`);
  nr.push(`pub global P2_BIG_B: Field = ${v.poseidon.t3[2].inputs[1]};`);
  nr.push(`pub global P2_BIG_EXPECTED: Field = ${v.poseidon.t3[2].output};`);
  nr.push("");
  nr.push(`pub global EXPECTED_S: Field = ${b.s.output};`);
  nr.push(`pub global EXPECTED_HN: Field = ${b.hn.output};`);
  nr.push(`pub global EXPECTED_DEAL_SUBJECT: Field = ${b.deal_subject.output};`);
  nr.push(`pub global EXPECTED_NULL_REP: Field = ${b.null_rep.output};`);
  nr.push(`pub global EXPECTED_NULL_BOND: Field = ${b.null_bond.output};`);
  nr.push(`pub global EXPECTED_HANDLE_COMMIT: Field = ${b.handle_commit.output};`);
  nr.push(`pub global EXPECTED_NOTE_BOND: Field = ${b.note_bond.output};`);
  nr.push(`pub global EXPECTED_LOCK_COMMIT: Field = ${b.lock_commit.output};`);
  nr.push(`pub global EXPECTED_LEAF_REP: Field = ${b.leaf_rep.output};`);
  nr.push("");
  nr.push(`pub global TREE_DEPTH: u32 = ${t.depth};`);
  nr.push(`pub global TREE_EMPTY_ROOT: Field = ${t.empty_root};`);
  nr.push(`pub global TREE_LEAVES: [Field; ${t.leaves.length}] = [`);
  nr.push(...t.leaves.map((x) => `    ${x},`));
  nr.push("];");
  nr.push(`pub global TREE_ROOTS: [Field; ${t.roots.length}] = [`);
  nr.push(...t.roots.map((x) => `    ${x},`));
  nr.push("];");
  for (const [i, m] of t.memberships.entries()) {
    nr.push(`pub global TREE_SIBLINGS_${i}: [Field; ${m.siblings.length}] = [`);
    nr.push(...m.siblings.map((x) => `    ${x},`));
    nr.push("];");
    nr.push(`pub global TREE_INDICES_${i}: [u8; ${m.indices.length}] = [${m.indices.join(", ")}];`);
    nr.push(`pub global TREE_MEMBERSHIP_ROOT_${i}: Field = ${m.root};`);
  }
  nr.push("");
  // Registry section (V1): the humanity registry vectors the register circuits prove against.
  // The registry domain id is already emitted above as REGISTRY_ID (same pinned constant);
  // hsk is keccak-derived (raw >= p), so it is reduced like every other .nr input.
  const r = (v as { registry: RegistryVectors }).registry;
  nr.push(`pub global REGISTRY_DEPTH: u32 = ${r.depth};`);
  nr.push(`pub global REGISTRY_HSK: Field = ${dec(field(r.hsk))};`);
  nr.push(`pub global REGISTRY_IDENTITY_COMMITMENT: Field = ${r.identity_commitment};`);
  nr.push(`pub global REGISTRY_EMPTY_ROOT: Field = ${r.empty_root};`);
  nr.push(`pub global REGISTRY_ROOT: Field = ${r.root};`);
  nr.push(`pub global REGISTRY_SAMPLE_HN: Field = ${r.sample_hn};`);
  nr.push(`pub global REGISTRY_SAMPLE_SK_ID: Field = ${r.sample_sk_id};`);
  nr.push(`pub global REGISTRY_SAMPLE_S: Field = ${r.sample_s};`);
  nr.push(`pub global REGISTRY_SAMPLE_LEAF0: Field = ${r.sample_leaf0};`);
  nr.push(`pub global REGISTRY_SIBLINGS: [Field; ${r.siblings.length}] = [`);
  nr.push(...r.siblings.map((x) => `    ${x},`));
  nr.push("];");
  nr.push(`pub global REGISTRY_INDICES: [u8; ${r.indices.length}] = [${r.indices.join(", ")}];`);
  nr.push("");
  return nr.join("\n");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
