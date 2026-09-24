// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBundleVerifier} from "../interfaces/IBundleVerifier.sol";

/// @title BundleVerifier
/// @notice The real `prepare_side` verifier behind the frozen `IBundleVerifier`
///         (PLURISWAP.md §3.15.4, 2026-09-23): one ultra_honk proof covering one side of an
///         activation — its passport, its admission and, when the deal carries bonds, its split.
///
/// @dev Fail-closed everywhere, like every other adapter: a malformed blob, an argument the proof's
///      public inputs do not name, a failed deploy, or any revert inside the generated verifier
///      reads as `false` — never as a revert-shaped pass.
///
///      The proof blob is `proof || public_inputs` (bb's layout): the trailing 448 bytes are the
///      fourteen public inputs in circuit order. Thirteen must match the caller's `BundleInputs`
///      exactly; the fourteenth is `decimals`, which the interface has no field for because the
///      adapter reads it from the SERVED token and requires the proof to have used that value — the
///      tier scale is `UNIT = 250 * 10^decimals`, so a proof scaled for another token's decimals
///      must not admit this deal (§3.14.7, and the same amplification `PrepareAdmitVerifier` does).
///
///      Two encodings that have bitten before and are pinned here:
///      * addresses are field elements RIGHT-aligned — `bytes32(uint256(uint160(token)))`, never
///        `bytes32(bytes20)`;
///      * `dealId` is a raw keccak tag that may sit above the BN254 modulus, so it is compared
///        reduced, which is the pinned mod-p rule at the adapter boundary.
///
///      The ticket lives in TRANSIENT storage (EIP-1153, Cancun — the same facility the kernel's
///      reentrancy guard uses). It is keyed by the hash of the inputs, so it can only satisfy a
///      module that is about to act on exactly those values, and it is gone when the transaction
///      ends: permission to assemble a bundle cannot be banked.
contract BundleVerifier is IBundleVerifier {
    /// @dev `verify(bytes,bytes32[])` — the generated ultra_honk verifier's only entrypoint.
    bytes4 internal constant VERIFY_SELECTOR = bytes4(keccak256("verify(bytes,bytes32[])"));

    /// @dev `decimals()` of the served ERC-20 — the tier scale is the token's own.
    bytes4 internal constant DECIMALS_SELECTOR = bytes4(keccak256("decimals()"));

    /// @dev The fourteen public inputs of `prepare_side`, in its declared order.
    uint256 internal constant PUBLIC_INPUTS = 14;

    uint256 internal constant BN254_P = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @dev The generated Honk verifier, deployed from initcode in the constructor. Zero (deploy
    ///      failed) fails every verify.
    address public immutable honkVerifier;

    constructor(bytes memory verifierInitcode) {
        address deployed;
        assembly {
            deployed := create(0, add(verifierInitcode, 0x20), mload(verifierInitcode))
        }
        honkVerifier = deployed;
    }

    /// @inheritdoc IBundleVerifier
    function verify(BundleInputs calldata inputs, bytes calldata proof) external returns (bool) {
        bytes32 key = _key(inputs);
        if (_ticket(key)) return true; // already proven in this transaction
        if (honkVerifier == address(0)) return false; // deploy failed — fail closed
        if (proof.length < PUBLIC_INPUTS * 32) return false; // cannot even carry the public inputs

        (bytes32[] memory pubs, bytes calldata honkProof) = _split(proof);
        if (!_namesTheSameSide(inputs, pubs)) return false;
        if (!_verify(honkProof, pubs)) return false;

        assembly ("memory-safe") {
            tstore(key, 1)
        }
        return true;
    }

    /// @inheritdoc IBundleVerifier
    function wasProven(BundleInputs calldata inputs) external view returns (bool) {
        return _ticket(_key(inputs));
    }

    /// @dev Every public input against the caller's values. The order is the circuit's, and a
    ///      mismatch anywhere is `false` — this is the whole of what the adapter promises.
    function _namesTheSameSide(BundleInputs calldata i, bytes32[] memory pubs) internal view returns (bool) {
        if (pubs[0] != i.dealSubject) return false;
        // The raw keccak tag may sit over p; the proof names its canonical field element.
        if (uint256(pubs[1]) != uint256(i.dealId) % BN254_P) return false;
        if (pubs[2] != bytes32(uint256(uint160(i.token)))) return false; // raw address < p always
        if (pubs[3] != bytes32(i.principal)) return false; // raw amount; >= p can never match
        // The scale belongs to the served token, not to the prover.
        if (_decimalsOf(i.token) != uint256(pubs[4])) return false;
        if (pubs[5] != i.repRoot) return false;
        if (pubs[6] != i.newLeaf) return false;
        if (pubs[7] != i.nullRep) return false;
        if (pubs[8] != i.pairTag) return false;
        if (pubs[9] != i.lockCommit) return false;
        if (pubs[10] != bytes32(i.lockAmount)) return false;
        if (pubs[11] != i.changeNote) return false;
        if (pubs[12] != i.nullBond) return false;
        if (pubs[13] != i.bondRoot) return false;
        return true;
    }

    /// @dev The ticket's slot: the hash of the inputs a module is about to act on. Content-keyed on
    ///      purpose — a ticket is worthless to anyone holding different values.
    function _key(BundleInputs calldata inputs) internal pure returns (bytes32) {
        return keccak256(abi.encode(inputs));
    }

    function _ticket(bytes32 key) internal view returns (bool set) {
        assembly ("memory-safe") {
            set := tload(key)
        }
    }

    /// @dev Split the blob into the trailing public inputs and the proof body. A malformed length
    ///      returns empty pubs, which fails every check above — never reverts.
    function _split(bytes calldata blob) internal pure returns (bytes32[] memory, bytes calldata) {
        if (blob.length < PUBLIC_INPUTS * 32) {
            return (new bytes32[](0), blob[0:0]);
        }
        uint256 proofLen = blob.length - PUBLIC_INPUTS * 32;
        bytes32[] memory pubs = new bytes32[](PUBLIC_INPUTS);
        for (uint256 i = 0; i < PUBLIC_INPUTS; i++) {
            pubs[i] = bytes32(blob[proofLen + i * 32:proofLen + (i + 1) * 32]);
        }
        return (pubs, blob[0:proofLen]);
    }

    /// @dev The served token's `decimals()`. Fail-closed read: any revert, missing code or short
    ///      return decodes to a sentinel no proof can name (the circuit bounds decimals below 32).
    function _decimalsOf(address token) internal view returns (uint256) {
        (bool ok, bytes memory ret) = token.staticcall(abi.encodeWithSelector(DECIMALS_SELECTOR));
        if (!ok || ret.length < 32) return type(uint256).max;
        return abi.decode(ret, (uint256));
    }

    /// @dev Call the generated verifier. `verify` is `view`: staticcall, so the adapter cannot even
    ///      be tricked into a state change; any revert or short/odd return is `false`.
    function _verify(bytes calldata honkProof, bytes32[] memory pubs) internal view returns (bool) {
        (bool ok, bytes memory ret) = honkVerifier.staticcall(abi.encodeWithSelector(VERIFY_SELECTOR, honkProof, pubs));
        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }
}
