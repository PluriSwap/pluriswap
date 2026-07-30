// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SignatureValidation} from "../src/libraries/SignatureValidation.sol";
import {IERC1271} from "../src/interfaces/IERC1271.sol";

contract SignatureValidationHarness {
    function isValid(address expected, bytes32 digest, bytes calldata signature)
        external
        view
        returns (bool)
    {
        return SignatureValidation.isValid(expected, digest, signature);
    }
}

contract Validating1271 is IERC1271 {
    bool public valid = true;

    function setValid(bool valid_) external {
        valid = valid_;
    }

    function isValidSignature(bytes32, bytes calldata) external view returns (bytes4) {
        return valid ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract SignatureValidationTest is Test {
    SignatureValidationHarness harness;
    Validating1271 wallet;
    uint256 privateKey = 0xA11CE;
    address signer;
    bytes32 digest = keccak256("signature-validation");

    function setUp() public {
        harness = new SignatureValidationHarness();
        wallet = new Validating1271();
        signer = vm.addr(privateKey);
    }

    function _signature() internal returns (uint8 v, bytes32 r, bytes32 s) {
        return vm.sign(privateKey, digest);
    }

    function test_canonical65Signature() public {
        (uint8 v, bytes32 r, bytes32 s) = _signature();
        assertTrue(harness.isValid(signer, digest, abi.encodePacked(r, s, v)));
    }

    function test_eip2098Signature() public {
        (uint8 v, bytes32 r, bytes32 s) = _signature();
        uint256 vs = uint256(s) | (uint256(v - 27) << 255);
        assertTrue(harness.isValid(signer, digest, abi.encodePacked(r, bytes32(vs))));
    }

    function test_highSAndBadVReject() public {
        (uint8 v, bytes32 r, bytes32 s) = _signature();
        uint256 curveOrder = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
        bytes32 highS = bytes32(curveOrder - uint256(s));
        assertFalse(harness.isValid(signer, digest, abi.encodePacked(r, highS, uint8(55 - v))));
        assertFalse(harness.isValid(signer, digest, abi.encodePacked(r, s, uint8(0))));
    }

    function test_contractWalletAcceptsArbitraryBytes() public {
        assertTrue(harness.isValid(address(wallet), digest, hex"deadbeef"));
        wallet.setValid(false);
        assertFalse(harness.isValid(address(wallet), digest, hex"deadbeef"));
    }

    function test_wrongSignerRejects() public {
        (uint8 v, bytes32 r, bytes32 s) = _signature();
        assertFalse(harness.isValid(address(0xB0B), digest, abi.encodePacked(r, s, v)));
    }
}
