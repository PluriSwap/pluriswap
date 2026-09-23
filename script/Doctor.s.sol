// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PackageId} from "../src/libraries/PackageId.sol";
import {Poseidon} from "../src/packages/libraries/Poseidon.sol";

/// @title Doctor
/// @notice Reads the deployment records and asks the chain whether they still describe it.
/// @dev Read-only: no broadcast, no key, safe to point at anything. Run it after a deploy, and run
///      it again whenever the tree has moved, because a deployment does not fail loudly when it goes
///      stale -- it just stops matching the code that is supposed to drive it. That is exactly what
///      happened here: a branch renamed a verb, added a `Status`, changed the shape of
///      `PackageId.arbitration` and widened three constructors, and nothing in the repo could tell
///      you that `deployments/sepolia*.json` no longer described anything runnable.
///
///      Three classes of check, and the second is the one that earns its keep:
///
///      * PRESENCE   -- every recorded address still has code.
///      * SHAPE      -- every getter the kernel calls answers. A module deployed before a policy
///                      getter existed reverts here, which is the signature of a stale deployment.
///      * CONSISTENCY-- the ids and the peer bindings a deal depends on still recompute from the
///                      LIVE getters, exactly as `Packages.resolve` would at activation. A package
///                      whose stored `packageId` disagrees with its own policy can never be named
///                      by a signed deal.
///
///      Usage: `forge script script/Doctor.s.sol:Doctor --rpc-url $RPC`
contract Doctor is Script {
    using stdJson for string;

    uint256 internal constant ARBITRUM_SEPOLIA = 421614;

    uint256 internal checks;
    uint256 internal failures;

    function run() external {
        console.log("chainId", block.chainid);
        _poseidon();
        _core();
        _packages("-packages.json", "packages");
        _packages("-kleros-packages.json", "kleros packages");
        _poolFactory();
        _private();

        console.log("");
        console.log("checks", checks);
        console.log("failures", failures);
        require(failures == 0, "doctor: the deployment records no longer describe this chain");
    }

    // --- checks ------------------------------------------------------------------------------

    function _poseidon() internal {
        // The private layer cannot hash without these, and they are not ours to deploy twice.
        _ok("PoseidonT3 has code", Poseidon.T3.code.length > 0);
        if (Poseidon.T3.code.length == 0) return;
        (bool okT3, bytes memory ret) =
            Poseidon.T3.staticcall(abi.encodeWithSelector(bytes4(0x561558fe), uint256(1), uint256(2)));
        _ok(
            "PoseidonT3 is circomlib",
            okT3 && ret.length == 32
                && abi.decode(ret, (uint256))
                    == 7853200120776062878684798364095072458815029376092732009249414926327459813530
        );
        // T2 is not on Arbitrum yet and `script/Poseidon.s.sol` puts it there. Its absence is only a
        // failure once a private layer has actually been deployed against it.
        if (Poseidon.T2.code.length == 0) {
            console.log("  --    PoseidonT2 absent (script/Poseidon.s.sol deploys it)");
        } else {
            _ok("PoseidonT2 has code", true);
        }
    }

    function _core() internal {
        string memory f = _file("");
        if (bytes(f).length == 0) return;
        address escrow = f.readAddress(".escrow");
        _ok("escrow has code", escrow.code.length > 0);
        if (escrow.code.length == 0) return;
        // A domain separator that does not bind THIS address is a record pointing at another deploy.
        (bool ok, bytes memory ret) = escrow.staticcall(abi.encodeWithSignature("domainSeparator()"));
        _ok("escrow answers domainSeparator", ok && ret.length == 32);
        _ok("escrow token has code", f.readAddress(".testToken").code.length > 0);
        // The verb this branch renamed: a record from before it points at an escrow without it.
        _ok("escrow has forceDisputeTimeout", _hasSelector(escrow, "forceDisputeTimeout(bytes32)"));
        _ok("escrow has retryPostTerminal", _hasSelector(escrow, "retryPostTerminal(bytes32)"));
    }

    function _packages(string memory suffix, string memory label) internal {
        string memory f = _file(suffix);
        if (bytes(f).length == 0) return;
        console.log("");
        console.log(label);
        address escrow = f.readAddress(".escrow");
        address passport = f.readAddress(".passport");
        address reputation = f.readAddress(".reputation");
        address vault = f.readAddress(".bondVault");
        address court = _tryAddress(f, ".arbitration");
        if (court == address(0)) court = _tryAddress(f, ".court");

        _ok("escrow has code", escrow.code.length > 0);
        _ok("passport has code", passport.code.length > 0);
        _ok("reputation has code", reputation.code.length > 0);
        _ok("bond vault has code", vault.code.length > 0);

        // PASSPORT: the id is just the address, so the only failure mode is a wrong record.
        _idMatches("passport id", passport, PackageId.passport(passport));

        // REPUTATION: every getter that enters the id must answer, and the stored id must agree.
        (bool shaped, uint256 act, uint256 comp, uint256 bps, uint256 floor_, address recipient) =
            _reputationPolicy(reputation);
        _ok("reputation policy getters answer", shaped);
        if (shaped) {
            _idMatches("reputation id", reputation, PackageId.reputation(reputation, recipient, act, comp, bps, floor_));
            _ok("reputation.operator == escrow", _addressOf(reputation, "operator()") == escrow);
            _ok("reputation.passport == passport", _addressOf(reputation, "passport()") == passport);
        }

        // BONDS: peer binding is what a counterparty relies on when they sign a BONDS deal.
        address sink = _addressOf(vault, "sink()");
        _idMatches("bonds id", vault, PackageId.bonds(vault, sink));
        _ok("vault.operator == escrow", _addressOf(vault, "operator()") == escrow);
        _ok("vault.passport == passport", _addressOf(vault, "passport()") == passport);

        // ARBITRATION: the contest policy is new. A court deployed before it reverts here, which is
        // precisely the stale-deployment signal this script exists to produce.
        if (court != address(0) && court.code.length > 0) {
            bool hasFee = _answers(court, "contestFee()");
            bool hasRecipient = _answers(court, "feeRecipient()");
            _ok("court declares contestFee (post-2026-09-22 shape)", hasFee);
            _ok("court declares feeRecipient", hasRecipient);
            if (hasFee && hasRecipient) {
                (bool okB, bytes memory b) = court.staticcall(abi.encodeWithSignature("packageBinding()"));
                if (okB && b.length == 64) {
                    (address partner, uint256 key) = abi.decode(b, (address, uint256));
                    uint256 fee = _uintOf(court, "contestFee()");
                    address to = _addressOf(court, "feeRecipient()");
                    _idMatches("arbitration id", court, PackageId.arbitration(court, partner, key, fee, to));
                    // The guard added on 2026-09-23: a priced contest with no recipient bricks
                    // `openDisputed`, a Core verb.
                    _ok("court: priced contest names a recipient", fee == 0 || to != address(0));
                } else {
                    _ok("court answers packageBinding", false);
                }
            }
        }
    }

    function _poolFactory() internal {
        string memory f = _file("-pool-factory.json");
        if (bytes(f).length == 0) return;
        console.log("");
        console.log("pool factory");
        address factory = f.readAddress(".factory");
        address impl = f.readAddress(".implementation");
        _ok("factory has code", factory.code.length > 0);
        _ok("implementation has code", impl.code.length > 0);
        // `officialCodehash` is the hash of the EIP-1167 CLONE the factory stamps out, not of the
        // implementation itself. A stale record here silently un-officialises every pool, so check it
        // against the factory's own answer AND against the clone the recorded implementation implies.
        bytes32 recorded = f.readBytes32(".officialCodehash");
        (bool ok, bytes memory ret) = factory.staticcall(abi.encodeWithSignature("officialCodehash()"));
        _ok("factory answers officialCodehash", ok && ret.length == 32);
        if (ok && ret.length == 32) _ok("recorded codehash == factory's", recorded == abi.decode(ret, (bytes32)));
        _ok(
            "codehash is the clone of the recorded implementation",
            recorded
                == keccak256(
                    abi.encodePacked(hex"363d3d373d3d3d363d73", bytes20(impl), hex"5af43d82803e903d91602b57fd5bf3")
                )
        );
    }

    function _private() internal {
        string memory f = _file("-private.json");
        if (bytes(f).length == 0) return;
        console.log("");
        console.log("private layer");
        address escrow = f.readAddress(".escrow");
        address passport = f.readAddress(".privatePassport");
        address reputation = f.readAddress(".privateReputation");
        address vault = f.readAddress(".privateBondVault");
        address tree = f.readAddress(".accountTree");
        address registry = f.readAddress(".humanityRegistry");

        _ok("private passport has code", passport.code.length > 0);
        _ok("private reputation has code", reputation.code.length > 0);
        _ok("private vault has code", vault.code.length > 0);
        _ok("accounts tree has code", tree.code.length > 0);
        _ok("humanity registry has code", registry.code.length > 0);

        // The wiring circle. An off-by-one in the deploy prediction produces a stack that deployed
        // cleanly and is wired to the wrong addresses forever.
        _ok("accounts tree owner == reputation", _addressOf(tree, "owner()") == reputation);
        _ok("reputation.bondsVault == vault", _addressOf(reputation, "bondsVault()") == vault);
        _ok("vault.reputation == reputation", _addressOf(vault, "reputation()") == reputation);
        _ok("reputation.accountTree == tree", _addressOf(reputation, "accountTree()") == tree);
        _ok("passport.accountTree == tree", _addressOf(passport, "accountTree()") == tree);
        _ok("reputation.operator == escrow", _addressOf(reputation, "operator()") == escrow);
        _ok("vault.operator == escrow", _addressOf(vault, "operator()") == escrow);
        // The window this branch widened: a tree still on the old ring is a liveness trap.
        _ok("accounts tree window >= 1024", _uintOf(tree, "rootHistory()") >= 1024);
    }

    // --- plumbing ----------------------------------------------------------------------------

    function _ok(string memory what, bool pass) internal {
        checks++;
        if (!pass) failures++;
        console.log(pass ? "  ok   " : "  FAIL ", what);
    }

    function _idMatches(string memory what, address module, bytes32 derived) internal {
        (bool ok, bytes memory ret) = module.staticcall(abi.encodeWithSignature("packageId()"));
        _ok(what, ok && ret.length == 32 && abi.decode(ret, (bytes32)) == derived);
    }

    /// @dev Presence of a getter, by calling it. Only valid for `view` functions with no arguments.
    function _answers(address target, string memory sig) internal view returns (bool) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        return ok && ret.length > 0;
    }

    /// @dev Presence of ANY function, including state-changing ones, which cannot be probed by
    ///      calling: a `staticcall` into a mutating function fails whether or not it exists. Scan the
    ///      deployed dispatcher for the selector instead. solc emits it as a literal, so a hit means
    ///      the ABI has it; a miss means the deployment predates it.
    function _hasSelector(address target, string memory sig) internal view returns (bool) {
        bytes4 sel = bytes4(keccak256(bytes(sig)));
        bytes memory code = target.code;
        if (code.length < 4) return false;
        for (uint256 i = 0; i + 4 <= code.length; i++) {
            if (code[i] == sel[0] && code[i + 1] == sel[1] && code[i + 2] == sel[2] && code[i + 3] == sel[3]) {
                return true;
            }
        }
        return false;
    }

    function _addressOf(address target, string memory sig) internal view returns (address) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        return ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
    }

    function _uintOf(address target, string memory sig) internal view returns (uint256) {
        (bool ok, bytes memory ret) = target.staticcall(abi.encodeWithSignature(sig));
        return ok && ret.length == 32 ? abi.decode(ret, (uint256)) : 0;
    }

    function _reputationPolicy(address rep)
        internal
        view
        returns (bool shaped, uint256 act, uint256 comp, uint256 bps, uint256 floor_, address recipient)
    {
        if (rep.code.length == 0) return (false, 0, 0, 0, 0, address(0));
        shaped = _answers(rep, "activationFee()") && _answers(rep, "completionFee()") && _answers(rep, "contestBps()")
            && _answers(rep, "contestFloor()") && _answers(rep, "feeRecipient()");
        if (!shaped) return (false, 0, 0, 0, 0, address(0));
        act = _uintOf(rep, "activationFee()");
        comp = _uintOf(rep, "completionFee()");
        bps = _uintOf(rep, "contestBps()");
        floor_ = _uintOf(rep, "contestFloor()");
        recipient = _addressOf(rep, "feeRecipient()");
    }

    function _tryAddress(string memory json, string memory key) internal view returns (address) {
        if (!vm.keyExistsJson(json, key)) return address(0);
        return json.readAddress(key);
    }

    /// @dev The record for this chain, or "" when there is none to check.
    function _file(string memory suffix) internal view returns (string memory) {
        string memory base = block.chainid == ARBITRUM_SEPOLIA ? "sepolia" : vm.toString(block.chainid);
        string memory path = string.concat("deployments/", base, suffix);
        if (bytes(suffix).length == 0) path = string.concat(path, ".json");
        if (!vm.exists(path)) {
            console.log("  --   no record:", path);
            return "";
        }
        return vm.readFile(path);
    }
}
