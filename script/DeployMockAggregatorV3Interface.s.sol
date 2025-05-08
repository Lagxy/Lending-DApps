// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {MockAggregatorV3Interface} from "../test/mocks/MockAggregatorV3Interface.sol";

contract DeployMock is Script {
    int256 public initialPrice = 605000000000; // 0.0000605 with 8 decimals
    uint8 public decimals = 8;

    function run() external {
        vm.startBroadcast();
        MockAggregatorV3Interface mock = new MockAggregatorV3Interface(msg.sender, initialPrice, decimals);

        console.log("MockAggregatorV3Interface deployed at:", address(mock));
        vm.stopBroadcast();
    }
}
