// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {Lending} from "../src/Lending.sol";

contract DeployLending is Script {
    function run() external {
        address liskIdrx = 0xfD498EF2a4A07189c715f43BA1Af8429C3af9B4d;
        address mockPriceFeed = 0x14Fa23DEf3832dD489F08D7ad618928b3B237Cb8;
        address uniswapRouterV2 = 0xa9eE1fAe42E9fe76Ada5E593D8b9C115c6f3d01E;

        vm.startBroadcast();

        Lending lending = new Lending(msg.sender, liskIdrx, mockPriceFeed, uniswapRouterV2);
        console.log("Lending contract deployed at:", address(lending));

        vm.stopBroadcast();
    }
}
