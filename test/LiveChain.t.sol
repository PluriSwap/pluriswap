// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {CoreDeployer} from "../src/CoreDeployer.sol";
import {CoreEscrow} from "../src/CoreEscrow.sol";
import {CreditLedger} from "../src/CreditLedger.sol";
import {Coordinator} from "../src/Coordinator.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {DealHashing} from "../src/libraries/DealHashing.sol";
import {

    DealState,
    DealTerms,
    FundingAuth,
    FundingPurpose,
    FundingSourceMode,
    FundingSpec,
    PositionKind,
    PositionPayoutAuth,
    ResolutionAction,
    ResolutionAuth,
    TerminalAllocation
} from "../src/libraries/DealTypes.sol";
import {InvalidChainId, Reentrancy} from "../src/libraries/CoreErrors.sol";
import {CoreDeploymentIntentOffchain} from "../src/libraries/ManifestTypes.sol";

contract ReentrantMockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address private _target;
    bytes private _callData;
    bool private _armed;

    bool public reentrySuccess;
    bytes public reentryReturndata;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;

        if (_armed) {
            _armed = false;
            (bool success, bytes memory returndata) = _target.call(_callData);
            reentrySuccess = success;
            reentryReturndata = returndata;
        }
        return true;
    }

    function arm(address target, bytes calldata callData) external {
        _target = target;
        _callData = callData;
        _armed = true;
    }
}

