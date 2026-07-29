// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {ExactTransferFailed} from "./CoreErrors.sol";

library ExactERC20 {
    function pullExact(IERC20 token, address from, uint256 amount) internal {
        uint256 beforeBal = token.balanceOf(address(this));
        bool ok = token.transferFrom(from, address(this), amount);
        if (!ok) revert ExactTransferFailed();
        uint256 afterBal = token.balanceOf(address(this));
        if (afterBal - beforeBal != amount) revert ExactTransferFailed();
    }

    function pushExact(IERC20 token, address to, uint256 amount) internal {
        uint256 beforeBal = token.balanceOf(address(this));
        bool ok = token.transfer(to, amount);
        if (!ok) revert ExactTransferFailed();
        uint256 afterBal = token.balanceOf(address(this));
        if (beforeBal - afterBal != amount) revert ExactTransferFailed();
    }
}
