// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Transfers 1% less than requested (fee-on-transfer).
contract FeeOnTransferToken {
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
        uint256 fee = amount / 100;
        uint256 send = amount - fee;
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += send;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        uint256 fee = amount / 100;
        uint256 send = amount - fee;
        balanceOf[from] -= amount;
        balanceOf[to] += send;
        return true;
    }
}
