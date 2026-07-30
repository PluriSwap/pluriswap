# SUPERSEDED — Mandatory Core (Foundry) Implementation Plan

**Status:** Superseded on 2026-07-29 by the production-remediation specification sequence.
**Do not execute this plan.** Its numbered tasks, milestone rules, interface shapes, deficit model, deployment steps, and commit instructions are historical and no longer authorized.

**Current authorities:**

- `PROTOCOL.md`
- `docs/superpowers/specs/2026-07-29-core-architecture-immutability-design.md` revision 0.3.0-rc1
- `docs/v2/technical/MANDATORY_CORE.md` 0.3.0-rc1

The replacement work first proves the independent funded/gap recovery reference model, then freezes interfaces and rewrites the sole-vault Core. In particular, CreditLedger—not Escrow—is the physical vault, generic package surfaces must be functional rather than permanent stubs, and the 0.2.x cumulative-scalar deficit design is withdrawn.

The body below is retained only as non-normative history explaining the discarded prototype sequence.

---

## File structure

```text
foundry.toml
remappings.txt
.gitignore
README.md
src/
  interfaces/
    ICoordinator.sol
    ICreditLedger.sol
    ICoreEscrow.sol
    IERC20.sol
    IERC1271.sol
  libraries/
    DealTypes.sol          # enums, structs, ProfileFlags
    CoreErrors.sol         # custom errors
    SettlementMath.sol     # floor bps + fee
    ExactERC20.sol         # balance-delta pull/push
    DealHashing.sol        # EIP-712 DealTerms / ResolutionAuth
  Coordinator.sol
  CreditLedger.sol
  CoreEscrow.sol
script/
  DeployCore.s.sol         # CREATE2 triad deploy
test/
  helpers/
    DealSigUtils.sol       # EIP-712 signing helpers for tests
    MockERC20.sol
    RevertingReceiver.sol
    FeeOnTransferToken.sol
  Coordinator.t.sol
  CreditLedger.t.sol
  CoreEscrow.t.sol
  Conformance.t.sol        # §17 normative paths
```

---

### Task 1: Foundry project skeleton

**Files:**
- Create: `foundry.toml`
- Create: `remappings.txt`
- Create: `.gitignore`
- Create: `README.md`
- Create: `src/.gitkeep` (removed once contracts land)

- [ ] **Step 1: Initialize Foundry**

```bash
cd /Users/econti/Documents/emi/pluriswap
forge init --no-commit --force .
```

If `forge init` conflicts with existing `PROTOCOL.md`/`docs/`, do not overwrite them. Prefer manual skeleton:

```bash
forge --version
mkdir -p src interfaces libraries script test/helpers
```

- [ ] **Step 2: Write `foundry.toml`**

```toml
[profile.default]
src = "src"
out = "out"
libs = ["lib"]
solc_version = "0.8.24"
optimizer = true
optimizer_runs = 200
via_ir = false
evm_version = "paris"
fs_permissions = [{ access = "read", path = "./" }]

[fmt]
line_length = 100
tab_width = 4
bracket_spacing = false
```

- [ ] **Step 3: Write `remappings.txt`**

```text
forge-std/=lib/forge-std/src/
```

- [ ] **Step 4: Install forge-std**

```bash
forge install foundry-rs/forge-std --no-commit
```

- [ ] **Step 5: Write `.gitignore`**

```gitignore
cache/
out/
broadcast/
lib/
.env
.DS_Store
```

Note: if the team prefers committing `lib/forge-std`, remove `lib/` from gitignore and use `forge install` with commit. Default here: gitignore libs and document install in README.

- [ ] **Step 6: Write minimal `README.md`**

```markdown
# PluriSwap

Business source of truth: `PROTOCOL.md`  
Core tech spec: `docs/v2/technical/MANDATORY_CORE.md`

## Contracts (Foundry)

```bash
forge install
forge test
```
```

- [ ] **Step 7: Verify forge works**

```bash
forge build
```

Expected: success (empty or placeholder src).

- [ ] **Step 8: Commit**

```bash
git add foundry.toml remappings.txt .gitignore README.md lib/forge-std 2>/dev/null || true
git add foundry.toml remappings.txt .gitignore README.md
git commit -m "$(cat <<'EOF'
chore: initialize Foundry workspace for Mandatory Core

EOF
)"
```

---

### Task 2: Types, errors, and interfaces

