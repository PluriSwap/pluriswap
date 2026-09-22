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
///      terminals invoice and run post-terminal work. Everything a terminal calls on a module is `try`: a package
///      can lose its fee or its lock, never hold the principal hostage. Lives outside `Escrow` for bytecode headroom.
library Packages {
    using SafeERC20 for IERC20;

    uint8 internal constant PASSPORT = 1;
    uint8 internal constant REP = 2;
    uint8 internal constant BONDS = 4;
    uint8 internal constant ZK = 8;
    uint8 internal constant ARB = 16;

    /// Post-terminal package calls, as bits of `Deal.postPending`. Each is cleared only when its own call
    /// succeeds, which is what makes `Escrow.retryPostTerminal` idempotent.
    uint8 internal constant POST_NOTIFY_H = 0x01;
    uint8 internal constant POST_NOTIFY_P = 0x02;
    uint8 internal constant POST_BOND_A = 0x04;
    uint8 internal constant POST_BOND_B = 0x08;

    /// @dev A bond disposal TRUST-03 fails open on: the vault stopped answering or drifted off its signed
    ///      id, so the bit is cleared like a success and the lock stays in the vault permanently. It clears
    ///      exactly like a success, which is precisely why it needs its own announcement: `postPending`
    ///      reaching zero cannot tell the two apart, and one of them is real value nobody gets back.
    event BondDisposalAbandoned(bytes32 indexed dealId, address indexed vault);

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
                ids,
                PackageId.reputation(
                    mods.reputation,
                    r.feeRecipient(),
                    r.activationFee(),
                    r.completionFee(),
                    r.contestBps(),
                    r.contestFloor()
                )
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
            // `admit` is not `view` and runs between `resolve`'s validation and this read, so a module can
            // answer one policy while it is being checked and another while it is being paid. Re-bind the
            // values actually charged to a signed id before pulling anything. `completionInvoice` and `zk`
            // both charge the value they validated; this was the one path that re-read instead.
            uint256 fee = r.activationFee();
            address to = r.feeRecipient();
            _requireStillNamed(
                t.packageIds,
                PackageId.reputation(address(r), to, fee, r.completionFee(), r.contestBps(), r.contestFloor())
            );
            if (fee != 0) {
                Settlement.pullExact(t.token, t.holder, fee);
                IERC20(t.token).safeTransfer(to, fee);
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
        uint256 contestBps;
        uint256 contestFloor;
        try r.contestBps() returns (uint256 bps) {
            contestBps = bps;
        } catch {
            return (0, address(0));
        }
        try r.contestFloor() returns (uint256 floor_) {
            contestFloor = floor_;
        } catch {
            return (0, address(0));
        }
        if (!named(d, PackageId.reputation(address(r), to, activation, fee, contestBps, contestFloor))) {
            return (0, address(0));
        }
    }

    /// @dev 1% when `bps == 100`. Zero bps is a flat floor (free if the floor is also 0).
    function contestDue(uint256 principal, uint256 bps, uint256 floor_) public pure returns (uint256) {
        if (bps == 0) return floor_;
        uint256 pct = principal * bps / 10_000;
        return pct < floor_ ? floor_ : pct;
    }

    /// @dev Contest-open invoice: `(0, 0)` without reputation or when the module drifted. Fail-open on
    ///      drift so a Core `openDisputed` is not bricked (KERNEL-04); a healthy official module always
    ///      charges, which is what makes opening a fight cost something.
    function contestInvoice(Deal storage d) public view returns (uint256 fee, address to) {
        if ((d.pkgs & REP) == 0) return (0, address(0));
        IReputation r = IReputation(d.mods.reputation);
        uint256 activation;
        uint256 completion;
        uint256 bps;
        uint256 floor_;
        try r.feeRecipient() returns (address recipient) {
            to = recipient;
        } catch {
            return (0, address(0));
        }
        try r.contestBps() returns (uint256 amount) {
            bps = amount;
        } catch {
            return (0, address(0));
        }
        try r.contestFloor() returns (uint256 amount) {
            floor_ = amount;
        } catch {
            return (0, address(0));
        }
        try r.activationFee() returns (uint256 amount) {
            activation = amount;
        } catch {
            return (0, address(0));
        }
        try r.completionFee() returns (uint256 amount) {
            completion = amount;
        } catch {
            return (0, address(0));
        }
        if (!named(d, PackageId.reputation(address(r), to, activation, completion, bps, floor_))) {
            return (0, address(0));
        }
        fee = contestDue(d.terms.principal, bps, floor_);
    }

    /// @dev Pull the contest-open fee from `payer` (the opener) once. Shared by `openDisputed` and
    ///      `openCourt` from `FIAT_SENT` so entering the fight cannot be charged twice. Fail-closed:
    ///      a short allowance reverts and the deal stays where it was.
    function chargeContest(Deal storage d, address payer) public {
        if (d.contestPaid) return;
        (uint256 fee, address to) = contestInvoice(d);
        if (fee != 0) {
            Settlement.pullExact(d.terms.token, payer, fee);
            IERC20(d.terms.token).safeTransfer(to, fee);
        }
        d.contestPaid = true;
    }

    // --- post-terminal work -----------------------------------------------------------------------------------

    /// @dev Which post-terminal calls this deal owes, from its bound kinds and the terminal's bond action.
    ///      `Unlock` is one call per subject; burn and slash take both subjects in a single call.
    function postTerminalOwed(Deal storage d, BondAction bond) public view returns (uint8 owed) {
        if ((d.pkgs & REP) != 0) owed = POST_NOTIFY_H | POST_NOTIFY_P;
        if ((d.pkgs & BONDS) != 0) owed |= bond == BondAction.Unlock ? POST_BOND_A | POST_BOND_B : POST_BOND_A;
    }

    /// @dev Attempt the post-terminal calls still set in `pending` and return the bits that remain. One
    ///      implementation serves both the first attempt from `_close` and every retry from
    ///      `Escrow.retryPostTerminal`, so the two cannot drift apart.
    ///
    ///      Every call is `try`, because a package can lose its fee or its lock but never hold the principal
    ///      hostage (KERNEL-04). A bit is cleared only when its call succeeds, so a retry can never apply a
    ///      reputation delta twice or dispose the same lock twice.
    ///
    ///      A bond call is also cleared when the vault is unreadable or has drifted off its signed id:
    ///      TRUST-03 makes that a permanent fail-open with the lock left in the vault, so keeping the bit set
    ///      would leave `postPending` unable to ever reach zero. Reputation has no drift gate -- a
    ///      notification is not a charge, and `completionInvoice` already denies a drifted module its fee --
    ///      so its bits stay pending until the module answers. A module that never comes back leaves them set,
    ///      and `retryPostTerminal` stays callable as a no-op; that is deliberate, because silently dropping
    ///      the notification would hide a subject's capacity leak.
    function runPostTerminal(
        Deal storage d,
        bytes32 dealId,
        uint8 closeH,
        uint8 closeP,
        uint8 bondAction,
        uint8 pending
    ) public returns (uint8 left) {
        left = pending;
        DealTerms storage t = d.terms;

        if ((left & (POST_NOTIFY_H | POST_NOTIFY_P)) != 0 && (d.pkgs & REP) != 0) {
            IReputation r = IReputation(d.mods.reputation);
            if ((left & POST_NOTIFY_H) != 0) {
                try r.notifyTerminal(d.subjectH, t.token, t.principal, IReputation.Close(closeH)) {
                    left &= ~POST_NOTIFY_H;
                } catch {}
            }
            if ((left & POST_NOTIFY_P) != 0) {
                try r.notifyTerminal(d.subjectP, t.token, t.principal, IReputation.Close(closeP)) {
                    left &= ~POST_NOTIFY_P;
                } catch {}
            }
        }

        if ((left & (POST_BOND_A | POST_BOND_B)) != 0 && (d.pkgs & BONDS) != 0) {
            IBondVault vault = IBondVault(d.mods.bonds);
            address sink;
            bool readable = true;
            try vault.sink() returns (address s) {
                sink = s;
            } catch {
                readable = false;
            }
            if (!readable || !named(d, PackageId.bonds(address(vault), sink))) {
                left &= ~(POST_BOND_A | POST_BOND_B);
                emit BondDisposalAbandoned(dealId, address(vault));
                return left;
            }
            BondAction bond = BondAction(bondAction);
            if (bond == BondAction.Unlock) {
                if ((left & POST_BOND_A) != 0) {
                    try vault.unlock(d.subjectH, t.token, dealId) {
                        left &= ~POST_BOND_A;
                    } catch {}
                }
                if ((left & POST_BOND_B) != 0) {
                    try vault.unlock(d.subjectP, t.token, dealId) {
                        left &= ~POST_BOND_B;
                    } catch {}
                }
            } else if ((left & POST_BOND_A) != 0) {
                bool done;
                if (bond == BondAction.Burn) {
                    try vault.burn(d.subjectH, d.subjectP, t.token, dealId) {
                        done = true;
                    } catch {}
                } else if (bond == BondAction.HolderWins) {
                    try vault.slash(d.subjectP, d.subjectH, t.token, dealId, t.holder) {
                        done = true;
                    } catch {}
                } else {
                    try vault.slash(d.subjectH, d.subjectP, t.token, dealId, t.provider) {
                        done = true;
                    } catch {}
                }
                if (done) left &= ~POST_BOND_A;
            }
        }
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

    /// @dev The same search as `_requireNamed`, for a policy that *was* named when `resolve` validated it and
    ///      is being re-checked after a non-view module call. Different meaning, so a different error: the
    ///      caller did not fail to name a package, the module stopped matching the one they signed.
    function _requireStillNamed(bytes32[] memory ids, bytes32 id) private pure {
        for (uint256 i; i < ids.length; i++) {
            if (ids[i] == id) return;
        }
        revert PackageDrift();
    }
}
