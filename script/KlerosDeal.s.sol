// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Status, DealTerms, HolderAuthorization, ProviderAgreement, ControllerAcceptance} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Escrow} from "../src/Escrow.sol";
import {TestToken} from "../src/TestToken.sol";
import {IArbitratorV2} from "../src/packages/interfaces/IKlerosV2.sol";
import {KlerosAdapter} from "../src/packages/KlerosAdapter.sol";

/// @dev Core-only except ARBITRATION: activate → markFiat → openCourt on live Kleros.
contract KlerosDeal is Script {
    using stdJson for string;

    uint256 internal constant PRINCIPAL = 1_000_000;
    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    function run() external {
        uint256 holderPk = _holderKey();
        uint256 providerPk = _providerKey();
        address holder = vm.addr(holderPk);
        address provider = vm.addr(providerPk);
        string memory catalog = vm.readFile(_path());
        TestToken token = TestToken(catalog.readAddress(".testToken"));
        Escrow escrow = Escrow(catalog.readAddress(".escrow"));
        KlerosAdapter court = KlerosAdapter(catalog.readAddress(".arbitration"));
        require(address(escrow).code.length > 0, "escrow");
        require(court.kernel() == address(escrow), "kernel");

        uint256 cost = IArbitratorV2(court.arbitrator()).arbitrationCost(court.extraData());
        if (provider.balance < 0.001 ether) {
            vm.startBroadcast(holderPk);
            (bool ok,) = provider.call{value: 0.002 ether}("");
            require(ok, "fund provider");
            vm.stopBroadcast();
        }

        vm.startBroadcast(holderPk);
        token.mint(holder, PRINCIPAL);
        token.approve(address(escrow), PRINCIPAL);
        vm.stopBroadcast();

        bytes32 id = _activate(escrow, address(token), holder, provider, holderPk, providerPk);
        vm.startBroadcast(providerPk);
        escrow.markFiat(id);
        vm.stopBroadcast();
        vm.startBroadcast(holderPk);
        escrow.openCourt{value: cost}(id);
        vm.stopBroadcast();

        require(escrow.status(id) == Status.ARBITRATION_ACTIVE, "court");
        require(court.opened(id), "opened");
        require(court.readRuling(id) == 0, "unruled");

        console.log("dealId", vm.toString(id));
        console.log("disputeId", court.disputeOf(id));
        console.log("cost", cost);

        vm.serializeUint("k", "chainId", catalog.readUint(".chainId"));
        vm.serializeAddress("k", "testToken", address(token));
        vm.serializeAddress("k", "passport", catalog.readAddress(".passport"));
        vm.serializeAddress("k", "reputation", catalog.readAddress(".reputation"));
        vm.serializeAddress("k", "bondVault", catalog.readAddress(".bondVault"));
        vm.serializeAddress("k", "verifier", catalog.readAddress(".verifier"));
        vm.serializeAddress("k", "zk", catalog.readAddress(".zk"));
        vm.serializeAddress("k", "klerosCore", catalog.readAddress(".klerosCore"));
        vm.serializeAddress("k", "templateRegistry", catalog.readAddress(".templateRegistry"));
        vm.serializeUint("k", "templateId", catalog.readUint(".templateId"));
        vm.serializeAddress("k", "arbitration", address(court));
        vm.serializeAddress("k", "feeRecipient", catalog.readAddress(".feeRecipient"));
        vm.serializeAddress("k", "sink", catalog.readAddress(".sink"));
        vm.serializeAddress("k", "escrow", address(escrow));
        vm.serializeBytes32("k", "passportId", catalog.readBytes32(".passportId"));
        vm.serializeBytes32("k", "reputationId", catalog.readBytes32(".reputationId"));
        vm.serializeBytes32("k", "bondsId", catalog.readBytes32(".bondsId"));
        vm.serializeBytes32("k", "zkId", catalog.readBytes32(".zkId"));
        vm.serializeBytes32("k", "arbId", catalog.readBytes32(".arbId"));
        vm.serializeUint("k", "disputeId", court.disputeOf(id));
        string memory json = vm.serializeBytes32("k", "arbDealId", id);
        vm.writeJson(json, _path());
        console.log("wrote", _path());
    }

    function _activate(
        Escrow escrow,
        address token,
        address holder,
        address provider,
        uint256 holderPk,
        uint256 providerPk
    ) internal returns (bytes32 id) {
        DealTerms memory terms;
        terms.holder = holder;
        terms.controller = holder;
        terms.provider = provider;
        terms.token = token;
        terms.principal = PRINCIPAL;
        terms.fiatDuration = 3600;
        terms.releaseDuration = 1800;
        terms.disputeDuration = 7200;
        terms.arbitrationDuration = 7 days;
        terms.packageIds = _one(escrow.arbId());

        HolderAuthorization memory ha =
            HolderAuthorization({terms: terms, nonce: 1, deadline: block.timestamp + 1 days});
        ProviderAgreement memory pa =
            ProviderAgreement({terms: terms, nonce: 1, deadline: block.timestamp + 1 days});
        ControllerAcceptance memory ca;
        bytes memory hs = _sign(escrow, Consent.hashHolderAuthorization(ha), holderPk);
        bytes memory ps = _sign(escrow, Consent.hashProviderAgreement(pa), providerPk);
        vm.startBroadcast(holderPk);
        id = escrow.activate(ha, hs, pa, ps, ca, "");
        vm.stopBroadcast();
    }

    function _one(bytes32 a) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](1);
        ids[0] = a;
    }

    function _sign(Escrow escrow, bytes32 structHash, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = MessageHashUtils.toTypedDataHash(escrow.domainSeparator(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _path() internal view returns (string memory) {
        if (block.chainid == ARBITRUM_SEPOLIA) return "deployments/sepolia-kleros-packages.json";
        return string.concat("deployments/", vm.toString(block.chainid), "-kleros-packages.json");
    }

    function _holderKey() internal view returns (uint256 pk) {
        if (block.chainid == 31337) {
            return 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
        pk = vm.envUint("HOLDER_PRIVATE_KEY");
    }

    function _providerKey() internal view returns (uint256 pk) {
        if (block.chainid == 31337) {
            return 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        }
        pk = vm.envUint("PROVIDER_PRIVATE_KEY");
    }
}