**Files:**
- Create: `src/libraries/DealTypes.sol`
- Create: `src/libraries/CoreErrors.sol`
- Create: `src/interfaces/IERC20.sol`
- Create: `src/interfaces/IERC1271.sol`
- Create: `src/interfaces/ICoordinator.sol`
- Create: `src/interfaces/ICreditLedger.sol`
- Create: `src/interfaces/ICoreEscrow.sol`
- Test: `test/DealTypes.t.sol`

- [ ] **Step 1: Write failing smoke test for enum values**

Create `test/DealTypes.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DealState, Outcome, ProfileFlags} from "../src/libraries/DealTypes.sol";

contract DealTypesTest is Test {
    function test_DealState_ReleasedIsTerminalThreshold() public pure {
        assertEq(uint8(DealState.Released), 4);
        assertEq(uint8(DealState.Funded), 1);
    }

    function test_ProfileFlags_PaymentProofBit() public pure {
        assertEq(ProfileFlags.PAYMENT_PROOF, 1);
    }
}
```

- [ ] **Step 2: Run test — expect fail (file missing)**

```bash
forge test --match-contract DealTypesTest -vv
```

Expected: compilation error (DealTypes not found).

- [ ] **Step 3: Implement `DealTypes.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

enum DealState {
    None,
    Funded,
    FiatSent,
    Disputed,
    Released,
    ResolvedSplit,
    ResolvedByDisputeTimeout,
    Cancelled,
    ArbitrationActive,
    ResolvedByArbitration,
    Stalemate
}

enum Outcome {
    None,
    VoluntaryRelease,
    CosignedRelease,
    PaymentProofRelease,
    TimeoutClaim,
    ProviderCancel,
    FiatTimeoutCancel,
    MutualCancel,
    MutualSplit,
    ArbitrationHolderWin,
    ArbitrationProviderWin,
    ArbitrationRefused,
    ArbitrationTimeout,
    DisputeTimeout
}

enum ModuleRole {
    PaymentProofVerifier,
    ArbitrationAdapter,
    BondVault,
    Pool,
    HumanityVerifier,
    ReputationPolicy,
    RatePolicy,
    PackagePolicy
}

enum ResolutionAction {
    MutualCancel,
    CosignedRelease,
    Split
}

library ProfileFlags {
    uint32 internal constant PAYMENT_PROOF = 1 << 0;
    uint32 internal constant ARBITRATION = 1 << 1;
    uint32 internal constant BONDS = 1 << 2;
    uint32 internal constant POOL = 1 << 3;
    uint32 internal constant REPUTATION = 1 << 4;
    uint32 internal constant HUMANITY = 1 << 5;
    uint32 internal constant RATE_POLICY = 1 << 6;
    uint32 internal constant CROWDFUNDED_POOL = 1 << 7;
}

struct ModuleIdentity {
    ModuleRole role;
    address module;
    bytes32 codehash;
    bytes32 policyHash;
}

struct DealTerms {
    address holder;
    address provider;
    address holderReceiver;
    address providerReceiver;
    address token;
    bytes32 tokenRiskHash;
    bytes32 custodyBoundaryId;
    uint256 principal;
    uint256 activationFee;
    address activationFeeRecipient;
    uint256 completionFee;
    address completionFeeRecipient;
    uint256 nonce;
    uint64 createExpiry;
    uint64 fiatDuration;
    uint64 releaseDuration;
    uint64 disputeDuration;
    uint16 disputeTimeoutProviderBps;
    bytes32 fiatCurrency;
    uint256 fiatAmount;
    bytes32 paymentMethod;
    bytes32 payeeCommitment;
    bytes32 paymentReferenceCommitment;
    uint32 profileFlags;
    bytes32 packageId;
    bytes32 packageHash;
    ModuleIdentity[] modules;
    bytes extensions;
}

struct Deal {
    DealState state;
    Outcome outcome;
    address holder;
    address provider;
    address holderReceiver;
    address providerReceiver;
    address token;
    uint256 principal;
    uint256 activationFee;
    address activationFeeRecipient;
    uint256 completionFee;
    address completionFeeRecipient;
    uint16 disputeTimeoutProviderBps;
    uint64 activatedAt;
    uint64 fiatDeadline;
    uint64 releaseDuration;
    uint64 releaseDeadline;
    uint64 disputeDuration;
    uint64 disputeDeadline;
    uint32 profileFlags;
    bytes32 packageId;
    bytes32 packageHash;
    bytes32 termsHash;
    bytes32 custodyBoundaryId;
    bytes32 tokenRiskHash;
    bytes32 extensionsHash;
    ModuleIdentity[8] modules;
}

struct ResolutionAuth {
    bytes32 dealId;
    ResolutionAction action;
    uint256 resolutionNonce;
    uint64 expiry;
    uint16 providerShareBps;
    bytes extensions;
}

function isTerminal(DealState s) pure returns (bool) {
    return uint8(s) >= uint8(DealState.Released);
}
```

