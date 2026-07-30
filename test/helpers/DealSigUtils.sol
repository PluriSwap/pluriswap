// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {DealHashing} from "../../src/libraries/DealHashing.sol";
import {DealTerms, ResolutionAuth} from "../../src/libraries/DealTypes.sol";

library DealSigUtils {
    address private constant VM_ADDRESS = address(uint160(uint256(keccak256("hevm cheat code"))));

    bytes32 internal constant DOMAIN_TYPEHASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );

    function domainSeparator(uint256 chainId, address verifyingContract)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                DOMAIN_TYPEHASH,
                keccak256(bytes("PluriSwap")),
                keccak256(bytes("2")),
                chainId,
                verifyingContract
            )
        );
    }

    function signDeal(uint256 pk, bytes32 domainSep, DealTerms memory terms)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest_ = DealHashing.digest(domainSep, DealHashing.hashDealTerms(terms));
        return _sign(pk, digest_);
    }

    function signResolution(uint256 pk, bytes32 domainSep, ResolutionAuth memory auth)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest_ = DealHashing.digest(domainSep, DealHashing.hashResolution(auth));
        return _sign(pk, digest_);
    }

    function _sign(uint256 pk, bytes32 digest_) private view returns (bytes memory) {
        Vm vm = Vm(VM_ADDRESS);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest_);
        return abi.encodePacked(r, s, v);
    }
}
