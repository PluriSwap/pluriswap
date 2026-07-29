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
