// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {
    Status,
    Deal,
    DealTerms,
    DealClocks,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    MutualCancel,
    CoSignedRelease,
    MutualSplit,
    PackageMods,
    BondAction
} from "./libraries/Types.sol";
import {IEscrow} from "./interfaces/IEscrow.sol";
import {Terms} from "./libraries/Terms.sol";
import {Consent} from "./libraries/Consent.sol";
import {Settlement} from "./libraries/Settlement.sol";
import {Clocks} from "./libraries/Clocks.sol";
import {Packages} from "./libraries/Packages.sol";
import {IReputation} from "./packages/interfaces/IReputation.sol";
import {IPaymentProof} from "./packages/interfaces/IPaymentProof.sol";
import {ICourt} from "./packages/interfaces/ICourt.sol";

contract Escrow is EIP712, ReentrancyGuardTransient, IEscrow {
    error TermsMismatch();
    error DeadlinePassed();
    error InvalidHolderSignature();
    error InvalidProviderSignature();
    error InvalidControllerSignature();
    error ControllerAcceptanceRequired();
    error NonceUsed();
    error DealExists();
    error Unauthorized();
    error WrongStatus();
    error DealIdMismatch();
    error DeadlineMismatch();
    error BpsMismatch();
    error PackageNotSelected();
    error EdgeOff();
    error NotRuled();

    event Activated(
        bytes32 dealId, address holder, address provider, address controller, address token, uint256 principal
    );
    event Transitioned(bytes32 dealId, Status from, Status to);
    event Settled(bytes32 dealId, Status status, uint256 holderAmt, uint256 providerAmt);
    event NonceCancelled(address signer, uint256 nonce);

    uint16 internal constant ALL = 10_000;
    uint16 internal constant HALF = 5_000;

    /// @dev How a terminal splits the pot and what it tells the packages.
    struct Outcome {
        Status next;
        uint16 providerBps;
        IReputation.Close closeH;
        IReputation.Close closeP;
        BondAction bond;
    }

    mapping(address signer => mapping(uint256 nonce => bool consumed)) public used;
    mapping(address signer => mapping(uint256 nonce => bytes32 dealId)) public dealOf;
    mapping(bytes32 dealId => Deal) internal deals;
    Settlement.Store internal settlement;

    constructor() EIP712("PluriSwap", "1") {}

    // --- read ------------------------------------------------------------------------------------------

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function status(bytes32 dealId) external view returns (Status) {
        return deals[dealId].status;
    }

    function settlementOf(bytes32 dealId)
        external
        view
        returns (Status status_, uint256 holderAmt, uint256 providerAmt)
    {
        Deal storage d = deals[dealId];
        return (d.status, d.holderAmt, d.providerAmt);
    }

    function subjects(bytes32 dealId) external view returns (bytes32, bytes32) {
        return (deals[dealId].subjectH, deals[dealId].subjectP);
    }

    function modules(bytes32 dealId) external view returns (PackageMods memory) {
        return deals[dealId].mods;
    }

    function terms(bytes32 dealId) external view returns (DealTerms memory) {
        return deals[dealId].terms;
    }

    function clocks(bytes32 dealId) external view returns (DealClocks memory) {
        Deal storage d = deals[dealId];
        return DealClocks({
            activatedAt: d.activatedAt,
            fiatSentAt: d.fiatSentAt,
            disputedAt: d.disputedAt,
            arbitrationOpenedAt: d.arbitrationOpenedAt
        });
    }

    function kinds(bytes32 dealId) external view returns (uint8) {
        return deals[dealId].pkgs;
    }

    function creditOf(address token, address beneficiary) external view returns (uint256) {
        return Settlement.creditOf(settlement, token, beneficiary);
    }

    // --- activation --------------------------------------------------------------------------------------

    function activate(
        HolderAuthorization calldata ha,
        bytes calldata holderSig,
        ProviderAgreement calldata pa,
        bytes calldata providerSig,
        ControllerAcceptance calldata ca,
        bytes calldata controllerSig
    ) external nonReentrant returns (bytes32 id) {
        PackageMods memory mods;
        id = _activate(ha, holderSig, pa, providerSig, ca, controllerSig, mods);
    }

    function activate(
        HolderAuthorization calldata ha,
        bytes calldata holderSig,
        ProviderAgreement calldata pa,
        bytes calldata providerSig,
        ControllerAcceptance calldata ca,
        bytes calldata controllerSig,
        PackageMods calldata mods
    ) external nonReentrant returns (bytes32 id) {
        id = _activate(ha, holderSig, pa, providerSig, ca, controllerSig, mods);
    }

    function _activate(
        HolderAuthorization calldata ha,
        bytes calldata holderSig,
        ProviderAgreement calldata pa,
        bytes calldata providerSig,
        ControllerAcceptance calldata ca,
        bytes calldata controllerSig,
        PackageMods memory mods
    ) internal returns (bytes32 id) {
        DealTerms calldata t = ha.terms;
        bytes32 termsHash = Terms.hashTerms(t);
        if (termsHash != Terms.hashTerms(pa.terms)) revert TermsMismatch();

        if (block.timestamp > ha.deadline || block.timestamp > pa.deadline) revert DeadlinePassed();

        if (!Consent.isValid(t.holder, _hashTypedDataV4(Consent.hashHolderAuthorization(ha)), holderSig)) {
            revert InvalidHolderSignature();
        }
        if (!Consent.isValid(t.provider, _hashTypedDataV4(Consent.hashProviderAgreement(pa)), providerSig)) {
            revert InvalidProviderSignature();
        }

        uint256 controllerNonce;
        if (t.holder != t.controller) {
            if (ca.terms.controller != t.controller) revert ControllerAcceptanceRequired();
            if (termsHash != Terms.hashTerms(ca.terms)) revert TermsMismatch();
            if (block.timestamp > ca.deadline) revert DeadlinePassed();
            if (!Consent.isValid(t.controller, _hashTypedDataV4(Consent.hashControllerAcceptance(ca)), controllerSig)) {
                revert InvalidControllerSignature();
            }
            if (used[t.controller][ca.nonce]) revert NonceUsed();
            controllerNonce = ca.nonce;
        }

        if (used[t.holder][ha.nonce] || used[t.provider][pa.nonce]) revert NonceUsed();

        uint8 pkgs = Packages.resolve(t.packageIds, mods);
        id = Consent.dealId(_domainSeparatorV4(), t, ha.nonce, pa.nonce, controllerNonce);
        if (deals[id].status != Status.NONE) revert DealExists();

        (bytes32 subjectH, bytes32 subjectP) = Packages.engage(t, pkgs, id, mods);
        Settlement.pullExact(t.token, t.holder, t.principal);

        used[t.holder][ha.nonce] = true;
        used[t.provider][pa.nonce] = true;
        dealOf[t.holder][ha.nonce] = id;
        dealOf[t.provider][pa.nonce] = id;
        if (t.holder != t.controller) {
            used[t.controller][ca.nonce] = true;
            dealOf[t.controller][ca.nonce] = id;
        }

        Deal storage d = deals[id];
        d.status = Status.FUNDED;
        d.terms = t;
        d.activatedAt = block.timestamp;
        d.subjectH = subjectH;
        d.subjectP = subjectP;
        d.pkgs = pkgs;
        d.mods = mods;
        emit Transitioned(id, Status.NONE, Status.FUNDED);
        emit Activated(id, t.holder, t.provider, t.controller, t.token, t.principal);
    }

    // --- core verbs ---------------------------------------------------------------------------------------

    function markFiat(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FUNDED) revert WrongStatus();
        _requireNotZk(d);
        if (msg.sender != d.terms.provider) revert Unauthorized();
        emit Transitioned(dealId, d.status, Status.FIAT_SENT);
        d.status = Status.FIAT_SENT;
        d.fiatSentAt = block.timestamp;
    }

    function release(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FIAT_SENT) revert WrongStatus();
        if (msg.sender != d.terms.controller) revert Unauthorized();
        _close(dealId, d, d.terms.principal, _released());
    }

    function cancelByProvider(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FUNDED) revert WrongStatus();
        if (msg.sender != d.terms.provider) revert Unauthorized();
        _close(dealId, d, d.terms.principal, _cancelled());
    }

    function timeoutFiat(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FUNDED) revert WrongStatus();
        Clocks.requireDue(d.activatedAt, d.terms.fiatDuration);
        _close(dealId, d, d.terms.principal, _cancelled());
    }

    /// @dev Provider-positive timeout: fiat was sent, the Controller never released. The Provider closed the
    ///      trade and is credited for it; the Holder's side is silent (an absent Controller is not proven fault).
    function claim(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FIAT_SENT) revert WrongStatus();
        _requireNotZk(d);
        Clocks.requireDue(d.fiatSentAt, d.terms.releaseDuration);
        _close(
            dealId,
            d,
            d.terms.principal,
            Outcome(Status.CLAIMED, ALL, IReputation.Close.Silent, IReputation.Close.Peaceful, BondAction.Unlock)
        );
    }

    function openDisputed(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FIAT_SENT) revert WrongStatus();
        _requireNotZk(d);
        if (msg.sender != d.terms.controller) revert Unauthorized();
        Clocks.requireStrictlyBefore(d.fiatSentAt, d.terms.releaseDuration);
        emit Transitioned(dealId, d.status, Status.DISPUTED);
        d.status = Status.DISPUTED;
        d.disputedAt = block.timestamp;
    }

    /// @dev Neither side co-signed nor went to court inside the dispute window: both locks burn.
    function forceStalemate(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.DISPUTED) revert WrongStatus();
        Clocks.requireDue(d.disputedAt, d.terms.disputeDuration);
        _close(dealId, d, d.terms.principal, _stalemate(BondAction.Burn, IReputation.Close.Stalemate));
    }

    function mutualCancel(
        MutualCancel calldata providerMsg,
        bytes calldata providerSig,
        MutualCancel calldata controllerMsg,
        bytes calldata controllerSig
    ) external nonReentrant {
        _assertDualSignEnvelope(providerMsg.dealId, providerMsg.deadline, controllerMsg.dealId, controllerMsg.deadline);
        Deal storage d = deals[providerMsg.dealId];
        _assertLiveForDualSign(d.status);
        _consumeDualSign(
            d.terms.provider,
            _hashTypedDataV4(Consent.hashMutualCancel(providerMsg)),
            providerSig,
            providerMsg.nonce,
            d.terms.controller,
            _hashTypedDataV4(Consent.hashMutualCancel(controllerMsg)),
            controllerSig,
            controllerMsg.nonce
        );
        _close(providerMsg.dealId, d, d.terms.principal, _cancelled());
    }

    function coSignedRelease(
        CoSignedRelease calldata providerMsg,
        bytes calldata providerSig,
        CoSignedRelease calldata controllerMsg,
        bytes calldata controllerSig
    ) external nonReentrant {
        _assertDualSignEnvelope(providerMsg.dealId, providerMsg.deadline, controllerMsg.dealId, controllerMsg.deadline);
        Deal storage d = deals[providerMsg.dealId];
        _assertDualSignFromActive(d.status);
        _consumeDualSign(
            d.terms.provider,
            _hashTypedDataV4(Consent.hashCoSignedRelease(providerMsg)),
            providerSig,
            providerMsg.nonce,
            d.terms.controller,
            _hashTypedDataV4(Consent.hashCoSignedRelease(controllerMsg)),
            controllerSig,
            controllerMsg.nonce
        );
        _close(providerMsg.dealId, d, d.terms.principal, _released());
    }

    function mutualSplit(
        MutualSplit calldata providerMsg,
        bytes calldata providerSig,
        MutualSplit calldata controllerMsg,
        bytes calldata controllerSig
    ) external nonReentrant {
        _assertDualSignEnvelope(providerMsg.dealId, providerMsg.deadline, controllerMsg.dealId, controllerMsg.deadline);
        if (providerMsg.providerBps != controllerMsg.providerBps) revert BpsMismatch();
        if (providerMsg.providerBps > ALL) revert BpsMismatch();
        Deal storage d = deals[providerMsg.dealId];
        _assertDualSignFromActive(d.status);
        _consumeDualSign(
            d.terms.provider,
            _hashTypedDataV4(Consent.hashMutualSplit(providerMsg)),
            providerSig,
            providerMsg.nonce,
            d.terms.controller,
            _hashTypedDataV4(Consent.hashMutualSplit(controllerMsg)),
            controllerSig,
            controllerMsg.nonce
        );
        _close(
            providerMsg.dealId,
            d,
            d.terms.principal,
            Outcome(
                Status.RESOLVED_SPLIT,
                providerMsg.providerBps,
                IReputation.Close.Peaceful,
                IReputation.Close.Peaceful,
                BondAction.Unlock
            )
        );
    }

    // --- package verbs --------------------------------------------------------------------------------------

    function verifyProof(bytes32 dealId, bytes calldata proof) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FUNDED) revert WrongStatus();
        if ((d.pkgs & Packages.ZK) == 0) revert PackageNotSelected();
        (IPaymentProof module, uint256 fee, address to) = Packages.zk(d);
        module.verifyProof(dealId, proof);
        uint256 left = _invoice(d.terms.principal, fee, d.terms.token, to);
        _close(dealId, d, left, _released());
    }

    /// @dev Court only opens from DISPUTED. FIAT_SENT must go through openDisputed first.
    function openCourt(bytes32 dealId) external payable nonReentrant {
        Deal storage d = deals[dealId];
        if ((d.pkgs & Packages.ARB) == 0) revert PackageNotSelected();
        _requireNotZk(d);
        if (d.status != Status.DISPUTED) revert WrongStatus();
        if (msg.sender != d.terms.controller) revert Unauthorized();
        Clocks.requireStrictlyBefore(d.disputedAt, d.terms.disputeDuration);
        ICourt c = Packages.court(d);
        c.openCourt{value: msg.value}(dealId, msg.sender);
        emit Transitioned(dealId, d.status, Status.ARBITRATION_ACTIVE);
        d.status = Status.ARBITRATION_ACTIVE;
        d.arbitrationOpenedAt = block.timestamp;
    }

    /// @dev 1 = Holder wins (refund, Provider's lock to the Holder), 2 = Provider wins (payout, Holder's lock to
    ///      the Provider), 3 = neither wins: half each, completion fee, locks back. Never STALEMATE — that
    ///      status is only the kernel timeout of DISPUTED when the parties did not open court.
    function readRuling(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.ARBITRATION_ACTIVE) revert WrongStatus();
        uint8 ruling = ICourt(d.mods.court).readRuling(dealId);
        if (ruling == 1) {
            _close(
                dealId,
                d,
                d.terms.principal,
                Outcome(
                    Status.RESOLVED_BY_ARBITRATION,
                    0,
                    IReputation.Close.ArbWin,
                    IReputation.Close.ArbLoss,
                    BondAction.HolderWins
                )
            );
        } else if (ruling == 2) {
            _close(
                dealId,
                d,
                d.terms.principal,
                Outcome(
                    Status.RESOLVED_BY_ARBITRATION,
                    ALL,
                    IReputation.Close.ArbLoss,
                    IReputation.Close.ArbWin,
                    BondAction.ProviderWins
                )
            );
        } else if (ruling == 3) {
            _close(dealId, d, d.terms.principal, _arbNeither(IReputation.Close.Stalemate));
        } else {
            revert NotRuled();
        }
    }

    /// @dev The court never answered: same "neither wins" as a refuse. Half each, completion fee, locks
    ///      back, nobody's score moves. The court's failure is not the parties' fault.
    function forceArbitrationTimeout(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.ARBITRATION_ACTIVE) revert WrongStatus();
        Clocks.requireDue(d.arbitrationOpenedAt, d.terms.arbitrationDuration);
        _close(dealId, d, d.terms.principal, _arbNeither(IReputation.Close.Silent));
    }

    // --- settlement --------------------------------------------------------------------------------------------

    function withdraw(address token) external nonReentrant {
        Settlement.withdraw(settlement, token, msg.sender);
    }

    function cancelNonce(uint256 nonce) external {
        used[msg.sender][nonce] = true;
        emit NonceCancelled(msg.sender, nonce);
    }

    // --- internals -------------------------------------------------------------------------------------------------

    function _released() private pure returns (Outcome memory) {
        return Outcome(Status.RELEASED, ALL, IReputation.Close.Peaceful, IReputation.Close.Peaceful, BondAction.Unlock);
    }

    function _cancelled() private pure returns (Outcome memory) {
        return Outcome(Status.CANCELLED, 0, IReputation.Close.Silent, IReputation.Close.Silent, BondAction.Unlock);
    }

    function _stalemate(BondAction bond, IReputation.Close close) private pure returns (Outcome memory) {
        return Outcome(Status.STALEMATE, HALF, close, close, bond);
    }

    /// @dev Jury path: neither side won. Same split and fee as a kernel stalemate, distinct status.
    function _arbNeither(IReputation.Close close) private pure returns (Outcome memory) {
        return Outcome(Status.RESOLVED_BY_ARBITRATION, HALF, close, close, BondAction.Unlock);
    }

    /// @dev One exit for every terminal. The completion fee is invoiced on the whole pot whenever any of it
    ///      reaches the Provider (a trade happened), before the split; a refund to the Holder is never invoiced.
    ///      KERNEL-04: a fee that does not fit is skipped, a terminal never reverts on a package.
    function _close(bytes32 dealId, Deal storage d, uint256 pot, Outcome memory o) internal {
        uint256 providerAmt = pot * o.providerBps / ALL;
        if (providerAmt != 0) {
            (uint256 fee, address to) = Packages.completionInvoice(d);
            pot = _invoice(pot, fee, d.terms.token, to);
            providerAmt = pot * o.providerBps / ALL;
        }
        uint256 holderAmt = pot - providerAmt;

        emit Transitioned(dealId, d.status, o.next);
        d.status = o.next;
        d.holderAmt = holderAmt;
        d.providerAmt = providerAmt;
        emit Settled(dealId, o.next, holderAmt, providerAmt);
        if (holderAmt != 0) Settlement.creditThenTryPush(settlement, d.terms.token, d.terms.holder, holderAmt);
        if (providerAmt != 0) Settlement.creditThenTryPush(settlement, d.terms.token, d.terms.provider, providerAmt);
        Packages.disposeBond(d, dealId, o.bond);
        Packages.notify(d, o.closeH, o.closeP);
    }

    function _invoice(uint256 left, uint256 fee, address token, address to) internal returns (uint256) {
        if (fee == 0 || fee > left) return left;
        left -= fee;
        Settlement.creditThenTryPush(settlement, token, to, fee);
        return left;
    }

    function _requireNotZk(Deal storage d) internal view {
        if ((d.pkgs & Packages.ZK) != 0) revert EdgeOff();
    }

    function _assertDualSignEnvelope(bytes32 dealIdA, uint256 deadlineA, bytes32 dealIdB, uint256 deadlineB)
        private
        view
    {
        if (dealIdA != dealIdB) revert DealIdMismatch();
        if (deadlineA != deadlineB) revert DeadlineMismatch();
        if (block.timestamp > deadlineA) revert DeadlinePassed();
    }

    function _assertLiveForDualSign(Status s) private pure {
        if (s != Status.FUNDED && s != Status.FIAT_SENT && s != Status.DISPUTED && s != Status.ARBITRATION_ACTIVE) {
            revert WrongStatus();
        }
    }

    function _assertDualSignFromActive(Status s) private pure {
        if (s != Status.FIAT_SENT && s != Status.DISPUTED && s != Status.ARBITRATION_ACTIVE) revert WrongStatus();
    }

    function _consumeDualSign(
        address provider,
        bytes32 providerDigest,
        bytes calldata providerSig,
        uint256 providerNonce,
        address controller,
        bytes32 controllerDigest,
        bytes calldata controllerSig,
        uint256 controllerNonce
    ) private {
        if (!Consent.isValid(provider, providerDigest, providerSig)) {
            revert InvalidProviderSignature();
        }
        if (!Consent.isValid(controller, controllerDigest, controllerSig)) revert InvalidControllerSignature();
        if (used[provider][providerNonce] || used[controller][controllerNonce]) revert NonceUsed();
        used[provider][providerNonce] = true;
        used[controller][controllerNonce] = true;
    }
}
