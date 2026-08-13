// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Status, DealTerms} from "../src/libraries/Types.sol";
import {BaseTest} from "./Base.t.sol";

contract CreditFirstTest is BaseTest {
    function test_release_toRevertingProvider_stillReleased() public {
        bytes32 id = _activateP2P(1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.mockCallRevert(address(token), abi.encodeCall(IERC20.transfer, (provider, PRINCIPAL)), "blocked");
        vm.prank(holder);
        escrow.release(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.RELEASED));
        assertEq(escrow.creditOf(address(token), provider), PRINCIPAL);
        assertEq(token.balanceOf(address(escrow)), PRINCIPAL);
        assertEq(token.balanceOf(provider), 0);
    }

    function test_withdraw_afterFailedPush() public {
        bytes32 id = _activateP2P(1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.mockCallRevert(address(token), abi.encodeCall(IERC20.transfer, (provider, PRINCIPAL)), "blocked");
        vm.prank(holder);
        escrow.release(id);
        vm.clearMockedCalls();
        vm.prank(provider);
        escrow.withdraw(address(token));
        assertEq(token.balanceOf(provider), PRINCIPAL);
        assertEq(escrow.creditOf(address(token), provider), 0);
    }

    function test_stalemate_partialPushFailure_keepsBothCredits() public {
        DealTerms memory terms = _p2pTerms();
        terms.releaseDuration = 100;
        terms.disputeDuration = 0;
        bytes32 id = _activateP2PWith(terms, 1, 1);
        vm.prank(provider);
        escrow.markFiat(id);
        vm.prank(holder);
        escrow.openDisputed(id);
        vm.mockCallRevert(
            address(token), abi.encodeCall(IERC20.transfer, (holder, PRINCIPAL / 2)), "blocked"
        );
        escrow.forceStalemate(id);
        assertEq(uint8(escrow.status(id)), uint8(Status.STALEMATE));
        assertEq(escrow.creditOf(address(token), holder), PRINCIPAL / 2);
        assertEq(token.balanceOf(provider), PRINCIPAL / 2);
        assertEq(token.balanceOf(holder), 0);
    }
}
