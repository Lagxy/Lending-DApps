// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {MockUniswapV2Router} from "../test/mocks/MockUniswapV2Router.onlyOwner.sol";

contract DeployMockUniswapV2Router is Script {
    function run() external {
        vm.startBroadcast();

        // Deploy MockUniswapV2Router contract
        MockUniswapV2Router mockRouter = new MockUniswapV2Router();
        console.log("MockUniswapV2Router deployed to:", address(mockRouter));

        vm.stopBroadcast();
    }
}
