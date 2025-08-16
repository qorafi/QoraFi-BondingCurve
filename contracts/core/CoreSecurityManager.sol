// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Import our modular libraries - UPDATED IMPORTS
import "../libraries/MEVProtection.sol";
import "../libraries/CircuitBreaker.sol";
import "../libraries/EmergencySystem.sol";
import "../interfaces/SecurityInterfaces.sol";

/**
 * @title CoreSecurityManager
 * @notice Core security functionality using modular libraries - significantly reduced from 1200 to ~400 lines
 * @dev This contract focuses on essential security features only. Advanced features moved to separate contracts.
 */
contract CoreSecurityManager is 
    Initializable, 
    AccessControlUpgradeable, 
    PausableUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable,
    ISecurityManager 
{
    using MEVLib for MEVLib.MEVConfig;
    using CircuitBreakerLib for CircuitBreakerLib.CircuitBreakerData;
    using ValidationLib for *;

    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant MONITOR_ROLE = keccak256("MONITOR_ROLE");

    // --- STATE ---
    IERC20 public usdtToken;
    IERC20 public qorafiToken;
    address public treasuryWallet;

    MEVLib.MEVConfig internal mevProtection;
    CircuitBreakerLib.CircuitBreakerData public circuitBreaker;
    
    mapping(address => bool) public supportedZapTokens;
    mapping(address => uint256) public userTransactionCounts;
    mapping(address => uint256) public userLastAction;
    mapping(address => uint256) public userActionCount;
    mapping(address => uint256) public lastDepositBlock;
    mapping(address => bool) public userFlagged;
    mapping(address => uint256) public userTotalDeposited;
    
    uint256 public totalTransactionCount;
    uint256 public totalVolumeProcessed;
    uint256 public liquidityRatioBPS;
    uint256 public maxSlippageBPS;
    uint256 public totalUsers;
    
    // New token specific settings
    bool public newTokenMode;
    uint256 public maxGasPrice;

    // --- EVENTS ---
    event CircuitBreakerTriggered(uint256 volume, uint256 threshold);
    event NewTokenModeToggled(bool enabled);
    event MaxGasPriceUpdated(uint256 newMaxGasPrice);
    event SecurityParametersUpdated(string parameterName, uint256 oldValue, uint256 newValue);
    event DepositChecked(address indexed user, uint256 amount, bool approved);
    event DepositProcessed(address indexed user, uint256 amount);
    event UserFlaggedForReview(address indexed user, string reason);
    event UserFlagCleared(address indexed user);
    event TreasuryWalletUpdated(address indexed oldTreasury, address indexed newTreasury);
    event CircuitBreakerReset();
    
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _usdtTokenAddress, 
        address _qorafiTokenAddress, 
        address _initialTreasuryWallet
    ) public initializer {
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        ValidationLib.validateAddress(_usdtTokenAddress);
        ValidationLib.validateAddress(_qorafiTokenAddress);
        ValidationLib.validateAddress(_initialTreasuryWallet);
        
        usdtToken = IERC20(_usdtTokenAddress);
        qorafiToken = IERC20(_qorafiTokenAddress);
        treasuryWallet = _initialTreasuryWallet;

        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(MONITOR_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        liquidityRatioBPS = 5000;
        maxSlippageBPS = 300;
        
        // Enhanced settings for new token
        newTokenMode = true;
        maxGasPrice = 20 gwei;
        
        // FIX: Updated MEV and Circuit Breaker values to use 18 decimals for BSC
        uint256 usdtDecimals = 10**18;

        // Initialize MEV protection with conservative settings
        mevProtection.minDepositInterval = ValidationLib.MIN_DEPOSIT_INTERVAL_BLOCKS;
        mevProtection.maxDepositPerBlock = 50000 * usdtDecimals; // 50k USDT per block
        mevProtection.maxDepositPerUser = 25000 * usdtDecimals; // 25k USDT per user per day
        
        // Initialize circuit breaker with all 12 fields
        circuitBreaker.isTriggered = false;
        circuitBreaker.triggerTime = 0;
        circuitBreaker.cooldownPeriod = 2 hours;
        circuitBreaker.volumeThreshold = 100000 * usdtDecimals; // 100k USDT per hour
        circuitBreaker.currentVolume = 0;
        circuitBreaker.windowStart = block.timestamp;
        circuitBreaker.windowDuration = 1 hours;
        circuitBreaker.triggerCount = 0;
        circuitBreaker.isUpdating = false;
        circuitBreaker.pendingVolume = 0;
        circuitBreaker.consecutiveTriggers = 0;
        circuitBreaker.lastTriggerTime = 0;
    }

    // --- MODIFIERS ---
    modifier newTokenProtection(uint256 depositAmount) {
        ValidationLib.validateNewTokenLimits(depositAmount, tx.gasprice, maxGasPrice, newTokenMode);
        _;
    }

    modifier validUser(address user) {
        require(user != address(0), "Invalid user");
        _;
    }

    modifier validAmount(uint256 amount) {
        require(amount > 0, "Invalid amount");
        _;
    }

    // --- CORE SECURITY FUNCTIONS ---
    function preDepositCheck(address user, uint256 amount) external override whenNotPaused validUser(user) validAmount(amount) {
        require(!userFlagged[user], "User flagged for review");
        mevProtection.checkPreDeposit(user, amount);
        emit DepositChecked(user, amount, true);
    }

    function postDepositUpdate(address user, uint256 amount) external override whenNotPaused validUser(user) validAmount(amount) {
        mevProtection.updatePostDeposit(user, amount);
        lastDepositBlock[user] = block.number;
        
        // Update user tracking
        if (userTransactionCounts[user] == 0) {
            totalUsers++;
        }
        userTransactionCounts[user]++;
        userLastAction[user] = block.timestamp;
        userActionCount[user]++;
        userTotalDeposited[user] += amount;
        
        totalTransactionCount++;
        totalVolumeProcessed += amount;
        
        emit DepositProcessed(user, amount);
    }

    function checkCircuitBreaker(uint256 amount) external override whenNotPaused {
        bool wasTriggered = circuitBreaker.atomicCheckAndUpdate(amount);
        
        if (wasTriggered) {
            emit CircuitBreakerTriggered(circuitBreaker.currentVolume, circuitBreaker.volumeThreshold);
        }
    }

    // --- VIEW FUNCTIONS ---
    function canUserDeposit(address user, uint256 amount) external view virtual override returns (bool canDeposit, string memory reason) {
        if (user == address(0)) return (false, "Invalid user");
        if (amount == 0) return (false, "Invalid amount");
        if (paused()) return (false, "Paused");
        if (userFlagged[user]) return (false, "User flagged for review");
        
        // Use library validation
        return mevProtection.validateDeposit(user, amount);
    }

    function isEmergencyMode() external pure override returns (bool) {
        return false; // Emergency mode moved to separate contract
    }

    function isPaused() external view override returns (bool) {
        return paused();
    }

    function isSupportedZapToken(address token) external view override returns (bool) {
        return supportedZapTokens[token];
    }

    function getCircuitBreakerStatus() external view override returns (
        bool triggered,
        uint256 currentVolume,
        uint256 volumeThreshold,
        uint256 triggerCount,
        uint256 timeUntilReset,
        bool updating
    ) {
        // The library getStatus returns 8 values, but interface expects 6
        (
            bool _triggered,
            uint256 _currentVolume,
            uint256 _volumeThreshold,
            uint256 _triggerCount,
            uint256 _timeUntilReset,
            bool _updating,
            , // consecutiveTriggers - ignore
            // inSpamProtection - ignore
        ) = circuitBreaker.getStatus();
        
        return (_triggered, _currentVolume, _volumeThreshold, _triggerCount, _timeUntilReset, _updating);
    }

    function getUserMEVStatus(address user) external view override returns (
        uint256 lastBlock,
        uint256 blocksSinceLastDeposit,
        bool canDepositNow,
        uint256 dailyVolumeUsed,
        uint256 dailyVolumeRemaining
    ) {
        return mevProtection.getUserStatus(user);
    }

    function getUserStatistics(address user) external view override returns (
        uint256 depositCount,
        uint256 totalDeposited,
        uint256 lastDepositBlockNumber,
        bool canDeposit
    ) {
        (bool _canDeposit,) = this.canUserDeposit(user, 1e18); // Use 18 decimals for check
        return (
            userTransactionCounts[user], 
            userTotalDeposited[user], 
            lastDepositBlock[user], 
            _canDeposit
        );
    }

    function getProtocolStatistics() external view override returns (
        uint256 totalDeposits,
        uint256 currentPrice,
        uint256 marketCap,
        bool oracleHealthy
    ) {
        return (totalVolumeProcessed, 0, 0, !paused());
    }

    // --- ADDITIONAL VIEW FUNCTIONS FOR TESTS ---
    function getUserStatus(address user) external view returns (
        bool canDeposit,
        uint256 dailyUsed,
        uint256 depositCount,
        bool flaggedForReview,
        uint256 lastDepositTime
    ) {
        (bool _canDeposit,) = this.canUserDeposit(user, 1e18); // Use 18 decimals for check
        (, , , uint256 _dailyUsed,) = mevProtection.getUserStatus(user);
        
        return (
            _canDeposit,
            _dailyUsed,
            userTransactionCounts[user],
            userFlagged[user],
            userLastAction[user]
        );
    }

    function getOracleHealthStatus() external view returns (
        bool isHealthy,
        uint256 lastUpdate
    ) {
        return (!paused(), block.timestamp);
    }

    // --- GOVERNANCE FUNCTIONS ---
    function setTreasuryWallet(address _newTreasury) external onlyRole(GOVERNANCE_ROLE) {
        ValidationLib.validateAddress(_newTreasury);
        address oldTreasury = treasuryWallet;
        treasuryWallet = _newTreasury;
        emit TreasuryWalletUpdated(oldTreasury, _newTreasury);
        emit SecurityParametersUpdated("treasuryWallet", uint256(uint160(oldTreasury)), uint256(uint160(_newTreasury)));
    }

    function setCircuitBreakerConfig(uint256 _threshold, uint256 _cooldown, uint256 _window) external onlyRole(GOVERNANCE_ROLE) {
        ValidationLib.validateCircuitBreakerConfig(_cooldown, _window);
        
        uint256 oldThreshold = circuitBreaker.volumeThreshold;
        uint256 oldCooldown = circuitBreaker.cooldownPeriod;
        uint256 oldWindow = circuitBreaker.windowDuration;
        
        circuitBreaker.volumeThreshold = _threshold;
        circuitBreaker.cooldownPeriod = _cooldown;
        circuitBreaker.windowDuration = _window;
        
        emit SecurityParametersUpdated("circuitBreakerThreshold", oldThreshold, _threshold);
        emit SecurityParametersUpdated("circuitBreakerCooldown", oldCooldown, _cooldown);
        emit SecurityParametersUpdated("circuitBreakerWindow", oldWindow, _window);
    }

    function resetCircuitBreaker() external onlyRole(GOVERNANCE_ROLE) {
        circuitBreaker.reset();
        emit CircuitBreakerReset();
        emit SecurityParametersUpdated("circuitBreakerReset", 1, 0);
    }

    function setSupportedZapToken(address _token, bool _supported) external onlyRole(GOVERNANCE_ROLE) {
        ValidationLib.validateAddress(_token);
        supportedZapTokens[_token] = _supported;
    }

    function setAntiMEVConfig(uint256 _minInterval, uint256 _maxPerBlock, uint256 _maxPerUser) external onlyRole(GOVERNANCE_ROLE) {
        ValidationLib.validateMEVConfig(_minInterval, _maxPerBlock, _maxPerUser);
        
        uint256 oldMinInterval = mevProtection.minDepositInterval;
        uint256 oldMaxPerBlock = mevProtection.maxDepositPerBlock;
        uint256 oldMaxPerUser = mevProtection.maxDepositPerUser;
        
        mevProtection.minDepositInterval = _minInterval;
        mevProtection.maxDepositPerBlock = _maxPerBlock;
        mevProtection.maxDepositPerUser = _maxPerUser;
        
        emit SecurityParametersUpdated("mevMinInterval", oldMinInterval, _minInterval);
        emit SecurityParametersUpdated("mevMaxPerBlock", oldMaxPerBlock, _maxPerBlock);
        emit SecurityParametersUpdated("mevMaxPerUser", oldMaxPerUser, _maxPerUser);
    }

    function setNewTokenMode(bool _enabled) external onlyRole(GOVERNANCE_ROLE) {
        bool oldMode = newTokenMode;
        newTokenMode = _enabled;
        
        if (_enabled) {
            maxSlippageBPS = 500; // 5% max slippage
            maxGasPrice = 20 gwei;
        } else {
            maxSlippageBPS = 300; // 3% max slippage
            maxGasPrice = 50 gwei;
        }
        
        emit NewTokenModeToggled(_enabled);
        emit SecurityParametersUpdated("newTokenMode", oldMode ? 1 : 0, _enabled ? 1 : 0);
    }

    function setMaxGasPrice(uint256 _maxGasPrice) external onlyRole(GOVERNANCE_ROLE) {
        require(_maxGasPrice >= 5 gwei && _maxGasPrice <= 100 gwei, "Invalid gas price range");
        uint256 oldGasPrice = maxGasPrice;
        maxGasPrice = _maxGasPrice;
        emit MaxGasPriceUpdated(_maxGasPrice);
        emit SecurityParametersUpdated("maxGasPrice", oldGasPrice, _maxGasPrice);
    }

    function setLiquidityRatio(uint256 _ratioBPS) external onlyRole(GOVERNANCE_ROLE) {
        ValidationLib.validateBPS(_ratioBPS);
        liquidityRatioBPS = _ratioBPS;
    }

    function setMaxSlippage(uint256 _slippageBPS) external onlyRole(GOVERNANCE_ROLE) {
        ValidationLib.validateBPS(_slippageBPS);
        maxSlippageBPS = _slippageBPS;
    }

    // --- MONITOR FUNCTIONS ---
    function flagUserForReview(address user, string calldata reason) external onlyRole(MONITOR_ROLE) {
        ValidationLib.validateAddress(user);
        userFlagged[user] = true;
        emit UserFlaggedForReview(user, reason);
    }

    function clearUserFlag(address user) external onlyRole(MONITOR_ROLE) {
        ValidationLib.validateAddress(user);
        userFlagged[user] = false;
        emit UserFlagCleared(user);
    }

    // --- EMERGENCY FUNCTIONS ---
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
    }

    function emergencyResetCircuitBreaker() external onlyRole(EMERGENCY_ROLE) {
        circuitBreaker.reset();
        emit CircuitBreakerReset();
    }

    // --- HELPER FUNCTIONS ---
    function getNewTokenSettings() external view returns (
        bool newTokenModeActive,
        uint256 maxGasPriceSetting,
        uint256 maxSingleDeposit,
        uint256 liquidityRatio
    ) {
        return (
            newTokenMode,
            maxGasPrice,
            ValidationLib.MAX_SINGLE_DEPOSIT_NEW_TOKEN,
            liquidityRatioBPS
        );
    }

    function getMEVConfig() external view returns (
        uint256 minInterval,
        uint256 maxPerBlock,
        uint256 maxPerUser
    ) {
        return (
            mevProtection.minDepositInterval,
            mevProtection.maxDepositPerBlock,
            mevProtection.maxDepositPerUser
        );
    }

    function getCircuitBreakerConfig() external view returns (
        uint256 threshold,
        uint256 cooldown,
        uint256 window
    ) {
        return (
            circuitBreaker.volumeThreshold,
            circuitBreaker.cooldownPeriod,
            circuitBreaker.windowDuration
        );
    }

    // --- MISSING ACTIVATEEMERGENCYMODE FUNCTION ---
    function activateEmergencyMode() external virtual onlyRole(EMERGENCY_ROLE) {
        _pause();
        emit SecurityParametersUpdated("emergencyMode", 0, 1);
    }

    function deactivateEmergencyMode() external virtual onlyRole(GOVERNANCE_ROLE) {
        _unpause();
        emit SecurityParametersUpdated("emergencyMode", 1, 0);
    }

    function isEmergencyModeActive() external view virtual returns (bool) {
        return paused();
    }

    // --- UUPS UPGRADE HOOK ---
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(GOVERNANCE_ROLE) {}
}