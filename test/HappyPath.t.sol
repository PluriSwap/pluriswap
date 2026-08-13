// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Status} from "../src/libraries/Types.sol";
import {Escrow} from "../src/Escrow.sol";
import {BaseTest} from "./Base.t.sol";

contract HappyPathTest is BaseTest {
    function test_markFiat_onlyProvider() public {
        bytes32 id = _activateP2P(1, 1);

        vm.prank(holder);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.markFiat(id);

        vm.prank(provider);
        escrow.markFiat(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.FIAT_SENT));
    }

    function test_release_onlyController_paysProvider() public {
        bytes32 id = _activateP2P(1, 1);
        vm.prank(provider);
        escrow.markFiat(id);

        vm.prank(provider);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.release(id);

        vm.prank(holder);
        escrow.release(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), PRINCIPAL);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_release_revertsFromFunded() public {
        bytes32 id = _activateP2P(1, 1);
        vm.prank(holder);
        vm.expectRevert(Escrow.WrongStatus.selector);
        escrow.release(id);
    }

    function test_holderCannotRelease_whenDistinctController() public {
        bytes32 id = _activateDistinctController(1, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(holder);
        vm.expectRevert(Escrow.Unauthorized.selector);
        escrow.release(id);
        vm.prank(controller);
        escrow.release(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(token.balanceOf(provider), PRINCIPAL);
    }
}
