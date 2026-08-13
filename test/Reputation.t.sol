// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../src/TestToken.sol";
import {PassportMock} from "../src/packages/PassportMock.sol";
import {Reputation} from "../src/packages/Reputation.sol";
import {PackageId} from "../src/packages/PackageId.sol";

contract ReputationTest is Test {
    bytes32 internal constant SUBJECT_H = keccak256("subject-h");
    address internal holder = address(0xA11CE);
    address internal feeRecipient = address(0xFEE);

    TestToken internal token;
    PassportMock internal passport;
    Reputation internal reputation;

    function setUp() public {
        token = new TestToken();
        passport = new PassportMock();
        reputation = new Reputation(passport, feeRecipient, 0, 0);
    }

    function test_packageId_passportAndReputationStable() public view {
        assertEq(passport.packageId(), PackageId.passport(address(passport)));
        assertEq(reputation.packageId(), PackageId.reputation(address(reputation), feeRecipient, 0, 0));
    }

    function test_noPassport_noAdmit() public {
        vm.expectRevert(PassportMock.NoPassport.selector);
        reputation.admit(holder, address(token), 1, false);
    }

    function test_t1Cap() public {
        passport.setHuman(holder, SUBJECT_H);
        uint256 cap = 250 * 10 ** uint256(token.decimals());
        vm.expectRevert(Reputation.CapExceeded.selector);
        reputation.admit(holder, address(token), cap + 1, false);
        reputation.admit(holder, address(token), cap, false);
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), cap);
        vm.expectRevert(Reputation.CapExceeded.selector);
        reputation.admit(holder, address(token), 1, false);
    }

    function test_notifyTerminal_doesNotRevertEscrow() public {
        TerminalHarness escrow = new TerminalHarness();
        escrow.releaseThenNotify(reputation, holder, address(token), 1);
        assertEq(uint8(escrow.status()), uint8(TerminalHarness.Status.RELEASED));
    }
}

contract TerminalHarness {
    enum Status {
        NONE,
        RELEASED
    }

    Status public status;

    function releaseThenNotify(Reputation r, address wallet, address token, uint256 principal) external {
        status = Status.RELEASED;
        try r.notifyTerminal(wallet, token, principal, Reputation.Close.Peaceful) {} catch {}
    }
}