- [ ] **Step 4: Implement `CoreErrors.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library CoreErrors {
    error InvalidSignature();
    error Expired();
    error NonceUsed();
    error InvalidState();
    error InvalidTiming();
    error Unauthorized();
    error InvalidTerms();
    error ExactTransferFailed();
    error ModuleNotAllowed();
    error ModuleCodehashMismatch();
    error ProfileDisabled();
    error TerminalDeal();
    error ZeroAddress();
    error InvalidBps();
    error SelfReceiver();
    error CrowdfundGated();
    error DealExists();
    error DeficitActive();
    error InsufficientCredit();
}
```

(Use `error` at file level if preferred — either style is fine; keep names identical to the tech spec.)

Prefer file-level errors for gas-efficient reverts:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

error InvalidSignature();
error Expired();
error NonceUsed();
error InvalidState();
error InvalidTiming();
error Unauthorized();
error InvalidTerms();
error ExactTransferFailed();
error ModuleNotAllowed();
error ModuleCodehashMismatch();
error ProfileDisabled();
error TerminalDeal();
error ZeroAddress();
error InvalidBps();
error SelfReceiver();
error CrowdfundGated();
error DealExists();
error DeficitActive();
error InsufficientCredit();
```

- [ ] **Step 5: Implement minimal ERC20 / ERC1271 / triad interfaces**

Copy interface shapes exactly from `MANDATORY_CORE.md` §§4.1–4.3 into:

- `src/interfaces/ICoordinator.sol`
- `src/interfaces/ICreditLedger.sol`
- `src/interfaces/ICoreEscrow.sol`
- `src/interfaces/IERC20.sol` (`balanceOf`, `transfer`, `transferFrom`, `approve`, `allowance`)
- `src/interfaces/IERC1271.sol` (`isValidSignature` → `bytes4`)

Import `DealTypes` structs in the Core interfaces.

- [ ] **Step 6: Run types test**

```bash
forge test --match-contract DealTypesTest -vv
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/libraries src/interfaces test/DealTypes.t.sol
git commit -m "$(cat <<'EOF'
feat(core): add DealTypes, errors, and Core interfaces

EOF
)"
```

---

### Task 3: ExactERC20 + SettlementMath libraries

**Files:**
- Create: `src/libraries/ExactERC20.sol`
- Create: `src/libraries/SettlementMath.sol`
- Create: `test/helpers/MockERC20.sol`
- Create: `test/helpers/FeeOnTransferToken.sol`
- Test: `test/ExactERC20.t.sol`
- Test: `test/SettlementMath.t.sol`

- [ ] **Step 1: Write `MockERC20.sol` and failing ExactERC20 tests**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
```

Create `test/helpers/FeeOnTransferToken.sol` (transfers 1% less than requested) and `test/ExactERC20.t.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {FeeOnTransferToken} from "./helpers/FeeOnTransferToken.sol";
import {ExactERC20} from "../src/libraries/ExactERC20.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ExactTransferFailed} from "../src/libraries/CoreErrors.sol";

contract ExactPuller {
    using ExactERC20 for IERC20;
    function pull(IERC20 token, address from, uint256 amount) external {
        token.pullExact(from, amount);
    }
}

contract ExactERC20Test is Test {
    MockERC20 mock;
    FeeOnTransferToken feeTok;
    ExactPuller puller;
    address alice = address(0xA11CE);

    function setUp() public {
        mock = new MockERC20();
        feeTok = new FeeOnTransferToken();
        puller = new ExactPuller();
        mock.mint(alice, 1000e18);
        feeTok.mint(alice, 1000e18);
        vm.prank(alice);
        mock.approve(address(puller), type(uint256).max);
        vm.prank(alice);
        feeTok.approve(address(puller), type(uint256).max);
    }

    function test_pullExact_success() public {
        puller.pull(IERC20(address(mock)), alice, 100e18);
        assertEq(mock.balanceOf(address(puller)), 100e18);
    }

    function test_pullExact_feeOnTransfer_reverts() public {
        vm.expectRevert(ExactTransferFailed.selector);
        puller.pull(IERC20(address(feeTok)), alice, 100e18);
    }
}
```

