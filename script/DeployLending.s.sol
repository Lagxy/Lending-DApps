// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {Lending} from "../src/Lending.sol";

contract DeployLending is Script {
    function run() external {
        address liskIdrx = 0x6cC49B2a44482486849DE370ae62Edfd794873B5;
        address mockPriceFeed = 0x14Fa23DEf3832dD489F08D7ad618928b3B237Cb8;
        address uniswapRouterV2 = 0x43f04D494c59E0014c7Ac9eA3308342A104b2508;

        vm.startBroadcast();

        Lending lending = new Lending(msg.sender, liskIdrx, mockPriceFeed, uniswapRouterV2);
        console.log("Owner:", lending.owner());
        console.log("Lending contract deployed at:", address(lending));

        vm.stopBroadcast();
    }
}
