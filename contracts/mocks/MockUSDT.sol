// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockUSDT
 * @dev A simple ERC20 token to mock USDT on BSC with 18 decimals.
 * Includes a mint function for testing purposes.
 */
contract MockUSDT is ERC20, Ownable {
    constructor() ERC20("Mock USDT", "MUSDT") Ownable(msg.sender) {
        // The ERC20 constructor in OpenZeppelin 5.x no longer sets decimals by default.
        // It's assumed to be 18. If you need a different value, you would override the decimals() function.
    }

    /**
     * @notice Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     * @dev This function is only callable by the owner to facilitate testing.
     */
    function mint(address account, uint256 amount) external onlyOwner {
        _mint(account, amount);
    }
}
