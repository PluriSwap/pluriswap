// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IAccountVerifier} from "../interfaces/IAccountVerifier.sol";
import {HumanityRegistry} from "../HumanityRegistry.sol";

/// @title RegistryAccountVerifier
/// @notice The real `register_account` verifier behind the frozen `IAccountVerifier`
///         (PLURISWAP.md §3.15.9, V1): proves the account side of the register bundle —
///         that `leaf0` is bound to the same per-human secret behind the burned `hn`
///         (the initial leaf's salt IS the hsk; the circuit pins it).
/// @dev Same fail-closed shape as `RegistryHumanityVerifier`, minus the root check: this
///      circuit does not re-prove membership. The bundle order does that work — the
///      reputation only trusts an hn the passport has already burned against its own
///      membership proof — and the identical public `hn` across both proofs cannot be
///      satisfied with two different registry domains without breaking Poseidon. The
///      domain is still checked here (the adapter's own read): a proof naming a foreign
///      registry fails closed.
///
///      Public inputs in circuit order: `hn`, `leaf0`, `registryId`.
contract RegistryAccountVerifier is IAccountVerifier {
    /// @dev `verify(bytes,bytes32[])` — the generated ultra_honk verifier's only entrypoint.
    bytes4 internal constant VERIFY_SELECTOR = bytes4(keccak256("verify(bytes,bytes32[])"));

    /// @dev The BN254 scalar field — the domain of every public input the circuits prove over.
    uint256 internal constant BN254_P = 21888242871839275222246405745257275088548364400416034343698204186575808495617;

    /// @dev (hn, leaf0, registryId) — must mirror register_account's pub signature order.
    uint256 internal constant PUBLIC_INPUTS = 3;

    HumanityRegistry public immutable registry;
    /// @dev The generated Honk verifier, deployed from initcode in the constructor. Zero
    ///      (deploy failed) fails every verify.
    address public immutable honkVerifier;

    error ZeroRegistry();

    constructor(HumanityRegistry registry_, bytes memory verifierInitcode) {
        if (address(registry_) == address(0)) revert ZeroRegistry();
        registry = registry_;
        address deployed;
        assembly {
            deployed := create(0, add(verifierInitcode, 0x20), mload(verifierInitcode))
        }
        honkVerifier = deployed;
    }

    /// @inheritdoc IAccountVerifier
    function verifyAccount(bytes calldata proof, bytes32 hn, bytes32 leaf0) external view returns (bool) {
        if (honkVerifier == address(0)) return false; // deploy failed — fail closed
        // A blob that cannot even carry the public inputs section is malformed: false, never
        // a panic (the empty-pubs path below would be an out-of-bounds read).
        if (proof.length < PUBLIC_INPUTS * 32) return false;
        (bytes32[] memory pubs, bytes calldata honkProof) = _split(proof);
        if (pubs[0] != hn) return false; // the nullifier the passport burned this bundle
        if (pubs[1] != leaf0) return false; // the initial leaf the reputation is inserting
        // The registry domain is a raw bytes32 tag (keccak-derived, may sit over p); the
        // proof names its canonical field element. The pinned mod-p rule applies here,
        // at the adapter boundary — a pub input can never be >= p and still match.
        if (uint256(pubs[2]) != uint256(registry.registryId()) % BN254_P) return false;
        return _verify(honkProof, pubs);
    }

    /// @dev Split the blob into the trailing public inputs and the proof body. Malformed
    ///      length returns empty pubs, which fails every caller's checks — never reverts.
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

    /// @dev Call the generated verifier. `verify` is `view`: staticcall, so the adapter cannot
    ///      even be tricked into a state change; any revert or odd return is `false`.
    function _verify(bytes calldata honkProof, bytes32[] memory pubs) internal view returns (bool) {
        (bool ok, bytes memory ret) = honkVerifier.staticcall(abi.encodeWithSelector(VERIFY_SELECTOR, honkProof, pubs));
        return ok && ret.length == 32 && abi.decode(ret, (bool));
    }
}
