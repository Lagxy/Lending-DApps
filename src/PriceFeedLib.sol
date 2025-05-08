// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

library PriceFeedLib {
    struct PriceData {
        uint256 value;
        uint8 decimals;
        uint256 updatedAt;
    }

    function getNormalizedPrice(AggregatorV3Interface feed, uint256 staleTime)
        internal
        view
        returns (PriceData memory)
    {
        (, int256 price,, uint256 updatedAt,) = feed.latestRoundData();
        require(price > 0, "Invalid price");
        require(block.timestamp - updatedAt <= staleTime, "Stale price");

        return PriceData({value: uint256(price), decimals: feed.decimals(), updatedAt: updatedAt});
    }

    function scaleTo18Decimals(uint256 value, uint8 decimals) internal pure returns (uint256) {
        return decimals < 18 ? value * (10 ** (18 - decimals)) : value / (10 ** (decimals - 18));
    }

    function convertPrice(PriceData memory from, PriceData memory to) internal pure returns (uint256) {
        return (from.value * to.value) / 1e18;
    }
}
