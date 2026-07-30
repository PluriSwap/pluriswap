// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CoreEscrow} from "../../src/CoreEscrow.sol";
import {CreditLedger} from "../../src/CreditLedger.sol";
import {Coordinator} from "../../src/Coordinator.sol";
import {MockERC20} from "./MockERC20.sol";
import {DealSigUtils} from "./DealSigUtils.sol";
import {
    DealTerms,
    ModuleIdentity,
    DealState,
    Outcome,
    ResolutionAction,
    ResolutionAuth
} from "../../src/libraries/DealTypes.sol";

abstract contract CoreTestBase is Test {
    CoreEscrow escrow;
    CreditLedger ledger;
    Coordinator coordinator;
    MockERC20 token;

    uint256 holderPk = 0xA11CE;
    uint256 providerPk = 0xB0B;
    address holder;
    address provider;
    address holderReceiver = address(0x1111);
    address providerReceiver = address(0x2222);
    address feeRecipient = address(0xFEE);

    bytes32 domainSep;

    function setUp() public virtual {
        holder = vm.addr(holderPk);
        provider = vm.addr(providerPk);

        uint64 chainId_ = uint64(block.chainid);
        address deployer = address(this);
        uint64 nonce = uint64(vm.getNonce(deployer));
        address escrowPredicted = vm.computeCreateAddress(deployer, nonce + 2);

        ledger = new CreditLedger(escrowPredicted, chainId_);
        coordinator = new Coordinator(chainId_, escrowPredicted, address(this));
        escrow = new CoreEscrow(
            chainId_, 2, keccak256("charter"), keccak256("tech"), address(ledger), address(coordinator)
        );
        require(address(escrow) == escrowPredicted, "escrow addr");

        token = new MockERC20();
        domainSep = escrow.DOMAIN_SEPARATOR();
    }

    function _baseTerms(uint256 principal, uint256 nonce)
        internal
        view
        returns (DealTerms memory t)
    {
        ModuleIdentity[] memory modules;
        t.holder = holder;
        t.provider = provider;
        t.holderReceiver = holderReceiver;
        t.providerReceiver = providerReceiver;
        t.token = address(token);
        t.principal = principal;
        t.nonce = nonce;
        t.createExpiry = uint64(block.timestamp + 1 days);
        t.fiatDuration = 1 hours;
        t.releaseDuration = 1 hours;
        t.disputeDuration = 1 hours;
        t.disputeTimeoutProviderBps = 5000;
        t.modules = modules;
        t.extensions = "";
    }

    function _activate(DealTerms memory t) internal returns (bytes32 dealId) {
        token.mint(holder, t.principal + t.activationFee);
        vm.prank(holder);
        token.approve(address(escrow), type(uint256).max);

        bytes memory holderSig = DealSigUtils.signDeal(holderPk, domainSep, t);
        bytes memory providerSig = DealSigUtils.signDeal(providerPk, domainSep, t);
        dealId = escrow.activate(t, holderSig, providerSig, "");
    }

    function _markFiat(bytes32 dealId) internal {
        vm.prank(provider);
        escrow.markFiatSent(dealId);
    }

    function _openDispute(bytes32 dealId) internal {
        vm.prank(holder);
        escrow.openDispute(dealId, "");
    }

    function _mutualResolve(
        bytes32 dealId,
        ResolutionAction action,
        uint256 resolutionNonce,
        uint16 providerShareBps
    ) internal {
        ResolutionAuth memory auth;
        auth.dealId = dealId;
        auth.action = action;
        auth.resolutionNonce = resolutionNonce;
        auth.expiry = uint64(block.timestamp + 1 days);
        auth.providerShareBps = providerShareBps;
        escrow.mutualResolve(
            dealId,
            auth,
            DealSigUtils.signResolution(holderPk, domainSep, auth),
            DealSigUtils.signResolution(providerPk, domainSep, auth)
        );
    }
}
