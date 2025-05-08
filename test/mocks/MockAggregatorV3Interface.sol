// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockAggregatorV3Interface is MockV3Aggregator, Ownable {
    int256 private price;
    uint8 private decimalPlaces;

    event PriceUpdated(int256 newPrice);

    constructor(address _initialOwner, int256 _initialPrice, uint8 _decimals)
        MockV3Aggregator(_decimals, _initialPrice)
        Ownable(_initialOwner)
    {
        price = _initialPrice;
        decimalPlaces = _decimals;
    }

    // Set a new price to simulate updates (restricted to the owner)
    function setPrice(int256 _newPrice) external onlyOwner {
        price = _newPrice;
        emit PriceUpdated(_newPrice);
    }
}
