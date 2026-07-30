// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {ExactERC20} from "../src/libraries/ExactERC20.sol";
import {ExactTransferFailed} from "../src/libraries/CoreErrors.sol";
import {MockERC20} from "./helpers/MockERC20.sol";
import {FeeOnTransferToken} from "./helpers/FeeOnTransferToken.sol";

contract ExactERC20Harness {
    using ExactERC20 for IERC20;

    function pull(address token, address from, uint256 amount) external {
        IERC20(token).pullExact(from, amount);
    }

    function push(address token, address to, uint256 amount) external {
        IERC20(token).pushExact(to, amount);
    }
}

contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external virtual {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

contract FalseReturnToken {
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
        return false;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return false;
    }
}

contract BonusTransferToken is NoReturnToken {
    function transfer(address to, uint256 amount) external override {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount + 1;
    }

    function transferFrom(address from, address to, uint256 amount) external override {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount + 1;
    }
}

contract MalformedReturnToken {
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
        assembly ("memory-safe") {
            mstore(0, 1)
            mstore(32, 2)
            return(0, 64)
        }
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        assembly ("memory-safe") {
            mstore(0, 1)
            mstore(32, 2)
            return(0, 64)
        }
    }
}

contract ExactERC20Test is Test {
    ExactERC20Harness harness;
    address user = address(0xA11CE);
    address receiver = address(0xB0B);

    function setUp() public {
        harness = new ExactERC20Harness();
    }

    function test_exactPullAndPush() public {
        MockERC20 token = new MockERC20();
        token.mint(user, 100);
        vm.prank(user);
        token.approve(address(harness), type(uint256).max);

        harness.pull(address(token), user, 40);
        assertEq(token.balanceOf(address(harness)), 40);
        harness.push(address(token), receiver, 40);
        assertEq(token.balanceOf(receiver), 40);
        assertEq(token.balanceOf(address(harness)), 0);
    }

    function test_noReturnTokenIsAccepted() public {
        NoReturnToken token = new NoReturnToken();
        token.mint(user, 100);
        vm.prank(user);
        token.approve(address(harness), type(uint256).max);
        harness.pull(address(token), user, 40);
        harness.push(address(token), receiver, 40);
        assertEq(token.balanceOf(receiver), 40);
    }

    function test_feeOnTransferPullRejects() public {
        FeeOnTransferToken token = new FeeOnTransferToken();
        token.mint(user, 100);
        vm.prank(user);
        token.approve(address(harness), type(uint256).max);
        vm.expectRevert(ExactTransferFailed.selector);
        harness.pull(address(token), user, 100);
    }

    function test_feeOnTransferPushRejects() public {
        FeeOnTransferToken token = new FeeOnTransferToken();
        token.mint(address(harness), 100);
        vm.expectRevert(ExactTransferFailed.selector);
        harness.push(address(token), receiver, 100);
    }

    function test_bonusTransferRejects() public {
        BonusTransferToken token = new BonusTransferToken();
        token.mint(user, 100);
        vm.prank(user);
        token.approve(address(harness), type(uint256).max);
        vm.expectRevert(ExactTransferFailed.selector);
        harness.pull(address(token), user, 40);
    }

    function test_falseReturnRejects() public {
        FalseReturnToken token = new FalseReturnToken();
        token.mint(user, 100);
        vm.prank(user);
        token.approve(address(harness), type(uint256).max);
        vm.expectRevert(ExactTransferFailed.selector);
        harness.pull(address(token), user, 40);
    }

    function test_malformedReturnRejects() public {
        MalformedReturnToken token = new MalformedReturnToken();
        token.mint(user, 100);
        vm.prank(user);
        token.approve(address(harness), type(uint256).max);
        vm.expectRevert(ExactTransferFailed.selector);
        harness.pull(address(token), user, 40);
    }
}
