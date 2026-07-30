// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "../interfaces/IERC20.sol";
import {ExactTransferFailed} from "./CoreErrors.sol";

library ExactERC20 {
    function pullExact(IERC20 token, address from, uint256 amount) internal {
        exactTransferFrom(token, from, address(this), amount);
    }

    function pushExact(IERC20 token, address to, uint256 amount) internal {
        exactTransfer(token, to, amount);
    }

    /// @notice Executes an exact two-sided ERC-20 transferFrom.
    /// @dev Supports tokens with no return data, but rejects false, malformed,
    ///      fee-on-transfer, bonus-transfer, rebasing, and non-contract tokens.
    function exactTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        if (address(token).code.length == 0 || from == to) revert ExactTransferFailed();
        if (amount == 0) return;

        uint256 sourceBefore = _balanceOfExact(token, from);
        uint256 destinationBefore = _balanceOfExact(token, to);

        (bool ok, bytes memory returndata) = address(token)
            .call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount));
        if (!ok || !_optionalReturnTrue(returndata)) revert ExactTransferFailed();

        uint256 sourceAfter = _balanceOfExact(token, from);
        uint256 destinationAfter = _balanceOfExact(token, to);
        if (sourceAfter > sourceBefore || sourceBefore - sourceAfter != amount) {
            revert ExactTransferFailed();
        }
        if (destinationAfter < destinationBefore || destinationAfter - destinationBefore != amount)
        {
            revert ExactTransferFailed();
        }
    }

    function exactTransfer(IERC20 token, address to, uint256 amount) internal {
        if (address(token).code.length == 0 || address(this) == to) revert ExactTransferFailed();
        if (amount == 0) return;

        uint256 sourceBefore = _balanceOfExact(token, address(this));
        uint256 destinationBefore = _balanceOfExact(token, to);
        (bool ok, bytes memory returndata) =
            address(token).call(abi.encodeWithSelector(IERC20.transfer.selector, to, amount));
        if (!ok || !_optionalReturnTrue(returndata)) revert ExactTransferFailed();

        uint256 sourceAfter = _balanceOfExact(token, address(this));
        uint256 destinationAfter = _balanceOfExact(token, to);
        if (sourceAfter > sourceBefore || sourceBefore - sourceAfter != amount) {
            revert ExactTransferFailed();
        }
        if (destinationAfter < destinationBefore || destinationAfter - destinationBefore != amount)
        {
            revert ExactTransferFailed();
        }
    }

    function exactExternalFee(IERC20 token, address from, address to, uint256 amount) internal {
        exactTransferFrom(token, from, to, amount);
    }

    function _optionalReturnTrue(bytes memory returndata) private pure returns (bool) {
        if (returndata.length == 0) return true;
        if (returndata.length != 32) return false;
        uint256 value;
        assembly ("memory-safe") {
            value := mload(add(returndata, 32))
        }
        return value == 1;
    }

    function _balanceOfExact(IERC20 token, address account) private view returns (uint256 value) {
        (bool ok, bytes memory returndata) =
            address(token).staticcall(abi.encodeWithSelector(IERC20.balanceOf.selector, account));
        if (!ok || returndata.length != 32) revert ExactTransferFailed();
        assembly ("memory-safe") {
            value := mload(add(returndata, 32))
        }
    }
}
