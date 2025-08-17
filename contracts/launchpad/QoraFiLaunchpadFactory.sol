// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IQoraFiToken} from "../interfaces/IQoraFiToken.sol";
import {IQoraFiLaunchpadFactory} from "../interfaces/IQoraFiLaunchpadFactory.sol";

// Import the self-contained QoraFiToken
import {QoraFiToken} from "./QoraFiToken.sol";

/**
 * @title QoraFiLaunchpadFactory
 * @notice Factory for deploying self-contained QoraFi tokens with deadline system
 * @dev Works with self-contained QoraFiToken (no separate interface imports)
 */
contract QoraFiLaunchpadFactory is Ownable, ReentrancyGuard, IQoraFiLaunchpadFactory {

    // --- State Variables ---
    address public treasury;
    address public dexTreasury;
    address public signer;
    uint256 public launchFee;
    
    // Default parameters for token template
    address public immutable uniV2Router;
    uint256 public defaultTotalSupply;
    uint256 public defaultVirtualTokenReserves;
    uint256 public defaultVirtualCollateralReserves;
    uint256 public defaultFeeBasisPoints;
    uint256 public defaultDexFeeBasisPoints;
    uint256 public defaultMigrationFeeFixed;
    uint256 public defaultPoolCreationFee;
    uint256 public defaultMcLowerLimit;
    uint256 public defaultMcUpperLimit;
    uint256 public defaultTokensMigrationThreshold;
    
    // Registry of deployed tokens
    mapping(address => bool) public isDeployedToken;
    address[] public deployedTokens;
    
    // Signature replay protection
    mapping(bytes32 => bool) public usedSignatures;
    
    // Access control for migration
    mapping(address => bool) public canMigrate;

    // --- Events (defined in interface) ---

    // --- Errors (defined in interface) ---

    /**
     * @notice Constructor to initialize the factory
     */
    constructor(
        address _initialOwner,
        address _treasury,
        address _dexTreasury,
        address _signer,
        uint256 _launchFee,
        address _uniV2Router,
        uint256 _defaultTotalSupply,
        uint256 _defaultVirtualTokenReserves,
        uint256 _defaultVirtualCollateralReserves,
        uint256 _defaultFeeBasisPoints,
        uint256 _defaultDexFeeBasisPoints,
        uint256 _defaultMigrationFeeFixed,
        uint256 _defaultPoolCreationFee,
        uint256 _defaultMcLowerLimit,
        uint256 _defaultMcUpperLimit,
        uint256 _defaultTokensMigrationThreshold
    ) Ownable(_initialOwner) {
        if (_treasury == address(0) || _dexTreasury == address(0) || 
            _signer == address(0) || _uniV2Router == address(0)) {
            revert InvalidAddress();
        }
        if (_defaultTotalSupply == 0 || _defaultMcUpperLimit == 0) {
            revert InvalidParameters();
        }
        
        treasury = _treasury;
        dexTreasury = _dexTreasury;
        signer = _signer;
        launchFee = _launchFee;
        uniV2Router = _uniV2Router;
        
        // Set default parameters
        defaultTotalSupply = _defaultTotalSupply;
        defaultVirtualTokenReserves = _defaultVirtualTokenReserves;
        defaultVirtualCollateralReserves = _defaultVirtualCollateralReserves;
        defaultFeeBasisPoints = _defaultFeeBasisPoints;
        defaultDexFeeBasisPoints = _defaultDexFeeBasisPoints;
        defaultMigrationFeeFixed = _defaultMigrationFeeFixed;
        defaultPoolCreationFee = _defaultPoolCreationFee;
        defaultMcLowerLimit = _defaultMcLowerLimit;
        defaultMcUpperLimit = _defaultMcUpperLimit;
        defaultTokensMigrationThreshold = _defaultTokensMigrationThreshold;
        
        // Owner can migrate tokens by default
        canMigrate[_initialOwner] = true;
    }

    // --- Admin Functions ---
    
    function setLaunchFee(uint256 _newFee) external onlyOwner {
        uint256 oldFee = launchFee;
        launchFee = _newFee;
        emit LaunchFeeUpdated(oldFee, _newFee);
    }

    function setTreasury(address _newTreasury) external onlyOwner {
        if (_newTreasury == address(0)) revert InvalidAddress();
        address oldTreasury = treasury;
        treasury = _newTreasury;
        emit TreasuryUpdated(oldTreasury, _newTreasury);
    }

    function setDexTreasury(address _newDexTreasury) external onlyOwner {
        if (_newDexTreasury == address(0)) revert InvalidAddress();
        address oldDexTreasury = dexTreasury;
        dexTreasury = _newDexTreasury;
        emit DexTreasuryUpdated(oldDexTreasury, _newDexTreasury);
    }

    function setSigner(address _newSigner) external onlyOwner {
        if (_newSigner == address(0)) revert InvalidAddress();
        address oldSigner = signer;
        signer = _newSigner;
        emit SignerUpdated(oldSigner, _newSigner);
    }

    function setDefaultParameters(
        uint256 _totalSupply,
        uint256 _virtualTokenReserves,
        uint256 _virtualCollateralReserves,
        uint256 _feeBasisPoints,
        uint256 _dexFeeBasisPoints,
        uint256 _migrationFeeFixed,
        uint256 _poolCreationFee,
        uint256 _mcLowerLimit,
        uint256 _mcUpperLimit,
        uint256 _tokensMigrationThreshold
    ) external onlyOwner {
        if (_totalSupply == 0 || _mcUpperLimit == 0) revert InvalidParameters();
        
        defaultTotalSupply = _totalSupply;
        defaultVirtualTokenReserves = _virtualTokenReserves;
        defaultVirtualCollateralReserves = _virtualCollateralReserves;
        defaultFeeBasisPoints = _feeBasisPoints;
        defaultDexFeeBasisPoints = _dexFeeBasisPoints;
        defaultMigrationFeeFixed = _migrationFeeFixed;
        defaultPoolCreationFee = _poolCreationFee;
        defaultMcLowerLimit = _mcLowerLimit;
        defaultMcUpperLimit = _mcUpperLimit;
        defaultTokensMigrationThreshold = _tokensMigrationThreshold;
        
        emit DefaultParametersUpdated();
    }

    function setMigrationPermission(address _account, bool _canMigrate) external onlyOwner {
        canMigrate[_account] = _canMigrate;
        emit MigrationPermissionUpdated(_account, _canMigrate);
    }

    function withdrawFees() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoFeesToWithdraw();
        
        (bool success, ) = treasury.call{value: balance}("");
        if (!success) revert FeeWithdrawalFailed();
        
        emit FeesWithdrawn(treasury, balance);
    }

    // --- Token Creation ---
    
    /**
     * @notice Create a new QoraFi token with deadline system
     * @param _name Token name
     * @param _symbol Token symbol
     * @param _deadlineDuration Deadline duration (24h, 48h, or 72h)
     * @param _nonce Unique nonce for signature
     * @param _signature Authorization signature
     */
    function createQoraFiToken(
        string calldata _name,
        string calldata _symbol,
        uint256 _deadlineDuration, // 24h, 48h, or 72h in seconds
        uint256 _nonce,
        bytes calldata _signature
    ) external payable nonReentrant returns (address tokenAddress) {
        if (msg.value != launchFee) revert InvalidLaunchFee();
        
        if (bytes(_name).length == 0 || bytes(_symbol).length == 0) {
            revert InvalidParameters();
        }

        // Validate deadline duration
        if (_deadlineDuration != 24 hours && _deadlineDuration != 48 hours && _deadlineDuration != 72 hours) {
            revert InvalidDeadlineDuration();
        }

        _checkSignatureAndStore(_name, _symbol, _deadlineDuration, _nonce, _signature);

        // Deploy new token instance using the ConstructorParams struct
        QoraFiToken token = new QoraFiToken(
            QoraFiToken.ConstructorParams({
                name: _name,
                symbol: _symbol,
                creator: msg.sender,
                treasury: treasury,
                dexTreasury: dexTreasury,
                uniV2Router: uniV2Router,
                totalSupply: defaultTotalSupply,
                virtualTokenReserves: defaultVirtualTokenReserves,
                virtualCollateralReserves: defaultVirtualCollateralReserves,
                feeBasisPoints: defaultFeeBasisPoints,
                dexFeeBasisPoints: defaultDexFeeBasisPoints,
                migrationFeeFixed: defaultMigrationFeeFixed,
                poolCreationFee: defaultPoolCreationFee,
                mcLowerLimit: defaultMcLowerLimit,
                mcUpperLimit: defaultMcUpperLimit,
                tokensMigrationThreshold: defaultTokensMigrationThreshold,
                deadlineDuration: _deadlineDuration
            })
        );

        tokenAddress = address(token);
        
        isDeployedToken[tokenAddress] = true;
        deployedTokens.push(tokenAddress);
        
        emit NewQoraFiToken(tokenAddress, msg.sender, _name, _symbol, _deadlineDuration, _signature);
    }
    
    function _checkSignatureAndStore(
        string calldata _name,
        string calldata _symbol,
        uint256 _deadlineDuration,
        uint256 _nonce,
        bytes calldata _signature
    ) internal {
        bytes32 sigHash = keccak256(_signature);
        if (usedSignatures[sigHash]) revert SignatureAlreadyUsed();

        bytes32 messageHash = keccak256(abi.encodePacked(
            _name, 
            _symbol, 
            _deadlineDuration,
            _nonce, 
            address(this), 
            block.chainid, 
            msg.sender
        ));
        
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);

        if (!SignatureChecker.isValidSignatureNow(signer, ethSignedMessageHash, _signature)) {
            revert InvalidSignature();
        }

        usedSignatures[sigHash] = true;
    }

    // --- Trading Proxy Functions ---
    
    function buyFromLaunchpad(address _token) external payable nonReentrant {
        if (!isDeployedToken[_token]) revert TokenNotDeployed();
        QoraFiToken(_token).buy{value: msg.value}(msg.sender);
    }

    function buyExactOutFromLaunchpad(
        address _token,
        uint256 _tokenAmount,
        uint256 _maxCollateralAmount
    ) external payable nonReentrant {
        if (!isDeployedToken[_token]) revert TokenNotDeployed();
        QoraFiToken(_token).buyExactOut{value: msg.value}(msg.sender, _tokenAmount, _maxCollateralAmount);
    }

    function buyExactInFromLaunchpad(
        address _token,
        uint256 _amountOutMin
    ) external payable nonReentrant {
        if (!isDeployedToken[_token]) revert TokenNotDeployed();
        QoraFiToken(_token).buyExactIn{value: msg.value}(msg.sender, _amountOutMin);
    }

    // Note: Selling functions removed - only buying allowed during bonding curve phase

    function migrateFromLaunchpad(address _token) external nonReentrant {
        if (!canMigrate[msg.sender]) revert UnauthorizedMigration();
        if (!isDeployedToken[_token]) revert TokenNotDeployed();
        
        QoraFiToken(_token).migrate();
    }

    // --- Admin Functions for Cancelled Sales ---

    /**
     * @notice Cancel a token sale manually (admin only)
     */
    function cancelTokenSale(address _token) external onlyOwner nonReentrant {
        if (!isDeployedToken[_token]) revert TokenNotDeployed();
        QoraFiToken(_token).cancelSale();
        emit TokenSaleCancelled(_token, "Manual admin cancellation");
    }

    /**
     * @notice Trigger emergency refund for all buyers of a cancelled sale
     */
    function emergencyRefundAllBuyers(address _token) external onlyOwner nonReentrant {
        if (!isDeployedToken[_token]) revert TokenNotDeployed();
        QoraFiToken(_token).emergencyRefundAll();
    }

    /**
     * @notice Check deadline status for a token
     */
    function checkTokenDeadline(address _token) external view returns (
        uint256 deadline,
        uint256 timeRemaining,
        bool isExpired,
        bool isCancelled
    ) {
        if (!isDeployedToken[_token]) revert TokenNotDeployed();
        return QoraFiToken(_token).getDeadlineInfo();
    }

    /**
     * @notice Batch check deadlines for multiple tokens
     */
    function batchCheckDeadlines(address[] calldata _tokens) external {
        for (uint256 i = 0; i < _tokens.length; i++) {
            if (isDeployedToken[_tokens[i]]) {
                try QoraFiToken(_tokens[i]).checkAndCancelIfExpired() {
                    // Token deadline checked successfully
                } catch {
                    // Token might already be migrated or cancelled
                }
            }
        }
    }

    // --- View Functions ---
    
    function getDeployedTokensCount() external view returns (uint256) {
        return deployedTokens.length;
    }

    function getDeployedToken(uint256 _index) external view returns (address) {
        require(_index < deployedTokens.length, "Index out of bounds");
        return deployedTokens[_index];
    }

    function getAllDeployedTokens() external view returns (address[] memory) {
        return deployedTokens;
    }

    function isSignatureUsed(bytes calldata _signature) external view returns (bool) {
        bytes32 sigHash = keccak256(_signature);
        return usedSignatures[sigHash];
    }

    /**
     * @notice Get tokens deployed by a specific creator
     */
    function getTokensByCreator(address _creator) external view returns (address[] memory creatorTokens) {
        uint256 count = 0;
        
        // First pass: count tokens
        for (uint256 i = 0; i < deployedTokens.length; i++) {
            try QoraFiToken(deployedTokens[i]).creator() returns (address creator) {
                if (creator == _creator) {
                    count++;
                }
            } catch {
                // Skip if call fails
            }
        }
        
        // Second pass: populate array
        creatorTokens = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < deployedTokens.length; i++) {
            try QoraFiToken(deployedTokens[i]).creator() returns (address creator) {
                if (creator == _creator) {
                    creatorTokens[index] = deployedTokens[i];
                    index++;
                }
            } catch {
                // Skip if call fails
            }
        }
    }

    /**
     * @notice Get active tokens (not cancelled or migrated)
     */
    function getActiveTokens() external view returns (address[] memory activeTokens) {
        uint256 count = 0;
        
        // First pass: count active tokens
        for (uint256 i = 0; i < deployedTokens.length; i++) {
            try QoraFiToken(deployedTokens[i]).getState() returns (IQoraFiToken.TokenState state) {
                try QoraFiToken(deployedTokens[i]).getDeadlineInfo() returns (uint256, uint256, bool, bool isCancelled) {
                    if ((state == IQoraFiToken.TokenState.Active || state == IQoraFiToken.TokenState.Succeeded) && !isCancelled) {
                        count++;
                    }
                } catch {
                    // Skip if call fails
                }
            } catch {
                // Skip if call fails
            }
        }
        
        // Second pass: populate array
        activeTokens = new address[](count);
        uint256 index = 0;
        for (uint256 i = 0; i < deployedTokens.length; i++) {
            try QoraFiToken(deployedTokens[i]).getState() returns (IQoraFiToken.TokenState state) {
                try QoraFiToken(deployedTokens[i]).getDeadlineInfo() returns (uint256, uint256, bool, bool isCancelled) {
                    if ((state == IQoraFiToken.TokenState.Active || state == IQoraFiToken.TokenState.Succeeded) && !isCancelled) {
                        activeTokens[index] = deployedTokens[i];
                        index++;
                    }
                } catch {
                    // Skip if call fails
                }
            } catch {
                // Skip if call fails
            }
        }
    }

    // --- Emergency Functions ---
    
    function emergencyTokenRecovery(address _token, uint256 _amount) external onlyOwner {
        if (_token == address(0)) revert InvalidAddress();
        require(IERC20(_token).transfer(treasury, _amount), "Token transfer failed");
    }
    
    receive() external payable {}
}