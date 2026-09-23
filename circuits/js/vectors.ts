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
import * as tiers from "./lib/tiers.ts";
import { IncrementalPoseidonTree } from "./lib/merkle.ts";
import { SparseTree, indexOf } from "./lib/sparse.ts";

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
// The anti-farming state of the leaf (§3.14.7, 2026-09-23). The builders row uses free sample values,
// like every other builder input; the FLOW below uses the real derivations.
const LEAF_CP_ROOT = BigInt(keccak("pluri:cp-root:1"));
const LEAF_EPOCH = 19_800n;
const LEAF_EPOCH_CREDITS = 3n;
// The counterparty of the pinned deal: a second account, with its own secret. The whole point of the
// pair construction is that neither side can name it alone.
const CP_SK_ID = BigInt(keccak("pluri:counterparty-sk:1")) % P;
// The rate window the pinned claim is proven in. The circuit has no clock: the module passes
// `block.timestamp / 1 day`, so the fixture commits to the epoch the suites' own clock
// (1_700_000_000, the V1 lesson about realistic timestamps) actually falls in.
const CLAIM_EPOCH = 1_700_000_000n / 86_400n;
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

// The prepare flow of V2 (PLURISWAP.md §3.15.4): the account tree is depth 32 (§3.15.3),
// the pinned test token has 6 decimals (USDC-like), and the sample deal takes 100 units of
// principal in flight from the just-registered genesis leaf — T1's base cap (250 units)
// admits it. The new leaf's salt is fresh: prepare_admit rotates it.
const ACCOUNT_DEPTH = 32;
const PREPARE_DECIMALS = 6n;
const PREPARE_PRINCIPAL = 100_000_000n;

// The vault flow of V3 (PLURISWAP.md §3.15.6): the notes tree is depth 20 (§3.15.3), and
// the sample story CONTINUES the prepare deal — the deposited note (the builders' note:
// 1_500_000_000 of the 6-dec token) funds the same deal's bond lock. §3.14.5's lock is
// (principal+9)/10 = 10_000_000, the split's change note carries the 1_490_000_000
// remainder, and after the terminal claim the released lock reabsorbs into a fresh note.
// The withdraw sample spends part of the change note (400_000_000) to a synthetic dest,
// leaving a second change note — the partial branch; the whole-consumption branch
// (changeNote == 0) is proven by the circuit's own tests, not by a second fixture proof.
const NOTES_DEPTH = 20;
const BOND_LOCK_AMOUNT = (PREPARE_PRINCIPAL + 9n) / 10n; // §3.14.5, exactly what reserve cross-checks
const BOND_CHANGE_AMOUNT = AMOUNT - BOND_LOCK_AMOUNT; // the split's conservation
// Every salt of this flow is DERIVED (2026-09-23), so none of them is a constant here: the
// deposit's comes from its index, and each child's from the nullifier of what it was carved out
// of. The sample IS the recovery walk — deposit index 0 → bond split → reabsorb / withdraw —
// and `notes.test.ts` replays it from `sk_id` and the public amounts alone.
const DEPOSIT_INDEX = 0n;
const WITHDRAW_DEST = 0x2222222222222222222222222222222222222222n; // synthetic 20-byte dest
const WITHDRAW_AMOUNT = 400_000_000n;
const WITHDRAW_CHANGE_AMOUNT = BOND_CHANGE_AMOUNT - WITHDRAW_AMOUNT;