- [ ] **Step 2: Implement `ExactERC20.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {ExactTransferFailed} from "./CoreErrors.sol";

library ExactERC20 {
    function pullExact(IERC20 token, address from, uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        bool ok = token.transferFrom(from, address(this), amount);
        if (!ok) revert ExactTransferFailed();
        uint256 after_ = token.balanceOf(address(this));
        if (after_ - before != amount) revert ExactTransferFailed();
    }

    function pushExact(IERC20 token, address to, uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        bool ok = token.transfer(to, amount);
        if (!ok) revert ExactTransferFailed();
        uint256 after_ = token.balanceOf(address(this));
        if (before - after_ != amount) revert ExactTransferFailed();
    }
}
```

- [ ] **Step 3: Implement `SettlementMath.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library SettlementMath {
    uint16 internal constant BPS_DENOM = 10_000;

    function providerGross(uint256 principal, uint16 bps) internal pure returns (uint256) {
        return (principal * uint256(bps)) / uint256(BPS_DENOM);
    }

    function split(uint256 principal, uint16 providerBps)
        internal
        pure
        returns (uint256 holderGross, uint256 provGross)
    {
        provGross = providerGross(principal, providerBps);
        holderGross = principal - provGross;
    }

    function completionCollected(uint256 completionFee, uint256 provGross)
        internal
        pure
        returns (uint256)
    {
        if (provGross == 0) return 0;
        return completionFee < provGross ? completionFee : provGross;
    }
}
```

- [ ] **Step 4: Tests for math edge cases**

Cover: `bps=0`, `bps=10000`, `bps=5000` odd principal dust to holder, `completionFee > providerGross`.

```bash
forge test --match-contract SettlementMathTest -vv
forge test --match-contract ExactERC20Test -vv
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/libraries/ExactERC20.sol src/libraries/SettlementMath.sol test/
git commit -m "$(cat <<'EOF'
feat(core): add ExactERC20 and SettlementMath libraries

EOF
)"
```

---

### Task 4: Coordinator

**Files:**
- Create: `src/Coordinator.sol`
- Test: `test/Coordinator.t.sol`

- [ ] **Step 1: Write failing tests**

Tests:
1. `isAllowed` false by default  
2. owner `allow` → true  
3. `disallow` → false  
4. non-owner allow reverts  
5. constructor zeroes reject

- [ ] **Step 2: Implement `Coordinator.sol`**

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICoordinator} from "./interfaces/ICoordinator.sol";
import {ModuleRole} from "./libraries/DealTypes.sol";
import {ZeroAddress, Unauthorized} from "./libraries/CoreErrors.sol";

contract Coordinator is ICoordinator {
    uint64 public immutable chainId;
    address public immutable escrow;
    address public owner;

    mapping(bytes32 => bool) internal _allowed;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(uint64 chainId_, address escrow_, address owner_) {
        if (escrow_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        chainId = chainId_;
        escrow = escrow_;
        owner = owner_;
    }

    function _key(ModuleRole role, address module, bytes32 codehash, bytes32 policyHash)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(role, module, codehash, policyHash));
    }

    function isAllowed(ModuleRole role, address module, bytes32 codehash, bytes32 policyHash)
        external
        view
        returns (bool)
    {
        return _allowed[_key(role, module, codehash, policyHash)];
    }

    function allow(ModuleRole role, address module, bytes32 codehash, bytes32 policyHash)
        external
        onlyOwner
    {
        if (module == address(0)) revert ZeroAddress();
        _allowed[_key(role, module, codehash, policyHash)] = true;
        emit ModuleAllowed(role, module, codehash, policyHash);
    }

    function disallow(ModuleRole role, address module, bytes32 codehash, bytes32 policyHash)
        external
        onlyOwner
    {
        _allowed[_key(role, module, codehash, policyHash)] = false;
        emit ModuleDisallowed(role, module, codehash, policyHash);
    }
}
```

- [ ] **Step 3: Run tests**

```bash
forge test --match-contract CoordinatorTest -vv
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/Coordinator.sol test/Coordinator.t.sol
git commit -m "$(cat <<'EOF'
feat(core): implement Coordinator module allowlist

