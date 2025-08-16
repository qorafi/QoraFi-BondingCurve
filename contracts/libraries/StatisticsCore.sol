// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title StatisticsCore
 * @notice Core statistics tracking functionality
 */

// --- STATISTICS LIBRARY ---
library StatisticsLib {
    struct UserStats {
        uint256 transactionCount;
        uint256 totalVolume;
        uint256 lastTransactionTime;
        uint256 lastTransactionBlock;
        uint256 firstTransactionTime;
        uint256 averageTransactionSize;
        uint256 maxTransactionSize;
        uint256 minTransactionSize;
    }

    struct ProtocolStats {
        uint256 totalTransactions;
        uint256 totalVolume;
        uint256 uniqueUsers;
        uint256 lastUpdateTime;
        uint256 dailyVolume;
        uint256 dailyTransactions;
        uint256 lastDayReset;
        uint256 peakDailyVolume;
        uint256 peakDailyTransactions;
    }

    struct TimeWindowStats {
        uint256 windowStart;
        uint256 windowDuration;
        uint256 windowVolume;
        uint256 windowTransactions;
        uint256 maxVolumeInWindow;
        uint256 minVolumeInWindow;
    }

    /**
     * @notice Updates running statistics for a user
     * @param userStats Mapping of user statistics
     * @param user User address
     * @param amount Transaction amount
     */
    function updateUserStats(
        mapping(address => UserStats) storage userStats,
        address user,
        uint256 amount
    ) internal {
        UserStats storage stats = userStats[user];
        
        // First transaction
        if (stats.transactionCount == 0) {
            stats.firstTransactionTime = block.timestamp;
            stats.minTransactionSize = amount;
            stats.maxTransactionSize = amount;
        } else {
            // Update min/max
            if (amount < stats.minTransactionSize) {
                stats.minTransactionSize = amount;
            }
            if (amount > stats.maxTransactionSize) {
                stats.maxTransactionSize = amount;
            }
        }
        
        // Update counters
        stats.transactionCount++;
        stats.totalVolume += amount;
        stats.lastTransactionTime = block.timestamp;
        stats.lastTransactionBlock = block.number;
        
        // Update average
        stats.averageTransactionSize = stats.totalVolume / stats.transactionCount;
    }

    /**
     * @notice Updates protocol-wide statistics
     * @param protocolStats Protocol statistics storage
     * @param amount Transaction amount
     * @param userCount Current user count
     */
    function updateProtocolStats(
        ProtocolStats storage protocolStats,
        uint256 amount,
        uint256 userCount
    ) internal {
        // Check if we need to reset daily stats
        uint256 currentDay = block.timestamp / 86400;
        uint256 lastDay = protocolStats.lastDayReset / 86400;
        
        if (currentDay > lastDay) {
            // Store peak values before reset
            if (protocolStats.dailyVolume > protocolStats.peakDailyVolume) {
                protocolStats.peakDailyVolume = protocolStats.dailyVolume;
            }
            if (protocolStats.dailyTransactions > protocolStats.peakDailyTransactions) {
                protocolStats.peakDailyTransactions = protocolStats.dailyTransactions;
            }
            
            // Reset daily stats
            protocolStats.dailyVolume = 0;
            protocolStats.dailyTransactions = 0;
            protocolStats.lastDayReset = block.timestamp;
        }
        
        // Update all stats
        protocolStats.totalTransactions++;
        protocolStats.totalVolume += amount;
        protocolStats.uniqueUsers = userCount;
        protocolStats.lastUpdateTime = block.timestamp;
        protocolStats.dailyVolume += amount;
        protocolStats.dailyTransactions++;
    }

    /**
     * @notice Updates time window statistics
     * @param windowStats Time window statistics storage
     * @param amount Transaction amount
     */
    function updateTimeWindowStats(
        TimeWindowStats storage windowStats,
        uint256 amount
    ) internal {
        // Check if window has expired
        if (block.timestamp > windowStats.windowStart + windowStats.windowDuration) {
            // Reset window
            windowStats.windowStart = block.timestamp;
            windowStats.windowVolume = amount;
            windowStats.windowTransactions = 1;
            windowStats.maxVolumeInWindow = amount;
            windowStats.minVolumeInWindow = amount;
        } else {
            // Update existing window
            windowStats.windowVolume += amount;
            windowStats.windowTransactions++;
            
            if (amount > windowStats.maxVolumeInWindow) {
                windowStats.maxVolumeInWindow = amount;
            }
            if (amount < windowStats.minVolumeInWindow) {
                windowStats.minVolumeInWindow = amount;
            }
        }
    }

    /**
     * @notice Gets user statistics
     * @param userStats Mapping of user statistics
     * @param user User address
     * @return transactionCount Number of transactions
     * @return totalVolume Total volume transacted
     * @return lastTransactionTime Last transaction timestamp
     * @return lastTransactionBlock Last transaction block
     * @return firstTransactionTime First transaction timestamp
     * @return averageTransactionSize Average transaction size
     * @return maxTransactionSize Maximum transaction size
     * @return minTransactionSize Minimum transaction size
     */
    function getUserStats(
        mapping(address => UserStats) storage userStats,
        address user
    ) internal view returns (
        uint256 transactionCount,
        uint256 totalVolume,
        uint256 lastTransactionTime,
        uint256 lastTransactionBlock,
        uint256 firstTransactionTime,
        uint256 averageTransactionSize,
        uint256 maxTransactionSize,
        uint256 minTransactionSize
    ) {
        UserStats storage stats = userStats[user];
        return (
            stats.transactionCount,
            stats.totalVolume,
            stats.lastTransactionTime,
            stats.lastTransactionBlock,
            stats.firstTransactionTime,
            stats.averageTransactionSize,
            stats.maxTransactionSize,
            stats.minTransactionSize
        );
    }

    /**
     * @notice Gets protocol statistics
     * @param protocolStats Protocol statistics storage
     * @return totalTransactions Total number of transactions
     * @return totalVolume Total volume
     * @return uniqueUsers Number of unique users
     * @return lastUpdateTime Last update timestamp
     * @return dailyVolume Today's volume
     * @return dailyTransactions Today's transactions
     * @return peakDailyVolume Peak daily volume
     * @return peakDailyTransactions Peak daily transactions
     */
    function getProtocolStats(
        ProtocolStats storage protocolStats
    ) internal view returns (
        uint256 totalTransactions,
        uint256 totalVolume,
        uint256 uniqueUsers,
        uint256 lastUpdateTime,
        uint256 dailyVolume,
        uint256 dailyTransactions,
        uint256 peakDailyVolume,
        uint256 peakDailyTransactions
    ) {
        return (
            protocolStats.totalTransactions,
            protocolStats.totalVolume,
            protocolStats.uniqueUsers,
            protocolStats.lastUpdateTime,
            protocolStats.dailyVolume,
            protocolStats.dailyTransactions,
            protocolStats.peakDailyVolume,
            protocolStats.peakDailyTransactions
        );
    }

    /**
     * @notice Gets time window statistics
     * @param windowStats Time window statistics storage
     * @return windowStart Window start timestamp
     * @return windowDuration Window duration
     * @return windowVolume Volume in current window
     * @return windowTransactions Transactions in current window
     * @return maxVolumeInWindow Max volume in window
     * @return minVolumeInWindow Min volume in window
     * @return timeRemaining Time remaining in window
     */
    function getTimeWindowStats(
        TimeWindowStats storage windowStats
    ) internal view returns (
        uint256 windowStart,
        uint256 windowDuration,
        uint256 windowVolume,
        uint256 windowTransactions,
        uint256 maxVolumeInWindow,
        uint256 minVolumeInWindow,
        uint256 timeRemaining
    ) {
        uint256 windowEnd = windowStats.windowStart + windowStats.windowDuration;
        uint256 remaining = block.timestamp < windowEnd ? windowEnd - block.timestamp : 0;
        
        return (
            windowStats.windowStart,
            windowStats.windowDuration,
            windowStats.windowVolume,
            windowStats.windowTransactions,
            windowStats.maxVolumeInWindow,
            windowStats.minVolumeInWindow,
            remaining
        );
    }

    /**
     * @notice Calculates user activity metrics
     * @param userStats Mapping of user statistics
     * @param user User address
     * @return daysSinceFirst Days since first transaction
     * @return daysSinceLast Days since last transaction
     * @return avgTransactionsPerDay Average transactions per day
     * @return avgVolumePerDay Average volume per day
     */
    function getUserActivityMetrics(
        mapping(address => UserStats) storage userStats,
        address user
    ) internal view returns (
        uint256 daysSinceFirst,
        uint256 daysSinceLast,
        uint256 avgTransactionsPerDay,
        uint256 avgVolumePerDay
    ) {
        UserStats storage stats = userStats[user];
        
        if (stats.transactionCount == 0) {
            return (0, 0, 0, 0);
        }
        
        daysSinceFirst = (block.timestamp - stats.firstTransactionTime) / 86400;
        daysSinceLast = (block.timestamp - stats.lastTransactionTime) / 86400;
        
        if (daysSinceFirst > 0) {
            avgTransactionsPerDay = stats.transactionCount / daysSinceFirst;
            avgVolumePerDay = stats.totalVolume / daysSinceFirst;
        } else {
            // Same day as first transaction
            avgTransactionsPerDay = stats.transactionCount;
            avgVolumePerDay = stats.totalVolume;
        }
    }

    /**
     * @notice Checks if user is active (transacted recently)
     * @param userStats Mapping of user statistics
     * @param user User address
     * @param inactiveDays Days to consider inactive
     * @return isActive Whether user is active
     */
    function isUserActive(
        mapping(address => UserStats) storage userStats,
        address user,
        uint256 inactiveDays
    ) internal view returns (bool isActive) {
        UserStats storage stats = userStats[user];
        
        if (stats.transactionCount == 0) return false;
        
        uint256 daysSinceLast = (block.timestamp - stats.lastTransactionTime) / 86400;
        return daysSinceLast <= inactiveDays;
    }

    /**
     * @notice Initializes time window statistics
     * @param windowStats Time window statistics storage
     * @param duration Window duration in seconds
     */
    function initializeTimeWindow(
        TimeWindowStats storage windowStats,
        uint256 duration
    ) internal {
        windowStats.windowStart = block.timestamp;
        windowStats.windowDuration = duration;
        windowStats.windowVolume = 0;
        windowStats.windowTransactions = 0;
        windowStats.maxVolumeInWindow = 0;
        windowStats.minVolumeInWindow = type(uint256).max;
    }
}

