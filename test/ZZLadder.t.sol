// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {Reputation} from "../src/packages/Reputation.sol";
import {IReputation} from "../src/packages/interfaces/IReputation.sol";
import {PassportMock} from "../mocks/PassportMock.sol";
import {TestToken} from "../mocks/TestToken.sol";

contract LadderTest is Test {
    Reputation internal rep;
    TestToken internal tok;
    PassportMock internal pass;
    bytes32 internal constant S = keccak256("subject");
    address internal operator = address(0xAA);

    function setUp() public {
        tok = new TestToken();
        pass = new PassportMock();
        pass.setHuman(address(this), S);
        rep = new Reputation(pass, address(0xFEE), 0, 0, 0, 0, operator);
    }

    function _close(Reputation r, uint256 principal, IReputation.Close kind) internal {
        vm.startPrank(operator);
        r.admit(address(this), address(tok), principal, address(0));
        r.notifyTerminal(S, address(tok), principal, kind);
        vm.stopPrank();
    }

    function test_ladder() public {
        uint256 deals;
        uint256 last;
        for (uint256 i = 0; i < 40; i++) {
            uint256 c = rep.cap(S, address(tok), false);
            if (c != last) {
                console2.log("deals", deals);
                console2.log("  score", rep.score(S, address(tok)));
                console2.log("  cap  ", c == type(uint256).max ? 0 : c / 1e6);
                last = c;
            }
            if (c == type(uint256).max) {
                console2.log("T5 (sin limite) tras deals:", deals);
                return;
            }
            _close(rep, c, IReputation.Close.Peaceful);
            deals++;
        }
    }

    function test_concurrency() public {
        vm.startPrank(operator);
        rep.admit(address(this), address(tok), 150e6, address(0));
        console2.log("primer deal 150 ok; inFlight", rep.inFlight(S, address(tok)) / 1e6);
        vm.expectRevert(Reputation.CapExceeded.selector);
        rep.admit(address(this), address(tok), 150e6, address(0));
        console2.log("segundo deal 150 RECHAZADO: el cap es concurrente, no por deal");
        vm.stopPrank();
    }

    function test_penalty() public {
        for (uint256 i = 0; i < 5; i++) {
            _close(rep, 250e6, IReputation.Close.Peaceful);
        }
        console2.log("5 deals limpios de 250 -> score", rep.score(S, address(tok)));
        console2.log("  cap", rep.cap(S, address(tok), false) / 1e6);
        _close(rep, 500e6, IReputation.Close.Stalemate);
        console2.log("un stalemate    -> score", rep.score(S, address(tok)));
        console2.log("  cap", rep.cap(S, address(tok), false) / 1e6);
    }
}