EOF
)"
```

---

### Task 5: CreditLedger (ordinary credits + withdraw)

**Files:**
- Create: `src/CreditLedger.sol`
- Create: `test/helpers/RevertingReceiver.sol`
- Test: `test/CreditLedger.t.sol`

**Scope this task:** ordinary mode only (credit, withdraw, withdrawTo). Deficit mode is Task 11.

- [ ] **Step 1: Write failing tests**

1. Only escrow can `credit`  
2. `credit` then `withdraw` by third party pays beneficiary  
3. double withdraw reverts `InsufficientCredit`  
4. ETH send to ledger reverts  
5. `withdrawTo` with valid beneficiary EIP-712 works  
6. bad signature reverts  

- [ ] **Step 2: Implement `CreditLedger.sol` (ordinary path)**

Implement per `MANDATORY_CORE.md` §10.1–10.2 / §4.2:

- immutables: `escrow`, `chainId`
- `credit(dealId, token, beneficiary, amount)` escrow-only; reject zero beneficiary; reject beneficiary == ledger or escrow
- `withdraw(token, beneficiary)` any caller; `ExactERC20.pushExact`
- EIP-712 domain name `"PluriSwapCreditLedger"` version `"2"`
- `withdrawTo(...)` as specified
- `receive() external payable { revert(); }`
- `reallocateRecovery` stub: `revert DeficitActive()` until Task 11 (or empty revert `InvalidState`) — prefer implementing signature now and body in Task 11

Include `nonReentrant` via a minimal local guard:

```solidity
uint256 private locked = 1;
modifier nonReentrant() {
    require(locked == 1, "REENTRANCY");
    locked = 2;
    _;
    locked = 1;
}
```

- [ ] **Step 3: Run tests**

```bash
forge test --match-contract CreditLedgerTest -vv
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/CreditLedger.sol test/CreditLedger.t.sol test/helpers/RevertingReceiver.sol
git commit -m "$(cat <<'EOF'
feat(core): implement CreditLedger pull credits and withdraw

EOF
)"
```

---

### Task 6: DealHashing (EIP-712) + test sig utils

**Files:**
- Create: `src/libraries/DealHashing.sol`
- Create: `test/helpers/DealSigUtils.sol`
- Test: `test/DealHashing.t.sol`

- [ ] **Step 1: Implement typehashes and `hashDealTerms` / `hashResolution` in `DealHashing.sol`**

Follow `MANDATORY_CORE.md` §5 exactly:

- `DealTerms` type string with `modulesHash` + `extensionsHash`
- `modulesHash = keccak256(abi.encode(modules))`
- `extensionsHash = extensions.length == 0 ? bytes32(0) : keccak256(extensions)`
- `ResolutionAuth` type string

Also export `hashModuleIdentity` if needed for encode consistency.

- [ ] **Step 2: Implement `DealSigUtils.sol` for tests**

Helper that builds domain separator matching Escrow (`name=PluriSwap`, `version=2`, chainId, verifyingContract) and signs with `vm.sign`.

- [ ] **Step 3: Golden test**

Fixed inputs → assert exact `termsHash` bytes32 constant committed in the test (generate once with a small forge script or first run logs, then freeze).

- [ ] **Step 4: Commit**

```bash
git add src/libraries/DealHashing.sol test/helpers/DealSigUtils.sol test/DealHashing.t.sol
git commit -m "$(cat <<'EOF'
feat(core): add EIP-712 DealTerms and ResolutionAuth hashing

EOF
)"
```

---

### Task 7: CoreEscrow skeleton + CREATE2 deploy wiring

**Files:**
- Create: `src/CoreEscrow.sol` (constructor, views, ETH reject, stub entrypoints)
- Create: `script/DeployCore.s.sol`
- Test: `test/DeployCore.t.sol`

**Circular address problem:** Ledger and Coordinator need Escrow address; Escrow needs both. Use CREATE2 salts in deploy script/tests.

- [ ] **Step 1: Write deploy test that predicts addresses**

```solidity
// Pseudo-flow in test:
address deployer = address(this);
bytes32 saltLedger = keccak256("ledger");
bytes32 saltCoord = keccak256("coord");
bytes32 saltEscrow = keccak256("escrow");
// computeCreate2Address for each with initcode hashes
// deploy Ledger(escrowPredicted, chainId)
// deploy Coordinator(chainId, escrowPredicted, owner)
// deploy Escrow{salt}(…)
assertEq(address(escrow), escrowPredicted);
assertEq(address(ledger.escrow()), address(escrow));
```

- [ ] **Step 2: Implement Escrow constructor + immutables + stubs**

Constructor args: `chainId, protocolVersion=2, charterHash, techSpecHash, ledger, coordinator`.

Stubs for all state-changing functions: `revert InvalidState()` except extension stubs `revert ProfileDisabled()`.

Views: `getDeal`, `dealState`, `DOMAIN_SEPARATOR`, hashes.

`receive() external payable { revert(); }`

- [ ] **Step 3: Implement `DeployCore.s.sol`**

Broadcastable script using same CREATE2 scheme; reads `charterHash`/`techSpecHash` from env or constants.

- [ ] **Step 4: Run deploy test**

```bash
forge test --match-contract DeployCoreTest -vv
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/CoreEscrow.sol script/DeployCore.s.sol test/DeployCore.t.sol
git commit -m "$(cat <<'EOF'
feat(core): add CoreEscrow skeleton and CREATE2 deploy script

