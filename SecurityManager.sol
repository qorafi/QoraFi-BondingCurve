// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title SecurityManager (Enhanced)
 * @notice A modular base contract for security features with improved configurability and monitoring
 * @dev Designed to be inherited by other core protocol contracts with enhanced security measures
 */
contract SecurityManager is AccessControl, Pausable, ReentrancyGuard {
    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant MONITOR_ROLE = keccak256("MONITOR_ROLE");

    // --- CONSTANTS ---
    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant MIN_EMERGENCY_DELAY = 6 hours;
    uint256 public constant MAX_EMERGENCY_DELAY = 7 days;
    uint256 public constant MIN_COOLDOWN_PERIOD = 10 minutes;
    uint256 public constant MAX_COOLDOWN_PERIOD = 24 hours;
    uint256 public constant MAX_BLOCK_INTERVAL = 100;
    uint256 public constant MAX_VOLUME_WINDOW = 24 hours;

    // --- STRUCTS ---
    struct CircuitBreaker {
        bool triggered;
        uint256 triggerTime;
        uint256 cooldownPeriod;
        uint256 volumeThreshold;
        uint256 currentVolume;
        uint256 windowStart;
        uint256 windowDuration;
        uint256 triggerCount;
        uint256 lastResetTime;
    }
    
    struct EmergencyTransaction {
        address target;
        uint256 value;
        bytes data;
        uint256 executeAfter;
        bool executed;
        address proposer;
        uint256 proposalTime;
        string description;
    }

    struct MEVProtection {
        uint256 minDepositInterval;
        uint256 maxDepositPerBlock;
        uint256 maxDepositPerUser;
        uint256 maxDailyVolume;
        mapping(address => uint256) lastDepositBlock;
        mapping(address => uint256) userDailyVolume;
        mapping(address => uint256) userDayStart;
        mapping(uint256 => uint256) blockDepositTotal;
    }

    // --- STATE VARIABLES ---
    IERC20 public usdtToken;
    IERC20 public qorafiToken;
    address public treasuryWallet;
    
    // Configurable Parameters
    uint256 public liquidityRatioBPS;
    uint256 public maxSlippageBPS;

    // Enhanced Security Features
    MEVProtection private mevProtection;
    mapping(bytes32 => EmergencyTransaction) public emergencyTransactions;
    CircuitBreaker public circuitBreaker;
    mapping(address => bool) public supportedZapTokens;
    mapping(address => uint256) public userRiskScores;
    
    // Emergency and Monitoring
    string public pauseReason;
    uint256 public emergencyDelayPeriod;
    bool public emergencyModeActive;
    uint256 public emergencyModeActivatedAt;
    
    // Monitoring and Analytics
    uint256 public totalTransactionCount;
    uint256 public totalVolumeProcessed;
    mapping(address => uint256) public userTransactionCounts;
    
    // Rate Limiting
    mapping(address => uint256) public userLastAction;
    mapping(address => uint256) public userActionCount;
    uint256 public globalRateLimit;
    uint256 public userRateLimit;

    // --- EVENTS ---
    event EmergencyModeToggled(bool enabled, string reason);
    event EmergencyTransactionQueued(bytes32 indexed txHash, address indexed proposer, address target, uint256 value, string description);
    event EmergencyTransactionExecuted(bytes32 indexed txHash, address indexed executor);
    event EmergencyTransactionCancelled(bytes32 indexed txHash, address indexed canceller);
    event AntiMEVConfigUpdated(uint256 newMinInterval, uint256 newMaxPerBlock, uint256 newMaxPerUser);
    event ZapTokenUpdated(address indexed token, bool isSupported);
    event CircuitBreakerTriggered(uint256 volume, uint256 threshold, uint256 triggerCount);
    event CircuitBreakerReset(address indexed resetter, uint256 triggerCount);
    event TreasuryWalletUpdated(address indexed oldTreasury, address indexed newTreasury);
    event ParametersInitialized(uint256 liquidityRatio, uint256 maxSlippage);
    event LiquidityRatioUpdated(uint256 oldRatio, uint256 newRatio);
    event MaxSlippageUpdated(uint256 oldSlippage, uint256 newSlippage);
    event CircuitBreakerConfigUpdated(uint256 volumeThreshold, uint256 cooldownPeriod, uint256 windowDuration);
    event PausedWithReason(string reason, address indexed pauser);
    event UserRiskScoreUpdated(address indexed user, uint256 oldScore, uint256 newScore);
    event RateLimitExceeded(address indexed user, uint256 attemptedAction, uint256 limit);
    event EmergencyDelayUpdated(uint256 oldDelay, uint256 newDelay);

    // --- ERRORS ---
    error InvalidAddress();
    error DepositTooFrequent();
    error DepositTooLarge();
    error BlockDepositLimitExceeded();
    error DailyLimitExceeded();
    error CircuitBreakerActive();
    error TokenNotSupported();
    error InvalidAmount();
    error DeadlineExpired();
    error InvalidSlippage();
    error EmergencyModeActive();
    error InvalidDelayPeriod();
    error RateLimitExceeded();
    error InvalidRiskScore();
    error TransactionNotFound();
    error TransactionAlreadyExecuted();
    error TimelockNotExpired();
    error UnauthorizedCancellation();

    // --- CONSTRUCTOR ---
    constructor(
        address _usdtTokenAddress, 
        address _qorafiTokenAddress, 
        address _initialTreasuryWallet
    ) {
        require(_usdtTokenAddress != address(0), "SecurityManager: Invalid USDT address");
        require(_qorafiTokenAddress != address(0), "SecurityManager: Invalid QoraFi address");
        require(_initialTreasuryWallet != address(0), "SecurityManager: Invalid treasury address");
        
        usdtToken = IERC20(_usdtTokenAddress);
        qorafiToken = IERC20(_qorafiTokenAddress);
        treasuryWallet = _initialTreasuryWallet;

        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(MONITOR_ROLE, msg.sender);

        liquidityRatioBPS = 5000;
        maxSlippageBPS = 300;
        emergencyDelayPeriod = 24 hours;
        
        mevProtection.minDepositInterval = 3;
        mevProtection.maxDepositPerBlock = 100000 * 10**6;
        mevProtection.maxDepositPerUser = 50000 * 10**6;
        mevProtection.maxDailyVolume = 1000000 * 10**6;
        
        circuitBreaker = CircuitBreaker({
            triggered: false,
            triggerTime: 0,
            cooldownPeriod: 1 hours,
            volumeThreshold: 500000 * 10**6,
            currentVolume: 0,
            windowStart: block.timestamp,
            windowDuration: 1 hours,
            triggerCount: 0,
            lastResetTime: block.timestamp
        });

        globalRateLimit = 100;
        userRateLimit = 10;

        emit ParametersInitialized(liquidityRatioBPS, maxSlippageBPS);
    }

    // --- MODIFIERS ---
    modifier antiMEV(uint256 depositAmount) {
        _preDepositAntiMEVCheck(msg.sender, depositAmount);
        _;
        _postDepositAntiMEVUpdate(msg.sender, depositAmount);
    }

    modifier onlyWhenNotEmergency() {
        if (emergencyModeActive) revert EmergencyModeActive();
        _;
    }

    modifier rateLimited() {
        _checkRateLimit(msg.sender);
        _;
        _updateRateLimit(msg.sender);
    }

    // --- ENHANCED SECURITY HELPERS ---
    function _preDepositAntiMEVCheck(address user, uint256 depositAmount) internal view {
        if (mevProtection.minDepositInterval > 0 && 
            block.number - mevProtection.lastDepositBlock[user] < mevProtection.minDepositInterval) {
            revert DepositTooFrequent();
        }
        
        if (mevProtection.maxDepositPerBlock > 0 && 
            mevProtection.blockDepositTotal[block.number] + depositAmount > mevProtection.maxDepositPerBlock) {
            revert BlockDepositLimitExceeded();
        }

        if (mevProtection.maxDepositPerUser > 0) {
            uint256 userDayStart = mevProtection.userDayStart[user];
            if (block.timestamp >= userDayStart + 1 days) {
                // Reset counter for new day - this will be updated in post check
            } else {
                uint256 userDailyVolume = mevProtection.userDailyVolume[user];
                if (userDailyVolume + depositAmount > mevProtection.maxDepositPerUser) {
                    revert DailyLimitExceeded();
                }
            }
        }
    }

    function _postDepositAntiMEVUpdate(address user, uint256 depositAmount) internal {
        mevProtection.lastDepositBlock[user] = block.number;
        mevProtection.blockDepositTotal[block.number] += depositAmount;
        
        if (block.timestamp >= mevProtection.userDayStart[user] + 1 days) {
            mevProtection.userDayStart[user] = block.timestamp;
            mevProtection.userDailyVolume[user] = depositAmount;
        } else {
            mevProtection.userDailyVolume[user] += depositAmount;
        }

        userTransactionCounts[user]++;
        totalTransactionCount++;
        totalVolumeProcessed += depositAmount;
    }

    function _checkCircuitBreaker(uint256 depositAmount) internal {
        CircuitBreaker storage cb = circuitBreaker;
        
        if (block.timestamp > cb.windowStart + cb.windowDuration) {
            cb.currentVolume = 0;
            cb.windowStart = block.timestamp;
        }

        if (cb.triggered) {
            if (block.timestamp < cb.triggerTime + cb.cooldownPeriod) {
                revert CircuitBreakerActive();
            } else {
                cb.triggered = false;
            }
        }

        uint256 newVolume = cb.currentVolume + depositAmount;
        if (cb.volumeThreshold > 0 && newVolume > cb.volumeThreshold) {
            cb.triggered = true;
            cb.triggerTime = block.timestamp;
            cb.triggerCount++;
            
            emit CircuitBreakerTriggered(newVolume, cb.volumeThreshold, cb.triggerCount);
            revert CircuitBreakerActive();
        }
        
        cb.currentVolume = newVolume;
    }

    function _checkRateLimit(address user) internal view {
        uint256 hourStart = block.timestamp - (block.timestamp % 1 hours);
        
        if (userLastAction[user] >= hourStart && userActionCount[user] >= userRateLimit) {
            revert RateLimitExceeded();
        }
    }

    function _updateRateLimit(address user) internal {
        uint256 hourStart = block.timestamp - (block.timestamp % 1 hours);
        
        if (userLastAction[user] < hourStart) {
            userActionCount[user] = 1;
        } else {
            userActionCount[user]++;
        }
        userLastAction[user] = block.timestamp;
    }

    // --- ENHANCED GOVERNANCE FUNCTIONS ---
    function setTreasuryWallet(address _newTreasury) external onlyRole(GOVERNANCE_ROLE) {
        require(_newTreasury != address(0), "SecurityManager: Invalid treasury address");
        address oldTreasury = treasuryWallet;
        treasuryWallet = _newTreasury;
        emit TreasuryWalletUpdated(oldTreasury, _newTreasury);
    }

    function setCircuitBreakerConfig(
        uint256 _volumeThreshold, 
        uint256 _cooldownPeriod,
        uint256 _windowDuration
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(_cooldownPeriod >= MIN_COOLDOWN_PERIOD && _cooldownPeriod <= MAX_COOLDOWN_PERIOD, 
            "SecurityManager: Invalid cooldown period");
        require(_windowDuration > 0 && _windowDuration <= MAX_VOLUME_WINDOW,
            "SecurityManager: Invalid window duration");
            
        circuitBreaker.volumeThreshold = _volumeThreshold;
        circuitBreaker.cooldownPeriod = _cooldownPeriod;
        circuitBreaker.windowDuration = _windowDuration;
        
        emit CircuitBreakerConfigUpdated(_volumeThreshold, _cooldownPeriod, _windowDuration);
    }

    function resetCircuitBreaker() external onlyRole(GOVERNANCE_ROLE) {
        uint256 oldTriggerCount = circuitBreaker.triggerCount;
        circuitBreaker.triggered = false;
        circuitBreaker.currentVolume = 0;
        circuitBreaker.windowStart = block.timestamp;
        circuitBreaker.lastResetTime = block.timestamp;
        
        emit CircuitBreakerReset(msg.sender, oldTriggerCount);
    }

    function setSupportedZapToken(address _token, bool _supported) external onlyRole(GOVERNANCE_ROLE) {
        require(_token != address(0), "SecurityManager: Invalid token address");
        supportedZapTokens[_token] = _supported;
        emit ZapTokenUpdated(_token, _supported);
    }

    function setAntiMEVConfig(
        uint256 _minInterval, 
        uint256 _maxPerBlock,
        uint256 _maxPerUser
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(_minInterval <= MAX_BLOCK_INTERVAL, "SecurityManager: Interval too large");
        
        mevProtection.minDepositInterval = _minInterval;
        mevProtection.maxDepositPerBlock = _maxPerBlock;
        mevProtection.maxDepositPerUser = _maxPerUser;
        
        emit AntiMEVConfigUpdated(_minInterval, _maxPerBlock, _maxPerUser);
    }

    function setUserRiskScore(address _user, uint256 _score) external onlyRole(MONITOR_ROLE) {
        require(_user != address(0), "SecurityManager: Invalid user address");
        require(_score <= 100, "SecurityManager: Invalid risk score");
        
        uint256 oldScore = userRiskScores[_user];
        userRiskScores[_user] = _score;
        
        emit UserRiskScoreUpdated(_user, oldScore, _score);
    }

    function setEmergencyDelay(uint256 _newDelay) external onlyRole(GOVERNANCE_ROLE) {
        require(_newDelay >= MIN_EMERGENCY_DELAY && _newDelay <= MAX_EMERGENCY_DELAY,
            "SecurityManager: Invalid emergency delay");
            
        uint256 oldDelay = emergencyDelayPeriod;
        emergencyDelayPeriod = _newDelay;
        
        emit EmergencyDelayUpdated(oldDelay, _newDelay);
    }

    function setRateLimits(uint256 _globalLimit, uint256 _userLimit) external onlyRole(GOVERNANCE_ROLE) {
        globalRateLimit = _globalLimit;
        userRateLimit = _userLimit;
    }

    // --- ENHANCED EMERGENCY FUNCTIONS ---
    function queueEmergencyTransaction(
        address target, 
        uint256 value, 
        bytes calldata data,
        string calldata description
    ) external onlyRole(EMERGENCY_ROLE) returns (bytes32) {
        require(target != address(0), "SecurityManager: Invalid target");
        require(bytes(description).length > 0, "SecurityManager: Description required");
        
        bytes32 txHash = keccak256(abi.encode(target, value, data, block.timestamp, block.number, msg.sender));
        require(emergencyTransactions[txHash].target == address(0), "SecurityManager: Transaction already exists");
        
        emergencyTransactions[txHash] = EmergencyTransaction({
            target: target,
            value: value,
            data: data,
            executeAfter: block.timestamp + emergencyDelayPeriod,
            executed: false,
            proposer: msg.sender,
            proposalTime: block.timestamp,
            description: description
        });
        
        emit EmergencyTransactionQueued(txHash, msg.sender, target, value, description);
        return txHash;
    }

    function executeEmergencyTransaction(bytes32 txHash) external onlyRole(EMERGENCY_ROLE) {
        EmergencyTransaction storage txInfo = emergencyTransactions[txHash];
        if (txInfo.target == address(0)) revert TransactionNotFound();
        if (block.timestamp < txInfo.executeAfter) revert TimelockNotExpired();
        if (txInfo.executed) revert TransactionAlreadyExecuted();

        txInfo.executed = true;
        (bool success, ) = txInfo.target.call{value: txInfo.value}(txInfo.data);
        require(success, "SecurityManager: Emergency transaction failed");
        
        emit EmergencyTransactionExecuted(txHash, msg.sender);
    }

    function cancelEmergencyTransaction(bytes32 txHash) external {
        EmergencyTransaction storage txInfo = emergencyTransactions[txHash];
        if (txInfo.target == address(0)) revert TransactionNotFound();
        if (txInfo.executed) revert TransactionAlreadyExecuted();
        
        if (msg.sender != txInfo.proposer && !hasRole(GOVERNANCE_ROLE, msg.sender)) {
            revert UnauthorizedCancellation();
        }

        delete emergencyTransactions[txHash];
        emit EmergencyTransactionCancelled(txHash, msg.sender);
    }

    function activateEmergencyMode(string calldata reason) external onlyRole(EMERGENCY_ROLE) {
        emergencyModeActive = true;
        emergencyModeActivatedAt = block.timestamp;
        pauseReason = reason;
        _pause();
        emit EmergencyModeToggled(true, reason);
    }

    function deactivateEmergencyMode() external onlyRole(GOVERNANCE_ROLE) {
        emergencyModeActive = false;
        pauseReason = "";
        _unpause();
        emit EmergencyModeToggled(false, "Deactivated by governance");
    }

    function emergencyPause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function emergencyUnpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function emergencyPauseWithReason(string calldata reason) external onlyRole(PAUSER_ROLE) {
        pauseReason = reason;
        _pause();
        emit PausedWithReason(reason, msg.sender);
    }

    function emergencyUnpauseAndClearReason() external onlyRole(PAUSER_ROLE) {
        pauseReason = "";
        _unpause();
    }

    // --- ENHANCED VIEW FUNCTIONS ---
    function getCircuitBreakerStatus() external view returns (
        bool triggered,
        uint256 triggerTime,
        uint256 currentVolume,
        uint256 volumeThreshold,
        uint256 timeUntilReset,
        uint256 windowStart,
        uint256 triggerCount,
        uint256 windowDuration
    ) {
        uint256 timeLeft = 0;
        if (circuitBreaker.triggered && block.timestamp < circuitBreaker.triggerTime + circuitBreaker.cooldownPeriod) {
            timeLeft = (circuitBreaker.triggerTime + circuitBreaker.cooldownPeriod) - block.timestamp;
        }
        
        return (
            circuitBreaker.triggered,
            circuitBreaker.triggerTime,
            circuitBreaker.currentVolume,
            circuitBreaker.volumeThreshold,
            timeLeft,
            circuitBreaker.windowStart,
            circuitBreaker.triggerCount,
            circuitBreaker.windowDuration
        );
    }

    function canUserDeposit(address user, uint256 amount) external view returns (bool canDeposit, string memory reason) {
        if (paused()) {
            return (false, "Contract paused");
        }
        
        if (emergencyModeActive) {
            return (false, "Emergency mode active");
        }
        
        if (circuitBreaker.triggered) {
            if (block.timestamp < circuitBreaker.triggerTime + circuitBreaker.cooldownPeriod) {
                return (false, "Circuit breaker active");
            }
        }
        
        if (mevProtection.minDepositInterval > 0 && 
            block.number - mevProtection.lastDepositBlock[user] < mevProtection.minDepositInterval) {
            return (false, "Deposit too frequent");
        }
        
        if (mevProtection.maxDepositPerBlock > 0 && 
            mevProtection.blockDepositTotal[block.number] + amount > mevProtection.maxDepositPerBlock) {
            return (false, "Block deposit limit exceeded");
        }

        if (mevProtection.maxDepositPerUser > 0) {
            uint256 userDayStart = mevProtection.userDayStart[user];
            if (block.timestamp < userDayStart + 1 days) {
                if (mevProtection.userDailyVolume[user] + amount > mevProtection.maxDepositPerUser) {
                    return (false, "Daily user limit exceeded");
                }
            }
        }
        
        uint256 newVolume = circuitBreaker.currentVolume + amount;
        if (circuitBreaker.volumeThreshold > 0 && newVolume > circuitBreaker.volumeThreshold) {
            return (false, "Would trigger circuit breaker");
        }
        
        return (true, "Can deposit");
    }

    function getConfiguration() external view returns (
        uint256 liquidityRatio,
        uint256 maxSlippage,
        uint256 minInterval,
        uint256 maxPerBlock,
        uint256 maxPerUser,
        address treasury,
        uint256 emergencyDelay
    ) {
        return (
            liquidityRatioBPS,
            maxSlippageBPS,
            mevProtection.minDepositInterval,
            mevProtection.maxDepositPerBlock,
            mevProtection.maxDepositPerUser,
            treasuryWallet,
            emergencyDelayPeriod
        );
    }

    function getUserMEVStatus(address user) external view returns (
        uint256 lastBlock,
        uint256 blocksSinceLastDeposit,
        bool canDepositNow,
        uint256 dailyVolumeUsed,
        uint256 dailyVolumeLimit,
        uint256 dayStartTime
    ) {
        uint256 lastUserBlock = mevProtection.lastDepositBlock[user];
        uint256 blocksSince = block.number > lastUserBlock ? block.number - lastUserBlock : 0;
        bool canDeposit = mevProtection.minDepositInterval == 0 || blocksSince >= mevProtection.minDepositInterval;
        
        return (
            lastUserBlock, 
            blocksSince, 
            canDeposit,
            mevProtection.userDailyVolume[user],
            mevProtection.maxDepositPerUser,
            mevProtection.userDayStart[user]
        );
    }

    function getCurrentBlockDepositStatus() external view returns (
        uint256 currentBlockDeposits,
        uint256 maxAllowed,
        uint256 remainingCapacity
    ) {
        uint256 currentDeposits = mevProtection.blockDepositTotal[block.number];
        uint256 remaining = mevProtection.maxDepositPerBlock > currentDeposits ? 
            mevProtection.maxDepositPerBlock - currentDeposits : 0;
        
        return (currentDeposits, mevProtection.maxDepositPerBlock, remaining);
    }

    function getUserRoles(address user) external view returns (
        bool isGovernance,
        bool isPauser,
        bool isEmergency,
        bool isMonitor
    ) {
        return (
            hasRole(GOVERNANCE_ROLE, user),
            hasRole(PAUSER_ROLE, user),
            hasRole(EMERGENCY_ROLE, user),
            hasRole(MONITOR_ROLE, user)
        );
    }

    function getProtocolStatistics() external view returns (
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

    function getUserStatistics(address user) external view returns (
        uint256 transactionCount,
        uint256 riskScore,
        uint256 lastActionTime,
        uint256 actionsThisHour
    ) {
        return (
            userTransactionCounts[user],
            userRiskScores[user],
            userLastAction[user],
            userActionCount[user]
        );
    }

    function getEmergencyTransaction(bytes32 txHash) external view returns (EmergencyTransaction memory) {
        return emergencyTransactions[txHash];
    }
}