// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CreditLedger} from "../src/CreditLedger.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {
    InsufficientCredit,
    InvalidSignature,
    SelfReceiver,
    Unauthorized,
    ZeroAddress
} from "../src/libraries/CoreErrors.sol";

contract CreditLedgerTest is Test {
    CreditLedger ledger;
    MockERC20 token;
    address escrow = address(this);
    address beneficiary = address(0xB1);
    address stranger = address(0x57);

    uint256 beneficiaryKey = 0xA11CE;

    function setUp() public {
        beneficiary = vm.addr(beneficiaryKey);
        ledger = new CreditLedger(escrow, uint64(block.chainid));
        token = new MockERC20();
        token.mint(address(ledger), 1000e18);
    }

    function test_onlyEscrow_canCredit() public {
        vm.prank(stranger);
        vm.expectRevert(Unauthorized.selector);
        ledger.credit(bytes32(uint256(1)), address(token), beneficiary, 10e18);
    }

    function test_credit_then_withdraw_byThirdParty() public {
        ledger.credit(bytes32(uint256(1)), address(token), beneficiary, 10e18);
        assertEq(ledger.creditOf(address(token), beneficiary), 10e18);

        vm.prank(stranger);
        ledger.withdraw(address(token), beneficiary);
        assertEq(token.balanceOf(beneficiary), 10e18);
        assertEq(ledger.creditOf(address(token), beneficiary), 0);
    }

    function test_doubleWithdraw_reverts() public {
        ledger.credit(bytes32(uint256(1)), address(token), beneficiary, 10e18);
        ledger.withdraw(address(token), beneficiary);
        vm.expectRevert(InsufficientCredit.selector);
        ledger.withdraw(address(token), beneficiary);
    }

    function test_ethReceive_reverts() public {
        vm.expectRevert();
        (bool ok,) = address(ledger).call{value: 1 ether}("");
        ok; // silence
    }

    function test_credit_selfReceiver_reverts() public {
        vm.expectRevert(SelfReceiver.selector);
        ledger.credit(bytes32(uint256(1)), address(token), address(ledger), 1);
    }

    function test_withdrawTo_validSig() public {
        ledger.credit(bytes32(uint256(1)), address(token), beneficiary, 10e18);
        address to = address(0x70);
        uint256 nonce = 1;
        uint64 expiry = uint64(block.timestamp + 1 days);

        bytes32 typeHash = keccak256(
            "CreditWithdrawAuth(address token,address beneficiary,address to,uint256 amount,uint256 nonce,uint64 expiry)"
        );
        bytes32 structHash = keccak256(
            abi.encode(typeHash, address(token), beneficiary, to, uint256(10e18), nonce, expiry)
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", ledger.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(beneficiaryKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        ledger.withdrawTo(address(token), beneficiary, to, 10e18, nonce, expiry, sig);
        assertEq(token.balanceOf(to), 10e18);
    }

    function test_withdrawTo_badSig_reverts() public {
        ledger.credit(bytes32(uint256(1)), address(token), beneficiary, 10e18);
        address to = address(0x70);
        uint256 nonce = 1;
        uint64 expiry = uint64(block.timestamp + 1 days);

        bytes32 typeHash = keccak256(
            "CreditWithdrawAuth(address token,address beneficiary,address to,uint256 amount,uint256 nonce,uint64 expiry)"
        );
        bytes32 structHash = keccak256(
            abi.encode(typeHash, address(token), beneficiary, to, uint256(10e18), nonce, expiry)
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", ledger.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xDEAD, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.expectRevert(InvalidSignature.selector);
        ledger.withdrawTo(address(token), beneficiary, to, 10e18, nonce, expiry, sig);
    }

    function test_constructor_zeroEscrow_reverts() public {
        vm.expectRevert(ZeroAddress.selector);
        new CreditLedger(address(0), 1);
    }
}
