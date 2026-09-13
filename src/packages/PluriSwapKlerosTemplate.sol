// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @dev Kleros V2 dispute template (KIP-99 `DisputeDetails` v1.0). 0x00 refuse, 0x01 Holder, 0x02 Provider;
///      matches `KlerosAdapter._map`.
///
///      The Court UI renders the template with mustache after running `mappings()`: one `abi/call` against the
///      arbitrable (`{{arbitrableAddress}}` = the adapter) with `{{externalDisputeID}}` (= `uint256(dealId)`),
///      which fills `dealId`, `holder`, `provider`, `token`, `amount` from `KlerosAdapter.caseOf`. Nothing else is
///      fetched: no subgraph, no IPFS beyond the policy. `policyURI` is mandatory in the schema (multiaddr, e.g.
///      `/ipfs/<cid>/policy.pdf`); without it the Court UI refuses to render the case.
library PluriSwapKlerosTemplate {
    function json(uint256 chainId, address arbitrator, string memory policyUri) internal pure returns (string memory) {
        return string.concat(
            '{"title":"PluriSwap escrow: {{amount}} for deal {{dealId}}",',
            '"description":"The Holder ({{holder}}) locked {{amount}} in a PluriSwap escrow against an off-chain payment. ',
            "The Provider ({{provider}}) claims the payment was completed; the Holder disputes it. ",
            'Both parties submit their evidence in this case. Decide who receives the escrowed amount.",',
            '"question":"Who should receive the escrowed amount?",',
            '"answers":[',
            '{"id":"0x00","title":"Refuse to Arbitrate / Invalid","description":"The dispute cannot be decided. The escrow splits 50/50 and no bond moves."},',
            '{"id":"0x01","title":"Holder","description":"Return the escrowed amount to the Holder. The Provider did not complete the payment."},',
            '{"id":"0x02","title":"Provider","description":"Release the escrowed amount to the Provider. The payment was completed as agreed."}',
            "],",
            '"policyURI":"',
            policyUri,
            '",',
            '"arbitratorChainID":"',
            Strings.toString(chainId),
            '",',
            '"arbitratorAddress":"',
            Strings.toHexString(arbitrator),
            '",',
            '"metadata":{"dealId":"{{dealId}}","holder":"{{holder}}","provider":"{{provider}}","token":"{{token}}","amount":"{{amount}}"},',
            '"aliases":{"Holder":"{{holder}}","Provider":"{{provider}}"},',
            '"category":"Escrow","lang":"en_US","specification":"KIP-99","version":"1.0"}'
        );
    }

    /// @dev `seek` indexes the tuple returned by `caseOf`; `populate` names the mustache variables above.
    function mappings() internal pure returns (string memory) {
        return string.concat(
            '[{"type":"abi/call",',
            '"abi":"function caseOf(uint256) view returns (bytes32,address,address,address,string)",',
            '"functionName":"caseOf",',
            '"address":"{{arbitrableAddress}}",',
            '"args":["{{externalDisputeID}}"],',
            '"seek":["0","1","2","3","4"],',
            '"populate":["dealId","holder","provider","token","amount"]}]'
        );
    }

    function tag() internal pure returns (string memory) {
        return "pluriswap";
    }
}
