// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC1271} from "../interfaces/IERC1271.sol";

/// @notice Canonical EOA/ERC-1271 signature validation shared by Core and Ledger.
library SignatureValidation {
    bytes4 internal constant ERC1271_MAGICVALUE = 0x1626ba7e;
    uint256 internal constant SECP256K1N_HALF_ORDER =
        0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0;

    function isValid(address expected, bytes32 digest, bytes calldata signature)
        internal
        view
        returns (bool)
    {
        if (expected == address(0)) return false;

        if (expected.code.length != 0) {
            (bool ok, bytes memory result) = expected.staticcall(
                abi.encodeWithSelector(IERC1271.isValidSignature.selector, digest, signature)
            );
            if (!ok || result.length != 32) return false;
            bytes4 magic;
            assembly ("memory-safe") {
                magic := mload(add(result, 32))
            }
            return magic == ERC1271_MAGICVALUE;
        }

        (uint8 v, bytes32 r, bytes32 s) = _decode(signature);
        if (v != 27 && v != 28) return false;
        if (uint256(s) == 0 || uint256(s) > SECP256K1N_HALF_ORDER) return false;

        address signer = ecrecover(digest, v, r, s);
        return signer != address(0) && signer == expected;
    }

    function _decode(bytes calldata signature)
        private
        pure
        returns (uint8 v, bytes32 r, bytes32 s)
    {
        if (signature.length == 65) {
            assembly ("memory-safe") {
                r := calldataload(signature.offset)
                s := calldataload(add(signature.offset, 32))
                v := byte(0, calldataload(add(signature.offset, 64)))
            }
            return (v, r, s);
        }

        if (signature.length == 64) {
            bytes32 vs;
            assembly ("memory-safe") {
                r := calldataload(signature.offset)
                vs := calldataload(add(signature.offset, 32))
            }
            uint256 vsValue = uint256(vs);
            v = uint8(27 + (vsValue >> 255));
            s = bytes32(
                vsValue & 0x7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff
            );
            return (v, r, s);
        }

        return (0, bytes32(0), bytes32(0));
    }
}
