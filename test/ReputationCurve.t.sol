// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Reputation} from "../src/packages/Reputation.sol";
import {IReputation} from "../src/packages/interfaces/IReputation.sol";
import {PassportMock} from "../mocks/PassportMock.sol";
import {TestToken} from "../mocks/TestToken.sol";

/// @title The reputation curve
/// @notice Pins the ladder table of PLURISWAP.md §3.14.7 against the code that produces it.
/// @dev `script/ReputationLadder.s.sol` walks this on a real chain and narrates it, which is how you
///      learn what the package does. This is the fast half: the spec now states "five deals at the
///      cap reach T2, twenty-one reach T5" as a measured fact, and a measured fact in a document
///      rots silently unless something fails when it stops being true.
///
///      The shape worth remembering: a deal AT THE CAP is worth two points, because the T1 cap is
///      exactly the score's unit of volume (+1 for closing, +1 for the volume). So the climb
///      accelerates on its own — a higher cap means more volume per deal.
contract ReputationCurveTest is Test {
    Reputation internal rep;
    TestToken internal token;
    PassportMock internal passport;
    bytes32 internal constant SUBJECT = keccak256("curve");
    address internal operator = address(0xAA);
    address internal wallet = address(0xA11CE);

    function setUp() public {
        token = new TestToken();
        passport = new PassportMock();
        passport.setHuman(wallet, SUBJECT);
        rep = new Reputation(passport, address(0xFEE), 0, 0, 0, 0, operator);
    }

    function _closeAtCap(IReputation.Close kind) internal returns (uint256 principal) {
        principal = rep.cap(SUBJECT, address(token), false);
        vm.startPrank(operator);
        rep.admit(wallet, address(token), principal, address(0));
        rep.notifyTerminal(SUBJECT, address(token), principal, kind);
        vm.stopPrank();
    }

    function _cap() internal view returns (uint256) {
        return rep.cap(SUBJECT, address(token), false);
    }

    function _score() internal view returns (uint256) {
        return rep.score(SUBJECT, address(token));
    }

    /// The table in §3.14.7, row by row.
    function test_theLadderIsWhatTheSpecSays() public {
        assertEq(_score(), 0);
        assertEq(_cap(), 250e6, "T1");

        for (uint256 i = 0; i < 5; i++) {
            _closeAtCap(IReputation.Close.Peaceful);
        }
        assertEq(_score(), 10, "five deals at the cap");
        assertEq(_cap(), 500e6, "T2");

        for (uint256 i = 0; i < 5; i++) {
            _closeAtCap(IReputation.Close.Peaceful);
        }
        assertEq(_score(), 25, "ten deals");
        assertEq(_cap(), 1000e6, "T3");

        for (uint256 i = 0; i < 5; i++) {
            _closeAtCap(IReputation.Close.Peaceful);
        }
        assertEq(_score(), 50, "fifteen deals");
        assertEq(_cap(), 2000e6, "T4");

        for (uint256 i = 0; i < 6; i++) {
            _closeAtCap(IReputation.Close.Peaceful);
        }
        assertEq(_score(), 104, "twenty-one deals");
        // T5's base column tops at 5.000 (2026-09-23): unlimited exposure is the BOND column, so the
        // protocol's one uncapped position always has a live lock — 10% of itself — behind it.
        assertEq(_cap(), 5000e6, "T5 without bond");
        assertEq(rep.cap(SUBJECT, address(token), true), type(uint256).max, "T5 with bond: no limit");
    }

    /// A deal at the cap is worth two points and not one: the cap IS the unit.
    function test_aDealAtTheCapIsWorthTwo() public {
        _closeAtCap(IReputation.Close.Peaceful);
        assertEq(_score(), 2);
    }

    /// The cap is the most that can be OPEN at once, which is the thing people misread.
    function test_theCapIsConcurrentNotPerDeal() public {
        vm.startPrank(operator);
        rep.admit(wallet, address(token), 150e6, address(0));
        vm.expectRevert(Reputation.CapExceeded.selector);
        rep.admit(wallet, address(token), 150e6, address(0));
        vm.stopPrank();
        assertEq(rep.inFlight(SUBJECT, address(token)), 150e6, "the first one is still holding it");
    }

    /// Slow to earn, fast to lose: five clean deals of work, one abandoned dispute, back to T1.
    function test_oneAbandonedDisputeCostsATier() public {
        for (uint256 i = 0; i < 5; i++) {
            _closeAtCap(IReputation.Close.Peaceful);
        }
        assertEq(_cap(), 500e6, "T2");
        _closeAtCap(IReputation.Close.Stalemate); // the reading an abandoned dispute gives the opener
        assertEq(_score(), 5, "minus five");
        assertEq(_cap(), 250e6, "back to T1, in one deal");
    }

    /// The counterparty of an abandoned dispute gets the same credit as a clean trade. Worth pinning
    /// because it is an incentive, not an accident: it is why refusing to settle can pay.
    function test_theCounterpartyOfAnAbandonmentIsPaidLikeACleanTrade() public {
        bytes32 other = keccak256("counterparty");
        address otherWallet = address(0xB0B);
        passport.setHuman(otherWallet, other);
        vm.startPrank(operator);
        rep.admit(wallet, address(token), 250e6, address(0));
        rep.admit(otherWallet, address(token), 250e6, address(0));
        rep.notifyTerminal(SUBJECT, address(token), 250e6, IReputation.Close.Stalemate);
        rep.notifyTerminal(other, address(token), 250e6, IReputation.Close.Peaceful);
        vm.stopPrank();
        assertEq(_score(), 0, "the opener lost five, floored at zero");
        assertEq(rep.score(other, address(token)), 2, "the counterparty gained a clean trade");
    }

    /// An arbitration loss is three times an abandonment, and a win costs nothing.
    function test_aVerdictWeighsMoreThanAClockRunningOut() public {
        for (uint256 i = 0; i < 10; i++) {
            _closeAtCap(IReputation.Close.Peaceful);
        }
        uint256 before = _score();
        _closeAtCap(IReputation.Close.ArbLoss);
        assertEq(_score(), before - 15, "a proven loss is fifteen");

        uint256 mid = _score();
        _closeAtCap(IReputation.Close.ArbWin);
        assertEq(_score(), mid, "a win moves nothing: the volume is not credited either");
    }
}
