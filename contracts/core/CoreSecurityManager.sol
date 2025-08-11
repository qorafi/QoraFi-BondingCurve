// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

// Import our modular libraries
import "./SecurityLibraries.sol";
import "./Interfaces.sol";

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
    using MEVLib for MEVLib.MEVProtection;
    using CircuitBreakerLib for CircuitBreakerLib.CircuitBreaker;
    using ValidationLib for *;

    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant MONITOR_ROLE = keccak256("MONITOR_ROLE");

    // --- STATE ---
    IERC20Upgradeable public usdtToken;
    IERC20Upgradeable public qorafiToken;
    address public treasuryWallet;

    MEVLib.MEVProtection internal mevProtection;
    CircuitBreakerLib.CircuitBreaker public circuitBreaker;
    
    mapping(address => bool) public supportedZapTokens;
    mapping(address => uint256) public userTransactionCounts;
    mapping(address => uint256) public userLastAction;
    mapping(address => uint256) public userActionCount;
    mapping(address => uint256) public lastDepositBlock;
    
    uint256 public totalTransactionCount;
    uint256 public totalVolumeProcessed;
    uint256 public liquidityRatioBPS;
    uint256 public maxSlippageBPS;
    
    // New token specific settings
    bool public newTokenMode;
    uint256 public maxGasPrice;

    // --- EVENTS ---
    event CircuitBreakerTriggered(uint256 volume, uint256 threshold);
    event NewTokenModeToggled(bool enabled);
    event MaxGasPriceUpdated(uint256 newMaxGasPrice);
    event SecurityParametersUpdated(string parameterName, uint256 oldValue, uint256 newValue);
    
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
        
        usdtToken = IERC20Upgradeable(_usdtTokenAddress);
        qorafiToken = IERC20Upgradeable(_qorafiTokenAddress);
        treasuryWallet = _initialTreasuryWallet;

        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(MONITOR_ROLE, msg.sender);

        liquidityRatioBPS = 5000;
        maxSlippageBPS = 300;
        
        // Enhanced settings for new token
        newTokenMode = true;
        maxGasPrice = 20 gwei;
        
        // Initialize MEV protection with conservative settings
        mevProtection.minDepositInterval = ValidationLib.MIN_DEPOSIT_INTERVAL_BLOCKS;
        mevProtection.maxDepositPerBlock = 50000 * 10**6; // 50k USDT per block
        mevProtection.maxDepositPerUser = 25000 * 10**6; // 25k USDT per user per day
        
        // Initialize circuit breaker
        circuitBreaker = CircuitBreakerLib.CircuitBreaker({
            triggered: false,
            triggerTime: 0,
            cooldownPeriod: 2 hours,
            volumeThreshold: 100000 * 10**6, // 100k USDT per hour
            currentVolume: 0,
            windowStart: block.timestamp,
            windowDuration: 1 hours,
            triggerCount: 0,
            updating: false,
            pendingVolume: 0
        });
    }

    // --- MODIFIERS ---
    modifier newTokenProtection(uint256 depositAmount) {
        ValidationLib.validateNewTokenLimits(depositAmount, tx.gasprice, maxGasPrice, newTokenMode);
        _;
    }

    // --- CORE SECURITY FUNCTIONS ---
    function preDepositCheck(address user, uint256 amount) external override {
        mevProtection.checkPreDeposit(user, amount);
    }

    function postDepositUpdate(address user, uint256 amount) external override {
        mevProtection.updatePostDeposit(user, amount);
        lastDepositBlock[user] = block.number;
        
        // Update user tracking
        userTransactionCounts[user]++;
        userLastAction[user] = block.timestamp;
        userActionCount[user]++;
        
        totalTransactionCount++;
        totalVolumeProcessed += amount;
    }

    function checkCircuitBreaker(uint256 amount) external override {
        bool wasTriggered = circuitBreaker.atomicCheckAndUpdate(amount);
        
        if (wasTriggered) {
            emit CircuitBreakerTriggered(circuitBreaker.currentVolume, circuitBreaker.volumeThreshold);
        }
    }

    // --- VIEW FUNCTIONS ---
    function canUserDeposit(address user, uint256 amount) external view override returns (bool canDeposit, string memory reason) {
        if (paused()) return (false, "Paused");
        
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
        return circuitBreaker.getStatus();
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
        (bool _canDeposit,) = this.canUserDeposit(user, 1e6);
        return (userTransactionCounts[user], 0, lastDepositBlock[user], _canDeposit);
    }

    function getProtocolStatistics() external view override returns (
        uint256 totalDeposits,
        uint256 currentPrice,
        uint256 marketCap,
        bool oracleHealthy
    ) {
        return (totalVolumeProcessed, 0, 0, !paused());
    }

    // --- GOVERNANCE FUNCTIONS ---
    function setTreasuryWallet(address _newTreasury) external onlyRole(GOVERNANCE_ROLE) {
        ValidationLib.validateAddress(_newTreasury);
        address oldTreasury = treasuryWallet;
        treasuryWallet = _newTreasury;
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

    // --- EMERGENCY FUNCTIONS ---
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
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

    // --- UUPS UPGRADE HOOK ---
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(GOVERNANCE_ROLE) {}
}