// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// --- LIBRARIES ---
library MEVLib {
    struct MEVProtection {
        uint256 minDepositInterval;
        uint256 maxDepositPerBlock;
        uint256 maxDepositPerUser;
        mapping(address => uint256) lastDepositBlock;
        mapping(address => uint256) userDailyVolume;
        mapping(address => uint256) userDayStart;
        mapping(uint256 => uint256) blockDepositTotal;
    }

    error DepositTooFrequent();
    error BlockDepositLimitExceeded();
    error DailyLimitExceeded();

    function checkPreDeposit(MEVProtection storage mev, address user, uint256 amount) internal view {
        // Enhanced check for new token - more blocks required
        if (mev.minDepositInterval > 0 && block.number - mev.lastDepositBlock[user] < mev.minDepositInterval) {
            revert DepositTooFrequent();
        }
        // Atomic block deposit check to prevent race conditions
        if (mev.maxDepositPerBlock > 0 && mev.blockDepositTotal[block.number] + amount > mev.maxDepositPerBlock) {
            revert BlockDepositLimitExceeded();
        }
        // Enhanced daily limit tracking
        uint256 userDayStart = mev.userDayStart[user];
        if (mev.maxDepositPerUser > 0 && userDayStart != 0 && block.timestamp < userDayStart + 1 days) {
            if (mev.userDailyVolume[user] + amount > mev.maxDepositPerUser) {
                revert DailyLimitExceeded();
            }
        }
    }

    function updatePostDeposit(MEVProtection storage mev, address user, uint256 amount) internal {
        mev.lastDepositBlock[user] = block.number;
        mev.blockDepositTotal[block.number] += amount;
        
        // Reset daily volume if new day
        if (mev.userDayStart[user] == 0 || block.timestamp >= mev.userDayStart[user] + 1 days) {
            mev.userDayStart[user] = block.timestamp;
            mev.userDailyVolume[user] = amount;
        } else {
            mev.userDailyVolume[user] += amount;
        }
    }
}

library CircuitBreakerLib {
    struct CircuitBreaker {
        bool triggered;
        uint256 triggerTime;
        uint256 cooldownPeriod;
        uint256 volumeThreshold;
        uint256 currentVolume;
        uint256 windowStart;
        uint256 windowDuration;
        uint256 triggerCount;
        // New fields for atomic operations
        bool updating;
        uint256 pendingVolume;
    }

    error CircuitBreakerActive();
    error CircuitBreakerUpdating();

    function check(CircuitBreaker storage cb) internal view {
        if (cb.updating) revert CircuitBreakerUpdating();
        if (cb.triggered && block.timestamp < cb.triggerTime + cb.cooldownPeriod) {
            revert CircuitBreakerActive();
        }
    }

    function atomicCheckAndUpdate(CircuitBreaker storage cb, uint256 amount) internal {
        // Set updating flag to prevent race conditions
        if (cb.updating) revert CircuitBreakerUpdating();
        cb.updating = true;
        
        // Check if cooldown expired
        if (cb.triggered && block.timestamp >= cb.triggerTime + cb.cooldownPeriod) {
            cb.triggered = false;
        }
        
        // If still triggered, revert
        if (cb.triggered) {
            cb.updating = false;
            revert CircuitBreakerActive();
        }
        
        // Reset window if expired
        if (block.timestamp > cb.windowStart + cb.windowDuration) {
            cb.currentVolume = 0;
            cb.windowStart = block.timestamp;
        }

        // Check if new volume would trigger circuit breaker
        uint256 newVolume = cb.currentVolume + amount;
        if (cb.volumeThreshold > 0 && newVolume > cb.volumeThreshold) {
            cb.triggered = true;
            cb.triggerTime = block.timestamp;
            cb.triggerCount++;
            cb.updating = false;
            revert CircuitBreakerActive();
        }
        
        // Update volume
        cb.currentVolume = newVolume;
        cb.updating = false;
    }

    function update(CircuitBreaker storage cb, uint256 amount) internal {
        if (block.timestamp > cb.windowStart + cb.windowDuration) {
            cb.currentVolume = 0;
            cb.windowStart = block.timestamp;
        }

        if (cb.triggered && block.timestamp >= cb.triggerTime + cb.cooldownPeriod) {
            cb.triggered = false;
        }

        uint256 newVolume = cb.currentVolume + amount;
        if (cb.volumeThreshold > 0 && newVolume > cb.volumeThreshold) {
            cb.triggered = true;
            cb.triggerTime = block.timestamp;
            cb.triggerCount++;
            revert CircuitBreakerActive();
        }
        
        cb.currentVolume = newVolume;
    }
}

