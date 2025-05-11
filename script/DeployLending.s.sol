// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {Lending} from "../src/Lending.sol";

contract DeployLending is Script {
    function run() external {
        address liskIdrx = 0xD63029C1a3dA68b51c67c6D1DeC3DEe50D681661;
        address mockPriceFeed = 0x14Fa23DEf3832dD489F08D7ad618928b3B237Cb8;
        address uniswapRouterV2 = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;

        vm.startBroadcast();

        Lending lending = new Lending(msg.sender, liskIdrx, mockPriceFeed, uniswapRouterV2);
        console.log("Owner:", lending.owner());
        console.log("Lending contract deployed at:", address(lending));

        vm.stopBroadcast();
    }
}