contract LiveChainTest is Test {
    uint256 internal constant HOLDER_PK = 0xA11CE;
    uint256 internal constant PROVIDER_PK = 0xB0B;
    uint256 internal constant PRINCIPAL = 100;
    address internal constant RECEIVER = address(0xBEEF);

    uint256 internal chainA;
    address internal holder;
    address internal provider;
    CoreDeployer internal deployer;
    CoreEscrow internal escrow;
    CreditLedger internal ledger;
    MockERC20 internal token;

    struct ActivationCall {
        DealTerms terms;
        FundingSpec principalSpec;
        FundingSpec feeSpec;
        FundingAuth principalAuth;
        FundingAuth feeAuth;
        bytes principalSig;
        bytes feeSig;
        bytes holderSig;
        bytes providerSig;
    }

    struct FundingCall {
        bytes32 termsHash;
        bytes32 dealId;
        FundingSpec principalSpec;
        FundingSpec feeSpec;
        FundingAuth principalAuth;
        FundingAuth feeAuth;
        bytes principalSig;
        bytes feeSig;
    }

    function setUp() public {
        chainA = block.chainid;
        assertLe(chainA, type(uint64).max);
        holder = vm.addr(HOLDER_PK);
        provider = vm.addr(PROVIDER_PK);

        deployer = _newDeployer();
        (bytes memory ledgerCode, bytes memory coordinatorCode, bytes memory escrowCode) =
            _initCodes(deployer);
        deployer.deployTriad(ledgerCode, coordinatorCode, escrowCode);

        escrow = deployer.escrow();
        ledger = deployer.ledger();
        token = new MockERC20();
    }

    function test_coreEscrowReentrancyUsesCustomError() public {
        ReentrantMockERC20 reentrantToken = new ReentrantMockERC20();
        token = MockERC20(address(reentrantToken));
        (ActivationCall memory call_,) = _activationCall(61, 62);
        _mintAndApproveHolder(PRINCIPAL);
        reentrantToken.arm(address(escrow), _encodeActivate(call_));

        escrow.activate(
            call_.terms,
            call_.principalSpec,
            call_.feeSpec,
            call_.principalAuth,
            call_.feeAuth,
            call_.principalSig,
            call_.feeSig,
            call_.holderSig,
            call_.providerSig
        );

        assertFalse(reentrantToken.reentrySuccess());
        assertEq(reentrantToken.reentryReturndata(), abi.encodeWithSelector(Reentrancy.selector));
    }

    function test_creditLedgerReentrancyUsesCustomError() public {
        ReentrantMockERC20 reentrantToken = new ReentrantMockERC20();
        token = MockERC20(address(reentrantToken));
        FundingCall memory call_ = _fundingCall(keccak256("reentrant-funding"), 71);
        _mintAndApproveHolder(PRINCIPAL);
        reentrantToken.arm(address(ledger), _encodeFunding(call_));

        vm.prank(address(escrow));
        (bool success,) = address(ledger).call(_encodeFunding(call_));

        assertTrue(success);
        assertFalse(reentrantToken.reentrySuccess());
        assertEq(reentrantToken.reentryReturndata(), abi.encodeWithSelector(Reentrancy.selector));
    }

    function test_activateRejectsCachedDomainOnChangedChainWithoutEffects() public {
        (ActivationCall memory call_, bytes32 dealId) = _activationCall(11, 12);
        bytes32 positionId = _dealPositionId(dealId);
        _mintAndApproveHolder(PRINCIPAL);

        uint256 holderBalanceBefore = token.balanceOf(holder);
        uint256 ledgerBalanceBefore = token.balanceOf(address(ledger));
        (bool success, bytes memory result) = _callOnChainB(address(escrow), _encodeActivate(call_));

        _assertInvalidChainId(success, result);
        assertFalse(escrow.usedHolderNonce(holder, call_.terms.nonce));
        assertEq(escrow.dealState(dealId), DealState.None);
        assertFalse(ledger.positionExists(positionId));
        assertEq(ledger.accountedAssets(address(token)), 0);
        assertEq(ledger.nominalOutstanding(address(token)), 0);
        assertEq(token.balanceOf(holder), holderBalanceBefore);
        assertEq(token.balanceOf(address(ledger)), ledgerBalanceBefore);

        escrow.activate(
            call_.terms,
            call_.principalSpec,
            call_.feeSpec,
            call_.principalAuth,
            call_.feeAuth,
            call_.principalSig,
            call_.feeSig,
            call_.holderSig,
            call_.providerSig
        );
        assertTrue(escrow.usedHolderNonce(holder, call_.terms.nonce));
    }

    function test_mutualResolveRejectsCachedDomainOnChangedChainWithoutEffects() public {
        bytes32 dealId = _activateOnChainA(21, 22);
        bytes32 dealPositionId = _dealPositionId(dealId);
        ResolutionAuth memory auth = ResolutionAuth({
            dealId: dealId,
            action: uint8(ResolutionAction.MutualCancel),
            resolutionNonce: 23,
            expiry: uint64(block.timestamp + 1 days),
            providerShareBps: 0,
            operatorFaultCode: 0,
            operatorFaultEvidenceHash: bytes32(0),
            reservationDispositionsHash: bytes32(0),
            extensionsHash: bytes32(0)
        });
        bytes memory holderSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), HOLDER_PK);
        bytes memory providerSig =
            _sign(escrow.DOMAIN_SEPARATOR(), DealHashing.hashResolution(auth), PROVIDER_PK);
        uint256 nominalBefore = ledger.positionNominal(dealPositionId);
        uint256 assetsBefore = ledger.accountedAssets(address(token));

        (bool success, bytes memory result) = _callOnChainB(
            address(escrow),
            abi.encodeCall(CoreEscrow.mutualResolve, (dealId, auth, holderSig, providerSig))
        );

        _assertInvalidChainId(success, result);
        assertFalse(
            escrow.usedResolutionNonce(dealId, ResolutionAction.MutualCancel, auth.resolutionNonce)
        );
        assertEq(escrow.dealState(dealId), DealState.Funded);
        assertEq(escrow.getTerminalHash(dealId), bytes32(0));
        assertFalse(ledger.positionConsumed(dealPositionId));
        assertEq(ledger.positionNominal(dealPositionId), nominalBefore);
        assertEq(ledger.accountedAssets(address(token)), assetsBefore);

        escrow.mutualResolve(dealId, auth, holderSig, providerSig);
        assertTrue(
            escrow.usedResolutionNonce(dealId, ResolutionAction.MutualCancel, auth.resolutionNonce)
        );
    }

    function test_fundingRejectsCachedDomainOnChangedChainWithoutEffects() public {
        FundingCall memory call_ = _fundingCall(keccak256("wrong-chain-funding"), 31);
        bytes32 positionId = _dealPositionId(call_.dealId);
        _mintAndApproveHolder(PRINCIPAL);
        uint256 holderBalanceBefore = token.balanceOf(holder);
        uint256 allowanceBefore = token.allowance(holder, address(ledger));

        (bool success, bytes memory result) =
            _callOnChainBAs(address(escrow), address(ledger), _encodeFunding(call_));

        _assertInvalidChainId(success, result);
        assertFalse(ledger.positionExists(positionId));
        assertEq(ledger.accountedAssets(address(token)), 0);
        assertEq(ledger.nominalOutstanding(address(token)), 0);
        assertEq(token.balanceOf(holder), holderBalanceBefore);
        assertEq(token.balanceOf(address(ledger)), 0);
        assertEq(token.allowance(holder, address(ledger)), allowanceBefore);

        vm.prank(address(escrow));
        (success,) = address(ledger).call(_encodeFunding(call_));
        assertTrue(success, "cached funding authorization was consumed");
    }

    function test_withdrawPositionToRejectsCachedDomainOnChangedChainWithoutEffects() public {
        bytes32 positionId = _createMaturedPosition(keccak256("wrong-chain-withdraw"), 41);
        PositionPayoutAuth memory auth = _payoutAuth(1, positionId, 42, PRINCIPAL);
        bytes memory signature = _signPayout(auth);
        uint256 positionBefore = ledger.positionNominal(positionId);
        uint256 assetsBefore = ledger.accountedAssets(address(token));
        uint256 nominalBefore = ledger.nominalOutstanding(address(token));
        uint256 ledgerBalanceBefore = token.balanceOf(address(ledger));

        (bool success, bytes memory result) = _callOnChainB(
            address(ledger), abi.encodeCall(CreditLedger.withdrawPositionTo, (auth, signature))
        );

        _assertInvalidChainId(success, result);
        assertFalse(ledger.positionConsumed(positionId));
        assertEq(ledger.positionNominal(positionId), positionBefore);
        assertEq(ledger.accountedAssets(address(token)), assetsBefore);
        assertEq(ledger.nominalOutstanding(address(token)), nominalBefore);
        assertEq(token.balanceOf(address(ledger)), ledgerBalanceBefore);
        assertEq(token.balanceOf(RECEIVER), 0);

        (success,) = address(ledger)
            .call(abi.encodeCall(CreditLedger.withdrawPositionTo, (auth, signature)));
        assertTrue(success, "cached withdrawal authorization was consumed");
    }

    function test_claimRecoveryToRejectsCachedDomainOnChangedChainWithoutEffects() public {
        bytes32 positionId = _createMaturedPosition(keccak256("wrong-chain-recovery"), 51);
        token.burn(address(ledger), 50);
        ledger.checkpointBoundary(address(token));
        token.mint(address(this), 25);
        token.approve(address(ledger), 25);
        ledger.depositRecovery(address(token), 25);

        PositionPayoutAuth memory auth = _payoutAuth(2, positionId, 52, type(uint256).max);
        bytes memory signature = _signPayout(auth);
        uint256 positionBefore = ledger.positionNominal(positionId);
        uint256 assetsBefore = ledger.accountedAssets(address(token));
        uint256 nominalBefore = ledger.nominalOutstanding(address(token));
        uint256 ledgerBalanceBefore = token.balanceOf(address(ledger));
        bytes32 checkpointBefore = ledger.boundaryCheckpointId(address(token));

        (bool success, bytes memory result) = _callOnChainB(
            address(ledger), abi.encodeCall(CreditLedger.claimRecoveryTo, (auth, signature))
        );

        _assertInvalidChainId(success, result);
        assertFalse(ledger.positionConsumed(positionId));
        assertEq(ledger.positionNominal(positionId), positionBefore);
        assertEq(ledger.accountedAssets(address(token)), assetsBefore);
        assertEq(ledger.nominalOutstanding(address(token)), nominalBefore);
        assertEq(ledger.boundaryCheckpointId(address(token)), checkpointBefore);
        assertEq(token.balanceOf(address(ledger)), ledgerBalanceBefore);
        assertEq(token.balanceOf(RECEIVER), 0);

        (success,) =
            address(ledger).call(abi.encodeCall(CreditLedger.claimRecoveryTo, (auth, signature)));
        assertTrue(success, "cached recovery authorization was consumed");
    }

    function test_deployTriadRejectsChangedChainBeforeCreatingChildren() public {
        CoreDeployer pending = _newDeployer();
        (bytes memory ledgerCode, bytes memory coordinatorCode, bytes memory escrowCode) =
            _initCodes(pending);

        (bool success, bytes memory result) = _callOnChainB(
            address(pending),
            abi.encodeCall(CoreDeployer.deployTriad, (ledgerCode, coordinatorCode, escrowCode))
        );

        _assertInvalidChainId(success, result);
        assertFalse(pending.triadDeployed());
        assertEq(address(pending.ledger()).code.length, 0);
        assertEq(address(pending.coordinator()).code.length, 0);
        assertEq(address(pending.escrow()).code.length, 0);

        pending.deployTriad(ledgerCode, coordinatorCode, escrowCode);
        assertTrue(pending.triadDeployed());
    }

    function test_creditLedgerConstructorRejectsUint64OverflowBeforeTruncation() public {
        bytes memory initCode = abi.encodePacked(
            _replaceChainIdWithBlockNumber(type(CreditLedger).creationCode),
            abi.encode(address(0xE), address(0xC), uint64(0))
        );
        (bool success, bytes memory result) = _deployAtUint64Overflow(initCode);
        _assertInvalidChainId(success, result);
    }

    function test_coordinatorConstructorRejectsUint64OverflowBeforeTruncation() public {
        bytes memory initCode = abi.encodePacked(
            _replaceChainIdWithBlockNumber(type(Coordinator).creationCode),
            abi.encode(uint64(0), address(0xE), address(this))
        );
        (bool success, bytes memory result) = _deployAtUint64Overflow(initCode);
        _assertInvalidChainId(success, result);
    }

    function test_coreEscrowConstructorRejectsUint64OverflowBeforeTruncation() public {
        bytes memory initCode = abi.encodePacked(
            _replaceChainIdWithBlockNumber(type(CoreEscrow).creationCode),
            abi.encode(
                uint64(0),
                uint32(2),
                keccak256("overflow-charter"),
                keccak256("overflow-tech"),
                address(token),
                address(this),
                keccak256("overflow-manifest")
            )
        );
        (bool success, bytes memory result) = _deployAtUint64Overflow(initCode);
        _assertInvalidChainId(success, result);
    }

    function test_coreDeployerConstructorRejectsUint64OverflowBeforeTruncation() public {
        bytes memory initCode = abi.encodePacked(
            _replaceChainIdWithBlockNumber(type(CoreDeployer).creationCode),
            abi.encode(
                uint8(1),
                uint32(2),
                keccak256("charter"),
                keccak256("tech"),
                address(this),
                address(this),
                _offchain()
            )
        );
        (bool success, bytes memory result) = _deployAtUint64Overflow(initCode);
        _assertInvalidChainId(success, result);
    }

    function deployRaw(bytes calldata initCode) external returns (address deployed) {
        bytes memory initCodeMemory = initCode;
        assembly ("memory-safe") {
            deployed := create(0, add(initCodeMemory, 0x20), mload(initCodeMemory))
            if iszero(deployed) {
                returndatacopy(0, 0, returndatasize())
                revert(0, returndatasize())
            }
        }
    }

    function _newDeployer() internal returns (CoreDeployer) {
        return new CoreDeployer(
            1, 2, keccak256("charter"), keccak256("tech"), address(this), address(this), _offchain()
        );
    }

    function _offchain() internal pure returns (CoreDeploymentIntentOffchain memory offchain) {
        offchain = CoreDeploymentIntentOffchain({
            buildHash: bytes32(uint256(1)),
            plannedDeploymentMethodHash: bytes32(uint256(2)),
            coreDeployerCreationCodeHash: bytes32(uint256(3)),
            factoryCreationCodeHash: bytes32(0),
            ledgerCreationCodeHash: bytes32(uint256(5)),
            coordinatorCreationCodeHash: bytes32(uint256(6)),
            escrowCreationCodeHash: bytes32(uint256(7)),
            capabilityHash: bytes32(uint256(8)),
            governanceHash: bytes32(uint256(9)),
            predecessorIntentHash: bytes32(0)
        });
    }

    function _initCodes(CoreDeployer target)
        internal
        view
        returns (
            bytes memory ledgerInitCode,
            bytes memory coordinatorInitCode,
            bytes memory escrowInitCode
        )
    {
        ledgerInitCode = abi.encodePacked(
            type(CreditLedger).creationCode,
            abi.encode(address(target.escrow()), address(target.coordinator()), target.chainId())
        );
        coordinatorInitCode = abi.encodePacked(
            type(Coordinator).creationCode,
            abi.encode(target.chainId(), address(target.escrow()), target.coordinatorOwner())
        );
        escrowInitCode = abi.encodePacked(
            type(CoreEscrow).creationCode,
            abi.encode(
                target.chainId(),
                target.protocolVersion(),
                target.charterHash(),
                target.techSpecHash(),
                address(target.ledger()),
                address(target.coordinator()),
                target.intentHash()
            )
        );
    }

    function _activationCall(uint256 termsNonce, uint256 fundingNonce)
        internal
        view
        returns (ActivationCall memory call_, bytes32 dealId)
    {
        call_.principalSpec = _fundingSpec(FundingPurpose.Principal, PRINCIPAL);
        call_.feeSpec = _fundingSpec(FundingPurpose.ActivationFee, 0);
        call_.terms = DealTerms({
            holder: holder,
            provider: provider,
            holderReceiver: holder,
            providerReceiver: provider,
            token: address(token),
            principalFundingHash: DealHashing.hashFundingSpec(call_.principalSpec),
            activationFeeFundingHash: bytes32(0),
            tokenRiskHash: bytes32(0),
            custodyBoundaryId: DealHashing.custodyBoundaryId(
                escrow.chainId(), escrow.protocolVersion(), address(ledger), address(token)
            ),
            principal: PRINCIPAL,
            activationFee: 0,
            activationFeeRecipient: address(0),
            completionFee: 0,
            completionFeeRecipient: address(0),
            nonce: termsNonce,
            createExpiry: uint64(block.timestamp + 1 days),
            fiatDuration: 1 hours,
            releaseDuration: 1 hours,
            disputeDuration: 1 hours,
            disputeTimeoutProviderBps: 5_000,
            fiatCurrency: keccak256("USD"),
            fiatAmount: 1_000,
            paymentMethod: keccak256("SEPA"),
            payeeCommitment: bytes32(0),
            paymentReferenceCommitment: bytes32(0),
            profileFlags: 0,
            packageSelectionHash: bytes32(0),
            packageContestTermsHash: bytes32(0),
            poolAuthorityHash: bytes32(0),
            arbitrationTermsHash: bytes32(0),
            reservationsHash: bytes32(0),
            modulesHash: bytes32(0),
            extensionsHash: bytes32(0)
        });
        bytes32 termsHash = DealHashing.hashDealTerms(call_.terms);
        dealId = DealHashing.hashDealId(
            escrow.chainId(),
            escrow.protocolVersion(),
            address(escrow),
            termsHash,
            holder,
            provider,
            termsNonce
        );
        call_.principalAuth = FundingAuth({
            termsHash: termsHash,
            fundingSpecHash: call_.terms.principalFundingHash,
            purpose: FundingPurpose.Principal,
            authority: holder,
            nonce: fundingNonce,
            expiry: uint64(block.timestamp + 1 days)
        });
        call_.feeAuth = FundingAuth({
            termsHash: termsHash,
            fundingSpecHash: bytes32(0),
            purpose: FundingPurpose.ActivationFee,
            authority: holder,
            nonce: fundingNonce + 1,
            expiry: uint64(block.timestamp + 1 days)
        });
        call_.principalSig = _sign(
            ledger.DOMAIN_SEPARATOR(), DealHashing.hashFundingAuth(call_.principalAuth), HOLDER_PK
        );
        call_.holderSig = _sign(escrow.DOMAIN_SEPARATOR(), termsHash, HOLDER_PK);
        call_.providerSig = _sign(escrow.DOMAIN_SEPARATOR(), termsHash, PROVIDER_PK);
    }

    function _activateOnChainA(uint256 termsNonce, uint256 fundingNonce)
        internal
        returns (bytes32 dealId)
    {
        ActivationCall memory call_;
        (call_, dealId) = _activationCall(termsNonce, fundingNonce);
        _mintAndApproveHolder(PRINCIPAL);
        escrow.activate(
            call_.terms,
            call_.principalSpec,
            call_.feeSpec,
            call_.principalAuth,
            call_.feeAuth,
            call_.principalSig,
            call_.feeSig,
            call_.holderSig,
            call_.providerSig
        );
    }

    function _fundingCall(bytes32 dealId, uint256 nonce)
        internal
        view
        returns (FundingCall memory call_)
    {
        call_.termsHash = keccak256(abi.encodePacked("terms", dealId));
        call_.dealId = dealId;
        call_.principalSpec = _fundingSpec(FundingPurpose.Principal, PRINCIPAL);
        call_.feeSpec = _fundingSpec(FundingPurpose.ActivationFee, 0);
        call_.principalAuth = FundingAuth({
            termsHash: call_.termsHash,
            fundingSpecHash: DealHashing.hashFundingSpec(call_.principalSpec),
            purpose: FundingPurpose.Principal,
            authority: holder,
            nonce: nonce,
            expiry: uint64(block.timestamp + 1 days)
        });
        call_.feeAuth = FundingAuth({
            termsHash: call_.termsHash,
            fundingSpecHash: bytes32(0),
            purpose: FundingPurpose.ActivationFee,
            authority: holder,
            nonce: nonce + 1,
            expiry: uint64(block.timestamp + 1 days)
        });
        call_.principalSig = _sign(
            ledger.DOMAIN_SEPARATOR(), DealHashing.hashFundingAuth(call_.principalAuth), HOLDER_PK
        );
    }

    function _fundOnChainA(bytes32 dealId, uint256 nonce) internal {
        FundingCall memory call_ = _fundingCall(dealId, nonce);
        _mintAndApproveHolder(PRINCIPAL);
        vm.prank(address(escrow));
        (bool success,) = address(ledger).call(_encodeFunding(call_));
        assertTrue(success);
    }

    function _createMaturedPosition(bytes32 dealId, uint256 nonce)
        internal
        returns (bytes32 positionId)
    {
        _fundOnChainA(dealId, nonce);
        bytes32 terminalHash = keccak256(abi.encodePacked("terminal", dealId));
        positionId = _terminalPositionId(dealId, terminalHash, holder);
        TerminalAllocation[] memory allocations = new TerminalAllocation[](1);
        allocations[0] =
            TerminalAllocation({beneficiary: holder, amount: PRINCIPAL, positionId: positionId});
        vm.prank(address(escrow));
        ledger.settleDealAndReservations(dealId, address(token), terminalHash, allocations);
    }

    function _fundingSpec(uint8 purpose, uint256 amount)
        internal
        view
        returns (FundingSpec memory)
    {
        return FundingSpec({
            purpose: purpose,
            sourceMode: FundingSourceMode.WalletPull,
            token: address(token),
            amount: amount,
            source: holder,
            sourcePositionId: bytes32(0),
            authority: holder
        });
    }

    function _payoutAuth(uint8 action, bytes32 positionId, uint256 nonce, uint256 maxAmount)
        internal
        view
        returns (PositionPayoutAuth memory)
    {
        return PositionPayoutAuth({
            action: action,
            token: address(token),
            positionId: positionId,
            beneficiary: holder,
            to: RECEIVER,
            maxAmount: maxAmount,
            nonce: nonce,
            expiry: uint64(block.timestamp + 1 days)
        });
    }

    function _signPayout(PositionPayoutAuth memory auth) internal view returns (bytes memory) {
        bytes32 typeHash = keccak256(
            "PositionPayoutAuth(uint8 action,address token,bytes32 positionId,address beneficiary,address to,uint256 maxAmount,uint256 nonce,uint64 expiry)"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                typeHash,
                auth.action,
                auth.token,
                auth.positionId,
                auth.beneficiary,
                auth.to,
                auth.maxAmount,
                auth.nonce,
                auth.expiry
            )
        );
        return _sign(ledger.DOMAIN_SEPARATOR(), structHash, HOLDER_PK);
    }

    function _sign(bytes32 domainSeparator, bytes32 structHash, uint256 privateKey)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 digest = DealHashing.digest(domainSeparator, structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _mintAndApproveHolder(uint256 amount) internal {
        token.mint(holder, amount);
        vm.prank(holder);
        token.approve(address(ledger), type(uint256).max);
    }

    function _dealPositionId(bytes32 dealId) internal view returns (bytes32) {
        return DealHashing.positionId(
            _boundaryId(), PositionKind.ActiveDeal, dealId, bytes32(0), address(0)
        );
    }

    function _terminalPositionId(bytes32 dealId, bytes32 terminalHash, address beneficiary)
        internal
        view
        returns (bytes32)
    {
        return DealHashing.positionId(
            _boundaryId(), PositionKind.DealTerminal, dealId, terminalHash, beneficiary
        );
    }

    function _boundaryId() internal view returns (bytes32) {
        return DealHashing.custodyBoundaryId(ledger.chainId(), 2, address(ledger), address(token));
    }

    function _encodeActivate(ActivationCall memory call_) internal pure returns (bytes memory) {
        return abi.encodeCall(
            CoreEscrow.activate,
            (
                call_.terms,
                call_.principalSpec,
                call_.feeSpec,
                call_.principalAuth,
                call_.feeAuth,
                call_.principalSig,
                call_.feeSig,
                call_.holderSig,
                call_.providerSig
            )
        );
    }

    function _encodeFunding(FundingCall memory call_) internal view returns (bytes memory) {
        return abi.encodeCall(
            CreditLedger.fundDealAndReservations,
            (
                call_.termsHash,
                call_.dealId,
                address(token),
                PRINCIPAL,
                0,
                address(0),
                call_.principalSpec,
                call_.feeSpec,
                call_.principalAuth,
                call_.feeAuth,
                call_.principalSig,
                call_.feeSig
            )
        );
    }

    function _callOnChainB(address target, bytes memory callData)
        internal
        returns (bool success, bytes memory result)
    {
        vm.chainId(_otherChain(chainA));
        (success, result) = target.call(callData);
        vm.chainId(chainA);
    }

    function _callOnChainBAs(address caller, address target, bytes memory callData)
        internal
        returns (bool success, bytes memory result)
    {
        vm.chainId(_otherChain(chainA));
        vm.prank(caller);
        (success, result) = target.call(callData);
        vm.chainId(chainA);
    }

    /// @dev Foundry constrains vm.chainId below 2^64. Replacing executable CHAINID
    ///      opcodes with the same-width NUMBER opcode lets the real constructor
    ///      execute unchanged control flow against the otherwise-unrepresentable value.
    function _deployAtUint64Overflow(bytes memory initCode)
        internal
        returns (bool success, bytes memory result)
    {
        uint256 blockNumber = block.number;
        vm.roll(uint256(1) << 64);
        (success, result) = address(this).call(abi.encodeCall(this.deployRaw, (initCode)));
        vm.roll(blockNumber);
    }

    function _replaceChainIdWithBlockNumber(bytes memory code)
        internal
        pure
        returns (bytes memory)
    {
        uint256 replacements;
        uint256 cursor;
        while (cursor < code.length) {
            uint8 opcode = uint8(code[cursor]);
            if (opcode == 0x46) {
                code[cursor] = bytes1(uint8(0x43));
                ++replacements;
            }
            if (opcode >= 0x60 && opcode <= 0x7f) {
                cursor += uint256(opcode) - 0x5e;
            } else {
                ++cursor;
            }
        }
        require(replacements != 0, "constructor has no CHAINID opcode");
        return code;
    }

    function _otherChain(uint256 currentChain) internal pure returns (uint256) {
        return currentChain == type(uint64).max ? currentChain - 1 : currentChain + 1;
    }

    function _assertInvalidChainId(bool success, bytes memory result) internal pure {
        assertFalse(success, "expected InvalidChainId");
        assertEq(result.length, 4);
        assertEq(result, abi.encodeWithSelector(InvalidChainId.selector));
    }
}