/**
 * @title StatisticsCore Contract
 */
contract StatisticsCore {
    // Storage for testing
    mapping(address => StatisticsLib.UserStats) private userStats;
    StatisticsLib.ProtocolStats private protocolStats;
    StatisticsLib.TimeWindowStats private hourlyWindow;
    StatisticsLib.TimeWindowStats private dailyWindow;
    
    // Track unique users
    mapping(address => bool) private hasTransacted;
    uint256 private uniqueUserCount;

    constructor() {
        // Initialize time windows
        StatisticsLib.initializeTimeWindow(hourlyWindow, 1 hours);
        StatisticsLib.initializeTimeWindow(dailyWindow, 1 days);
    }
    
    function getLibraryVersion() external pure returns (string memory) {
        return "STATS-CORE-1.0.0";
    }
    
    // Core statistics functions
    function updateUserStats(address user, uint256 amount) external {
        // Track unique users
        if (!hasTransacted[user]) {
            hasTransacted[user] = true;
            uniqueUserCount++;
        }
        
        StatisticsLib.updateUserStats(userStats, user, amount);
        StatisticsLib.updateProtocolStats(protocolStats, amount, uniqueUserCount);
        StatisticsLib.updateTimeWindowStats(hourlyWindow, amount);
        StatisticsLib.updateTimeWindowStats(dailyWindow, amount);
    }
    
    function getUserStats(address user) external view returns (
        uint256 transactionCount,
        uint256 totalVolume,
        uint256 lastTransactionTime,
        uint256 lastTransactionBlock,
        uint256 firstTransactionTime,
        uint256 averageTransactionSize,
        uint256 maxTransactionSize,
        uint256 minTransactionSize
    ) {
        return StatisticsLib.getUserStats(userStats, user);
    }
    
    function getProtocolStats() external view returns (
        uint256 totalTransactions,
        uint256 totalVolume,
        uint256 uniqueUsers,
        uint256 lastUpdateTime,
        uint256 dailyVolume,
        uint256 dailyTransactions,
        uint256 peakDailyVolume,
        uint256 peakDailyTransactions
    ) {
        return StatisticsLib.getProtocolStats(protocolStats);
    }
    
    function getHourlyWindowStats() external view returns (
        uint256 windowStart,
        uint256 windowDuration,
        uint256 windowVolume,
        uint256 windowTransactions,
        uint256 maxVolumeInWindow,
        uint256 minVolumeInWindow,
        uint256 timeRemaining
    ) {
        return StatisticsLib.getTimeWindowStats(hourlyWindow);
    }
    
    function getDailyWindowStats() external view returns (
        uint256 windowStart,
        uint256 windowDuration,
        uint256 windowVolume,
        uint256 windowTransactions,
        uint256 maxVolumeInWindow,
        uint256 minVolumeInWindow,
        uint256 timeRemaining
    ) {
        return StatisticsLib.getTimeWindowStats(dailyWindow);
    }
    
    function getUserActivityMetrics(address user) external view returns (
        uint256 daysSinceFirst,
        uint256 daysSinceLast,
        uint256 avgTransactionsPerDay,
        uint256 avgVolumePerDay
    ) {
        return StatisticsLib.getUserActivityMetrics(userStats, user);
    }
    
    function isUserActive(address user, uint256 inactiveDays) external view returns (bool) {
        return StatisticsLib.isUserActive(userStats, user, inactiveDays);
    }
    
    function getUniqueUserCount() external view returns (uint256) {
        return uniqueUserCount;
    }
    
    function hasUserTransacted(address user) external view returns (bool) {
        return hasTransacted[user];
    }
    
    // System health check - calls library functions directly
    function getSystemHealthMetrics() external view returns (
        uint256 transactionsLastHour,
        uint256 volumeLastHour,
        uint256 transactionsLastDay,
        uint256 volumeLastDay,
        uint256 avgTransactionSize,
        bool isSystemHealthy
    ) {
        // Call library functions directly to avoid external function call issues
        (,, volumeLastHour, transactionsLastHour,,,) = StatisticsLib.getTimeWindowStats(hourlyWindow);
        (,, volumeLastDay, transactionsLastDay,,,) = StatisticsLib.getTimeWindowStats(dailyWindow);
        
        // Calculate average transaction size
        avgTransactionSize = transactionsLastDay > 0 ? volumeLastDay / transactionsLastDay : 0;
        
        // Simple health check: system is healthy if there were transactions in the last hour
        isSystemHealthy = transactionsLastHour > 0;
    }
    
    // Admin functions
    function resetStats() external {
        // Reset protocol stats
        protocolStats.totalTransactions = 0;
        protocolStats.totalVolume = 0;
        protocolStats.uniqueUsers = 0;
        protocolStats.dailyVolume = 0;
        protocolStats.dailyTransactions = 0;
        protocolStats.lastUpdateTime = block.timestamp;
        protocolStats.lastDayReset = block.timestamp;
        protocolStats.peakDailyVolume = 0;
        protocolStats.peakDailyTransactions = 0;
        
        // Reset unique user tracking
        uniqueUserCount = 0;
        
        // Reset windows
        StatisticsLib.initializeTimeWindow(hourlyWindow, 1 hours);
        StatisticsLib.initializeTimeWindow(dailyWindow, 1 days);
    }
    
    function getCurrentDay() external view returns (uint256) {
        return block.timestamp / 86400;
    }
    
    function getBlockInfo() external view returns (
        uint256 blockNumber,
        uint256 blockTimestamp,
        uint256 currentDay
    ) {
        return (
            block.number,
            block.timestamp,
            block.timestamp / 86400
        );
    }
}