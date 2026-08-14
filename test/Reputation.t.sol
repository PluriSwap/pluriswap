// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {TestToken} from "../src/TestToken.sol";
import {PassportMock} from "../src/packages/PassportMock.sol";
import {Reputation} from "../src/packages/Reputation.sol";
import {BondVault} from "../src/packages/BondVault.sol";
import {PackageId} from "../src/packages/PackageId.sol";
import {IPassport} from "../src/packages/interfaces/IPassport.sol";

contract ReputationTest is Test {
    uint256 internal constant UNIT = 250 * 1e6;
    bytes32 internal constant SUBJECT_H = keccak256("subject-h");
    address internal holder = address(0xA11CE);
    address internal holder2 = address(0xA11CE2);
    address internal feeRecipient = address(0xFEE);

    TestToken internal token;
    PassportMock internal passport;
    Reputation internal reputation;
    BondVault internal vault;

    function setUp() public {
        token = new TestToken();
        passport = new PassportMock();
        reputation = new Reputation(passport, feeRecipient, 1_000_000, 2_000_000);
        vault = new BondVault(address(this), address(0xdeaD), passport);
        passport.setHuman(holder, SUBJECT_H);
        token.mint(holder, 10_000_000);
        vm.prank(holder);
        token.approve(address(vault), type(uint256).max);
    }

    function test_packageId_passportAndReputationStable() public view {
        assertEq(passport.packageId(), PackageId.passport(address(passport)));
        assertEq(
            reputation.packageId(), PackageId.reputation(address(reputation), feeRecipient, 1_000_000, 2_000_000)
        );
    }

    function test_invoice_declaredInPackage() public view {
        (uint256 act, address actTo) = reputation.invoiceActivation();
        (uint256 done, address doneTo) = reputation.invoiceCompletion();
        assertEq(act, 1_000_000);
        assertEq(done, 2_000_000);
        assertEq(actTo, feeRecipient);
        assertEq(doneTo, feeRecipient);
    }

    function test_identify_twoWalletsShareSubject() public {
        passport.setHuman(holder2, SUBJECT_H);
        assertEq(passport.identify(holder), SUBJECT_H);
        assertEq(passport.identify(holder2), SUBJECT_H);
        reputation.admit(holder, address(token), UNIT / 2, address(0));
        reputation.admit(holder2, address(token), UNIT / 2, address(0));
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), UNIT);
        vm.expectRevert(Reputation.CapExceeded.selector);
        reputation.admit(holder2, address(token), 1, address(0));
    }

    function test_noPassport_noAdmit() public {
        vm.expectRevert(IPassport.NoPassport.selector);
        reputation.admit(address(0xB0B), address(token), 1, address(0));
    }

    function test_noPassport_noNotify() public {
        vm.expectRevert(IPassport.NoPassport.selector);
        reputation.notifyTerminal(address(0xB0B), address(token), 1, Reputation.Close.Peaceful);
    }

    function test_t1Cap() public {
        vm.expectRevert(Reputation.CapExceeded.selector);
        reputation.admit(holder, address(token), UNIT + 1, address(0));
        reputation.admit(holder, address(token), UNIT, address(0));
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), UNIT);
        vm.expectRevert(Reputation.CapExceeded.selector);
        reputation.admit(holder, address(token), 1, address(0));
    }

    function test_withBond_t1Cap400() public {
        uint256 capBond = 400 * 1e6;
        token.mint(holder, capBond);
        vm.prank(holder);
        vault.deposit(SUBJECT_H, address(token), capBond);
        vm.expectRevert(Reputation.CapExceeded.selector);
        reputation.admit(holder, address(token), capBond + 1, address(vault));
        reputation.admit(holder, address(token), capBond, address(vault));
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), capBond);
    }

    function test_withBond_insufficientAvailable() public {
        vm.expectRevert(Reputation.InsufficientBond.selector);
        reputation.admit(holder, address(token), UNIT, address(vault));
    }

    function test_notifyPeaceful_updatesScore() public {
        reputation.admit(holder, address(token), UNIT, address(0));
        reputation.notifyTerminal(holder, address(token), UNIT, Reputation.Close.Peaceful);
        (uint32 count, uint32 penalty, uint256 volume) = reputation.stats(SUBJECT_H, address(token));
        assertEq(count, 1);
        assertEq(penalty, 0);
        assertEq(volume, UNIT);
        assertEq(reputation.score(SUBJECT_H, address(token)), 2);
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), 0);
    }

    function test_notifySilent_noScore() public {
        reputation.admit(holder, address(token), UNIT, address(0));
        reputation.notifyTerminal(holder, address(token), UNIT, Reputation.Close.Silent);
        (uint32 count, uint32 penalty, uint256 volume) = reputation.stats(SUBJECT_H, address(token));
        assertEq(count, 0);
        assertEq(penalty, 0);
        assertEq(volume, 0);
        assertEq(reputation.score(SUBJECT_H, address(token)), 0);
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), 0);
    }

    function test_notifyStalemate_penaltyFive() public {
        reputation.admit(holder, address(token), UNIT, address(0));
        reputation.notifyTerminal(holder, address(token), UNIT, Reputation.Close.Stalemate);
        (, uint32 penalty,) = reputation.stats(SUBJECT_H, address(token));
        assertEq(penalty, 5);
        assertEq(reputation.score(SUBJECT_H, address(token)), 0);
    }

    function test_notifyArb_winNoVolume_lossPenaltyFifteen() public {
        reputation.admit(holder, address(token), UNIT / 2, address(0));
        reputation.notifyTerminal(holder, address(token), UNIT / 2, Reputation.Close.ArbWin);
        (uint32 count, uint32 penalty, uint256 volume) = reputation.stats(SUBJECT_H, address(token));
        assertEq(count, 0);
        assertEq(penalty, 0);
        assertEq(volume, 0);
        reputation.admit(holder, address(token), UNIT / 2, address(0));
        reputation.notifyTerminal(holder, address(token), UNIT / 2, Reputation.Close.ArbLoss);
        (, penalty,) = reputation.stats(SUBJECT_H, address(token));
        assertEq(penalty, 15);
    }

    function test_fivePeaceful_t2Cap() public {
        for (uint256 i; i < 5; i++) {
            reputation.admit(holder, address(token), UNIT, address(0));
            reputation.notifyTerminal(holder, address(token), UNIT, Reputation.Close.Peaceful);
        }
        assertEq(reputation.score(SUBJECT_H, address(token)), 10);
        uint256 t2 = 500 * 1e6;
        reputation.admit(holder, address(token), t2, address(0));
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), t2);
        vm.expectRevert(Reputation.CapExceeded.selector);
        reputation.admit(holder, address(token), 1, address(0));
    }

    function test_trio_peacefulUnlocksBond() public {
        bytes32 dealId = keccak256("deal-trio");
        token.mint(holder, UNIT / 10);
        vm.prank(holder);
        vault.deposit(SUBJECT_H, address(token), UNIT / 10);
        reputation.admit(holder, address(token), UNIT, address(vault));
        vault.reserve(SUBJECT_H, address(token), dealId, UNIT);
        reputation.notifyTerminal(holder, address(token), UNIT, Reputation.Close.Peaceful);
        vault.unlock(SUBJECT_H, address(token), dealId);
        vm.prank(holder);
        vault.withdraw(SUBJECT_H, address(token), UNIT / 10);
        assertEq(token.balanceOf(holder), 10_000_000 + UNIT / 10);
        assertEq(reputation.inFlight(SUBJECT_H, address(token)), 0);
        assertEq(reputation.score(SUBJECT_H, address(token)), 2);
    }

    function test_notifyTerminal_doesNotRevertEscrow() public {
        TerminalHarness escrow = new TerminalHarness();
        escrow.releaseThenNotify(reputation, address(0xB0B), address(token), 1);
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
