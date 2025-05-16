// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

contract DeployMockERC20 is Script {
    function run() external {
        vm.startBroadcast();

        // Token parameters
        string memory name = "IDRX Mock";
        string memory symbol = "IDRX";
        uint256 initialSupply = 1_000_000_000_000 * 1e2; // 1 trilion tokens (2 decimals)
        uint8 decimals = 2;

        // Deploy MockERC20 contract
        MockERC20 mockToken = new MockERC20(name, symbol, initialSupply, decimals);
        console.log("MockERC20 deployed to:", address(mockToken));

        vm.stopBroadcast();
    }
}
