// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {
    Status,
    DealTerms,
    HolderAuthorization,
    ProviderAgreement,
    ControllerAcceptance,
    PackageMods
} from "../src/libraries/Types.sol";
import {Consent} from "../src/libraries/Consent.sol";
import {Escrow} from "../src/Escrow.sol";
import {TestToken} from "../mocks/TestToken.sol";
import {PassportMock} from "../mocks/PassportMock.sol";
import {Reputation} from "../src/packages/Reputation.sol";

/// @title ReputationLadder
/// @notice Walks a subject up the tier ladder on chain and narrates what the cap does at each step.
/// @dev The reputation package is the one part of the protocol whose behaviour is a *curve* rather
///      than a transition, so no single deal shows what it does. This runs the curve: it earns the
///      tiers, hits the two refusals that surprise people, shows what a bond adds, and then throws
///      it away with one abandoned dispute.
///
///      Every subject is salted per run (`LADDER_RUN`, default the block timestamp), so the script
///      is repeatable on a chain that already has history — you can run it, look at it, and run it
///      again without the previous walk polluting the numbers.
///
///      Reading the output is the point; the `require`s are there so it is also a test.
///
///      Usage: `forge script script/ReputationLadder.s.sol:ReputationLadder --rpc-url $RPC --broadcast`
contract ReputationLadder is Script {
    using stdJson for string;

    uint256 internal constant ARBITRUM_SEPOLIA = 421614;
    uint256 internal constant UNIT = 250e6; // one T1 cap's worth, the score's unit of volume

    TestToken internal token;
    Escrow internal escrow;
    PassportMock internal passport;
    Reputation internal rep;

    bytes32 internal SUB_H;
    bytes32 internal SUB_P;
    uint256 internal holderPk;
    uint256 internal providerPk;
    address internal holder;
    address internal provider;
    /// @dev Derived from the run salt, because the same holder key signs for the other catalog
    ///      scripts: `used[signer][nonce]` is global per address, so a fixed start would collide.
    uint256 internal nonce;

    function run() external {
        _load();
        uint256 salt = vm.envOr("LADDER_RUN", block.timestamp);
        nonce = uint256(keccak256(abi.encodePacked("ladder-nonce", salt)));
        SUB_H = keccak256(abi.encodePacked("ladder-holder", salt));
        SUB_P = keccak256(abi.encodePacked("ladder-provider", salt));
        holderPk = _key("HOLDER_PRIVATE_KEY");
        providerPk = _key("PROVIDER_PRIVATE_KEY");
        holder = vm.addr(holderPk);
        provider = vm.addr(providerPk);

        _prepare();
        _start();
        _refusalTooBig();
        _climb();
        _refusalConcurrent();
        _bondColumn();
        _demotion();
        console.log("");
        console.log("ladder: done");
    }

    // ---------------------------------------------------------------- the walk

    function _start() internal view {
        console.log("");
        console.log("T1, a subject with no history");
        _state();
        console.log("  the cap is the MOST THAT CAN BE IN FLIGHT AT ONCE, not a per-deal limit");
    }

    /// The first thing people get wrong: the cap is checked at activation, so a deal above it does
    /// not fail late or get trimmed -- there is simply no deal.
    function _refusalTooBig() internal {
        uint256 cap = rep.cap(SUB_H, address(token), false);
        console.log("");
        console.log("asking for a deal above the cap");
        bool refused = _refused(cap + 1e6);
        console.log(refused ? "  refused: CapExceeded, no deal, no nonce spent" : "  ADMITTED (unexpected)");
        require(refused, "a deal above the cap must not activate");
    }

    /// Five clean deals at the cap is the whole of T1: +1 for closing, +1 for the volume (one UNIT),
    /// so a deal at the T1 cap is worth 2 points and 10 points is T2.
    function _climb() internal {
        console.log("");
        console.log("closing deals at the cap");
        for (uint256 i = 0; i < 5; i++) {
            uint256 cap = rep.cap(SUB_H, address(token), false);
            _release(_activate(cap));
            console.log("  deal", i + 1);
            _state();
        }
        require(rep.score(SUB_H, address(token)) >= 10, "five deals at the cap should reach T2");
        console.log("  T2: the cap doubled, and it did so by closing trades, not by asking");
    }

    /// The second surprise: the cap is concurrent. At T2 you can run one 500 deal or two 250s, never
    /// two 500s -- `inFlight + principal <= cap` is checked against everything still open.
    function _refusalConcurrent() internal {
        uint256 cap = rep.cap(SUB_H, address(token), false);
        console.log("");
        console.log("two deals at once, each half the cap");
        bytes32 a = _activate(cap / 2);
        bytes32 b = _activate(cap / 2);
        console.log("  both open; inFlight now equals the cap");
        _state();
        bool refused = _refused(1e6);
        console.log(refused ? "  a third deal of 1 token is refused: the cap is full" : "  ADMITTED (unexpected)");
        require(refused, "the cap must be concurrent");
        _release(a);
        _release(b);
        console.log("  both closed; the capacity came back, and the score grew again");
        _state();
    }

    /// A bond does not buy a tier: it widens the tier you already earned, and only while it is
    /// locked. 10% of the deal per side, and the cap column moves with it.
    function _bondColumn() internal view {
        console.log("");
        console.log("what a bond would add at this tier");
        console.log("  cap without bond", rep.cap(SUB_H, address(token), false) / 1e6);
        console.log("  cap with bond   ", rep.cap(SUB_H, address(token), true) / 1e6);
        console.log("  the bond is 10% of the deal, locked per side, returned on any peaceful close");
    }

    /// And the part worth staring at: one abandoned dispute is -5, which is two and a half clean
    /// deals at the T1 cap. Reputation is slow to earn and fast to lose, on purpose.
    function _demotion() internal {
        console.log("");
        console.log("one abandoned dispute, on a deal the Controller opens and walks away from");
        uint256 before = rep.score(SUB_H, address(token));
        bytes32 id = _activate(rep.cap(SUB_H, address(token), false), 3600, 100, 0);
        vm.startBroadcast(providerPk);
        escrow.markFiat(id);
        vm.stopBroadcast();
        vm.startBroadcast(holderPk);
        escrow.openDisputed(id); // costs the contest fee, from the opener's wallet
        escrow.forceDisputeTimeout(id); // disputeDuration 0: abandoned in the block it was opened
        vm.stopBroadcast();
        require(escrow.status(id) == Status.ABANDONED, "abandoned");
        console.log("  the principal went to the Provider in full, and the opener carries the score");
        console.log("  score before", before);
        _state();
        require(rep.score(SUB_H, address(token)) + 5 <= before + 1, "an abandoned dispute must cost the opener");
    }

    // ---------------------------------------------------------------- plumbing

    function _state() internal view {
        console.log("    score  ", rep.score(SUB_H, address(token)));
        console.log("    cap    ", rep.cap(SUB_H, address(token), false) / 1e6);
        console.log("    inFlight", rep.inFlight(SUB_H, address(token)) / 1e6);
    }

    function _activate(uint256 principal) internal returns (bytes32) {
        return _activate(principal, 3600, 1800, 7200);
    }

    /// @dev A refusal, demonstrated by actually asking and being told no -- but OUTSIDE the broadcast.
    ///      `forge script` queues every call made inside `startBroadcast` for sending, including ones
    ///      that reverted locally, so a caught revert in a broadcast block still ends up on the wire
    ///      and fails there. Run it locally instead: the kernel's answer is the same, and nothing is
    ///      sent. The activation reverts, so it leaves no local state behind either.
    function _refused(uint256 principal) internal returns (bool) {
        (HolderAuthorization memory ha, bytes memory hs, ProviderAgreement memory pa, bytes memory ps) =
            _envelope(principal, 3600, 1800, 7200);
        ControllerAcceptance memory ca;
        try escrow.activate(ha, hs, pa, ps, ca, "", _mods()) returns (bytes32) {
            return false;
        } catch {
            return true;
        }
    }

    function _activate(uint256 principal, uint256 fiatD, uint256 releaseD, uint256 disputeD)
        internal
        returns (bytes32 id)
    {
        (HolderAuthorization memory ha, bytes memory hs, ProviderAgreement memory pa, bytes memory ps) =
            _envelope(principal, fiatD, releaseD, disputeD);
        ControllerAcceptance memory ca;
        vm.startBroadcast(holderPk);
        id = escrow.activate(ha, hs, pa, ps, ca, "", _mods());
        vm.stopBroadcast();
    }

    function _mods() internal view returns (PackageMods memory mods) {
        mods.passport = address(passport);
        mods.reputation = address(rep);
    }

    function _envelope(uint256 principal, uint256 fiatD, uint256 releaseD, uint256 disputeD)
        internal
        returns (HolderAuthorization memory ha, bytes memory hs, ProviderAgreement memory pa, bytes memory ps)
    {
        DealTerms memory t;
        t.holder = holder;
        t.controller = holder;
        t.provider = provider;
        t.token = address(token);
        t.principal = principal;
        t.fiatDuration = fiatD;
        t.releaseDuration = releaseD;
        t.disputeDuration = disputeD;
        t.packageIds = _sorted2(passport.packageId(), rep.packageId());

        uint256 n = nonce++;
        ha = HolderAuthorization(t, n, block.timestamp + 1 days);
        pa = ProviderAgreement(t, n, block.timestamp + 1 days);
        hs = _sign(Consent.hashHolderAuthorization(ha), holderPk);
        ps = _sign(Consent.hashProviderAgreement(pa), providerPk);
    }

    function _release(bytes32 id) internal {
        vm.startBroadcast(providerPk);
        escrow.markFiat(id);
        vm.stopBroadcast();
        vm.startBroadcast(holderPk);
        escrow.release(id);
        vm.stopBroadcast();
    }

    function _prepare() internal {
        if (provider.balance < 0.001 ether) {
            vm.startBroadcast(holderPk);
            (bool ok,) = provider.call{value: 0.01 ether}("");
            require(ok, "fund provider");
            vm.stopBroadcast();
        }
        vm.startBroadcast(holderPk);
        // Generous: the walk opens a dozen deals and pays an activation fee and a contest on top.
        token.mint(holder, 100_000e6);
        token.approve(address(escrow), type(uint256).max);
        passport.setHuman(holder, SUB_H);
        passport.setHuman(provider, SUB_P);
        vm.stopBroadcast();
        vm.startBroadcast(providerPk);
        token.approve(address(escrow), type(uint256).max);
        vm.stopBroadcast();
    }

    function _sign(bytes32 structHash, uint256 pk) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", escrow.domainSeparator(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _sorted2(bytes32 a, bytes32 b) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](2);
        (ids[0], ids[1]) = a < b ? (a, b) : (b, a);
    }

    function _load() internal {
        string memory path = block.chainid == ARBITRUM_SEPOLIA
            ? "deployments/sepolia-packages.json"
            : string.concat("deployments/", vm.toString(block.chainid), "-packages.json");
        require(vm.exists(path), path);
        string memory json = vm.readFile(path);
        token = TestToken(json.readAddress(".testToken"));
        escrow = Escrow(json.readAddress(".escrow"));
        passport = PassportMock(json.readAddress(".passport"));
        rep = Reputation(json.readAddress(".reputation"));
        require(address(escrow).code.length > 0, "escrow");
    }

    function _key(string memory name) internal view returns (uint256) {
        if (block.chainid == 31337) {
            bool isProvider = keccak256(bytes(name)) == keccak256("PROVIDER_PRIVATE_KEY");
            return isProvider
                ? 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
                : 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        }
        return vm.envUint(name);
    }
}
