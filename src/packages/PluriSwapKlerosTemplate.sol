// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Static KIP-99 template. 0x00 refuse, 0x01 Holder, 0x02 Provider.
///      Matches `KlerosAdapter._map`. No IPFS; mappings are empty.
library PluriSwapKlerosTemplate {
    function json() internal pure returns (string memory) {
        return string.concat(
            '{"title":"PluriSwap escrow",',
            '"description":"Holder deposited principal. Provider claims the off-chain delivery was completed. Decide who receives the escrowed principal.",',
            '"question":"Who should receive the escrowed principal?",',
            '"answers":[',
            '{"id":"0x00","title":"Refuse to Arbitrate / Invalid","description":"The dispute cannot be decided."},',
            '{"id":"0x01","title":"Holder","description":"Return the principal to the Holder."},',
            '{"id":"0x02","title":"Provider","description":"Release the principal to the Provider."}',
            '],',
            '"arbitratorChainID":"421614",',
            '"arbitratorAddress":"0xE8442307d36e9bf6aB27F1A009F95CE8E11C3479",',
            '"category":"Escrow","lang":"en_US","specification":"KIP-99","version":"1.0"}'
        );
    }

    function mappings() internal pure returns (string memory) {
        return "[]";
    }

    function tag() internal pure returns (string memory) {
        return "pluriswap";
    }
}