// The disclosure layer of F4 (§3.15.7): the same account tree, one more leaf later in
// the account's life. The sample account is mid-history — 12 deals completed, 3 lots of
// volume, a +5 penalty already absorbed — score = 12 + 3 − 5 = 10, exactly at the T2
// boundary (the tier the penalty shaped: without it, 15 would read T3). Nothing in
// flight: the loan-consumer's question ("how has this account behaved"), not the deal
// engine's ("how much can it take now"). Version 3, the salt rotated past V3's claim.
// The attestation claims the HONEST exact bounds (tier 2, count 12); understating is
// the circuit's own tests. `expiry` is a pinned promise the consumer's clock checks.
const ATTEST_COUNT = 12n;
const ATTEST_VOLUME = 750_000_000n; // 3 lots at 6 decimals
const ATTEST_PENALTY = 5n;
const ATTEST_VERSION = 3n;
const ATTEST_EXPIRY = 1_800_000_000n;
const ATTEST_DECIMALS = 6n;
// The reveal's optional requester bind (§3.15.7 "bind a su pubkey efímera"): the pubkey
// hash of the one requester this profile was minted for, keccak-derived and reduced.
const REVEAL_REQUESTER = BigInt(keccak("pluri:requester:1"));

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
  const leaf = await c.leafRep(
    s,
    COUNT,
    VOLUME,
    PENALTY,
    IN_FLIGHT,
    TOKEN_ID,
    LEAF_SALT,
    VERSION,
    LEAF_CP_ROOT,
    LEAF_EPOCH,
    LEAF_EPOCH_CREDITS,
  );
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
    leaf_salt: { sk_id: dec(SK_ID), version: dec(VERSION), output: dec(await c.leafSalt(SK_ID, VERSION)) },
    // The two derivations the vault's salts come from: a note's seed is either a deposit index or
    // the nullifier of what it was carved out of; a lock's is the deal it belongs to. Pinned here
    // over free sample values, like every other builder — the FLOW's use of them is pinned by the
    // circuits' own vectors below.
    note_salt: { sk_id: dec(SK_ID), seed: dec(NOTE_SALT), output: dec(await c.noteSalt(SK_ID, NOTE_SALT)) },
    lock_salt: { sk_id: dec(SK_ID), deal_id: dec(DEAL_ID), output: dec(await c.lockSalt(SK_ID, DEAL_ID)) },
    // The anti-farming pair (§3.14.7): commutative by construction, so the row pins BOTH orders to the
    // same output — the property the whole rule rests on.
    pair_id: {
      s_a: dec(await c.accountCommitment(SK_ID)),
      s_b: dec(await c.accountCommitment(CP_SK_ID)),
      output: dec(await c.pairId(await c.accountCommitment(SK_ID), await c.accountCommitment(CP_SK_ID))),
      swapped: dec(await c.pairId(await c.accountCommitment(CP_SK_ID), await c.accountCommitment(SK_ID))),
    },
    pair_tag: {
      deal_id: dec(DEAL_ID),
      output: dec(await c.pairTag(await c.accountCommitment(SK_ID), await c.accountCommitment(CP_SK_ID), DEAL_ID)),
    },
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
      cp_root: dec(LEAF_CP_ROOT),
      epoch: dec(LEAF_EPOCH),
      epoch_credits: dec(LEAF_EPOCH_CREDITS),
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
  // The account link: the humanity nullifier binds the human, and the leaf is salted by DERIVATION
  // from the account secret, so `sk_id` alone recovers it (§3.15.3),
  // binding the burned hn to the account leaf through the shared secret.
  const regTree = await IncrementalPoseidonTree.create(REGISTRY_DEPTH);
  const identityCommitment = await c.accountCommitment(REGISTRY_HSK);
  const regRoot = await regTree.insert(identityCommitment);
  const regProof = regTree.proofOf(0);
  const sampleHn = await c.hn(REGISTRY_HSK, REGISTRY_ID);
  const sampleS = await c.accountCommitment(SK_ID);
  // The genesis leaf carries an EMPTY counterparty tree and a cold rate window: a new account has
  // met nobody, so its first deal with anyone is creditable.
  // The counterparty of the pinned deal, hoisted here because the ACTIVATION already needs it: the
  // pair is named when the two sides prepare, not when they claim.
  const cpS = await c.accountCommitment(CP_SK_ID);
  const cpEmpty = await SparseTree.create(c.CP_DEPTH);
  const cpEmptyRoot = cpEmpty.emptyRoot();
  const sampleLeaf0 =
    await c.leafRep(sampleS, 0n, 0n, 0n, 0n, 0n, await c.leafSalt(SK_ID, 0n), 0n, cpEmptyRoot, 0n, 0n);
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

  // ---------------------------------------------------------------- tier vectors (V2)
  // The §3.14.7 table as vectors: score (truncated volume lots, saturating penalty) and the
  // two cap columns, one row per tier plus the satSub edge and a truncated-division row.
  // The same rows pin the circuit's `tiers.nr` and the test mirror of the on-chain table.
  const tierRows: [bigint, bigint, bigint, bigint][] = [
    // count, volume, penalty, decimals — the five tiers, boundary-anchored.
    [0n, 0n, 0n, 6n], // score 0 -> T1
    [0n, 9n * 250_000_000n + 249_999_999n, 0n, 6n], // 9 lots (remainder dropped) -> still T1
    [0n, 10n * 250_000_000n, 0n, 6n], // 10 lots -> T2, exactly at the threshold
    [25n, 0n, 0n, 6n], // count alone -> T3
    [50n, 0n, 0n, 18n], // 18-dec scale -> T4
    [100n, 0n, 0n, 6n], // score 100 -> T5, unbounded
    [5n, 0n, 7n, 6n], // penalty 7 > base 5 -> satSub to 0 -> T1
    [250n, 250_000_001n, 0n, 6n], // count + one lot with remainder -> 251 -> T5
    // The §3.15.7 penalty bands, boundary-anchored on both sides of every cut. The cuts are
    // events (+5 a stalemate or an abandoned dispute, +15 an arbitration loss), so these rows
    // are the histories they name — and they double as score rows, since the band never
    // touches the score.
    [40n, 0n, 1n, 6n], // one point -> band 1 (the first thing that ever went wrong)
    [40n, 0n, 5n, 6n], // one stalemate -> still band 1
    [40n, 0n, 6n, 6n], // more than one -> band 2
    [40n, 0n, 15n, 6n], // one arbitration loss -> still band 2
    [40n, 0n, 16n, 6n], // a loss plus a stalemate -> band 3
  ];
  const tierVectors = tierRows.map(([count, volume, penalty, decimals]) => {
    const sc = tiers.score(count, volume, penalty, decimals);
    return {
      count: dec(count),
      volume: dec(volume),
      penalty: dec(penalty),
      decimals: dec(decimals),
      score: dec(sc),
      cap_base: dec(tiers.capRaw(sc, false, decimals) ?? 0n),
      cap_bond: dec(tiers.capRaw(sc, true, decimals) ?? 0n),
      // Unbounded is now a per-COLUMN fact, not a per-row one: only T5's bond column is.
      unbounded_base: tiers.capUnits(sc, false) === null,
      unbounded_bond: tiers.capUnits(sc, true) === null,
      // The §3.15.7 aggregate: off-chain only (no Solidity twin — the band is a disclosure
      // reading of the same counter), pinned JS<->Noir through these rows.
      band: dec(BigInt(tiers.penaltyBand(penalty))),
      volume_band: dec(BigInt(tiers.volumeBand(volume, decimals))),
    };
  });

  // ---------------------------------------------------------------- prepare vectors (V2)
  // The prepare circuits' pinned sample (§3.15.4): the registered genesis leaf of the
  // registry sample account (leaf0: all counters zero, token zero, derived salt, version 0)
  // goes into the depth-32 account tree; both prepares prove against that root —
  // passport.prepare and reputation.prepare run in one bundle, and reputation's own
  // insert happens inside, so both proofs see the same post-register tree.
  // The admission transition is the genesis branch of prepare_admit: leaf0 (token 0,
  // all-zero stats) admits a deal of the pinned token, taking PREPARE_PRINCIPAL in
  // flight under the T1 base cap, re-deriving the salt and bumping the version.
  const accountTree = await IncrementalPoseidonTree.create(ACCOUNT_DEPTH);
  const prepareRoot = await accountTree.insert(sampleLeaf0);
  const prepareProof = accountTree.proofOf(0);
  const prepareDealId = BigInt(keccak("pluri:prepare-deal:1"));
  const prepareDealSubject = await c.dealSubject(SK_ID, prepareDealId);
  const prepareNullRep = await c.nullRep(SK_ID, 0n);
  // A prepare moves principal into flight and nothing else: the counterparty tree and the rate window
  // ride through untouched, because credit is decided at the TERMINAL, not at admission.
  const prepareNewLeaf = await c.leafRep(
    sampleS,
    0n,
    0n,
    0n,
    PREPARE_PRINCIPAL,
    TOKEN_ID,
    await c.leafSalt(SK_ID, 1n),
    1n,
    cpEmptyRoot,
    0n,
    0n,
  );
  const prepareScore = tiers.score(0n, 0n, 0n, PREPARE_DECIMALS);
  const prepareCap = tiers.capRaw(prepareScore, false, PREPARE_DECIMALS);
  if (prepareCap === null || PREPARE_PRINCIPAL > prepareCap) {
    throw new Error(`prepare sample over its own cap: principal ${PREPARE_PRINCIPAL} > cap ${prepareCap}`);
  }
  const preparePairTag = await c.pairTag(sampleS, cpS, prepareDealId);
  const prepareVectors = {
    depth: ACCOUNT_DEPTH,
    // The genesis counterparty tree: empty, and the prepare carries it through untouched.
    cp_root: dec(cpEmptyRoot),
    // The pair, named at activation by both sides (§3.14.7).
    cp_s: dec(cpS),
    pair_tag: dec(preparePairTag),
    decimals: dec(PREPARE_DECIMALS),
    principal: dec(PREPARE_PRINCIPAL),
    token: dec(TOKEN_ID),
    sk_id: dec(SK_ID),
    deal_id: dec(prepareDealId),
    salt: dec(await c.leafSalt(SK_ID, 0n)),
    new_salt: dec(await c.leafSalt(SK_ID, 1n)),
    s: dec(sampleS),
    leaf0: dec(sampleLeaf0),
    siblings: prepareProof.siblings.map(dec),
    indices: prepareProof.indices,
    root: dec(prepareRoot),
    deal_subject: dec(prepareDealSubject),
    null_rep: dec(prepareNullRep),
    new_leaf: dec(prepareNewLeaf),
    score: dec(prepareScore),
    cap: dec(prepareCap ?? 0n),
  };

  // ---------------------------------------------------------------- vault vectors (V3)
  // One deal, two trees, the whole lifecycle (§3.15.4-§3.15.6). The notes tree (depth 20)
  // receives: the deposit's note (index 0), the split's change note (index 1) and the
  // reabsorbed lock's new note (index 2) — exactly the inserts the vault performs in the
  // e2e order. The account tree (depth 32) continues V2's: leaf0 (index 0), the prepare's
  // new leaf (index 1) — the claim proves against that root.
  // The deposit's note: salt derived from the account's deposit index (the one note with no
  // parent to derive from). `note` above stays a free-salt builder sample — it pins the BUILDER;
  // this pins the CIRCUIT's rule.
  const depositSalt = await c.noteSalt(SK_ID, DEPOSIT_INDEX);
  const depositNote = await c.noteBond(SK_ID, TOKEN_ID, AMOUNT, depositSalt);
  const notesTree = await IncrementalPoseidonTree.create(NOTES_DEPTH);
  const bondRoot0 = await notesTree.insert(depositNote); // vault.deposit's insert
  const bondProof = notesTree.proofOf(0); // prepare_bond's membership: the source note

  // deposit (§3.15.6): the only place fresh value enters the notes world. The proof pins
  // the note to the public amount: note = noteBond(sk_id, token, amount, salt).
  const depositVectors = {
    token: dec(TOKEN_ID),
    amount: dec(AMOUNT),
    note: dec(depositNote),
    sk_id: dec(SK_ID),
    index: dec(DEPOSIT_INDEX),
    salt: dec(depositSalt), // derived — carried for the twins and the recovery walk, not an input
  };

  // prepare_bond (§3.15.4 Bond): the split. The source note is a live leaf of bondRoot0;
  // the lock is §3.14.5's exact lockAmount, the change note the exact remainder, and both
  // lockAmount and token are public (F3's amendment: reserve cross-checks them).
  const bondLockSalt = await c.lockSalt(SK_ID, prepareDealId);
  const bondNullBond = await c.nullBond(SK_ID, depositSalt);
  const bondChangeSalt = await c.noteSalt(SK_ID, bondNullBond); // the split's change: seeded by the burn
  const bondLockCommit = await c.lockCommit(SK_ID, prepareDealId, BOND_LOCK_AMOUNT, bondLockSalt);
  const bondChangeNote = await c.noteBond(SK_ID, TOKEN_ID, BOND_CHANGE_AMOUNT, bondChangeSalt);
  const bondVectors = {
    depth: NOTES_DEPTH,
    deal_id: dec(prepareDealId),
    deal_subject: dec(prepareDealSubject),
    token: dec(TOKEN_ID),
    note_amount: dec(AMOUNT),
    source_salt: dec(depositSalt),
    lock_amount: dec(BOND_LOCK_AMOUNT),
    lock_salt: dec(bondLockSalt), // derived from the deal
    change_salt: dec(bondChangeSalt), // derived from the nullifier above
    lock_commit: dec(bondLockCommit),
    change_note: dec(bondChangeNote),
    null_bond: dec(bondNullBond),
    siblings: bondProof.siblings.map(dec),
    indices: bondProof.indices,
    root: dec(bondRoot0),
    sk_id: dec(SK_ID),
  };

  // claim (§3.15.5): the terminal delta of the SAME deal. The current leaf is the prepare's
  // new leaf (version 1, the principal in flight); the sample delta is Peaceful — the
  // table's other four kinds are pinned by the `deltas` rows below, proven in the circuit's
  // own tests. nullRep(v1) is the CURRENT version's nullifier (v0's was burned by prepare).
  const claimRoot = await accountTree.insert(prepareNewLeaf); // reputation.prepare's insert
  const claimProof = accountTree.proofOf(1);
  const claimNullRep = await c.nullRep(SK_ID, 1n);
  // The §3.15.5 delta table (the same arithmetic `Reputation`'s public twin applies):
  // Peaceful completes the deal (+1 count, +principal volume), Silent and ArbWin only
  // release the inFlight, Stalemate punishes +5, ArbLoss +15 — every kind releases
  // inFlight by the principal.
  const deltaOf = (kind: bigint): { count: bigint; volume: bigint; penalty: bigint; inFlight: bigint } => {
    if (kind === 0n) return { count: 1n, volume: PREPARE_PRINCIPAL, penalty: 0n, inFlight: 0n };
    if (kind === 2n) return { count: 0n, volume: 0n, penalty: 5n, inFlight: 0n };
    if (kind === 4n) return { count: 0n, volume: 0n, penalty: 15n, inFlight: 0n };
    return { count: 0n, volume: 0n, penalty: 0n, inFlight: 0n };
  };
  // The terminal that CREDITS (§3.14.7, 2026-09-23). The counterparty is fresh — the account's tree is
  // empty — so the Peaceful delta lands in full AND the counterparty is written into the slot its own
  // `S` addresses, which is what makes the second deal with them worth nothing.
  const cpBits = await c.cpPath(cpS);
  const cpIndex = indexOf(cpBits);
  const cpTreeBefore = await SparseTree.create(c.CP_DEPTH);
  const cpPathBefore = await cpTreeBefore.pathFor(cpIndex);
  const cpTreeAfter = await SparseTree.create(c.CP_DEPTH);
  cpTreeAfter.set(cpIndex, cpS);
  const cpRootAfter = await cpTreeAfter.root();
  const claimPairTag = await c.pairTag(sampleS, cpS, prepareDealId);
  const claimNewLeaf = await c.leafRep(
    sampleS,
    1n,
    PREPARE_PRINCIPAL,
    0n,
    0n,
    TOKEN_ID,
    await c.leafSalt(SK_ID, 2n),
    2n,
    cpRootAfter,
    CLAIM_EPOCH,
    1n,
  );
  const claimVectors = {
    depth: ACCOUNT_DEPTH,
    deal_id: dec(prepareDealId),
    deal_subject: dec(prepareDealSubject),
    kind: "0", // Peaceful
    token: dec(TOKEN_ID),
    principal: dec(PREPARE_PRINCIPAL),
    sk_id: dec(SK_ID),
    // The current leaf = the prepare sample's newLeaf: version 1, the principal in flight.
    count: "0",
    volume: "0",
    penalty: "0",
    in_flight: dec(PREPARE_PRINCIPAL),
    leaf_token: dec(TOKEN_ID),
    salt: dec(await c.leafSalt(SK_ID, 1n)),
    version: "1",
    // The anti-farming state the claim reads and moves (§3.14.7): an empty counterparty tree and a
    // cold window going in, the counterparty written and one credit spent coming out.
    cp_root: dec(cpEmptyRoot),
    epoch: "0",
    epoch_credits: "0",
    cp_sk_id: dec(CP_SK_ID),
    cp_s: dec(cpS),
    cp_index: dec(cpIndex),
    cp_siblings: cpPathBefore.siblings.map(dec),
    cp_indices: cpPathBefore.indices,
    cp_root_after: dec(cpRootAfter),
    pair_tag: dec(claimPairTag),
    claim_epoch: dec(CLAIM_EPOCH),
    new_salt: dec(await c.leafSalt(SK_ID, 2n)),
    new_leaf: dec(claimNewLeaf),
    null_rep: dec(claimNullRep),
    siblings: claimProof.siblings.map(dec),
    indices: claimProof.indices,
    root: dec(claimRoot),
  };

  // Two more scenarios for the 2026-09-23 rule, each one a real leaf in the same account tree so the
  // circuit can be exercised end to end rather than by arithmetic alone:
  //
  //   repeat  the SAME counterparty a second time — its slot is taken, so a Peaceful terminal moves
  //           the flight and nothing else;
  //   full    a fresh counterparty but a window already spent — the credit is refused, and the slot
  //           stays free for some later window.
  //
  // Both start from a leaf that looks like what a second admission would have written: the stats the
  // first claim left, the principal back in flight, the version bumped.
  const repeatLeaf = await c.leafRep(
    sampleS,
    1n,
    PREPARE_PRINCIPAL,
    0n,
    PREPARE_PRINCIPAL,
    TOKEN_ID,
    await c.leafSalt(SK_ID, 3n),
    3n,
    cpRootAfter,
    CLAIM_EPOCH,
    1n,
  );
  const repeatRoot = await accountTree.insert(repeatLeaf);
  const repeatProof = accountTree.proofOf(Number(accountTree.nextIndex) - 1);
  const repeatNewLeaf = await c.leafRep(
    sampleS,
    1n,
    PREPARE_PRINCIPAL,
    0n,
    0n,
    TOKEN_ID,
    await c.leafSalt(SK_ID, 4n),
    4n,
    cpRootAfter,
    CLAIM_EPOCH,
    1n,
  );
  const cpPathAfter = await cpTreeAfter.pathFor(cpIndex);

  const fullLeaf = await c.leafRep(
    sampleS,
    1n,
    PREPARE_PRINCIPAL,
    0n,
    PREPARE_PRINCIPAL,
    TOKEN_ID,
    await c.leafSalt(SK_ID, 3n),
    3n,
    cpEmptyRoot,
    CLAIM_EPOCH,
    16n,
  );
  const fullRoot = await accountTree.insert(fullLeaf);
  const fullProof = accountTree.proofOf(Number(accountTree.nextIndex) - 1);
  const fullNewLeaf = await c.leafRep(
    sampleS,
    1n,
    PREPARE_PRINCIPAL,
    0n,
    0n,
    TOKEN_ID,
    await c.leafSalt(SK_ID, 4n),
    4n,
    cpEmptyRoot,
    CLAIM_EPOCH,
    16n,
  );

  const claimRepeatVectors = {
    version: "3",
    cp_root: dec(cpRootAfter),
    epoch: dec(CLAIM_EPOCH),
    epoch_credits: "1",
    slot: dec(cpS),
    cp_siblings: cpPathAfter.siblings.map(dec),
    new_leaf: dec(repeatNewLeaf),
    null_rep: dec(await c.nullRep(SK_ID, 3n)),
    siblings: repeatProof.siblings.map(dec),
    indices: repeatProof.indices,
    root: dec(repeatRoot),
  };
  const claimFullVectors = {
    version: "3",
    cp_root: dec(cpEmptyRoot),
    epoch: dec(CLAIM_EPOCH),
    epoch_credits: "16",
    slot: "0",
    cp_siblings: cpPathBefore.siblings.map(dec),
    new_leaf: dec(fullNewLeaf),
    null_rep: dec(await c.nullRep(SK_ID, 3n)),
    siblings: fullProof.siblings.map(dec),
    indices: fullProof.indices,
    root: dec(fullRoot),
  };

  // The §3.15.5 delta table as rows (the tiers pattern): one row per Close kind over the
  // same current leaf, the JS twin computing each delta leaf. The claim proof commits the
  // Peaceful row; the circuit's tests prove all five against these rows, and the Solidity
  // mirror walks the same table.
  const deltaRows = [0n, 1n, 2n, 3n, 4n].map((kind) => {
    const d = deltaOf(kind);
    return {
      kind: dec(kind),
      count: "0",
      volume: "0",
      penalty: "0",
      in_flight: dec(PREPARE_PRINCIPAL),
      token: dec(TOKEN_ID),
      principal: dec(PREPARE_PRINCIPAL),
      new_count: dec(d.count),
      new_volume: dec(d.volume),
      new_penalty: dec(d.penalty),
      new_in_flight: dec(d.inFlight),
    };
  });

  // reabsorb (§3.15.6): the released lock merges back. The proof binds the stored
  // lockCommit — it opens to exactly (sk_id, dealId, amount, salt) with the record's own
  // amount — and mints a note of exactly that amount. No root, no membership: the lock
  // record is contract state. nullBond(sk_id, lockSalt) is one-use-per-lock.
  const reabsorbNullBond = await c.nullBond(SK_ID, bondLockSalt);
  const reabsorbNewSalt = await c.noteSalt(SK_ID, reabsorbNullBond);
  const reabsorbNewNote = await c.noteBond(SK_ID, TOKEN_ID, BOND_LOCK_AMOUNT, reabsorbNewSalt);
  const reabsorbVectors = {
    deal_id: dec(prepareDealId),
    deal_subject: dec(prepareDealSubject),
    token: dec(TOKEN_ID),
    amount: dec(BOND_LOCK_AMOUNT),
    lock_commit: dec(bondLockCommit),
    lock_salt: dec(bondLockSalt), // derived from the deal — reabsorb re-derives it, never receives it
    new_salt: dec(reabsorbNewSalt), // derived from the lock's nullifier
    new_note: dec(reabsorbNewNote),
    null_bond: dec(reabsorbNullBond),
    sk_id: dec(SK_ID),
  };

  // withdraw (§3.15.6): the change note (index 1) spends PART of itself to a fresh dest —
  // 400_000_000 out of 1_490_000_000, the 1_090_000_000 remainder living on as a second
  // change note. The membership witnesses the change note's OWN insert-time root (the root
  // `vault.prepare`'s insert produced): proofs reference any root of the vault's ring
  // buffer — the nullifier decides the replay (§3.15.3), not the root's age.
  await notesTree.insert(bondChangeNote); // vault.prepare's insert
  const withdrawProof = notesTree.proofOf(1);
  const withdrawNullBond = await c.nullBond(SK_ID, bondChangeSalt);
  const withdrawChangeSalt = await c.noteSalt(SK_ID, withdrawNullBond);
  const withdrawChangeNote = await c.noteBond(SK_ID, TOKEN_ID, WITHDRAW_CHANGE_AMOUNT, withdrawChangeSalt);
  const withdrawVectors = {
    depth: NOTES_DEPTH,
    token: dec(TOKEN_ID),
    dest: dec(WITHDRAW_DEST),
    amount: dec(WITHDRAW_AMOUNT),
    note_amount: dec(BOND_CHANGE_AMOUNT),
    source_salt: dec(bondChangeSalt),
    change_salt: dec(withdrawChangeSalt), // derived from the nullifier above
    change_note: dec(withdrawChangeNote),
    null_bond: dec(withdrawNullBond),
    siblings: withdrawProof.siblings.map(dec),
    indices: withdrawProof.indices,
    root: dec(withdrawProof.root),
    sk_id: dec(SK_ID),
  };

  // ---------------------------------------------------------------- attest vectors (F4)
  // The disclosure layer (§3.15.7): attest_base and reveal_advanced prove against the SAME
  // account tree the on-chain circuits use — this leaf enters at index 2, after V3's
  // claim (leaf0 at 0, the prepare's new leaf at 1), and each proof references its own
  // insert-time root. Both circuits share this one witness: the listing attestation and
  // the profile reveal are two views of one account state.
  // The disclosure sample sits mid-history, so its counterparty tree is NOT empty: twelve completed
  // deals means twelve accounts have vouched for it. The tree is built from twelve derived slots — the
  // attestation circuits never look inside it, but the leaf they prove membership of has to be a leaf
  // an honest history could actually produce.
  const attestCpTree = await SparseTree.create(c.CP_DEPTH);
  for (let i = 0n; i < ATTEST_COUNT; i++) {
    const other = await c.accountCommitment(BigInt(keccak(`pluri:attest-counterparty:${i}`)) % P);
    attestCpTree.set(indexOf(await c.cpPath(other)), other);
  }
  const attestCpRoot = await attestCpTree.root();
  const attestLeaf = await c.leafRep(
    sampleS,
    ATTEST_COUNT,
    ATTEST_VOLUME,
    ATTEST_PENALTY,
    0n,
    TOKEN_ID,
    await c.leafSalt(SK_ID, ATTEST_VERSION),
    ATTEST_VERSION,
    attestCpRoot,
    LEAF_EPOCH,
    LEAF_EPOCH_CREDITS,
  );
  const attestRoot = await accountTree.insert(attestLeaf);
  const attestProof = accountTree.proofOf(Number(accountTree.nextIndex) - 1);
  const attestHandle = await c.handleCommit(SK_ID, HANDLE_SALT);
  const attestScore = tiers.score(ATTEST_COUNT, ATTEST_VOLUME, ATTEST_PENALTY, ATTEST_DECIMALS);
  const attestTier = tiers.tierOf(attestScore);
  if (attestScore !== 10n || attestTier !== 2n) {
    throw new Error(`attest sample stats must sit exactly at the T2 boundary: score ${attestScore}`);
  }
  const attestVectors = {
    depth: ACCOUNT_DEPTH,
    sk_id: dec(SK_ID),
    handle_salt: dec(HANDLE_SALT),
    handle_commit: dec(attestHandle),
    // The leaf's own stats (§3.15.3 leafRep order) — the state, not the claim.
    count: dec(ATTEST_COUNT),
    volume: dec(ATTEST_VOLUME),
    penalty: dec(ATTEST_PENALTY),
    in_flight: "0",
    leaf_token: dec(TOKEN_ID),
    salt: dec(await c.leafSalt(SK_ID, ATTEST_VERSION)),
    version: dec(ATTEST_VERSION),
    cp_root: dec(attestCpRoot),
    epoch: dec(LEAF_EPOCH),
    epoch_credits: dec(LEAF_EPOCH_CREDITS),
    // The statement: the token the stats are denominated in (with its decimals — the
    // tier is a function of both, so the consumer cross-checks them against the ERC20),
    // the claimed bounds, and the freshness promise.
    token: dec(TOKEN_ID),
    decimals: dec(ATTEST_DECIMALS),
    tier: dec(attestTier),
    count_claimed: dec(ATTEST_COUNT),
    // The aggregate a listing carries about what went wrong: the sample absorbed one +5,
    // so band 1 -- visible as "something happened" without publishing the counter.
    volume_band: String(tiers.volumeBand(ATTEST_VOLUME, ATTEST_DECIMALS)),
    penalty_band: String(tiers.penaltyBand(ATTEST_PENALTY)),
    expiry: dec(ATTEST_EXPIRY),
    score: dec(attestScore),
    siblings: attestProof.siblings.map(dec),
    indices: attestProof.indices,
    root: dec(attestRoot),
  };

  // reveal_advanced (§3.15.7): the raw profile under the same handle, minted for the pinned
  // requester. The mask covers count (bit0) and volume (bit1); the PENALTY is outside it and
  // always revealed in full, because a reveal can be published without a base attestation and an
  // optional penalty there would reopen the hole the base attestation was changed to close.
  const revealVectors = {
    handle_commit: dec(attestHandle),
    fields_mask: "3",
    out_count: dec(ATTEST_COUNT),
    out_volume: dec(ATTEST_VOLUME),
    out_penalty: dec(ATTEST_PENALTY),
    requester: dec(field(dec(REVEAL_REQUESTER))),
    token: dec(TOKEN_ID),
    sk_id: dec(SK_ID),
    handle_salt: dec(HANDLE_SALT),
    count: dec(ATTEST_COUNT),
    volume: dec(ATTEST_VOLUME),
    penalty: dec(ATTEST_PENALTY),
    in_flight: "0",
    leaf_token: dec(TOKEN_ID),
    salt: dec(await c.leafSalt(SK_ID, ATTEST_VERSION)),
    version: dec(ATTEST_VERSION),
    cp_root: dec(attestCpRoot),
    epoch: dec(LEAF_EPOCH),
    epoch_credits: dec(LEAF_EPOCH_CREDITS),
    siblings: attestProof.siblings.map(dec),
    indices: attestProof.indices,
    root: dec(attestRoot),
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
    // The merged side (2026-09-23): the same deal the prepare and bond samples already describe,
    // proven in one statement instead of three. Every value is a reference to those two sections —
    // that IS the point: the three proofs were always talking about one deal.
    side: {
      lock_commit: dec(bondLockCommit),
      lock_amount: dec(BOND_LOCK_AMOUNT),
      change_note: dec(bondChangeNote),
      null_bond: dec(bondNullBond),
      bond_root: dec(bondRoot0),
      note_amount: dec(AMOUNT),
      source_salt: dec(depositSalt),
      note_siblings: bondProof.siblings.map(dec),
      note_indices: bondProof.indices,
    },
    claim_repeat: claimRepeatVectors,
    claim_full: claimFullVectors,
    tiers: tierVectors,
    // The row count as a scalar: the foundry parity mirror cannot count an array of
    // objects (this forge has no working array-length cheatcode), so the fixture names it.
    tiers_rows: dec(BigInt(tierRows.length)),
    deltas: deltaRows,
    deltas_rows: dec(BigInt(deltaRows.length)),
    prepare: prepareVectors,
    deposit: depositVectors,
    bond: bondVectors,
    claim: claimVectors,
    reabsorb: reabsorbVectors,
    withdraw: withdrawVectors,
    attest: attestVectors,
    reveal: revealVectors,
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

type TierVectors = {
  count: string;
  volume: string;
  penalty: string;
  decimals: string;
  score: string;
  cap_base: string;
  cap_bond: string;
  unbounded_base: boolean;
  unbounded_bond: boolean;
  band: string;
  volume_band: string;
  unbounded: boolean;
}[];

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

type SideVectors = {
  lock_commit: string;
  lock_amount: string;
  change_note: string;
  null_bond: string;
  bond_root: string;
  note_amount: string;
  source_salt: string;
  note_siblings: string[];
  note_indices: number[];
};

type ClaimScenario = {
  version: string;
  cp_root: string;
  epoch: string;
  epoch_credits: string;
  slot: string;
  cp_siblings: string[];
  new_leaf: string;
  null_rep: string;
  siblings: string[];
  indices: number[];
  root: string;
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

type DepositVectors = {
  token: string;
  amount: string;
  index: string;
  note: string;
  sk_id: string;
  salt: string;
};

type BondVectors = {
  depth: number;
  deal_id: string;
  deal_subject: string;
  token: string;
  note_amount: string;
  source_salt: string;
  lock_amount: string;
  lock_salt: string;
  change_salt: string;
  lock_commit: string;
  change_note: string;
  null_bond: string;
  siblings: string[];
  indices: number[];
  root: string;
  sk_id: string;
};

type ClaimVectors = {
  depth: number;
  deal_id: string;
  deal_subject: string;
  kind: string;
  token: string;
  principal: string;
  sk_id: string;
  count: string;
  volume: string;
  penalty: string;
  in_flight: string;
  leaf_token: string;
  salt: string;
  version: string;
  new_salt: string;
  new_leaf: string;
  null_rep: string;
  siblings: string[];
  indices: number[];
  root: string;
};

type DeltaRow = {
  kind: string;
  count: string;
  volume: string;
  penalty: string;
  in_flight: string;
  token: string;
  principal: string;
  new_count: string;
  new_volume: string;
  new_penalty: string;
  new_in_flight: string;
};

type ReabsorbVectors = {
  deal_id: string;
  deal_subject: string;
  token: string;
  amount: string;
  lock_commit: string;
  lock_salt: string;
  new_salt: string;
  new_note: string;
  null_bond: string;
  sk_id: string;
};

type WithdrawVectors = {
  depth: number;
  token: string;
  dest: string;
  amount: string;
  note_amount: string;
  source_salt: string;
  change_salt: string;
  change_note: string;
  null_bond: string;
  siblings: string[];
  indices: number[];
  root: string;
  sk_id: string;
};

type AttestVectors = {
  depth: number;
  sk_id: string;
  handle_salt: string;
  handle_commit: string;
  count: string;
  volume: string;
  penalty: string;
  in_flight: string;
  leaf_token: string;
  salt: string;
  version: string;
  token: string;
  decimals: string;
  tier: string;
  count_claimed: string;
  volume_band: string;
  penalty_band: string;
  expiry: string;
  score: string;
  siblings: string[];
  indices: number[];
  root: string;
};

type RevealVectors = {
  handle_commit: string;
  fields_mask: string;
  out_volume: string;
  out_penalty: string;
  requester: string;
  token: string;
  sk_id: string;
  handle_salt: string;
  count: string;
  volume: string;
  penalty: string;
  in_flight: string;
  leaf_token: string;
  salt: string;
  version: string;
  siblings: string[];
  indices: number[];
  root: string;
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
  nr.push(`pub global EXPECTED_NOTE_SALT: Field = ${b.note_salt.output};`);
  nr.push(`pub global EXPECTED_LOCK_SALT: Field = ${b.lock_salt.output};`);
  nr.push(`pub global EXPECTED_NOTE_BOND: Field = ${b.note_bond.output};`);
  nr.push(`pub global EXPECTED_LOCK_COMMIT: Field = ${b.lock_commit.output};`);
  nr.push(`pub global EXPECTED_PAIR_ID: Field = ${b.pair_id.output};`);
  nr.push(`pub global EXPECTED_PAIR_ID_SWAPPED: Field = ${b.pair_id.swapped};`);
  nr.push(`pub global PAIR_S_A: Field = ${b.pair_id.s_a};`);
  nr.push(`pub global PAIR_S_B: Field = ${b.pair_id.s_b};`);
  nr.push(`pub global EXPECTED_PAIR_TAG: Field = ${b.pair_tag.output};`);
  nr.push(`pub global LEAF_CP_ROOT: Field = ${dec(field(b.leaf_rep.cp_root))};`);
  nr.push(`pub global LEAF_EPOCH: Field = ${b.leaf_rep.epoch};`);
  nr.push(`pub global LEAF_EPOCH_CREDITS: Field = ${b.leaf_rep.epoch_credits};`);
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
  // Tiers section (V2): the §3.14.7 table rows as arrays, one index per row. `unbounded`
  // (score >= 100) pins the sentinel: both cap columns emit 0 for it and the flag carries
  // the meaning — a cap of 0 with unbounded false would otherwise be a nonsensical row.
  const ti = (v as { tiers: TierVectors }).tiers;
  nr.push(`pub global TIER_COUNT: u32 = ${ti.length};`);
  nr.push(`pub global TIER_COUNTS: [Field; ${ti.length}] = [`);
  nr.push(...ti.map((x) => `    ${x.count},`));
  nr.push("];");
  nr.push(`pub global TIER_VOLUMES: [Field; ${ti.length}] = [`);
  nr.push(...ti.map((x) => `    ${x.volume},`));
  nr.push("];");
  nr.push(`pub global TIER_PENALTIES: [Field; ${ti.length}] = [`);
  nr.push(...ti.map((x) => `    ${x.penalty},`));
  nr.push("];");
  nr.push(`pub global TIER_DECIMALS: [Field; ${ti.length}] = [`);
  nr.push(...ti.map((x) => `    ${x.decimals},`));
  nr.push("];");
  nr.push(`pub global TIER_SCORES: [Field; ${ti.length}] = [`);
  nr.push(...ti.map((x) => `    ${x.score},`));
  nr.push("];");
  nr.push(`pub global TIER_CAPS_BASE: [Field; ${ti.length}] = [`);
  nr.push(...ti.map((x) => `    ${x.cap_base},`));
  nr.push("];");
  nr.push(`pub global TIER_CAPS_BOND: [Field; ${ti.length}] = [`);
  nr.push(...ti.map((x) => `    ${x.cap_bond},`));
  nr.push("];");
  nr.push(`pub global TIER_BANDS: [Field; ${ti.length}] = [`);
  nr.push(...ti.map((x) => `    ${x.band},`));
  nr.push("];");
  nr.push(`pub global TIER_VOLUME_BANDS: [Field; ${ti.length}] = [`);
  nr.push(...ti.map((x) => `    ${x.volume_band},`));
  nr.push("];");
  nr.push(`pub global TIER_UNBOUNDED_BASE: [bool; ${ti.length}] = [`);
  nr.push(...ti.map((x) => `    ${x.unbounded_base},`));
  nr.push("];");
  nr.push(`pub global TIER_UNBOUNDED_BOND: [bool; ${ti.length}] = [`);
  nr.push(...ti.map((x) => `    ${x.unbounded_bond},`));
  nr.push("];");
  nr.push("");
  // Prepare section (V2): the pinned sample of the prepare circuits. salt and new_salt are
  // keccak-derived (raw >= p) — reduced here, as everywhere else, per the mod-p rule;
  // deal_id likewise. The other witnesses are already canonical field-sized values.
  const p = (v as { prepare: PrepareVectors }).prepare;
  nr.push(`pub global PREPARE_DEPTH: u32 = ${p.depth};`);
  nr.push(`pub global PREPARE_DECIMALS: Field = ${p.decimals};`);
  nr.push(`pub global PREPARE_PRINCIPAL: Field = ${p.principal};`);
  nr.push(`pub global PREPARE_TOKEN: Field = ${p.token};`);
  nr.push(`pub global PREPARE_SK_ID: Field = ${p.sk_id};`);
  nr.push(`pub global PREPARE_DEAL_ID: Field = ${dec(field(p.deal_id))};`);
  nr.push(`pub global PREPARE_SALT: Field = ${dec(field(p.salt))};`);
  nr.push(`pub global PREPARE_NEW_SALT: Field = ${dec(field(p.new_salt))};`);
  nr.push(`pub global PREPARE_CP_ROOT: Field = ${p.cp_root};`);
  nr.push(`pub global PREPARE_CP_S: Field = ${p.cp_s};`);
  nr.push(`pub global PREPARE_PAIR_TAG: Field = ${p.pair_tag};`);
  const sd = (v as { side: SideVectors }).side;
  nr.push(`pub global SIDE_LOCK_COMMIT: Field = ${sd.lock_commit};`);
  nr.push(`pub global SIDE_LOCK_AMOUNT: Field = ${sd.lock_amount};`);
  nr.push(`pub global SIDE_CHANGE_NOTE: Field = ${sd.change_note};`);
  nr.push(`pub global SIDE_NULL_BOND: Field = ${sd.null_bond};`);
  nr.push(`pub global SIDE_BOND_ROOT: Field = ${sd.bond_root};`);
  nr.push(`pub global SIDE_NOTE_AMOUNT: Field = ${sd.note_amount};`);
  nr.push(`pub global SIDE_SOURCE_SALT: Field = ${dec(field(sd.source_salt))};`);
  nr.push(`pub global SIDE_NOTE_SIBLINGS: [Field; ${sd.note_siblings.length}] = [`);
  nr.push(...sd.note_siblings.map((x) => `    ${x},`));
  nr.push("];");
  nr.push(`pub global SIDE_NOTE_INDICES: [u8; ${sd.note_indices.length}] = [${sd.note_indices.join(", ")}];`);
  nr.push(`pub global PREPARE_S: Field = ${p.s};`);
  nr.push(`pub global PREPARE_LEAF0: Field = ${p.leaf0};`);
  nr.push(`pub global PREPARE_ROOT: Field = ${p.root};`);
  nr.push(`pub global PREPARE_DEAL_SUBJECT: Field = ${p.deal_subject};`);
  nr.push(`pub global PREPARE_NULL_REP: Field = ${p.null_rep};`);
  nr.push(`pub global PREPARE_NEW_LEAF: Field = ${p.new_leaf};`);
  nr.push(`pub global PREPARE_SIBLINGS: [Field; ${p.siblings.length}] = [`);
  nr.push(...p.siblings.map((x) => `    ${x},`));
  nr.push("];");
  nr.push(`pub global PREPARE_INDICES: [u8; ${p.indices.length}] = [${p.indices.join(", ")}];`);
  nr.push("");
  // Vault sections (V3): the §3.15.5-§3.15.6 samples of the deposit/bond/claim/reabsorb/
  // withdraw circuits. Same mod-p rule: every keccak-derived salt and deal id reduces here,
  // the amounts and tokens are already canonical. The deltas rows pin §3.15.5's table.
  const d = (v as { deposit: DepositVectors }).deposit;
  nr.push(`pub global DEPOSIT_TOKEN: Field = ${d.token};`);
  nr.push(`pub global DEPOSIT_AMOUNT: Field = ${d.amount};`);
  nr.push(`pub global DEPOSIT_NOTE: Field = ${d.note};`);
  nr.push(`pub global DEPOSIT_SK_ID: Field = ${d.sk_id};`);
  nr.push(`pub global DEPOSIT_INDEX: Field = ${d.index};`);
  nr.push(`pub global DEPOSIT_SALT: Field = ${dec(field(d.salt))};`);
  nr.push("");
  const bo = (v as { bond: BondVectors }).bond;
  nr.push(`pub global BOND_DEPTH: u32 = ${bo.depth};`);
  nr.push(`pub global BOND_DEAL_ID: Field = ${dec(field(bo.deal_id))};`);
  nr.push(`pub global BOND_DEAL_SUBJECT: Field = ${bo.deal_subject};`);
  nr.push(`pub global BOND_TOKEN: Field = ${bo.token};`);
  nr.push(`pub global BOND_NOTE_AMOUNT: Field = ${bo.note_amount};`);
  nr.push(`pub global BOND_SOURCE_SALT: Field = ${dec(field(bo.source_salt))};`);
  nr.push(`pub global BOND_LOCK_AMOUNT: Field = ${bo.lock_amount};`);
  nr.push(`pub global BOND_LOCK_SALT: Field = ${dec(field(bo.lock_salt))};`);
  nr.push(`pub global BOND_CHANGE_SALT: Field = ${dec(field(bo.change_salt))};`);
  nr.push(`pub global BOND_LOCK_COMMIT: Field = ${bo.lock_commit};`);
  nr.push(`pub global BOND_CHANGE_NOTE: Field = ${bo.change_note};`);
  nr.push(`pub global BOND_NULL_BOND: Field = ${bo.null_bond};`);
  nr.push(`pub global BOND_ROOT: Field = ${bo.root};`);
  nr.push(`pub global BOND_SK_ID: Field = ${bo.sk_id};`);
  nr.push(`pub global BOND_SIBLINGS: [Field; ${bo.siblings.length}] = [`);
  nr.push(...bo.siblings.map((x) => `    ${x},`));
  nr.push("];");
  nr.push(`pub global BOND_INDICES: [u8; ${bo.indices.length}] = [${bo.indices.join(", ")}];`);
  nr.push("");
  const cl = (v as { claim: ClaimVectors }).claim;
  nr.push(`pub global CLAIM_DEPTH: u32 = ${cl.depth};`);
  nr.push(`pub global CLAIM_DEAL_ID: Field = ${dec(field(cl.deal_id))};`);
  nr.push(`pub global CLAIM_DEAL_SUBJECT: Field = ${cl.deal_subject};`);
  nr.push(`pub global CLAIM_KIND: Field = ${cl.kind};`);
  nr.push(`pub global CLAIM_TOKEN: Field = ${cl.token};`);
  nr.push(`pub global CLAIM_PRINCIPAL: Field = ${cl.principal};`);
  nr.push(`pub global CLAIM_SK_ID: Field = ${cl.sk_id};`);
  nr.push(`pub global CLAIM_COUNT: Field = ${cl.count};`);
  nr.push(`pub global CLAIM_VOLUME: Field = ${cl.volume};`);
  nr.push(`pub global CLAIM_PENALTY: Field = ${cl.penalty};`);
  nr.push(`pub global CLAIM_IN_FLIGHT: Field = ${cl.in_flight};`);
  nr.push(`pub global CLAIM_LEAF_TOKEN: Field = ${cl.leaf_token};`);
  nr.push(`pub global CLAIM_CP_ROOT: Field = ${cl.cp_root};`);
  nr.push(`pub global CLAIM_EPOCH_IN: Field = ${cl.epoch};`);
  nr.push(`pub global CLAIM_EPOCH_CREDITS: Field = ${cl.epoch_credits};`);
  nr.push(`pub global CLAIM_CP_SK_ID: Field = ${cl.cp_sk_id};`);
  nr.push(`pub global CLAIM_CP_S: Field = ${cl.cp_s};`);
  nr.push(`pub global CLAIM_CP_ROOT_AFTER: Field = ${cl.cp_root_after};`);
  nr.push(`pub global CLAIM_PAIR_TAG: Field = ${cl.pair_tag};`);
  nr.push(`pub global CLAIM_EPOCH: Field = ${cl.claim_epoch};`);
  nr.push(`pub global CLAIM_CP_SIBLINGS: [Field; ${cl.cp_siblings.length}] = [`);
  nr.push(...cl.cp_siblings.map((x) => `    ${x},`));
  nr.push("];");
  // The two 2026-09-23 scenarios: the same counterparty again, and a spent window.
  for (const [name, sc] of [["REPEAT", (v as { claim_repeat: ClaimScenario }).claim_repeat], ["FULL", (v as { claim_full: ClaimScenario }).claim_full]] as const) {
    nr.push(`pub global CLAIM_${name}_VERSION: Field = ${sc.version};`);
    nr.push(`pub global CLAIM_${name}_CP_ROOT: Field = ${sc.cp_root};`);
    nr.push(`pub global CLAIM_${name}_EPOCH: Field = ${sc.epoch};`);
    nr.push(`pub global CLAIM_${name}_CREDITS: Field = ${sc.epoch_credits};`);
    nr.push(`pub global CLAIM_${name}_SLOT: Field = ${sc.slot};`);
    nr.push(`pub global CLAIM_${name}_NEW_LEAF: Field = ${sc.new_leaf};`);
    nr.push(`pub global CLAIM_${name}_NULL_REP: Field = ${sc.null_rep};`);
    nr.push(`pub global CLAIM_${name}_ROOT: Field = ${sc.root};`);
    nr.push(`pub global CLAIM_${name}_CP_SIBLINGS: [Field; ${sc.cp_siblings.length}] = [`);
    nr.push(...sc.cp_siblings.map((x) => `    ${x},`));
    nr.push("];");
    nr.push(`pub global CLAIM_${name}_SIBLINGS: [Field; ${sc.siblings.length}] = [`);
    nr.push(...sc.siblings.map((x) => `    ${x},`));
    nr.push("];");
    nr.push(`pub global CLAIM_${name}_INDICES: [u8; ${sc.indices.length}] = [${sc.indices.join(", ")}];`);
  }
  nr.push(`pub global CLAIM_SALT: Field = ${dec(field(cl.salt))};`);
  nr.push(`pub global CLAIM_VERSION: Field = ${cl.version};`);
  nr.push(`pub global CLAIM_NEW_SALT: Field = ${dec(field(cl.new_salt))};`);
  nr.push(`pub global CLAIM_NEW_LEAF: Field = ${cl.new_leaf};`);
  nr.push(`pub global CLAIM_NULL_REP: Field = ${cl.null_rep};`);
  nr.push(`pub global CLAIM_ROOT: Field = ${cl.root};`);
  nr.push(`pub global CLAIM_SIBLINGS: [Field; ${cl.siblings.length}] = [`);
  nr.push(...cl.siblings.map((x) => `    ${x},`));
  nr.push("];");
  nr.push(`pub global CLAIM_INDICES: [u8; ${cl.indices.length}] = [${cl.indices.join(", ")}];`);
  nr.push("");
  const dl = (v as { deltas: DeltaRow[] }).deltas;
  nr.push(`pub global DELTA_COUNT: u32 = ${dl.length};`);
  nr.push(`pub global DELTA_KINDS: [Field; ${dl.length}] = [`);
  nr.push(...dl.map((x) => `    ${x.kind},`));
  nr.push("];");
  nr.push(`pub global DELTA_NEW_COUNTS: [Field; ${dl.length}] = [`);
  nr.push(...dl.map((x) => `    ${x.new_count},`));
  nr.push("];");
  nr.push(`pub global DELTA_NEW_VOLUMES: [Field; ${dl.length}] = [`);
  nr.push(...dl.map((x) => `    ${x.new_volume},`));
  nr.push("];");
  nr.push(`pub global DELTA_NEW_PENALTIES: [Field; ${dl.length}] = [`);
  nr.push(...dl.map((x) => `    ${x.new_penalty},`));
  nr.push("];");
  nr.push(`pub global DELTA_NEW_IN_FLIGHTS: [Field; ${dl.length}] = [`);
  nr.push(...dl.map((x) => `    ${x.new_in_flight},`));
  nr.push("];");
  nr.push("");
  const rb = (v as { reabsorb: ReabsorbVectors }).reabsorb;
  nr.push(`pub global REABSORB_DEAL_ID: Field = ${dec(field(rb.deal_id))};`);
  nr.push(`pub global REABSORB_DEAL_SUBJECT: Field = ${rb.deal_subject};`);
  nr.push(`pub global REABSORB_TOKEN: Field = ${rb.token};`);
  nr.push(`pub global REABSORB_AMOUNT: Field = ${rb.amount};`);
  nr.push(`pub global REABSORB_LOCK_COMMIT: Field = ${rb.lock_commit};`);
  nr.push(`pub global REABSORB_LOCK_SALT: Field = ${dec(field(rb.lock_salt))};`);
  nr.push(`pub global REABSORB_NEW_SALT: Field = ${dec(field(rb.new_salt))};`);
  nr.push(`pub global REABSORB_NEW_NOTE: Field = ${rb.new_note};`);
  nr.push(`pub global REABSORB_NULL_BOND: Field = ${rb.null_bond};`);
  nr.push(`pub global REABSORB_SK_ID: Field = ${rb.sk_id};`);
  nr.push("");
  const w = (v as { withdraw: WithdrawVectors }).withdraw;
  nr.push(`pub global WITHDRAW_DEPTH: u32 = ${w.depth};`);
  nr.push(`pub global WITHDRAW_TOKEN: Field = ${w.token};`);
  nr.push(`pub global WITHDRAW_DEST: Field = ${w.dest};`);
  nr.push(`pub global WITHDRAW_AMOUNT: Field = ${w.amount};`);
  nr.push(`pub global WITHDRAW_NOTE_AMOUNT: Field = ${w.note_amount};`);
  nr.push(`pub global WITHDRAW_SOURCE_SALT: Field = ${dec(field(w.source_salt))};`);
  nr.push(`pub global WITHDRAW_CHANGE_SALT: Field = ${dec(field(w.change_salt))};`);
  nr.push(`pub global WITHDRAW_CHANGE_NOTE: Field = ${w.change_note};`);
  nr.push(`pub global WITHDRAW_NULL_BOND: Field = ${w.null_bond};`);
  nr.push(`pub global WITHDRAW_ROOT: Field = ${w.root};`);
  nr.push(`pub global WITHDRAW_SK_ID: Field = ${w.sk_id};`);
  nr.push(`pub global WITHDRAW_SIBLINGS: [Field; ${w.siblings.length}] = [`);
  nr.push(...w.siblings.map((x) => `    ${x},`));
  nr.push("];");
  nr.push(`pub global WITHDRAW_INDICES: [u8; ${w.indices.length}] = [${w.indices.join(", ")}];`);
  nr.push("");
  // Attest section (F4): the disclosure samples of §3.15.7. The account is mid-history
  // (12 deals, 3 lots, a +5 penalty — score 10, exactly T2), nothing in flight, version
  // 3. The membership witness is the leaf's OWN insert-time root (index 2 of the account
  // tree, after V3's claim). The claim is the honest exact one; understating is the
  // circuit's own tests. handle_salt and salt are keccak-derived (raw >= p) — reduced.
  const a = (v as { attest: AttestVectors }).attest;
  nr.push(`pub global ATTEST_DEPTH: u32 = ${a.depth};`);
  nr.push(`pub global ATTEST_SK_ID: Field = ${a.sk_id};`);
  nr.push(`pub global ATTEST_HANDLE_SALT: Field = ${dec(field(a.handle_salt))};`);
  nr.push(`pub global ATTEST_HANDLE_COMMIT: Field = ${a.handle_commit};`);
  nr.push(`pub global ATTEST_COUNT: Field = ${a.count};`);
  nr.push(`pub global ATTEST_VOLUME: Field = ${a.volume};`);
  nr.push(`pub global ATTEST_PENALTY: Field = ${a.penalty};`);
  nr.push(`pub global ATTEST_IN_FLIGHT: Field = ${a.in_flight};`);
  nr.push(`pub global ATTEST_LEAF_TOKEN: Field = ${a.leaf_token};`);
  nr.push(`pub global ATTEST_CP_ROOT: Field = ${a.cp_root};`);
  nr.push(`pub global ATTEST_EPOCH: Field = ${a.epoch};`);
  nr.push(`pub global ATTEST_EPOCH_CREDITS: Field = ${a.epoch_credits};`);
  nr.push(`pub global ATTEST_SALT: Field = ${dec(field(a.salt))};`);
  nr.push(`pub global ATTEST_VERSION: Field = ${a.version};`);
  nr.push(`pub global ATTEST_TOKEN: Field = ${a.token};`);
  nr.push(`pub global ATTEST_DECIMALS: Field = ${a.decimals};`);
  nr.push(`pub global ATTEST_TIER: Field = ${a.tier};`);
  nr.push(`pub global ATTEST_COUNT_CLAIMED: Field = ${a.count_claimed};`);
  nr.push(`pub global ATTEST_VOLUME_BAND: Field = ${a.volume_band};`);
  nr.push(`pub global ATTEST_PENALTY_BAND: Field = ${a.penalty_band};`);
  nr.push(`pub global ATTEST_EXPIRY: Field = ${a.expiry};`);
  nr.push(`pub global ATTEST_SCORE: Field = ${a.score};`);
  nr.push(`pub global ATTEST_ROOT: Field = ${a.root};`);
  nr.push(`pub global ATTEST_SIBLINGS: [Field; ${a.siblings.length}] = [`);
  nr.push(...a.siblings.map((x) => `    ${x},`));
  nr.push("];");
  nr.push(`pub global ATTEST_INDICES: [u8; ${a.indices.length}] = [${a.indices.join(", ")}];`);
  nr.push("");
  // Reveal section (F4): the exact profile under the same handle — both fields chosen
  // (mask 0b11), minted for the pinned requester (keccak-derived, reduced). The witness
  // is the SAME account state as the attest section (one leaf, two views).
  const rv = (v as { reveal: RevealVectors }).reveal;
  nr.push(`pub global REVEAL_HANDLE_COMMIT: Field = ${rv.handle_commit};`);
  nr.push(`pub global REVEAL_FIELDS_MASK: Field = ${rv.fields_mask};`);
  nr.push(`pub global REVEAL_OUT_COUNT: Field = ${rv.out_count};`);
  nr.push(`pub global REVEAL_OUT_VOLUME: Field = ${rv.out_volume};`);
  nr.push(`pub global REVEAL_OUT_PENALTY: Field = ${rv.out_penalty};`);
  nr.push(`pub global REVEAL_REQUESTER: Field = ${rv.requester};`);
  nr.push(`pub global REVEAL_TOKEN: Field = ${rv.token};`);
  nr.push(`pub global REVEAL_SK_ID: Field = ${rv.sk_id};`);
  nr.push(`pub global REVEAL_HANDLE_SALT: Field = ${dec(field(rv.handle_salt))};`);
  nr.push(`pub global REVEAL_COUNT: Field = ${rv.count};`);
  nr.push(`pub global REVEAL_VOLUME: Field = ${rv.volume};`);
  nr.push(`pub global REVEAL_PENALTY: Field = ${rv.penalty};`);
  nr.push(`pub global REVEAL_IN_FLIGHT: Field = ${rv.in_flight};`);
  nr.push(`pub global REVEAL_LEAF_TOKEN: Field = ${rv.leaf_token};`);
  nr.push(`pub global REVEAL_CP_ROOT: Field = ${rv.cp_root};`);
  nr.push(`pub global REVEAL_EPOCH: Field = ${rv.epoch};`);
  nr.push(`pub global REVEAL_EPOCH_CREDITS: Field = ${rv.epoch_credits};`);
  nr.push(`pub global REVEAL_SALT: Field = ${dec(field(rv.salt))};`);
  nr.push(`pub global REVEAL_VERSION: Field = ${rv.version};`);
  nr.push(`pub global REVEAL_ROOT: Field = ${rv.root};`);
  nr.push(`pub global REVEAL_SIBLINGS: [Field; ${rv.siblings.length}] = [`);
  nr.push(...rv.siblings.map((x) => `    ${x},`));
  nr.push("];");
  nr.push(`pub global REVEAL_INDICES: [u8; ${rv.indices.length}] = [${rv.indices.join(", ")}];`);
  nr.push("");
  return nr.join("\n");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
