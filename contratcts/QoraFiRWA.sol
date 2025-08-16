// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title QoraFiRWA
 * @dev The ERC1155 contract to represent all tokenized Real-World Assets,
 * with DAO-controlled administration and asset recovery.
 */
contract QoraFiRWA is ERC1155, AccessControlEnumerable {
    using SafeERC20 for IERC20;

    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    address public treasuryAddress;

    event TreasuryAddressUpdated(address newTreasury);
    
    error InvalidAddress();
    error NoAssetsToWithdraw();

    constructor(address _initialTreasuryAddress) ERC1155("https://api.qorafi.com/rwa/{id}.json") {
        require(_initialTreasuryAddress != address(0), "Invalid treasury address");
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        treasuryAddress = _initialTreasuryAddress;
    }
    
    /**
     * @notice Mints a new RWA token or additional supply of an existing one.
     * @dev Can only be called by an address with the MINTER_ROLE (e.g., the RWAFactory).
     */
    function mint(address to, uint256 id, uint256 amount, bytes memory data)
        public
        onlyRole(MINTER_ROLE)
    {
        _mint(to, id, amount, data);
    }
    
    // --- GOVERNANCE-CONTROLLED FUNCTIONS ---

    /**
     * @notice Updates the base URI for all token metadata.
     * @dev Can only be called by the DAO (via the Timelock contract).
     */
    function setURI(string memory newuri) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _setURI(newuri);
    }
    
    /**
     * @notice Sets the Treasury address for recovering stuck assets.
     * @dev Can only be called by the DAO (via the Timelock contract).
     */
    function setTreasuryAddress(address _newTreasury) public onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_newTreasury == address(0)) revert InvalidAddress();
        treasuryAddress = _newTreasury;
        emit TreasuryAddressUpdated(_newTreasury);
    }

    /**
     * @notice Allows the DAO to withdraw any ERC20 tokens accidentally sent to this contract.
     * @dev Can only be called by the DAO (via the Timelock contract).
     */
    function withdrawStuckTokens(address _tokenAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        IERC20 token = IERC20(_tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) revert NoAssetsToWithdraw();
        token.safeTransfer(treasuryAddress, balance);
    }

    /**
     * @notice Allows the DAO to withdraw any BNB accidentally sent to this contract.
     * @dev Can only be called by the DAO (via the Timelock contract).
     */
    function withdrawStuckBNB() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoAssetsToWithdraw();
        (bool success, ) = payable(treasuryAddress).call{value: balance}("");
        require(success, "BNB withdrawal failed");
    }

    // --- Required Overrides for AccessControlEnumerable ---

    function _updateRoleMember(address account, bytes32 role, bool value)
        internal
        virtual
        override(AccessControl, AccessControlEnumerable)
    {
        super._updateRoleMember(account, role, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC1155, AccessControlEnumerable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    receive() external payable {}
}