// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script, console} from "forge-std/Script.sol";
import {Lending} from "../src/Lending.sol";

contract DeployLending is Script {
    function run() external {
        address liskIdrx = 0x18Bc5bcC660cf2B9cE3cd51a404aFe1a0cBD3C22;
        address mockPriceFeed = 0x18Bc5bcC660cf2B9cE3cd51a404aFe1a0cBD3C22; // not deployed yet

        vm.startBroadcast();

        Lending lending = new Lending(msg.sender, liskIdrx, mockPriceFeed);
        console.log("Lending contract deployed at:", address(lending));

        vm.stopBroadcast();
    }
}
