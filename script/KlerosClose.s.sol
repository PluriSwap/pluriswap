// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {Status} from "../src/libraries/Types.sol";
import {Escrow} from "../src/Escrow.sol";
import {KlerosAdapter} from "../src/packages/KlerosAdapter.sol";

interface IKlerosCoreAdvance {
    function draw(uint256 disputeId, uint256 iterations) external returns (uint256);
    function passPeriod(uint256 disputeId) external;
    function executeRuling(uint256 disputeId) external;
    function disputes(uint256 disputeId)
        external
        view
        returns (uint96 courtId, address arbitrated, uint8 period, bool ruled, uint256 lastPeriodChange);
    function getTimesPerPeriod(uint96 courtId) external view returns (uint256[4] memory);
}

/// @dev Idempotent closer: draw → passPeriod → executeRuling → escrow.readRuling.
///      Re-run after each Kleros period (12h on Sepolia court 1).
contract KlerosClose is Script {
    using stdJson for string;

    uint256 internal constant ARBITRUM_SEPOLIA = 421614;
    uint8 internal constant PERIOD_EVIDENCE = 0;
    uint8 internal constant PERIOD_EXECUTION = 4;

    function run() external {
        uint256 pk = _holderKey();
        string memory catalog = vm.readFile(_path());
        Escrow escrow = Escrow(catalog.readAddress(".escrow"));
        KlerosAdapter court = KlerosAdapter(catalog.readAddress(".arbitration"));
        bytes32 dealId = catalog.readBytes32(".arbDealId");
        uint256 disputeId = catalog.readUint(".disputeId");
        IKlerosCoreAdvance core = IKlerosCoreAdvance(address(court.arbitrator()));
        require(court.kernel() == address(escrow), "kernel");
        require(court.disputeOf(dealId) == disputeId, "dispute");

        vm.startBroadcast(pk);
        _advance(core, disputeId);
        if (uint8(escrow.status(dealId)) == uint8(Status.ARBITRATION_ACTIVE) && court.readRuling(dealId) != 0) {
            escrow.readRuling(dealId);
        }
        vm.stopBroadcast();

        (uint96 courtId, , uint8 period, bool ruled, uint256 lastChange) = core.disputes(disputeId);
        uint8 adapterRuling = court.readRuling(dealId);
        uint8 status = uint8(escrow.status(dealId));
        console.log("period", period);
        console.log("klerosRuled", ruled);
        console.log("adapterRuling", adapterRuling);
        console.log("escrowStatus", status);
        if (status == uint8(Status.ARBITRATION_ACTIVE) && adapterRuling == 0) {
            uint256[4] memory times = core.getTimesPerPeriod(courtId);
            uint256 due = lastChange + times[period < 4 ? period : 3];
            console.log("nextPeriodAt", due);
        }

        _write(catalog, dealId, disputeId, status, adapterRuling, period, ruled);
    }

    function _advance(IKlerosCoreAdvance core, uint256 disputeId) internal {
        (uint96 courtId, , uint8 period, bool ruled, uint256 lastChange) = core.disputes(disputeId);
        if (period == PERIOD_EVIDENCE) {
            uint256 drawn = core.draw(disputeId, 20);
            console.log("drawn", drawn);
            (courtId, , period, ruled, lastChange) = core.disputes(disputeId);
        }
        if (!ruled && period < PERIOD_EXECUTION) {
            uint256[4] memory times = core.getTimesPerPeriod(courtId);
            if (block.timestamp >= lastChange + times[period]) {
                core.passPeriod(disputeId);
                (courtId, , period, ruled, lastChange) = core.disputes(disputeId);
                console.log("passedTo", period);
            }
        }
        if (period == PERIOD_EXECUTION && !ruled) {
            core.executeRuling(disputeId);
            console.log("executed");
        }
    }

    function _write(
        string memory catalog,
        bytes32 dealId,
        uint256 disputeId,
        uint8 status,
        uint8 adapterRuling,
        uint8 period,
        bool ruled
    ) internal {
        vm.serializeUint("k", "chainId", catalog.readUint(".chainId"));
        vm.serializeAddress("k", "testToken", catalog.readAddress(".testToken"));
        vm.serializeAddress("k", "passport", catalog.readAddress(".passport"));
        vm.serializeAddress("k", "reputation", catalog.readAddress(".reputation"));
        vm.serializeAddress("k", "bondVault", catalog.readAddress(".bondVault"));
        vm.serializeAddress("k", "verifier", catalog.readAddress(".verifier"));
        vm.serializeAddress("k", "zk", catalog.readAddress(".zk"));
        vm.serializeAddress("k", "klerosCore", catalog.readAddress(".klerosCore"));
        vm.serializeAddress("k", "templateRegistry", catalog.readAddress(".templateRegistry"));
        vm.serializeUint("k", "templateId", catalog.readUint(".templateId"));
        vm.serializeAddress("k", "arbitration", catalog.readAddress(".arbitration"));
        vm.serializeAddress("k", "feeRecipient", catalog.readAddress(".feeRecipient"));
        vm.serializeAddress("k", "sink", catalog.readAddress(".sink"));
        vm.serializeAddress("k", "escrow", catalog.readAddress(".escrow"));
        vm.serializeBytes32("k", "passportId", catalog.readBytes32(".passportId"));
        vm.serializeBytes32("k", "reputationId", catalog.readBytes32(".reputationId"));
        vm.serializeBytes32("k", "bondsId", catalog.readBytes32(".bondsId"));
        vm.serializeBytes32("k", "zkId", catalog.readBytes32(".zkId"));
        vm.serializeBytes32("k", "arbId", catalog.readBytes32(".arbId"));
        vm.serializeUint("k", "disputeId", disputeId);
        vm.serializeUint("k", "klerosPeriod", period);
        vm.serializeBool("k", "klerosRuled", ruled);
        vm.serializeUint("k", "adapterRuling", adapterRuling);
        vm.serializeUint("k", "escrowStatus", status);
        string memory json = vm.serializeBytes32("k", "arbDealId", dealId);
        vm.writeJson(json, _path());
        console.log("wrote", _path());
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
}