EOF
)"
```

---

### Task 8: Activation (Core-only)

**Files:**
- Modify: `src/CoreEscrow.sol`
- Modify: `test/helpers/DealSigUtils.sol` (if needed)
- Test: `test/CoreEscrow.t.sol`

- [ ] **Step 1: Write failing activation tests**

1. Happy path: holder+provider sign zero-fee terms; holder approves; `activate` → `Funded`; principal on Escrow; nonce consumed  
2. Replay same nonce reverts `NonceUsed`  
3. Expired `createExpiry` reverts  
4. `holder == provider` reverts  
5. receiver == escrow reverts `SelfReceiver`  
6. fee-on-transfer token reverts `ExactTransferFailed`  
7. bad provider signature reverts  
8. `profileFlags` with module but empty allowlist reverts (even if we only test flags!=0 + module)  
9. `CROWDFUNDED_POOL` flag reverts `CrowdfundGated`  
10. nonzero activation fee credits recipient on Ledger  

- [ ] **Step 2: Implement `activate` per §6**

Order: checks → pull principal → activation fee credit via Ledger → store Deal → emit `DealActivated`.

Signature verify: ECDSA + EIP-1271 per §5.7.

`dealId = keccak256(abi.encode(address(this), termsHash, holder, provider, nonce))`.

For Core-only: require `modules.length == 0`, `extensions.length == 0`, `activationData.length == 0`, `profileFlags == 0`.

- [ ] **Step 3: Run tests**

```bash
forge test --match-contract CoreEscrowTest -vv
```

Expected: activation tests PASS (other stubs may still be uncovered).

- [ ] **Step 4: Commit**

```bash
git add src/CoreEscrow.sol test/CoreEscrow.t.sol
git commit -m "$(cat <<'EOF'
feat(core): implement Core-only deal activation

EOF
)"
```

---

### Task 9: Settlement engine + FUNDED exits

**Files:**
- Modify: `src/CoreEscrow.sol` (internal `_settle`, `markFiatSent`, `providerCancel`, `fiatTimeoutCancel`)
- Test: extend `test/CoreEscrow.t.sol`

- [ ] **Step 1: Failing tests**

1. `markFiatSent` by provider sets `releaseDeadline`  
2. non-provider mark reverts  
3. `providerCancel` → holder credit == principal; state Cancelled / ProviderCancel  
4. after `fiatDeadline`, third party `fiatTimeoutCancel` → same economics, outcome FiatTimeoutCancel  
5. before deadline, fiatTimeout reverts `InvalidTiming`  
6. activation fee not refunded on cancel  

- [ ] **Step 2: Implement `_settle` per §9.1**

CEI: update deal terminal fields → decrease active principal → `ledger.credit` holder/provider/fee → emit `DealTerminated`.

- [ ] **Step 3: Implement FUNDED transitions**

Wire `providerCancel` / `fiatTimeoutCancel` through `_settle` with bps 0.

- [ ] **Step 4: Run tests + commit**

```bash
forge test --match-path test/CoreEscrow.t.sol -vv
git add src/CoreEscrow.sol test/CoreEscrow.t.sol
git commit -m "$(cat <<'EOF'
feat(core): add settlement engine and FUNDED cancel paths

EOF
)"
```

---

### Task 10: FIAT_SENT paths (release, claim, openDispute)

**Files:**
- Modify: `src/CoreEscrow.sol`
- Test: extend `test/CoreEscrow.t.sol`

- [ ] **Step 1: Failing tests**

1. holder release → provider net = principal - completionFee; fee credited  
2. before release deadline, claim reverts  
3. after deadline, anyone claim → TimeoutClaim  
4. openDispute by holder before deadline → Disputed; sets disputeDeadline  
5. openDispute at/after release deadline reverts  
6. after dispute, claim and holderRelease revert  

- [ ] **Step 2: Implement `holderRelease`, `claim`, `openDispute`**

`openDispute`: Core-only requires `openData.length == 0`; no fee (DISPUTE-007).

- [ ] **Step 3: Run tests + commit**

```bash
forge test --match-path test/CoreEscrow.t.sol -vv
git add src/CoreEscrow.sol test/CoreEscrow.t.sol
git commit -m "$(cat <<'EOF'
feat(core): implement FIAT_SENT release, claim, and openDispute

