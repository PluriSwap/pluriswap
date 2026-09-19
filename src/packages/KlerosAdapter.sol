// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IArbitrableV2, IArbitratorV2} from "./interfaces/IKlerosV2.sol";
import {IDisputeTemplateRegistry} from "./interfaces/IDisputeTemplateRegistry.sol";
import {ICourt} from "./interfaces/ICourt.sol";
import {IEscrow} from "../interfaces/IEscrow.sol";
import {DealTerms} from "../libraries/Types.sol";
import {PackageId} from "../libraries/PackageId.sol";
import {PluriSwapKlerosTemplate} from "./PluriSwapKlerosTemplate.sol";

/// @dev Isolated Kleros V2 adapter. Does not move escrow principal.
///
///      PluriSwap touches Kleros exactly twice per deal:
///        1. `openCourt` (kernel only, Controller pays `arbitrationCost`): `createDispute` + `DisputeRequest`.
///        2. `rule` (KlerosCore only, after appeals): stores the verdict; the kernel reads it via `readRuling`.
///      Everything in between (evidence, appeals, juror votes) happens in the Kleros Court dapp. The dapp finds
///      the case through `DisputeRequest` and fills the template by calling `caseOf` on this contract.
///
///      Arbitrum One's KlerosCore enforces an arbitrable whitelist: `createDispute` reverts
///      `ArbitrableNotWhitelisted()` until Kleros governance lists the adapter address. Sepolia does not.
///
///      Implements `IArbitrableV2.rule` without inheriting the interface: the `Ruling` event
///      name collides with the kernel ternary enum.
contract KlerosAdapter is ICourt {
    error Unauthorized();
    error AlreadyOpen();
    error NotOpen();
    error AlreadyRuled();
    error InvalidRuling();
    error InsufficientFee();
    error ZeroAddress();
    error UnknownCase();

    uint256 public constant CHOICES = 2;

    enum Ruling {
        None,
        HolderWin,
        ProviderWin,
        Neither
    }

    IArbitratorV2 public immutable arbitrator;
    address public immutable kernel;
    uint256 public immutable templateId;
    bytes32 public immutable packageId;
    bytes public extraData;
    string public templateUri;
    string public policyUri;

    mapping(bytes32 dealId => bool) public opened;
    mapping(bytes32 dealId => uint256) public disputeOf;
    mapping(uint256 disputeId => bytes32) public dealOf;
    mapping(uint256 disputeId => bool) public known;
    mapping(bytes32 dealId => Ruling) public rulingOf;

    /// @param templateId_ Used only when `registry_` is zero (template registered out of band).
    /// @param templateUri_ Used only when `registry_` is zero.
    /// @param policyUri_ Multiaddr of the arbitration policy jurors read (`/ipfs/<cid>/...`). Baked into the
    ///        template when `registry_` is set. The Court UI rejects templates without it.
    constructor(
        address arbitrator_,
        bytes memory extraData_,
        uint256 templateId_,
        string memory templateUri_,
        address kernel_,
        address registry_,
        string memory policyUri_
    ) {
        if (arbitrator_ == address(0) || kernel_ == address(0)) revert ZeroAddress();
        arbitrator = IArbitratorV2(arbitrator_);
        extraData = extraData_;
        kernel = kernel_;
        policyUri = policyUri_;
        if (registry_ == address(0)) {
            templateId = templateId_;
            templateUri = templateUri_;
        } else {
            templateId = IDisputeTemplateRegistry(registry_)
                .setDisputeTemplate(PluriSwapKlerosTemplate.tag(), templateData(), templateMappings());
        }
        packageId = PackageId.kleros(address(this), arbitrator_, extraData_);
    }

    function packageBinding() external view returns (address partner, uint256 key) {
        return (address(arbitrator), uint256(keccak256(extraData)));
    }

    /// @dev Template exactly as registered (or as it would be registered) for this chain and arbitrator.
    function templateData() public view returns (string memory) {
        return PluriSwapKlerosTemplate.json(block.chainid, address(arbitrator), policyUri);
    }

    function templateMappings() public pure returns (string memory) {
        return PluriSwapKlerosTemplate.mappings();
    }

    /// @dev Only the kernel opens: it already checked status, clock and Controller. `controller` is the opener
    ///      the kernel vouches for; the adapter does not re-derive it.
    function openCourt(bytes32 dealId, address controller) external payable {
        if (msg.sender != kernel) revert Unauthorized();
        if (opened[dealId]) revert AlreadyOpen();
        uint256 cost = arbitrator.arbitrationCost(extraData);
        if (msg.value != cost) revert InsufficientFee();
        opened[dealId] = true; // effects before the arbitrator call (CEI)
        uint256 disputeId = arbitrator.createDispute{value: cost}(CHOICES, extraData);
        known[disputeId] = true;
        disputeOf[dealId] = disputeId;
        dealOf[disputeId] = dealId;
        emit IArbitrableV2.DisputeRequest(arbitrator, disputeId, uint256(dealId), templateId, templateUri);
        emit IArbitrableV2.DisputeRequest(arbitrator, disputeId, templateId);
    }

    function rule(uint256 disputeId, uint256 klerosRuling) external {
        if (msg.sender != address(arbitrator)) revert Unauthorized();
        if (!known[disputeId]) revert NotOpen();
        bytes32 dealId = dealOf[disputeId];
        if (rulingOf[dealId] != Ruling.None) revert AlreadyRuled();
        rulingOf[dealId] = _map(klerosRuling);
        emit IArbitrableV2.Ruling(arbitrator, disputeId, klerosRuling);
    }

    function readRuling(bytes32 dealId) external view returns (uint8) {
        return uint8(rulingOf[dealId]);
    }

    /// @dev Read by the Kleros Court dapp (template mapping `abi/call`) with `externalDisputeID = uint256(dealId)`.
    ///      `amount` is human-readable (`"1250.5 USDC"`); falls back to raw units if the token has no metadata.
    function caseOf(uint256 externalDisputeId)
        external
        view
        returns (bytes32 dealId, address holder, address provider, address token, string memory amount)
    {
        dealId = bytes32(externalDisputeId);
        if (!opened[dealId]) revert UnknownCase();
        DealTerms memory t = IEscrow(kernel).terms(dealId);
        return (dealId, t.holder, t.provider, t.token, _amount(t.token, t.principal));
    }

    /// @dev Kleros 0 (refuse) → ICourt 3 (neither). The kernel never closes that path as STALEMATE.
    function _map(uint256 klerosRuling) internal pure returns (Ruling) {
        if (klerosRuling == 0) return Ruling.Neither;
        if (klerosRuling == 1) return Ruling.HolderWin;
        if (klerosRuling == 2) return Ruling.ProviderWin;
        revert InvalidRuling();
    }

    function _amount(address token, uint256 principal) internal view returns (string memory) {
        uint8 decimals;
        string memory symbol;
        string memory raw = string.concat(Strings.toString(principal), " raw units of ", Strings.toHexString(token));
        if (token.code.length == 0) return raw; // try/catch does not cover the extcodesize check
        try IERC20Metadata(token).decimals() returns (uint8 d) {
            decimals = d;
        } catch {
            return raw;
        }
        try IERC20Metadata(token).symbol() returns (string memory s) {
            symbol = s;
        } catch {
            symbol = Strings.toHexString(token);
        }
        return string.concat(_decimal(principal, decimals), " ", symbol);
    }

    /// @dev `1250500000` with 6 decimals -> `"1250.5"`; `1000000` -> `"1"`.
    function _decimal(uint256 value, uint8 decimals) internal pure returns (string memory) {
        if (decimals == 0) return Strings.toString(value);
        uint256 base = 10 ** uint256(decimals);
        uint256 whole = value / base;
        uint256 frac = value % base;
        if (frac == 0) return Strings.toString(whole);
        bytes memory digits = new bytes(decimals);
        uint256 len;
        for (uint256 i = decimals; i > 0; i--) {
            uint8 digit = uint8(frac % 10);
            frac /= 10;
            digits[i - 1] = bytes1(uint8(48) + digit);
            if (digit != 0 && len == 0) len = i;
        }
        bytes memory trimmed = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            trimmed[i] = digits[i];
        }
        return string.concat(Strings.toString(whole), ".", string(trimmed));
    }
}
