// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DealState, Outcome, ProfileFlags} from "../src/libraries/DealTypes.sol";

contract DealTypesTest is Test {
    function test_DealState_ReleasedIsTerminalThreshold() public pure {
        assertEq(uint8(DealState.Released), 4);
        assertEq(uint8(DealState.Funded), 1);
    }

    function test_Outcome_DisputeTimeoutOrdinal() public pure {
        assertEq(uint8(Outcome.DisputeTimeout), 13);
    }

    function test_ProfileFlags_PaymentProofBit() public pure {
        assertEq(ProfileFlags.PAYMENT_PROOF, 1);
    }
}