/**
 * @title SecurityManager (Enhanced & Fixed)
 * @notice An upgradeable base contract for security features with improved configurability and monitoring.
 * @dev This contract is intended to be deployed behind a UUPS proxy.
 */
contract SecurityManager is Initializable, AccessControlUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    using MEVLib for MEVLib.MEVProtection;
    using CircuitBreakerLib for CircuitBreakerLib.CircuitBreaker;

    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant MONITOR_ROLE = keccak256("MONITOR_ROLE");

    // --- CONSTANTS ---
    uint256 public constant MAX_BPS = 10000;
    uint256 public constant MIN_DEPOSIT_INTERVAL_BLOCKS = 5; // Minimum blocks between deposits for new token
    uint256 public constant MAX_SINGLE_DEPOSIT_NEW_TOKEN = 5000 * 10**18; // 5k USDT max for new token

    // --- STRUCTS ---
    struct EmergencyTransaction {
        address target;
        uint256 value;
        bytes data;
        uint256 executeAfter;
        bool executed;
        address proposer;
        uint256 proposedAt;
    }

    // --- STATE ---
    IERC20 public usdtToken;
    IERC20 public qorafiToken;
    address public treasuryWallet;
    uint256 public liquidityRatioBPS;
    uint256 public maxSlippageBPS;

    MEVLib.MEVProtection internal mevProtection;
    CircuitBreakerLib.CircuitBreaker public circuitBreaker;
    
    mapping(address => bool) public supportedZapTokens;
    mapping(address => uint256) public userRiskScores;
    mapping(bytes32 => EmergencyTransaction) public emergencyTransactions;
    mapping(address => uint256) public lastDepositBlock; // For external access to MEV data
    
    bool public emergencyModeActive;
    uint256 public emergencyModeActivatedAt;
    uint256 public totalTransactionCount;
    uint256 public totalVolumeProcessed;
    mapping(address => uint256) public userTransactionCounts;
    mapping(address => uint256) public userLastAction;
    mapping(address => uint256) public userActionCount;
    
    // New token specific settings
    bool public newTokenMode;
    uint256 public maxGasPrice;
    uint256 public emergencyTransactionDelay;

    // --- EVENTS ---
    event EmergencyModeToggled(bool enabled);
    event CircuitBreakerTriggered(uint256 volume, uint256 threshold);
    event EmergencyTransactionProposed(bytes32 indexed txHash, address indexed proposer, address target, uint256 value, bytes data, uint256 executeAfter);
    event EmergencyTransactionExecuted(bytes32 indexed txHash, address indexed executor);
    event NewTokenModeToggled(bool enabled);
    event MaxGasPriceUpdated(uint256 newMaxGasPrice);
    event SecurityParametersUpdated(string parameterName, uint256 oldValue, uint256 newValue);
    
    // --- ERRORS ---
    error InvalidAddress();
    error TokenNotSupported();
    error DeadlineExpired();
    error InvalidSlippage();
    error EmergencyModeActive();
    error InvalidConfiguration();
    error TransactionNotFound();
    error TransactionAlreadyExecuted();
    error TimelockNotExpired();
    error GasPriceTooHigh();
    error NewTokenLimitExceeded();
    error RolesSameAddress();
    error InvalidDelay();

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

        require(_usdtTokenAddress != address(0) && _qorafiTokenAddress != address(0) && _initialTreasuryWallet != address(0), "Invalid addresses");
        
        usdtToken = IERC20(_usdtTokenAddress);
        qorafiToken = IERC20(_qorafiTokenAddress);
        treasuryWallet = _initialTreasuryWallet;

        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(MONITOR_ROLE, msg.sender);

        liquidityRatioBPS = 5000;
        maxSlippageBPS = 300;
        
        // Enhanced settings for new token
        newTokenMode = true;
        maxGasPrice = 20 gwei; // Prevent MEV attacks through high gas
        emergencyTransactionDelay = 24 hours; // 24h timelock for emergency transactions
        
        // More restrictive MEV protection for new token
        mevProtection.minDepositInterval = MIN_DEPOSIT_INTERVAL_BLOCKS;
        mevProtection.maxDepositPerBlock = 50000 * 10**18; // 50k USDT per block (reduced)
        mevProtection.maxDepositPerUser = 25000 * 10**18; // 25k USDT per user per day (reduced)
        
        // More sensitive circuit breaker for new token
        circuitBreaker = CircuitBreakerLib.CircuitBreaker({
            triggered: false,
            triggerTime: 0,
            cooldownPeriod: 2 hours, // Longer cooldown for new token
            volumeThreshold: 100000 * 10**18, // Lower threshold: 100k USDT per hour
            currentVolume: 0,
            windowStart: block.timestamp,
            windowDuration: 1 hours,
            triggerCount: 0,
            updating: false,
            pendingVolume: 0
        });
    }

    // --- MODIFIERS ---
    modifier antiMEV(uint256 depositAmount) {
        _preDepositAntiMEVCheck(msg.sender, depositAmount);
        _;
        _postDepositAntiMEVUpdate(msg.sender, depositAmount);
    }

    modifier newTokenProtection(uint256 depositAmount) {
        if (newTokenMode) {
            require(depositAmount <= MAX_SINGLE_DEPOSIT_NEW_TOKEN, "Exceeds new token deposit limit");
            require(tx.gasprice <= maxGasPrice, "Gas price too high");
        }
        _;
    }

    // --- INTERNAL FUNCTIONS ---
    function _preDepositAntiMEVCheck(address user, uint256 depositAmount) internal view {
        mevProtection.checkPreDeposit(user, depositAmount);
    }

    function _postDepositAntiMEVUpdate(address user, uint256 depositAmount) internal {
        mevProtection.updatePostDeposit(user, depositAmount);
        lastDepositBlock[user] = block.number; // Update external mapping
        userTransactionCounts[user]++;
        userLastAction[user] = block.timestamp;
        userActionCount[user]++;
        totalTransactionCount++;
        totalVolumeProcessed += depositAmount;
    }

    function _checkCircuitBreaker(uint256 depositAmount) internal {
        // Use atomic check and update to prevent race conditions
        circuitBreaker.atomicCheckAndUpdate(depositAmount);
        
        emit CircuitBreakerTriggered(circuitBreaker.currentVolume, circuitBreaker.volumeThreshold);
    }

    // --- GOVERNANCE ---
    function setTreasuryWallet(address _newTreasury) external onlyRole(GOVERNANCE_ROLE) {
        require(_newTreasury != address(0), "Invalid address");
        address oldTreasury = treasuryWallet;
        treasuryWallet = _newTreasury;
        emit SecurityParametersUpdated("treasuryWallet", uint256(uint160(oldTreasury)), uint256(uint160(_newTreasury)));
    }

    function setCircuitBreakerConfig(uint256 _threshold, uint256 _cooldown, uint256 _window) external onlyRole(GOVERNANCE_ROLE) {
        require(_cooldown >= 10 minutes && _cooldown <= 24 hours, "Invalid cooldown");
        require(_window > 0 && _window <= 24 hours, "Invalid window");
        
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
        circuitBreaker.triggered = false;
        circuitBreaker.currentVolume = 0;
        circuitBreaker.windowStart = block.timestamp;
        circuitBreaker.updating = false;
        emit SecurityParametersUpdated("circuitBreakerReset", 1, 0);
    }

    function setSupportedZapToken(address _token, bool _supported) external onlyRole(GOVERNANCE_ROLE) {
        require(_token != address(0), "Invalid token");
        supportedZapTokens[_token] = _supported;
    }

    function setAntiMEVConfig(uint256 _minInterval, uint256 _maxPerBlock, uint256 _maxPerUser) external onlyRole(GOVERNANCE_ROLE) {
        require(_minInterval >= 1, "Minimum interval too low");
        require(_maxPerBlock > 0, "Max per block must be positive");
        require(_maxPerUser > 0, "Max per user must be positive");
        
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
            // Activate stricter protections
            maxSlippageBPS = 500; // 5% max slippage
            maxGasPrice = 20 gwei;
        } else {
            // Relax protections as token matures
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

    function setEmergencyTransactionDelay(uint256 _delay) external onlyRole(GOVERNANCE_ROLE) {
        if (_delay < 1 hours || _delay > 7 days) revert InvalidDelay();
        uint256 oldDelay = emergencyTransactionDelay;
        emergencyTransactionDelay = _delay;
        emit SecurityParametersUpdated("emergencyTransactionDelay", oldDelay, _delay);
    }

    // --- EMERGENCY ---
    function activateEmergencyMode() external onlyRole(EMERGENCY_ROLE) {
        emergencyModeActive = true;
        emergencyModeActivatedAt = block.timestamp;
        _pause();
        emit EmergencyModeToggled(true);
    }

    function deactivateEmergencyMode() external onlyRole(GOVERNANCE_ROLE) {
        emergencyModeActive = false;
        _unpause();
        emit EmergencyModeToggled(false);
    }

    function proposeEmergencyTransaction(address target, uint256 value, bytes calldata data) external onlyRole(EMERGENCY_ROLE) returns (bytes32) {
        require(target != address(0), "Invalid target");
        bytes32 txHash = keccak256(abi.encode(target, value, data, block.timestamp, msg.sender));
        
        emergencyTransactions[txHash] = EmergencyTransaction({
            target: target,
            value: value,
            data: data,
            executeAfter: block.timestamp + emergencyTransactionDelay,
            executed: false,
            proposer: msg.sender,
            proposedAt: block.timestamp
        });

        emit EmergencyTransactionProposed(txHash, msg.sender, target, value, data, block.timestamp + emergencyTransactionDelay);
        return txHash;
    }

    function executeEmergencyTransaction(bytes32 txHash) external onlyRole(GOVERNANCE_ROLE) {
        EmergencyTransaction storage txInfo = emergencyTransactions[txHash];
        if (txInfo.target == address(0)) revert TransactionNotFound();
        if (block.timestamp < txInfo.executeAfter) revert TimelockNotExpired();
        if (txInfo.executed) revert TransactionAlreadyExecuted();

        txInfo.executed = true;
        (bool success, ) = txInfo.target.call{value: txInfo.value}(txInfo.data);
        require(success, "Emergency transaction failed");
        
        emit EmergencyTransactionExecuted(txHash, msg.sender);
    }

    // --- VIEW FUNCTIONS ---
    function canUserDeposit(address user, uint256 amount) external view returns (bool canDeposit, string memory reason) {
        if (paused()) return (false, "Paused");
        if (emergencyModeActive) return (false, "Emergency");
        
        // New token specific checks
        if (newTokenMode) {
            if (amount > MAX_SINGLE_DEPOSIT_NEW_TOKEN) return (false, "Exceeds new token limit");
            if (tx.gasprice > maxGasPrice) return (false, "Gas price too high");
        }
        
        if (circuitBreaker.triggered && block.timestamp < circuitBreaker.triggerTime + circuitBreaker.cooldownPeriod) {
            return (false, "Circuit breaker active");
        }
        
        if (mevProtection.minDepositInterval > 0 && block.number - mevProtection.lastDepositBlock[user] < mevProtection.minDepositInterval) {
            return (false, "Deposit too frequent");
        }
        if (mevProtection.maxDepositPerBlock > 0 && mevProtection.blockDepositTotal[block.number] + amount > mevProtection.maxDepositPerBlock) {
            return (false, "Block deposit limit exceeded");
        }
        uint256 userDayStart = mevProtection.userDayStart[user];
        if (mevProtection.maxDepositPerUser > 0 && userDayStart != 0 && block.timestamp < userDayStart + 1 days) {
            if (mevProtection.userDailyVolume[user] + amount > mevProtection.maxDepositPerUser) {
                return (false, "Daily limit exceeded");
            }
        }

        return (true, "OK");
    }

    function getCircuitBreakerStatus() external view returns (
        bool triggered,
        uint256 currentVolume,
        uint256 volumeThreshold,
        uint256 triggerCount,
        uint256 timeUntilReset,
        bool updating
    ) {
        uint256 timeLeft = 0;
        if (circuitBreaker.triggered && block.timestamp < circuitBreaker.triggerTime + circuitBreaker.cooldownPeriod) {
            timeLeft = circuitBreaker.triggerTime + circuitBreaker.cooldownPeriod - block.timestamp;
        }
        
        return (
            circuitBreaker.triggered,
            circuitBreaker.currentVolume,
            circuitBreaker.volumeThreshold,
            circuitBreaker.triggerCount,
            timeLeft,
            circuitBreaker.updating
        );
    }

    function getUserMEVStatus(address user) external view returns (
        uint256 lastBlock,
        uint256 blocksSinceLastDeposit,
        bool canDepositNow,
        uint256 dailyVolumeUsed,
        uint256 dailyVolumeRemaining
    ) {
        uint256 userLastBlock = mevProtection.lastDepositBlock[user];
        uint256 blocksSince = block.number > userLastBlock ? block.number - userLastBlock : 0;
        bool canDeposit = blocksSince >= mevProtection.minDepositInterval;
        uint256 dailyUsed = mevProtection.userDailyVolume[user];
        uint256 dailyRemaining = mevProtection.maxDepositPerUser > dailyUsed ? 
            mevProtection.maxDepositPerUser - dailyUsed : 0;
        
        return (userLastBlock, blocksSince, canDeposit, dailyUsed, dailyRemaining);
    }

    function getUserStatistics(address user) external view virtual returns (
        uint256 transactionCount,
        uint256 riskScore,
        uint256 lastActionTime,
        uint256 actionsThisHour
    ) {
        return (userTransactionCounts[user], userRiskScores[user], userLastAction[user], userActionCount[user]);
    }

    function getProtocolStatistics() external view virtual returns (
        uint256 totalTransactions,
        uint256 totalVolume,
        bool emergencyActive,
        uint256 emergencyActivatedTime,
        uint256 circuitBreakerTriggers
    ) {
        return (
            totalTransactionCount,
            totalVolumeProcessed,
            emergencyModeActive,
            emergencyModeActivatedAt,
            circuitBreaker.triggerCount
        );
    }

    function getNewTokenSettings() external view returns (
        bool newTokenModeActive,
        uint256 maxGasPriceSetting,
        uint256 maxSingleDeposit,
        uint256 emergencyDelay
    ) {
        return (
            newTokenMode,
            maxGasPrice,
            MAX_SINGLE_DEPOSIT_NEW_TOKEN,
            emergencyTransactionDelay
        );
    }

    function getEmergencyTransaction(bytes32 txHash) external view returns (
        address target,
        uint256 value,
        bytes memory data,
        uint256 executeAfter,
        bool executed,
        address proposer,
        uint256 proposedAt
    ) {
        EmergencyTransaction memory txInfo = emergencyTransactions[txHash];
        return (
            txInfo.target,
            txInfo.value,
            txInfo.data,
            txInfo.executeAfter,
            txInfo.executed,
            txInfo.proposer,
            txInfo.proposedAt
        );
    }
    
    // --- UUPS UPGRADE HOOK ---
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(GOVERNANCE_ROLE) {}
}