EOF
)"
```

---

### Task 11: DISPUTED timeout + mutualResolve

**Files:**
- Modify: `src/CoreEscrow.sol`
- Test: extend `test/CoreEscrow.t.sol`

- [ ] **Step 1: Failing tests**

1. disputeTimeout before deadline reverts  
2. disputeTimeout at deadline with bps 5000 → 50/50 floor split + completion fee on provider gross  
3. bps 0 → all holder, no completion fee  
4. bps 10000 → all provider gross, fee capped  
5. mutual cancel from Funded / FiatSent / Disputed  
6. cosigned release from FiatSent and Disputed  
7. split 2500 bps dust to holder  
8. resolution nonce replay reverts  
9. expired resolution reverts  

- [ ] **Step 2: Implement `disputeTimeout` and `mutualResolve`**

Verify both signatures over `ResolutionAuth` digest; enforce action-specific bps rules from §7.8.

- [ ] **Step 3: Run tests + commit**

```bash
forge test --match-path test/CoreEscrow.t.sol -vv
git add src/CoreEscrow.sol test/CoreEscrow.t.sol
git commit -m "$(cat <<'EOF'
feat(core): implement dispute timeout and dual-signed mutualResolve

EOF
)"
```

---

### Task 12: Extension stubs + codehash guard hooks

**Files:**
- Modify: `src/CoreEscrow.sol`
- Test: `test/ExtensionStubs.t.sol`

- [ ] **Step 1: Tests**

For each of `submitPaymentProof`, `openArbitration`, `submitArbitrationRuling`, `arbitrationTimeout` on a Core-only deal → expect `ProfileDisabled`.

Also: activate with `PAYMENT_PROOF` flag + module not allowlisted → `ModuleNotAllowed` (proves §6.4 wiring even without implementing proof logic).

- [ ] **Step 2: Implement stub bodies + `_requireModule` helper**

```solidity
function submitPaymentProof(bytes32 dealId, bytes calldata) external nonReentrant {
    Deal storage d = deals[dealId];
    if (d.state == DealState.None) revert InvalidState();
    if (d.profileFlags & ProfileFlags.PAYMENT_PROOF == 0) revert ProfileDisabled();
    _requireLiveCodehash(d, ModuleRole.PaymentProofVerifier);
    revert ProfileDisabled(); // full proof engine OUT_OF_SCOPE — keep explicit until PAY tech spec
}
```

For this Core milestone, even when the flag is set, after allowlist/codehash checks it is acceptable to `revert ProfileDisabled()` or a dedicated `ProfileNotImplemented()` — **prefer adding `error ProfileNotImplemented()`** only if you introduce it in CoreErrors and the tech spec addendum; otherwise keep `ProfileDisabled` for flag-off and document flag-on-without-engine as out-of-scope rejection via `InvalidTerms` at activation (stricter YAGNI: **reject nonzero profileFlags at activation in Core v0.2 milestone**).

**Milestone rule (lock for this plan):** `activate` MUST revert `InvalidTerms` if `profileFlags != 0`. Extension functions still exist and revert `ProfileDisabled`. This delivers CORE-SURF-001 stubs + CORE-SURF-013 without pretending profiles work.

Update Task 8 if needed so activation rejects nonzero flags.

- [ ] **Step 3: Commit**

```bash
git add src/CoreEscrow.sol test/ExtensionStubs.t.sol
git commit -m "$(cat <<'EOF'
feat(core): add extension entrypoint stubs and reject profiles at activation

EOF
)"
```

---

### Task 13: CreditLedger deficit mode (minimal)

**Files:**
- Modify: `src/CreditLedger.sol`
- Test: `test/CreditLedgerDeficit.t.sol`

- [ ] **Step 1: Failing tests**

Use a `MockERC20` that can `burnFromLedger` / seize balances to simulate issuer loss:

1. After credits exist, burn ledger tokens below liabilities → next withdraw enters deficit path / `DeficitEntered`  
2. Ordinary withdraw blocked or pays pro-rata only via `claimRecovery`  
3. Implement `claimRecovery(token, beneficiary)` if not in interface — **add to `ICreditLedger`** as specified by TOKEN-017 claim flow  

If interface gap: extend `ICreditLedger` with:

```solidity
function claimRecovery(address token, address beneficiary) external;
```

Mirror tech spec TOKEN-017.

- [ ] **Step 2: Implement deficit enter + pro-rata claim**

Keep it minimal but correct: irreversible `inDeficit`, fixed units, floor payouts, no cross-token subsidy.

- [ ] **Step 3: Commit**

```bash
git add src/interfaces/ICreditLedger.sol src/CreditLedger.sol test/CreditLedgerDeficit.t.sol
git commit -m "$(cat <<'EOF'
feat(core): add CreditLedger deficit recovery ledger

