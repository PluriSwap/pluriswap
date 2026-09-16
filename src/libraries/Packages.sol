// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Deal, DealTerms, PackageMods, BondAction} from "./Types.sol";
import {PackageId} from "./PackageId.sol";
import {Settlement} from "./Settlement.sol";
import {IPassport} from "../packages/interfaces/IPassport.sol";
import {IReputation} from "../packages/interfaces/IReputation.sol";
import {IBondVault} from "../packages/interfaces/IBondVault.sol";
import {IPaymentProof} from "../packages/interfaces/IPaymentProof.sol";
import {ICourt} from "../packages/interfaces/ICourt.sol";

/// @title Packages
/// @notice The kernel's package edge, as an external library (DELEGATECALL from `Escrow`).
/// @dev Resolution binds signed ids to live module policy (TRUST-03); engagement identifies, admits and reserves;
///      terminals invoice, dispose bonds and notify. Everything a terminal calls on a module is `try`: a package
///      can lose its fee or its lock, never hold the principal hostage. Lives outside `Escrow` for bytecode headroom.
library Packages {
    using SafeERC20 for IERC20;

    uint8 internal constant PASSPORT = 1;
    uint8 internal constant REP = 2;
    uint8 internal constant BONDS = 4;
    uint8 internal constant ZK = 8;
    uint8 internal constant ARB = 16;

    error UnknownPackage();
    error IncompatiblePackages();
    error PackageRequired();
    error PeerMismatch();
    error PackageDrift();

    // --- activation ----------------------------------------------------------------------------------

    /// @dev Every module the relayer names must hash to a signed id, and every signed id must be matched.
    function resolve(bytes32[] memory ids, PackageMods memory mods) public view returns (uint8 pkgs) {
        uint256 matched;
        if (mods.passport != address(0)) {
            _requireNamed(ids, PackageId.passport(mods.passport));
            pkgs |= PASSPORT;
            matched++;
        }
        if (mods.reputation != address(0)) {
            IReputation r = IReputation(mods.reputation);
            if (address(r.passport()) != mods.passport) revert PeerMismatch();
            _requireNamed(
                ids, PackageId.reputation(mods.reputation, r.feeRecipient(), r.activationFee(), r.completionFee())
            );
            pkgs |= REP;
            matched++;
        }
        if (mods.bonds != address(0)) {
            IBondVault vault = IBondVault(mods.bonds);
            if (address(vault.passport()) != mods.passport) revert PeerMismatch();
            _requireNamed(ids, PackageId.bonds(mods.bonds, vault.sink()));
            pkgs |= BONDS;
            matched++;
        }
        if (mods.zk != address(0)) {
            IPaymentProof z = IPaymentProof(mods.zk);
            _requireNamed(ids, PackageId.zk(address(z), address(z.verifier()), z.feeRecipient(), z.verifyFee()));
            pkgs |= ZK;
            matched++;
        }
        if (mods.court != address(0)) {
            (address partner, uint256 key) = ICourt(mods.court).packageBinding();
            _requireNamed(ids, PackageId.arbitration(mods.court, partner, key));
            pkgs |= ARB;
            matched++;
        }
        if (matched != ids.length) revert UnknownPackage();
        if ((pkgs & (ZK | ARB)) == (ZK | ARB)) revert IncompatiblePackages();
        if ((pkgs & REP) != 0 && (pkgs & PASSPORT) == 0) revert PackageRequired();
        if ((pkgs & BONDS) != 0 && (pkgs & (PASSPORT | REP)) != (PASSPORT | REP)) revert PackageRequired();
    }

    /// @dev Identify, admit (cap), pull the activation fee from the Holder, reserve both locks.
    ///      Runs in the kernel's context: pulls land on the escrow, then move to the fee recipient.
    function engage(DealTerms memory t, uint8 pkgs, bytes32 dealId, PackageMods memory mods)
        public
        returns (bytes32 subjectH, bytes32 subjectP)
    {
        if ((pkgs & PASSPORT) != 0) {
            subjectH = IPassport(mods.passport).identify(t.holder);
            subjectP = IPassport(mods.passport).identify(t.provider);
        }
        if ((pkgs & REP) != 0) {
            IReputation r = IReputation(mods.reputation);
            address v = (pkgs & BONDS) != 0 ? mods.bonds : address(0);
            r.admit(t.holder, t.token, t.principal, v);
            r.admit(t.provider, t.token, t.principal, v);
            uint256 fee = r.activationFee();
            if (fee != 0) {
                Settlement.pullExact(t.token, t.holder, fee);
                IERC20(t.token).safeTransfer(r.feeRecipient(), fee);
            }
        }
        if ((pkgs & BONDS) != 0) {
            IBondVault vault = IBondVault(mods.bonds);
            vault.reserve(subjectH, t.token, dealId, t.principal);
            vault.reserve(subjectP, t.token, dealId, t.principal);
        }
    }

    // --- live edges -----------------------------------------------------------------------------------

    /// @dev The ZK module of this deal, or `PackageDrift` if its live policy no longer hashes to the signed id.
    function zk(Deal storage d) public view returns (IPaymentProof z, uint256 fee, address to) {
        z = IPaymentProof(d.mods.zk);
        fee = z.verifyFee();
        to = z.feeRecipient();
        if (!named(d, PackageId.zk(address(z), address(z.verifier()), to, fee))) revert PackageDrift();
    }

    /// @dev The court of this deal, or `PackageDrift`.
    function court(Deal storage d) public view returns (ICourt c) {
        c = ICourt(d.mods.court);
        (address partner, uint256 key) = c.packageBinding();
        if (!named(d, PackageId.arbitration(address(c), partner, key))) revert PackageDrift();
    }

    // --- terminals --------------------------------------------------------------------------------------

    /// @dev Completion invoice of this deal: `(0, 0)` without reputation, when the module drifted its policy, or
    ///      when any policy getter reverts. TRUST-03: a module that drifts loses the invoice; Core exits keep
    ///      running. A reverting getter is drift the kernel cannot read, so it loses the invoice the same way.
    function completionInvoice(Deal storage d) public view returns (uint256 fee, address to) {
        if ((d.pkgs & REP) == 0) return (0, address(0));
        IReputation r = IReputation(d.mods.reputation);
        uint256 activation;
        try r.feeRecipient() returns (address recipient) {
            to = recipient;
        } catch {
            return (0, address(0));
        }
        try r.completionFee() returns (uint256 completion) {
            fee = completion;
        } catch {
            return (0, address(0));
        }
        try r.activationFee() returns (uint256 amount) {
            activation = amount;
        } catch {
            return (0, address(0));
        }
        if (!named(d, PackageId.reputation(address(r), to, activation, fee))) return (0, address(0));
    }

    /// @dev Unlock, burn, or move the loser's lock to the winner's signing address. Drift → fail-open, and so is a
    ///      vault whose `sink` getter reverts: `_close` calls this on every terminal, so a reverting read here
    ///      would otherwise hold the principal hostage with no exit left, not even `CANCELLED`.
    function disposeBond(Deal storage d, bytes32 dealId, BondAction bond) public {
        if ((d.pkgs & BONDS) == 0) return;
        IBondVault vault = IBondVault(d.mods.bonds);
        address sink;
        try vault.sink() returns (address s) {
            sink = s;
        } catch {
            return;
        }
        if (!named(d, PackageId.bonds(address(vault), sink))) return;
        DealTerms storage t = d.terms;
        if (bond == BondAction.Unlock) {
            try vault.unlock(d.subjectH, t.token, dealId) {} catch {}
            try vault.unlock(d.subjectP, t.token, dealId) {} catch {}
        } else if (bond == BondAction.Burn) {
            try vault.burn(d.subjectH, d.subjectP, t.token, dealId) {} catch {}
        } else if (bond == BondAction.HolderWins) {
            try vault.slash(d.subjectP, d.subjectH, t.token, dealId, t.holder) {} catch {}
        } else {
            try vault.slash(d.subjectH, d.subjectP, t.token, dealId, t.provider) {} catch {}
        }
    }

    /// @dev Reputation hears the terminal with the subjects snapshotted at activation (ADM-05).
    function notify(Deal storage d, IReputation.Close closeH, IReputation.Close closeP) public {
        if ((d.pkgs & REP) == 0) return;
        IReputation r = IReputation(d.mods.reputation);
        DealTerms storage t = d.terms;
        try r.notifyTerminal(d.subjectH, t.token, t.principal, closeH) {} catch {}
        try r.notifyTerminal(d.subjectP, t.token, t.principal, closeP) {} catch {}
    }

    // --- helpers --------------------------------------------------------------------------------------------

    function named(Deal storage d, bytes32 id) public view returns (bool) {
        bytes32[] storage ids = d.terms.packageIds;
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == id) return true;
        }
        return false;
    }

    function _requireNamed(bytes32[] memory ids, bytes32 id) private pure {
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == id) return;
        }
        revert UnknownPackage();
    }
}
