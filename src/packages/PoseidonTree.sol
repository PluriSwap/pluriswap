// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Poseidon} from "./libraries/Poseidon.sol";

/// @title PoseidonTree
/// @notice Incremental binary Merkle tree over the BN254 scalar field, Poseidon-hashed and
///         circomlib-compatible (PLURISWAP.md §3.15.3).
/// @dev Hashing runs through the pinned poseidon-solidity singleton (`Poseidon`, PLURISWAP.md §5.1),
///      called by address and never linked: our own build of that library is 29,315 B, past EIP-170.
///      One contract is one tree: the accounts tree (depth 32, owner `PrivateReputation`) and the
///      notes tree (depth 20, owner `PrivateBondVault` in F3). The owner is passed explicitly and
///      predicted at deploy, because the tree must be wired into the passports of the bundle before
///      its owning module exists. `insert` and `spend` are owner-only, so nothing outside the module
///      can move roots or burn nullifiers. Roots live in a `ROOT_HISTORY`-slot ring buffer; proofs
///      may reference any root still in the ring (`isKnownRoot`). The empty-tree root is seeded into
///      the ring at deploy, so it is "known" too. A zero leaf is rejected: a real leaf must never
///      alias the zero element. Leaf, root and nullifier values are BN254 field elements passed as
///      bytes32 and hashed as uint256 internally.
contract PoseidonTree {
    uint256 public constant ROOT_HISTORY = 64;
    uint256 public constant MAX_DEPTH = 32;

    uint8 public immutable depth;
    address public immutable owner;

    uint256[] private zeros;
    uint256[] private filledSubtrees;
    uint256[ROOT_HISTORY] private rootHistory;
    uint256 private rootCursor;

    uint256 public nextIndex;
    uint256 private currentRoot;

    mapping(bytes32 => bool) public isSpent;

    event LeafInserted(uint256 indexed index, bytes32 leaf, uint256 root);
    event NullifierSpent(bytes32 indexed nullifier);

    error BadDepth();
    error ZeroOwner();
    error TreeFull();
    error ZeroLeaf();
    error NotOwner();
    error NullifierUsed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(uint8 depth_, address owner_) {
        if (depth_ == 0 || depth_ > MAX_DEPTH) revert BadDepth();
        if (owner_ == address(0)) revert ZeroOwner();
        depth = depth_;
        owner = owner_;

        zeros.push(0);
        for (uint8 level = 1; level <= depth_; level++) {
            zeros.push(_hashPair(zeros[level - 1], zeros[level - 1]));
        }
        for (uint8 level = 0; level < depth_; level++) {
            filledSubtrees.push(zeros[level]);
        }
        currentRoot = zeros[depth_];
        rootHistory[0] = currentRoot;
        rootCursor = 1;
    }

    /// @notice Appends `leaf` and returns its index and the new root. Cost: `depth` Poseidon hashes.
    function insert(bytes32 leaf) external onlyOwner returns (uint256 index, bytes32 newRoot) {
        uint256 node = uint256(leaf);
        if (node == 0) revert ZeroLeaf();
        if (nextIndex >= uint256(1) << depth) revert TreeFull();

        uint256 cursor = nextIndex;
        for (uint8 level = 0; level < depth; level++) {
            if (cursor & 1 == 0) {
                filledSubtrees[level] = node;
                node = _hashPair(node, zeros[level]);
            } else {
                node = _hashPair(filledSubtrees[level], node);
            }
            cursor >>= 1;
        }

        index = nextIndex;
        nextIndex = index + 1;
        currentRoot = node;
        rootHistory[rootCursor] = node;
        rootCursor = (rootCursor + 1) % ROOT_HISTORY;

        emit LeafInserted(index, leaf, node);
        return (index, bytes32(node));
    }

    /// @notice Root of the empty tree until the first insert; root after the last insert afterwards.
    function root() external view returns (bytes32) {
        return bytes32(currentRoot);
    }

    /// @notice True while `root_` is one of the last `ROOT_HISTORY` roots (empty-tree root included).
    function isKnownRoot(bytes32 root_) external view returns (bool) {
        uint256 value = uint256(root_);
        if (value == 0) return false;
        for (uint256 i = 0; i < ROOT_HISTORY; i++) {
            if (rootHistory[i] == value) return true;
        }
        return false;
    }

    /// @notice Burns `nullifier` for this tree; burning the same value twice reverts.
    function spend(bytes32 nullifier) external onlyOwner {
        if (isSpent[nullifier]) revert NullifierUsed();
        isSpent[nullifier] = true;
        emit NullifierSpent(nullifier);
    }

    /// @dev The pinned poseidon-solidity singleton, called by address (PLURISWAP.md §5.1) — never a
    ///      library linked into this tree, whose build is past EIP-170. On a chain where the
    ///      singleton was never deployed this reverts, and since the constructor seeds `zeros` with
    ///      it, a tree can never exist without a hasher.
    function _hashPair(uint256 left, uint256 right) private view returns (uint256) {
        return Poseidon.t3(left, right);
    }
}
