// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Single-token custody. Only the immutable coordinator can release funds.
contract NDAICustody {
    using SafeERC20 for IERC20;

    IERC20 public immutable asset;
    address public immutable controller;

    error WrongChain();
    error OnlyController();

    constructor(IERC20 token) {
        if (block.chainid != 369) revert WrongChain();
        asset = token;
        controller = msg.sender;
    }

    function pay(address recipient, uint256 amount) external {
        if (msg.sender != controller) revert OnlyController();
        asset.safeTransfer(recipient, amount);
    }
}
