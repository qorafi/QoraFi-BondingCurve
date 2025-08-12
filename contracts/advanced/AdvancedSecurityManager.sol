// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../core/CoreSecurityManager.sol";
import "../libraries/SecurityLibraries.sol";
import "../interfaces/SecurityInterfaces.sol";

/**
 * @title AdvancedSecurityManager
 * @notice Advanced security features that extend CoreSecurityManager with enhanced protections
 * @dev Inherits from CoreSecurityManager and adds sophisticated monitoring and new token protections
 */
contract AdvancedSecurityManager is CoreSecurityManager {
    using EmergencyLib for mapping(bytes32 => EmergencyLib.EmergencyTransaction);
    using ValidationLib for *;

    // --- ADVANCED STATE ---
    mapping(address => uint256) public userRiskScores;
    mapping(bytes32 => EmergencyLib.EmergencyTransaction) public advancedEmergencyTransactions;
    mapping(uint256 => uint256) public advancedBlockPriceUpdates; // Flash loan detection
    
    bool public advancedEmergencyModeActive;
    uint256 public advancedEmergencyModeActivatedAt;
    uint256 public advancedEmergencyTransactionDelay;
    uint256 public advancedMaxUpdatesPerBlock;
    uint256 public advancedFlashLoanDetectionWindow;
    
    // Advanced monitoring
    mapping(address => UserBehaviorData) public userBehavior;
    mapping(uint256 => DailyMetrics) public dailyMetrics;
    
    // Risk assessment
    uint256 public highRiskThreshold;
    uint256 public suspiciousActivityWindow;
    uint256 public maxTransactionsPerWindow;

    // --- STRUCTS ---
    struct UserBehaviorData {
        uint256 avgTransactionSize;
        uint256 transactionFrequency;
        uint256 lastLargeTransaction;
        uint256 suspiciousActivityCount;
        bool flagged;
    }

    struct DailyMetrics {
        uint256 totalVolume;
        uint256 uniqueUsers;
        uint256 largeTransactionCount;
        uint256 emergencyTriggeredCount;
    }

    // --- EVENTS ---
    event AdvancedEmergencyModeToggled(bool enabled);
    event AdvancedEmergencyTransactionProposed(bytes32 indexed txHash, address indexed proposer, address target, uint256 value, bytes data, uint256 executeAfter);
    event AdvancedEmergencyTransactionExecuted(bytes32 indexed txHash, address indexed executor);
    event AdvancedEmergencyTransactionCancelled(bytes32 indexed txHash, address indexed canceller);
    event UserRiskScoreUpdated(address indexed user, uint256 oldScore, uint256 newScore);
    event SuspiciousActivityDetected(address indexed user, string reason);
    event AdvancedFlashLoanDetected(uint256 blockNumber, uint256 updateCount);
    event AdvancedProtectionTriggered(string protectionType, address user, uint256 value);

    // --- ERRORS ---
    error AdvancedEmergencyModeActive();
    error AdvancedFlashLoanAttackDetected();
    error AdvancedTooManyUpdatesPerBlock();
    error HighRiskUser();
    error SuspiciousActivity();

    function initializeAdvanced(
        uint256 _emergencyTransactionDelay,
        uint256 _maxUpdatesPerBlock,
        uint256 _flashLoanDetectionWindow
    ) public onlyRole(GOVERNANCE_ROLE) {
        advancedEmergencyTransactionDelay = _emergencyTransactionDelay;
        advancedMaxUpdatesPerBlock = _maxUpdatesPerBlock;
        advancedFlashLoanDetectionWindow = _flashLoanDetectionWindow;
        
        // Advanced protection settings
        highRiskThreshold = 8000; // 80 out of 100 risk score
        suspiciousActivityWindow = 1 hours;
        maxTransactionsPerWindow = 10;
    }

    // --- ADVANCED SECURITY CHECKS ---
    function advancedPreDepositCheck(address user, uint256 amount) external {
        // Run core checks first
        this.preDepositCheck(user, amount);
        
        // Advanced checks
        _checkUserRiskScore(user);
        _checkSuspiciousActivity(user, amount);
        _checkAdvancedFlashLoanActivity();
        
        // Update behavior analysis
        _updateUserBehavior(user, amount);
    }

    function _checkUserRiskScore(address user) internal view {
        uint256 riskScore = userRiskScores[user];
        if (riskScore > highRiskThreshold) {
            revert HighRiskUser();
        }
    }

    function _checkSuspiciousActivity(address user, uint256 amount) internal view {
        UserBehaviorData memory behavior = userBehavior[user];
        
        // Check if user is flagged
        if (behavior.flagged) {
            revert SuspiciousActivity();
        }
        
        // Check transaction frequency
        uint256 recentTransactions = _getRecentTransactionCount(user);
        if (recentTransactions > maxTransactionsPerWindow) {
            revert SuspiciousActivity();
        }
        
        // Check for unusual transaction size
        if (behavior.avgTransactionSize > 0) {
            uint256 sizeRatio = (amount * 100) / behavior.avgTransactionSize;
            if (sizeRatio > 1000) { // 10x larger than average
                revert SuspiciousActivity();
            }
        }
    }

    function _checkAdvancedFlashLoanActivity() internal {
        if (newTokenMode) {
            advancedBlockPriceUpdates[block.number]++;
            if (advancedBlockPriceUpdates[block.number] > advancedMaxUpdatesPerBlock) {
                emit AdvancedFlashLoanDetected(block.number, advancedBlockPriceUpdates[block.number]);
                revert AdvancedTooManyUpdatesPerBlock();
            }
        }
    }

    function _updateUserBehavior(address user, uint256 amount) internal {
        UserBehaviorData storage behavior = userBehavior[user];
        
        // Update average transaction size
        if (behavior.avgTransactionSize == 0) {
            behavior.avgTransactionSize = amount;
        } else {
            behavior.avgTransactionSize = (behavior.avgTransactionSize * 9 + amount) / 10; // Weighted average
        }
        
        // Track large transactions
        if (amount > 100000 * 10**6) { // $100k+
            behavior.lastLargeTransaction = block.timestamp;
            dailyMetrics[_getCurrentDay()].largeTransactionCount++;
        }
        
        // Update daily metrics
        DailyMetrics storage daily = dailyMetrics[_getCurrentDay()];
        daily.totalVolume += amount;
        daily.uniqueUsers++; // Simplified - would need better unique tracking
    }

    function _getRecentTransactionCount(address user) internal view returns (uint256) {
        // Simplified implementation - would track timestamps in a more sophisticated way
        return userTransactionCounts[user];
    }

    function _getCurrentDay() internal view returns (uint256) {
        return block.timestamp / 1 days;
    }

    // --- EMERGENCY SYSTEM (FIXED: Now uses advancedEmergencyModeActive consistently) ---
    function activateAdvancedEmergencyMode() external onlyRole(EMERGENCY_ROLE) {
        advancedEmergencyModeActive = true;
        advancedEmergencyModeActivatedAt = block.timestamp;
        _pause();
        emit AdvancedEmergencyModeToggled(true);
    }

    function deactivateAdvancedEmergencyMode() external onlyRole(GOVERNANCE_ROLE) {
        advancedEmergencyModeActive = false;
        _unpause();
        emit AdvancedEmergencyModeToggled(false);
    }

    function proposeAdvancedEmergencyTransaction(
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyRole(EMERGENCY_ROLE) returns (bytes32) {
        bytes32 txHash = advancedEmergencyTransactions.proposeTransaction(
            target,
            value,
            data,
            advancedEmergencyTransactionDelay,
            msg.sender
        );

        emit AdvancedEmergencyTransactionProposed(
            txHash,
            msg.sender,
            target,
            value,
            data,
            block.timestamp + advancedEmergencyTransactionDelay
        );
        
        return txHash;
    }

    function executeAdvancedEmergencyTransaction(bytes32 txHash) external onlyRole(GOVERNANCE_ROLE) {
        bool success = advancedEmergencyTransactions.executeTransaction(txHash);
        require(success, "Emergency transaction failed");
        
        emit AdvancedEmergencyTransactionExecuted(txHash, msg.sender);
    }

    function cancelAdvancedEmergencyTransaction(bytes32 txHash) external onlyRole(GOVERNANCE_ROLE) {
        advancedEmergencyTransactions.cancelTransaction(txHash);
        emit AdvancedEmergencyTransactionCancelled(txHash, msg.sender);
    }

    // --- RISK MANAGEMENT ---
    function updateUserRiskScore(address user, uint256 newScore) external onlyRole(MONITOR_ROLE) {
        require(newScore <= 10000, "Invalid risk score"); // 0-100 scale with 2 decimals
        uint256 oldScore = userRiskScores[user];
        userRiskScores[user] = newScore;
        emit UserRiskScoreUpdated(user, oldScore, newScore);
    }

    function flagUser(address user, bool flagged, string calldata reason) external onlyRole(MONITOR_ROLE) {
        userBehavior[user].flagged = flagged;
        if (flagged) {
            userBehavior[user].suspiciousActivityCount++;
            emit SuspiciousActivityDetected(user, reason);
        }
    }

    function batchUpdateRiskScores(
        address[] calldata users,
        uint256[] calldata scores
    ) external onlyRole(MONITOR_ROLE) {
        require(users.length == scores.length, "Array length mismatch");
        
        for (uint256 i = 0; i < users.length; i++) {
            require(scores[i] <= 10000, "Invalid risk score");
            uint256 oldScore = userRiskScores[users[i]];
            userRiskScores[users[i]] = scores[i];
            emit UserRiskScoreUpdated(users[i], oldScore, scores[i]);
        }
    }

    // --- ADVANCED GOVERNANCE ---
    function setAdvancedParameters(
        uint256 _highRiskThreshold,
        uint256 _suspiciousActivityWindow,
        uint256 _maxTransactionsPerWindow
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(_highRiskThreshold <= 10000, "Invalid threshold");
        require(_suspiciousActivityWindow <= 24 hours, "Invalid window");
        require(_maxTransactionsPerWindow > 0, "Invalid max transactions");
        
        highRiskThreshold = _highRiskThreshold;
        suspiciousActivityWindow = _suspiciousActivityWindow;
        maxTransactionsPerWindow = _maxTransactionsPerWindow;
    }

    function setFlashLoanProtection(
        uint256 _maxUpdatesPerBlock,
        uint256 _detectionWindow
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(_maxUpdatesPerBlock > 0, "Invalid max updates");
        require(_detectionWindow > 0, "Invalid detection window");
        
        advancedMaxUpdatesPerBlock = _maxUpdatesPerBlock;
        advancedFlashLoanDetectionWindow = _detectionWindow;
    }

    function setAdvancedEmergencyTransactionDelay(uint256 _delay) external onlyRole(GOVERNANCE_ROLE) {
        ValidationLib.validateDelay(_delay, 1 hours, 7 days);
        uint256 oldDelay = advancedEmergencyTransactionDelay;
        advancedEmergencyTransactionDelay = _delay;
        emit SecurityParametersUpdated("advancedEmergencyTransactionDelay", oldDelay, _delay);
    }

    // --- ADVANCED VIEW FUNCTIONS ---
    function getUserRiskAssessment(address user) external view returns (
        uint256 riskScore,
        bool flagged,
        uint256 avgTransactionSize,
        uint256 suspiciousActivityCount,
        bool canTransact
    ) {
        UserBehaviorData memory behavior = userBehavior[user];
        return (
            userRiskScores[user],
            behavior.flagged,
            behavior.avgTransactionSize,
            behavior.suspiciousActivityCount,
            userRiskScores[user] <= highRiskThreshold && !behavior.flagged
        );
    }

    function getDailyMetrics(uint256 day) external view returns (
        uint256 totalVolume,
        uint256 uniqueUsers,
        uint256 largeTransactionCount,
        uint256 emergencyTriggeredCount
    ) {
        DailyMetrics memory metrics = dailyMetrics[day];
        return (
            metrics.totalVolume,
            metrics.uniqueUsers,
            metrics.largeTransactionCount,
            metrics.emergencyTriggeredCount
        );
    }

    function getAdvancedSettings() external view returns (
        uint256 highRiskThresholdSetting,
        uint256 suspiciousActivityWindowSetting,
        uint256 maxTransactionsPerWindowSetting,
        uint256 emergencyDelaySettings,
        bool emergencyModeActiveSetting
    ) {
        return (
            highRiskThreshold,
            suspiciousActivityWindow,
            maxTransactionsPerWindow,
            advancedEmergencyTransactionDelay,
            advancedEmergencyModeActive
        );
    }

    function getAdvancedEmergencyTransaction(bytes32 txHash) external view returns (
        address target,
        uint256 value,
        bytes memory data,
        uint256 executeAfter,
        bool executed,
        address proposer,
        uint256 proposedAt
    ) {
        return advancedEmergencyTransactions.getTransaction(txHash);
    }

    function getFlashLoanProtectionStatus() external view returns (
        uint256 currentBlockUpdates,
        uint256 maxAllowedUpdates,
        uint256 detectionWindow,
        bool protectionActive
    ) {
        return (
            advancedBlockPriceUpdates[block.number],
            advancedMaxUpdatesPerBlock,
            advancedFlashLoanDetectionWindow,
            newTokenMode
        );
    }

    // --- OVERRIDE FOR EMERGENCY MODE (FIXED: Now consistent with variable name) ---
    function isEmergencyMode() external view override returns (bool) {
        return advancedEmergencyModeActive;
    }

    // Enhanced user deposit check with advanced features
    function canUserDeposit(address user, uint256 amount) external view override returns (bool canDeposit, string memory reason) {
        // Run basic checks first
        (bool basicCheck, string memory basicReason) = super.canUserDeposit(user, amount);
        if (!basicCheck) return (false, basicReason);
        
        // Emergency mode check
        if (advancedEmergencyModeActive) return (false, "Advanced emergency mode active");
        
        // Risk score check
        if (userRiskScores[user] > highRiskThreshold) return (false, "High risk user");
        
        // Flagged user check
        if (userBehavior[user].flagged) return (false, "User flagged for suspicious activity");
        
        // Flash loan protection
        if (newTokenMode && advancedBlockPriceUpdates[block.number] >= advancedMaxUpdatesPerBlock) {
            return (false, "Flash loan protection triggered");
        }
        
        return (true, "OK");
    }
}