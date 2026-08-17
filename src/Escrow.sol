// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    MutualCancel,
    CoSignedRelease,
    MutualSplit
} from "./libraries/Types.sol";
import {Terms} from "./libraries/Terms.sol";
import {Consent} from "./libraries/Consent.sol";
import {Settlement} from "./libraries/Settlement.sol";
import {Clocks} from "./libraries/Clocks.sol";
import {IPassport} from "./packages/interfaces/IPassport.sol";
import {ICourt} from "./packages/interfaces/ICourt.sol";
import {Reputation} from "./packages/Reputation.sol";
import {BondVault} from "./packages/BondVault.sol";
import {ZkMock} from "./packages/ZkMock.sol";

contract Escrow is EIP712, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

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
    error UnknownPackage();
    error IncompatiblePackages();
    error PackageRequired();
    error PackageNotSelected();
    error EdgeOff();
    error NotRuled();

    uint8 internal constant PKG_PASSPORT = 1;
    uint8 internal constant PKG_REP = 2;
    uint8 internal constant PKG_BONDS = 4;
    uint8 internal constant PKG_ZK = 8;
    uint8 internal constant PKG_ARB = 16;

    enum BondAction {
        Unlock,
        Burn,
        SlashHolder,
        SlashProvider
    }

    struct Deal {
        Status status;
        DealTerms terms;
        uint256 activatedAt;
        uint256 fiatSentAt;
        uint256 disputedAt;
        uint256 arbitrationOpenedAt;
        bytes32 subjectH;
        bytes32 subjectP;
        uint8 pkgs;
    }

    IPassport public immutable passport;
    Reputation public immutable reputation;
    BondVault public immutable vault;
    ZkMock public immutable zk;
    ICourt public immutable court;
    bytes32 public immutable passportId;
    bytes32 public immutable reputationId;
    bytes32 public immutable bondsId;
    bytes32 public immutable zkId;
    bytes32 public immutable arbId;

    mapping(address signer => mapping(uint256 nonce => bool consumed)) public used;
    mapping(bytes32 dealId => Deal) internal deals;
    Settlement.Store internal settlement;

    constructor(address passport_, address reputation_, address vault_, address zk_, address court_)
        EIP712("PluriSwap", "1")
    {
        passport = IPassport(passport_);
        reputation = Reputation(reputation_);
        vault = BondVault(vault_);
        zk = ZkMock(zk_);
        court = ICourt(court_);
        if (passport_ != address(0)) passportId = IPassport(passport_).packageId();
        if (reputation_ != address(0)) reputationId = Reputation(reputation_).packageId();
        if (vault_ != address(0)) bondsId = BondVault(vault_).packageId();
        if (zk_ != address(0)) zkId = ZkMock(zk_).packageId();
        if (court_ != address(0)) arbId = ICourt(court_).packageId();
    }

    function domainSeparator() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function status(bytes32 dealId) external view returns (Status) {
        return deals[dealId].status;
    }

    function subjects(bytes32 dealId) external view returns (bytes32, bytes32) {
        return (deals[dealId].subjectH, deals[dealId].subjectP);
    }

    function activate(
        HolderAuthorization calldata ha,
        bytes calldata holderSig,
        ProviderAgreement calldata pa,
        bytes calldata providerSig,
        ControllerAcceptance calldata ca,
        bytes calldata controllerSig
    ) external nonReentrant returns (bytes32 id) {
        DealTerms calldata terms = ha.terms;
        bytes32 termsHash = Terms.hashTerms(terms);
        if (termsHash != Terms.hashTerms(pa.terms)) revert TermsMismatch();

        if (block.timestamp > ha.deadline || block.timestamp > pa.deadline) revert DeadlinePassed();

        if (!Consent.isValid(terms.holder, _hashTypedDataV4(Consent.hashHolderAuthorization(ha)), holderSig)) {
            revert InvalidHolderSignature();
        }
        if (!Consent.isValid(terms.provider, _hashTypedDataV4(Consent.hashProviderAgreement(pa)), providerSig)) {
            revert InvalidProviderSignature();
        }

        uint256 controllerNonce;
        if (terms.holder != terms.controller) {
            if (ca.terms.controller != terms.controller) revert ControllerAcceptanceRequired();
            if (termsHash != Terms.hashTerms(ca.terms)) revert TermsMismatch();
            if (block.timestamp > ca.deadline) revert DeadlinePassed();
            if (!Consent.isValid(terms.controller, _hashTypedDataV4(Consent.hashControllerAcceptance(ca)), controllerSig))
            {
                revert InvalidControllerSignature();
            }
            if (used[terms.controller][ca.nonce]) revert NonceUsed();
            controllerNonce = ca.nonce;
        }

        if (used[terms.holder][ha.nonce] || used[terms.provider][pa.nonce]) revert NonceUsed();

        uint8 pkgs = _decodePackages(terms.packageIds);
        id = Consent.dealId(_domainSeparatorV4(), terms, ha.nonce, pa.nonce, controllerNonce);
        if (deals[id].status != Status.NONE) revert DealExists();

        (bytes32 subjectH, bytes32 subjectP) = _engage(terms, pkgs, id);
        Settlement.pullExact(terms.token, terms.holder, terms.principal);

        used[terms.holder][ha.nonce] = true;
        used[terms.provider][pa.nonce] = true;
        if (terms.holder != terms.controller) used[terms.controller][ca.nonce] = true;

        Deal storage d = deals[id];
        d.status = Status.FUNDED;
        d.terms = terms;
        d.activatedAt = block.timestamp;
        d.subjectH = subjectH;
        d.subjectP = subjectP;
        d.pkgs = pkgs;
    }

    function markFiat(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FUNDED) revert WrongStatus();
        _requireNotZk(d);
        if (msg.sender != d.terms.provider) revert Unauthorized();
        d.status = Status.FIAT_SENT;
        d.fiatSentAt = block.timestamp;
    }

    function release(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FIAT_SENT) revert WrongStatus();
        if (msg.sender != d.terms.controller) revert Unauthorized();
        uint256 left = _takeCompletion(d);
        _finish(dealId, d, Status.RELEASED, 0, left, Reputation.Close.Peaceful, Reputation.Close.Peaceful, BondAction.Unlock);
    }

    function cancelByProvider(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FUNDED) revert WrongStatus();
        if (msg.sender != d.terms.provider) revert Unauthorized();
        _finish(
            dealId,
            d,
            Status.CANCELLED,
            d.terms.principal,
            0,
            Reputation.Close.Silent,
            Reputation.Close.Silent,
            BondAction.Unlock
        );
    }

    function timeoutFiat(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FUNDED) revert WrongStatus();
        Clocks.requireDue(d.activatedAt, d.terms.fiatDuration);
        _finish(
            dealId,
            d,
            Status.CANCELLED,
            d.terms.principal,
            0,
            Reputation.Close.Silent,
            Reputation.Close.Silent,
            BondAction.Unlock
        );
    }

    function claim(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FIAT_SENT) revert WrongStatus();
        _requireNotZk(d);
        Clocks.requireDue(d.fiatSentAt, d.terms.releaseDuration);
        _finish(
            dealId, d, Status.RELEASED, 0, d.terms.principal, Reputation.Close.Silent, Reputation.Close.Silent, BondAction.Unlock
        );
    }

    function openDisputed(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FIAT_SENT) revert WrongStatus();
        _requireNotZk(d);
        if (msg.sender != d.terms.controller) revert Unauthorized();
        Clocks.requireStrictlyBefore(d.fiatSentAt, d.terms.releaseDuration);
        d.status = Status.DISPUTED;
        d.disputedAt = block.timestamp;
    }

    function forceStalemate(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.DISPUTED) revert WrongStatus();
        Clocks.requireDue(d.disputedAt, d.terms.disputeDuration);
        uint256 holderShare = d.terms.principal / 2;
        _finish(
            dealId,
            d,
            Status.STALEMATE,
            holderShare,
            d.terms.principal - holderShare,
            Reputation.Close.Stalemate,
            Reputation.Close.Stalemate,
            BondAction.Burn
        );
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
        _finish(
            providerMsg.dealId,
            d,
            Status.CANCELLED,
            d.terms.principal,
            0,
            Reputation.Close.Silent,
            Reputation.Close.Silent,
            BondAction.Unlock
        );
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
        uint256 left = _takeCompletion(d);
        _finish(
            providerMsg.dealId, d, Status.RELEASED, 0, left, Reputation.Close.Peaceful, Reputation.Close.Peaceful, BondAction.Unlock
        );
    }

    function mutualSplit(
        MutualSplit calldata providerMsg,
        bytes calldata providerSig,
        MutualSplit calldata controllerMsg,
        bytes calldata controllerSig
    ) external nonReentrant {
        _assertDualSignEnvelope(providerMsg.dealId, providerMsg.deadline, controllerMsg.dealId, controllerMsg.deadline);
        if (providerMsg.providerBps != controllerMsg.providerBps) revert BpsMismatch();
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
        uint256 left = _takeCompletion(d);
        uint256 providerShare = left * uint256(providerMsg.providerBps) / 10_000;
        _finish(
            providerMsg.dealId,
            d,
            Status.RESOLVED_SPLIT,
            left - providerShare,
            providerShare,
            Reputation.Close.Peaceful,
            Reputation.Close.Peaceful,
            BondAction.Unlock
        );
    }

    function verifyProof(bytes32 dealId, bytes calldata proof) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.FUNDED) revert WrongStatus();
        if ((d.pkgs & PKG_ZK) == 0) revert PackageNotSelected();
        zk.verifyProof(dealId, proof);
        uint256 left = d.terms.principal;
        (uint256 fee, address to) = zk.invoiceVerify();
        if (fee != 0) {
            left -= fee;
            Settlement.creditThenTryPush(settlement, d.terms.token, to, fee);
        }
        left = _takeCompletionFrom(d, left);
        _finish(dealId, d, Status.RELEASED, 0, left, Reputation.Close.Peaceful, Reputation.Close.Peaceful, BondAction.Unlock);
    }

    function openCourt(bytes32 dealId) external payable nonReentrant {
        Deal storage d = deals[dealId];
        if ((d.pkgs & PKG_ARB) == 0) revert PackageNotSelected();
        _requireNotZk(d);
        if (d.status != Status.FIAT_SENT && d.status != Status.DISPUTED) revert WrongStatus();
        if (msg.sender != d.terms.controller) revert Unauthorized();
        court.openCourt{value: msg.value}(dealId, msg.sender);
        d.status = Status.ARBITRATION_ACTIVE;
        d.arbitrationOpenedAt = block.timestamp;
    }

    function readRuling(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.ARBITRATION_ACTIVE) revert WrongStatus();
        uint8 ruling = court.readRuling(dealId);
        if (ruling == 0) revert NotRuled();
        if (ruling == 3) {
            uint256 holderShare = d.terms.principal / 2;
            _finish(
                dealId,
                d,
                Status.STALEMATE,
                holderShare,
                d.terms.principal - holderShare,
                Reputation.Close.Stalemate,
                Reputation.Close.Stalemate,
                BondAction.Burn
            );
            return;
        }
        uint256 left = _takeCompletion(d);
        if (ruling == 1) {
            _finish(
                dealId,
                d,
                Status.RESOLVED_BY_ARBITRATION,
                left,
                0,
                Reputation.Close.ArbWin,
                Reputation.Close.ArbLoss,
                BondAction.SlashHolder
            );
        } else if (ruling == 2) {
            _finish(
                dealId,
                d,
                Status.RESOLVED_BY_ARBITRATION,
                0,
                left,
                Reputation.Close.ArbLoss,
                Reputation.Close.ArbWin,
                BondAction.SlashProvider
            );
        } else {
            revert NotRuled();
        }
    }

    function forceArbitrationTimeout(bytes32 dealId) external nonReentrant {
        Deal storage d = deals[dealId];
        if (d.status != Status.ARBITRATION_ACTIVE) revert WrongStatus();
        Clocks.requireDue(d.arbitrationOpenedAt, d.terms.arbitrationDuration);
        uint256 holderShare = d.terms.principal / 2;
        _finish(
            dealId,
            d,
            Status.STALEMATE,
            holderShare,
            d.terms.principal - holderShare,
            Reputation.Close.Stalemate,
            Reputation.Close.Stalemate,
            BondAction.Burn
        );
    }

    function creditOf(address token, address beneficiary) external view returns (uint256) {
        return Settlement.creditOf(settlement, token, beneficiary);
    }

    function withdraw(address token) external nonReentrant {
        Settlement.withdraw(settlement, token, msg.sender);
    }

    function cancelNonce(uint256 nonce) external {
        used[msg.sender][nonce] = true;
    }

    function _decodePackages(bytes32[] memory ids) internal view returns (uint8 pkgs) {
        for (uint256 i; i < ids.length; i++) {
            bytes32 id = ids[i];
            if (passportId != bytes32(0) && id == passportId) pkgs |= PKG_PASSPORT;
            else if (reputationId != bytes32(0) && id == reputationId) pkgs |= PKG_REP;
            else if (bondsId != bytes32(0) && id == bondsId) pkgs |= PKG_BONDS;
            else if (zkId != bytes32(0) && id == zkId) pkgs |= PKG_ZK;
            else if (arbId != bytes32(0) && id == arbId) pkgs |= PKG_ARB;
            else revert UnknownPackage();
        }
        if ((pkgs & (PKG_ZK | PKG_ARB)) == (PKG_ZK | PKG_ARB)) revert IncompatiblePackages();
        if ((pkgs & PKG_REP) != 0 && (pkgs & PKG_PASSPORT) == 0) revert PackageRequired();
        if ((pkgs & PKG_BONDS) != 0 && (pkgs & (PKG_PASSPORT | PKG_REP)) != (PKG_PASSPORT | PKG_REP)) {
            revert PackageRequired();
        }
    }

    function _engage(DealTerms calldata terms, uint8 pkgs, bytes32 dealId)
        internal
        returns (bytes32 subjectH, bytes32 subjectP)
    {
        if ((pkgs & PKG_PASSPORT) != 0) {
            subjectH = passport.identify(terms.holder);
            subjectP = passport.identify(terms.provider);
        }
        if ((pkgs & PKG_REP) != 0) {
            address v = (pkgs & PKG_BONDS) != 0 ? address(vault) : address(0);
            reputation.admit(terms.holder, terms.token, terms.principal, v);
            reputation.admit(terms.provider, terms.token, terms.principal, v);
            (uint256 fee, address to) = reputation.invoiceActivation();
            if (fee != 0) {
                Settlement.pullExact(terms.token, terms.holder, fee);
                IERC20(terms.token).safeTransfer(to, fee);
            }
        }
        if ((pkgs & PKG_BONDS) != 0) {
            vault.reserve(subjectH, terms.token, dealId, terms.principal);
            vault.reserve(subjectP, terms.token, dealId, terms.principal);
        }
    }

    function _takeCompletion(Deal storage d) internal returns (uint256 left) {
        return _takeCompletionFrom(d, d.terms.principal);
    }

    function _takeCompletionFrom(Deal storage d, uint256 left) internal returns (uint256) {
        if ((d.pkgs & PKG_REP) == 0) return left;
        (uint256 fee, address to) = reputation.invoiceCompletion();
        if (fee == 0) return left;
        left -= fee;
        Settlement.creditThenTryPush(settlement, d.terms.token, to, fee);
        return left;
    }

    function _finish(
        bytes32 dealId,
        Deal storage d,
        Status next,
        uint256 holderAmt,
        uint256 providerAmt,
        Reputation.Close closeH,
        Reputation.Close closeP,
        BondAction bond
    ) internal {
        d.status = next;
        if (holderAmt != 0) {
            Settlement.creditThenTryPush(settlement, d.terms.token, d.terms.holder, holderAmt);
        }
        if (providerAmt != 0) {
            Settlement.creditThenTryPush(settlement, d.terms.token, d.terms.provider, providerAmt);
        }
        _disposeBond(dealId, d, bond);
        _notify(d, closeH, closeP);
    }

    function _disposeBond(bytes32 dealId, Deal storage d, BondAction bond) internal {
        if ((d.pkgs & PKG_BONDS) == 0) return;
        if (bond == BondAction.Unlock) {
            vault.unlock(d.subjectH, d.terms.token, dealId);
            vault.unlock(d.subjectP, d.terms.token, dealId);
        } else if (bond == BondAction.Burn) {
            vault.burn(d.subjectH, d.subjectP, d.terms.token, dealId);
        } else if (bond == BondAction.SlashHolder) {
            vault.slash(d.subjectP, d.subjectH, d.terms.token, dealId, d.terms.holder, d.terms.controller);
        } else {
            vault.slash(d.subjectH, d.subjectP, d.terms.token, dealId, d.terms.provider, d.terms.controller);
        }
    }

    function _notify(Deal storage d, Reputation.Close closeH, Reputation.Close closeP) internal {
        if ((d.pkgs & PKG_REP) == 0) return;
        try reputation.notifyTerminal(d.terms.holder, d.terms.token, d.terms.principal, closeH) {} catch {}
        try reputation.notifyTerminal(d.terms.provider, d.terms.token, d.terms.principal, closeP) {} catch {}
    }

    function _requireNotZk(Deal storage d) internal view {
        if ((d.pkgs & PKG_ZK) != 0) revert EdgeOff();
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
        if (
            s != Status.FUNDED && s != Status.FIAT_SENT && s != Status.DISPUTED && s != Status.ARBITRATION_ACTIVE
        ) revert WrongStatus();
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
        if (!Consent.isValid(provider, providerDigest, providerSig)) revert InvalidProviderSignature();
        if (!Consent.isValid(controller, controllerDigest, controllerSig)) revert InvalidControllerSignature();
        if (used[provider][providerNonce] || used[controller][controllerNonce]) revert NonceUsed();
        used[provider][providerNonce] = true;
        used[controller][controllerNonce] = true;
    }
}
