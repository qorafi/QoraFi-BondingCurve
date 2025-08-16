// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title USQ Token
 * @dev The stablecoin itself. It is a ERC20, where only the USQEngine
 * (which will be the USQEngine contract) can mint or burn tokens.
 */
contract USQ is ERC20, Ownable {
    constructor() ERC20("QoraFi Stablecoin", "USQ") Ownable(msg.sender) {}

    /**
     * @notice Creates new USQ tokens.
     * @dev Can only be called by the owner (the USQEngine contract).
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice Burns a user's USQ tokens.
     * @dev Can only be called by the owner (the USQEngine contract).
     * The user must first approve the USQEngine to spend their tokens.
     */
    function burn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
    }
}