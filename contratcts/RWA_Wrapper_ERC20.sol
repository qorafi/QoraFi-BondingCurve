// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

/**
 * @title RWA_Wrapper_ERC20
 * @dev A wrapper to make a specific ERC1155 token ID behave like a tradable ERC20.
 */
contract RWA_Wrapper_ERC20 is ERC20, Ownable, ERC1155Holder {
    IERC1155 public immutable underlyingRwaToken;
    uint256 public immutable rwaTokenId;

    constructor(
        address _underlyingRwaToken,
        uint256 _rwaTokenId,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) Ownable(msg.sender) {
        underlyingRwaToken = IERC1155(_underlyingRwaToken);
        rwaTokenId = _rwaTokenId;
    }

    /**
     * @notice Allows the factory to mint initial tokens during the Zap process.
     */
    function mintForFactory(address user, uint256 amount) public onlyOwner {
        _mint(user, amount);
    }

    /**
     * @notice Allows any user to wrap their ERC1155 token into this ERC20.
     * @dev User must first approve this contract to manage their ERC1155 tokens.
     */
    function wrap(uint256 amount) public {
        underlyingRwaToken.safeTransferFrom(msg.sender, address(this), rwaTokenId, amount, "");
        _mint(msg.sender, amount);
    }

    /**
     * @notice Allows a user to unwrap their ERC20 token to get the underlying ERC1155 back.
     */
    function unwrap(uint256 amount) public {
        _burn(msg.sender, amount);
        underlyingRwaToken.safeTransferFrom(address(this), msg.sender, rwaTokenId, amount, "");
    }
}