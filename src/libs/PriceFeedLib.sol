// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

library PriceFeedLib {
    error PriceFeedLib__StalePriceData();

    struct PriceData {
        uint256 value;
        uint8 decimals;
        uint256 updatedAt;
    }

    function getNormalizedPrice(address feed, uint256 staleTime) internal view returns (PriceData memory) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(feed);
        (, int256 price,, uint256 updatedAt,) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        require(block.timestamp - updatedAt <= staleTime, PriceFeedLib__StalePriceData());

        return PriceData({value: uint256(price), decimals: priceFeed.decimals(), updatedAt: updatedAt});
    }

    function scaleTo18Decimals(uint256 value, uint8 decimals) internal pure returns (uint256) {
        return decimals < 18 ? value * (10 ** (18 - decimals)) : value / (10 ** (decimals - 18));
    }

    // price token _feedFrom against _feedTo
    function convertPriceToTokenAmount(address _feedFrom, address _feedTo, uint256 staleTime)
        internal
        view
        returns (uint256 tokenAmount)
    {
        PriceData memory feedFrom = getNormalizedPrice(_feedFrom, staleTime);
        PriceData memory feedTo = getNormalizedPrice(_feedTo, staleTime);

        uint256 priceFrom = scaleTo18Decimals(feedFrom.value, feedFrom.decimals);
        uint256 priceTo = scaleTo18Decimals(feedTo.value, feedTo.decimals);

        require(priceTo > 0, "Division by zero");
        tokenAmount = (priceFrom * 1e18) / priceTo;
    }

    function getTokenTotalPrice(uint256 price, uint256 amount) internal pure returns (uint256) {
        return (price * amount) / 1e18;
    }
}