EOF
)"
```

---

### Task 14: Conformance suite (§17)

**Files:**
- Create: `test/Conformance.t.sol`

- [ ] **Step 1: Encode each normative path as a named test**

Map 1:1 to `MANDATORY_CORE.md` §17 items 1–15 that apply to Core-only (skip profile-enabled items 8 module delist-after-activate can still be tested with allowlist + rejected flags, or simulate by unit-testing Coordinator delist independence via snapshot fields).

Minimum required green:

1. `test_Conformance_ZeroFeeReleaseWithdraw`  
2. `test_Conformance_ActivationFeeNotRefundedOnCancel`  
3. `test_Conformance_FiatTimeoutThirdParty`  
4. `test_Conformance_ClaimCollectsCompletionFee`  
5. `test_Conformance_DisputeTimeoutResidual`  
6. `test_Conformance_MutualCancelReleaseSplit`  
7. `test_Conformance_DisputedBlocksClaimAndRelease`  
8. `test_Conformance_ExtensionStubsRevert`  
9. `test_Conformance_FeeOnTransferReject`  
10. `test_Conformance_WithdrawRetryAfterReceiverRevert`  
11. `test_Conformance_ReplayAcrossDomainFails` (different verifyingContract domain)  
12. `test_Conformance_ResidualExtremes`  
13. `test_Conformance_SplitDustToHolder`  

- [ ] **Step 2: Run full suite**

```bash
forge test -vv
```

Expected: all PASS.

- [ ] **Step 3: Commit**

```bash
git add test/Conformance.t.sol
git commit -m "$(cat <<'EOF'
test(core): add Mandatory Core conformance suite

EOF
)"
```

---

### Task 15: Docs polish + size size check

**Files:**
- Modify: `README.md`
- Modify: `docs/v2/technical/MANDATORY_CORE.md` (document control only if interface gained `claimRecovery`)

- [ ] **Step 1: Bytecode size check**

```bash
forge build --sizes
```

Expected: `CoreEscrow` under 24576 bytes. If over, enable `via_ir = true` sparingly or split pure helpers further into libraries (already planned).

- [ ] **Step 2: README commands**

Document:

```bash
forge install
forge test
forge script script/DeployCore.s.sol --rpc-url $RPC --broadcast --verify
```

- [ ] **Step 3: Final commit**

```bash
git add README.md docs/v2/technical/MANDATORY_CORE.md
git commit -m "$(cat <<'EOF'
docs: document Foundry Core build, test, and size gate

EOF
)"
```

---

## Spec coverage checklist

| Spec area | Task |
| --- | --- |
| Topology / CREATE2 deploy | 7, 15 |
| Types / interfaces / errors | 2 |
| Exact ERC-20 + math | 3 |
| Coordinator allowlist | 4 |
| CreditLedger + withdraw + EIP-712 withdrawTo | 5 |
| Deal hashing | 6 |
| Activation Core-only | 8, 12 |
| Settlement + FUNDED exits | 9 |
| FIAT_SENT + dispute open | 10 |
| Dispute timeout + mutualResolve | 11 |
| Extension stubs / Appendix C readiness | 12 |
| Deficit recovery | 13 |
| Conformance §17 | 14 |
| Solidity size / Arbitrum-oriented config | 1, 15 |

**Explicitly deferred (separate plans):** PAYMENT_PROOF, ARBITRATION, BONDS, POOL, HUMANITY, REPUTATION, RATE_POLICY, reference SKUs, crowdfunding.

---

## Notes for implementers

1. **Profile flags:** this milestone rejects `profileFlags != 0` at activation. Stubs remain for ABI/Appendix C stability.  
2. **No proxies** on Escrow/Ledger.  
3. **TDD:** each task writes failing tests first.  
4. **Commits:** one logical commit per task as written.  
5. Prefer `paris` EVM in foundry.toml for broad Arbitrum compatibility; revisit if targeting newer Arb nitro opcodes.
)
