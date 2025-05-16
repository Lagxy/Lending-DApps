// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MockUniswapV2Router
 * @dev Simulates Uniswap V2 Router behavior with configurable responses for testing
 */
contract MockUniswapV2Router {
    // Storage for mock exchange rates (tokenIn => tokenOut => rate)
    mapping(address => mapping(address => uint256)) public mockRates;

    // Storage for mock liquidity (pair => reserve0 => reserve1)
    mapping(address => mapping(uint256 => uint256)) public mockReserves;

    // Track swap calls for assertions
    struct SwapCall {
        uint256 amountIn;
        uint256 amountOutMin;
        address[] path;
        address to;
        uint256 deadline;
    }

    SwapCall[] public swapCalls;

    event SwapExecuted(uint256 amountIn, uint256 amountOut, address[] path, address indexed to);

    /**
     * @dev Set mock exchange rate between tokens (1e18 precision)
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param rate Exchange rate (1 tokenIn = X tokenOut)
     */
    function setMockRate(address tokenIn, address tokenOut, uint256 rate) external {
        mockRates[tokenIn][tokenOut] = rate;
        mockRates[tokenOut][tokenIn] = 1e36 / rate; // Auto-set inverse rate
    }

    /**
     * @dev Set mock liquidity reserves for a token pair
     * @param tokenA First token in pair
     * @param tokenB Second token in pair
     * @param reserveA Reserve amount for tokenA
     * @param reserveB Reserve amount for tokenB
     */
    function setMockReserves(address tokenA, address tokenB, uint256 reserveA, uint256 reserveB) external {
        address pair = pairFor(tokenA, tokenB);
        mockReserves[pair][0] = reserveA;
        mockReserves[pair][1] = reserveB;
    }

    function addLiquidity(address tokenA, address tokenB, uint256 amountA, uint256 amountB) external {
        address pair = pairFor(tokenA, tokenB);

        // Transfer tokens from the owner to the router
        require(IERC20(tokenA).transferFrom(msg.sender, address(this), amountA), "Transfer failed for tokenA");
        require(IERC20(tokenB).transferFrom(msg.sender, address(this), amountB), "Transfer failed for tokenB");

        // Update the reserves
        mockReserves[pair][0] += amountA;
        mockReserves[pair][1] += amountB;
    }

    /**
     * @dev Mock implementation of swapExactTokensForTokens
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(block.timestamp <= deadline, "MockUniswap: EXPIRED");
        require(path.length >= 2, "MockUniswap: INVALID_PATH");

        // Record the call for test assertions
        swapCalls.push(SwapCall(amountIn, amountOutMin, path, to, deadline));

        // Calculate output based on mock rate or reserves
        uint256 amountOut;
        if (mockRates[path[0]][path[path.length - 1]] > 0) {
            // Use fixed rate if set
            amountOut = (amountIn * mockRates[path[0]][path[path.length - 1]]) / 1e18;
        } else {
            // Simulate AMM math if reserves are set
            address pair = pairFor(path[0], path[1]);
            uint256 reserveIn = mockReserves[pair][0];
            uint256 reserveOut = mockReserves[pair][1];
            amountOut = (amountIn * reserveOut) / (reserveIn + amountIn);
        }

        require(amountOut >= amountOutMin, "MockUniswap: INSUFFICIENT_OUTPUT_AMOUNT");

        // uniswap transfer uses 18 decimals, but IDRX only use 2 decimals
        // the option is to change idrx to 18 decimals or make the uniswap transfer in 2 decimals, currently doing option 2
        // if(path[path.length-1] == 0xfD498EF2a4A07189c715f43BA1Af8429C3af9B4d){
        // if the token is Mock IDRX, normalize to 2 decimals
        amountOut /= (10 ** (18 - 2));
        // }

        // Return amounts array
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountOut;

        // Simulate token transfers
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        IERC20(path[path.length - 1]).transfer(to, amountOut);

        emit SwapExecuted(amountIn, amountOut, path, to);
        return amounts;
    }

    /**
     * @dev Get last swap call (for test assertions)
     */
    function getLastSwapCall() external view returns (SwapCall memory) {
        require(swapCalls.length > 0, "No swaps executed");
        return swapCalls[swapCalls.length - 1];
    }

    /**
     * @dev Simplified pair address calculation
     */
    function pairFor(address tokenA, address tokenB) public view returns (address) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            address(this), // Using mock address as fake factory
                            keccak256(abi.encodePacked(token0, token1)),
                            hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f" // init code hash
                        )
                    )
                )
            )
        );
    }

    // Add other Uniswap functions as needed for your tests...
    function getAmountsOut(uint256 amountIn, address[] memory path) public view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i; i < path.length - 1; i++) {
            if (mockRates[path[i]][path[i + 1]] > 0) {
                amounts[i + 1] = (amounts[i] * mockRates[path[i]][path[i + 1]]) / 1e18;
            } else {
                address pair = pairFor(path[i], path[i + 1]);
                uint256 reserveIn = mockReserves[pair][0];
                uint256 reserveOut = mockReserves[pair][1];
                amounts[i + 1] = (amounts[i] * reserveOut) / (reserveIn + amounts[i]);
            }
        }
    }
}
