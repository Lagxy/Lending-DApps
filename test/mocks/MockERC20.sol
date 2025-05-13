// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockERC20
 * @dev Simple ERC20 Token for testing purposes
 */
contract MockERC20 is ERC20, Ownable {
    /**
     * @dev Constructor that gives msg.sender all of the initial supply.
     * @param name Name of the token
     * @param symbol Symbol of the token
     * @param initialSupply Initial supply in wei
     */
    constructor(string memory name, string memory symbol, uint256 initialSupply) ERC20(name, symbol) Ownable(msg.sender){
        _mint(msg.sender, initialSupply);
    }

    /**
     * @dev Mint more tokens (only for testing purposes)
     * @param to The address to receive the tokens
     * @param amount The amount of tokens to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @dev Burn tokens from the sender's account (only for testing purposes)
     * @param amount The amount of tokens to burn
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /**
     * @dev Overriding 18 decimal to 2 decimal to simulate idrx decimal
     */
    function decimals() public pure override returns(uint8) {
        return 2;
    }
}
