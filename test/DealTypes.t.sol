// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    DealState,
    Outcome,
    ProfileFlags,
    PositionKind,
    FundingPurpose,
    FundingSourceMode,
    ResolutionAction,
    isTerminal
} from "../src/libraries/DealTypes.sol";

contract DealTypesTest is Test {
    function test_DealState_wireIds() public pure {
        // Non-terminal
        assertEq(DealState.None, 0);
        assertEq(DealState.Funded, 1);
        assertEq(DealState.FiatSent, 2);
        assertEq(DealState.Disputed, 3);
        assertEq(DealState.ArbitrationActive, 4);
        // Terminal at 16-21 (gap from 5-15)
        assertEq(DealState.Released, 16);
        assertEq(DealState.ResolvedSplit, 17);
        assertEq(DealState.ResolvedByDisputeTimeout, 18);
        assertEq(DealState.Cancelled, 19);
        assertEq(DealState.ResolvedByArbitration, 20);
        assertEq(DealState.Stalemate, 21);
    }

    function test_Outcome_wireIds() public pure {
        assertEq(Outcome.Invalid, 0);
        assertEq(Outcome.VoluntaryRelease, 1);
        assertEq(Outcome.CosignedRelease, 2);
        assertEq(Outcome.PaymentProofRelease, 3);
        assertEq(Outcome.TimeoutClaim, 4);
        assertEq(Outcome.ProviderCancel, 5);
        assertEq(Outcome.FiatTimeoutCancel, 6);
        assertEq(Outcome.MutualCancel, 7);
        assertEq(Outcome.MutualSplit, 8);
        assertEq(Outcome.ArbitrationHolderWin, 9);
        assertEq(Outcome.ArbitrationProviderWin, 10);
        assertEq(Outcome.ArbitrationRefused, 11);
        assertEq(Outcome.ArbitrationTimeout, 12);
        assertEq(Outcome.DisputeTimeout, 13);
    }

    function test_isTerminal_explicitMembership() public pure {
        // Non-terminal states
        assertFalse(isTerminal(DealState.None));
        assertFalse(isTerminal(DealState.Funded));
        assertFalse(isTerminal(DealState.FiatSent));
        assertFalse(isTerminal(DealState.Disputed));
        assertFalse(isTerminal(DealState.ArbitrationActive));

        // Terminal states
        assertTrue(isTerminal(DealState.Released));
        assertTrue(isTerminal(DealState.ResolvedSplit));
        assertTrue(isTerminal(DealState.ResolvedByDisputeTimeout));
        assertTrue(isTerminal(DealState.Cancelled));
        assertTrue(isTerminal(DealState.ResolvedByArbitration));
        assertTrue(isTerminal(DealState.Stalemate));

        // Reserved gap (5-15) is NOT terminal — ordinal comparison would be wrong
        assertFalse(isTerminal(5));
        assertFalse(isTerminal(10));
        assertFalse(isTerminal(15));
    }

    function test_ProfileFlags_bitValues() public pure {
        assertEq(ProfileFlags.PaymentProof, 1);
        assertEq(ProfileFlags.Arbitration, 2);
        assertEq(ProfileFlags.Bonds, 4);
        assertEq(ProfileFlags.Pool, 8);
        assertEq(ProfileFlags.Reputation, 16);
        assertEq(ProfileFlags.Humanity, 32);
        assertEq(ProfileFlags.RatePolicy, 64);
        assertEq(ProfileFlags.CrowdfundedPool, 128);
    }

    function test_PositionKind_ids() public pure {
        assertEq(PositionKind.Deal, 1);
        assertEq(PositionKind.ActivationFee, 2);
        assertEq(PositionKind.DealTerminal, 3);
        assertEq(PositionKind.Reservation, 4);
        assertEq(PositionKind.ReservationTerminal, 5);
    }

    function test_FundingPurpose_ids() public pure {
        assertEq(FundingPurpose.Principal, 1);
        assertEq(FundingPurpose.ActivationFee, 2);
    }

    function test_FundingSourceMode_ids() public pure {
        assertEq(FundingSourceMode.WalletPull, 1);
        assertEq(FundingSourceMode.LedgerPosition, 2);
    }

    function test_ResolutionAction_wireIds() public pure {
        assertEq(uint8(ResolutionAction.Invalid), 0);
        assertEq(uint8(ResolutionAction.MutualCancel), 1);
        assertEq(uint8(ResolutionAction.CosignedRelease), 2);
        assertEq(uint8(ResolutionAction.Split), 3);
    }
}
