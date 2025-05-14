// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IERC20WithDecimals {
    function decimals() external view returns (uint8);
}
