// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockUniswapV2Router
 * @dev Simulates Uniswap V2 Router behavior with configurable responses for testing
 */
contract MockUniswapV2Router is Ownable {
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

    constructor() Ownable(msg.sender) {}

    /**
     * @dev Set mock exchange rate between tokens (1e18 precision)
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param rate Exchange rate (1 tokenIn = X tokenOut)
     */
    function setMockRate(address tokenIn, address tokenOut, uint256 rate) external onlyOwner {
        mockRates[tokenIn][tokenOut] = rate;
        mockRates[tokenOut][tokenIn] = 1e36 / rate;
    }

    /**
     * @dev Set mock liquidity reserves for a token pair
     * @param tokenA First token in pair
     * @param tokenB Second token in pair
     * @param reserveA Reserve amount for tokenA
     * @param reserveB Reserve amount for tokenB
     */
    function setMockReserves(address tokenA, address tokenB, uint256 reserveA, uint256 reserveB) external onlyOwner {
        address pair = pairFor(tokenA, tokenB);
        mockReserves[pair][0] = reserveA;
        mockReserves[pair][1] = reserveB;
    }

    function addLiquidity(address tokenA, address tokenB, uint256 amountA, uint256 amountB) external onlyOwner {
        address pair = pairFor(tokenA, tokenB);

        // Transfer tokens from the owner to the router
        require(IERC20(tokenA).transferFrom(msg.sender, address(this), amountA), "Transfer failed for tokenA");
        require(IERC20(tokenB).transferFrom(msg.sender, address(this), amountB), "Transfer failed for tokenB");

        // Update the reserves
        mockReserves[pair][0] += amountA;
        mockReserves[pair][1] += amountB;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(block.timestamp <= deadline, "MockUniswap: EXPIRED");
        require(path.length >= 2, "MockUniswap: INVALID_PATH");

        swapCalls.push(SwapCall(amountIn, amountOutMin, path, to, deadline));

        uint256 amountOut;
        if (mockRates[path[0]][path[path.length - 1]] > 0) {
            amountOut = (amountIn * mockRates[path[0]][path[path.length - 1]]) / 1e18;
        } else {
            address pair = pairFor(path[0], path[1]);
            uint256 reserveIn = mockReserves[pair][0];
            uint256 reserveOut = mockReserves[pair][1];
            amountOut = (amountIn * reserveOut) / (reserveIn + amountIn);
        }

        require(amountOut >= amountOutMin, "MockUniswap: INSUFFICIENT_OUTPUT_AMOUNT");

        // uniswap transfer uses 18 decimals, but IDRX only use 2 decimals
        // the option is to change idrx to 18 decimals or make the uniswap transfer in 2 decimals, currently doing option 2
        if (path[path.length - 1] == 0xfD498EF2a4A07189c715f43BA1Af8429C3af9B4d) {
            // if the token is Mock IDRX, normalize to 2 decimals
            amountOut /= (10 ** (18 - 2));
        }

        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = amountOut;

        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        IERC20(path[path.length - 1]).transfer(to, amountOut);

        emit SwapExecuted(amountIn, amountOut, path, to);
        return amounts;
    }

    function pairFor(address tokenA, address tokenB) public view returns (address) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            address(this),
                            keccak256(abi.encodePacked(token0, token1)),
                            hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f"
                        )
                    )
                )
            )
        );
    }
}
