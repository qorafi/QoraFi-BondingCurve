// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title AnalyticsEngine
 * @notice Advanced analytics and trend analysis
 */

// --- ANALYTICS LIBRARY ---
library AnalyticsLib {
    struct TrendData {
        uint256[] values;
        uint256[] timestamps;
        uint256 maxDataPoints;
        uint256 currentIndex;
        bool isFull;
    }

    /**
     * @notice Adds a data point to trend tracking
     * @param trendData Trend data storage
     * @param value Value to add
     */
    function addDataPoint(TrendData storage trendData, uint256 value) internal {
        if (trendData.values.length == 0) {
            // Initialize arrays
            trendData.values = new uint256[](trendData.maxDataPoints);
            trendData.timestamps = new uint256[](trendData.maxDataPoints);
        }
        
        trendData.values[trendData.currentIndex] = value;
        trendData.timestamps[trendData.currentIndex] = block.timestamp;
        
        trendData.currentIndex = (trendData.currentIndex + 1) % trendData.maxDataPoints;
        
        if (trendData.currentIndex == 0) {
            trendData.isFull = true;
        }
    }

    /**
     * @notice Calculates trend direction
     * @param trendData Trend data storage
     * @param lookbackPoints Number of points to analyze
     * @return trendDirection 1 for upward, 0 for stable, -1 for downward
     */
    function getTrendDirection(
        TrendData storage trendData,
        uint256 lookbackPoints
    ) internal view returns (int256 trendDirection) {
        uint256 dataPoints = trendData.isFull ? trendData.maxDataPoints : trendData.currentIndex;
        if (dataPoints < 2 || lookbackPoints < 2) return 0;
        
        uint256 pointsToAnalyze = lookbackPoints > dataPoints ? dataPoints : lookbackPoints;
        
        uint256 increaseCount = 0;
        uint256 decreaseCount = 0;
        
        for (uint256 i = 1; i < pointsToAnalyze; i++) {
            uint256 currentIdx = (trendData.currentIndex + trendData.maxDataPoints - i) % trendData.maxDataPoints;
            uint256 prevIdx = (trendData.currentIndex + trendData.maxDataPoints - i - 1) % trendData.maxDataPoints;
            
            if (trendData.values[currentIdx] > trendData.values[prevIdx]) {
                increaseCount++;
            } else if (trendData.values[currentIdx] < trendData.values[prevIdx]) {
                decreaseCount++;
            }
        }
        
        if (increaseCount > decreaseCount) {
            return 1; // Upward trend
        } else if (decreaseCount > increaseCount) {
            return -1; // Downward trend
        } else {
            return 0; // Stable
        }
    }

    /**
     * @notice Gets recent values from trend data
     * @param trendData Trend data storage
     * @param count Number of recent values to get
     * @return recentValues Array of recent values
     * @return recentTimestamps Array of recent timestamps
     */
    function getRecentValues(
        TrendData storage trendData,
        uint256 count
    ) internal view returns (uint256[] memory recentValues, uint256[] memory recentTimestamps) {
        uint256 dataPoints = trendData.isFull ? trendData.maxDataPoints : trendData.currentIndex;
        uint256 returnCount = count > dataPoints ? dataPoints : count;
        
        recentValues = new uint256[](returnCount);
        recentTimestamps = new uint256[](returnCount);
        
        for (uint256 i = 0; i < returnCount; i++) {
            uint256 idx = (trendData.currentIndex + trendData.maxDataPoints - i - 1) % trendData.maxDataPoints;
            recentValues[i] = trendData.values[idx];
            recentTimestamps[i] = trendData.timestamps[idx];
        }
    }

    /**
     * @notice Gets total data points stored
     * @param trendData Trend data storage
     * @return totalPoints Total data points available
     */
    function getTotalDataPoints(TrendData storage trendData) internal view returns (uint256 totalPoints) {
        return trendData.isFull ? trendData.maxDataPoints : trendData.currentIndex;
    }

    /**
     * @notice Initializes trend data
     * @param trendData Trend data storage
     * @param maxPoints Maximum data points to store
     */
    function initializeTrend(TrendData storage trendData, uint256 maxPoints) internal {
        trendData.maxDataPoints = maxPoints;
        trendData.currentIndex = 0;
        trendData.isFull = false;
    }
}

// --- USER SEGMENTATION LIBRARY ---
library UserSegmentationLib {
    struct UserProfile {
        string userType;        // "new", "regular", "power", "whale"
        uint256 activityScore;  // Score from 0-100
        bool isHighValue;       // High value user
        bool isFrequentUser;    // Frequent user
        uint256 riskLevel;      // 0-100 risk assessment
        uint256 lifetimeValue;  // Estimated lifetime value
    }

    /**
     * @notice Analyzes user and creates profile
     * @param transactionCount Number of transactions
     * @param totalVolume Total volume
     * @param averageTransactionSize Average transaction size
     * @param maxTransactionSize Maximum transaction size
     * @param daysSinceFirst Days since first transaction
     * @param daysSinceLast Days since last transaction
     * @return userProfile User profile
     */
    function analyzeUser(
        uint256 transactionCount,
        uint256 totalVolume,
        uint256 averageTransactionSize,
        uint256 maxTransactionSize,
        uint256 daysSinceFirst,
        uint256 daysSinceLast
    ) internal pure returns (UserProfile memory userProfile) {
        if (transactionCount == 0) {
            return UserProfile("new", 0, false, false, 0, 0);
        }
        
        // Activity score calculation (0-100)
        uint256 activityScore = 0;
        
        // Transaction frequency (0-30 points)
        if (daysSinceFirst > 0) {
            uint256 txPerDay = transactionCount / (daysSinceFirst + 1);
            if (txPerDay >= 5) activityScore += 30;
            else if (txPerDay >= 2) activityScore += 20;
            else if (txPerDay >= 1) activityScore += 10;
        }
        
        // Recency (0-30 points)
        if (daysSinceLast == 0) activityScore += 30;      // Today
        else if (daysSinceLast <= 3) activityScore += 20; // Last 3 days
        else if (daysSinceLast <= 7) activityScore += 10; // Last week
        
        // Volume (0-40 points)
        if (totalVolume >= 100000 * 10**18) activityScore += 40;      // 100k+
        else if (totalVolume >= 10000 * 10**18) activityScore += 30;  // 10k+
        else if (totalVolume >= 1000 * 10**18) activityScore += 20;   // 1k+
        else if (totalVolume >= 100 * 10**18) activityScore += 10;    // 100+
        
        // User classification
        bool isHighValue = averageTransactionSize >= 1000 * 10**18 || maxTransactionSize >= 10000 * 10**18;
        bool isFrequentUser = transactionCount >= 10 && daysSinceLast <= 7;
        
        string memory userType;
        if (isHighValue && isFrequentUser) {
            userType = "whale";
        } else if (isFrequentUser || transactionCount >= 20) {
            userType = "power";
        } else if (transactionCount >= 5 || daysSinceFirst >= 7) {
            userType = "regular";
        } else {
            userType = "new";
        }
        
        // Risk assessment (simplified)
        uint256 riskLevel = 0;
        if (maxTransactionSize > averageTransactionSize * 10) riskLevel += 20; // Unusual large transactions
        if (daysSinceLast > 30) riskLevel += 15; // Inactive
        if (transactionCount < 3) riskLevel += 10; // New user
        
        // Lifetime value estimation (simplified)
        uint256 lifetimeValue = 0;
        if (daysSinceFirst > 0) {
            uint256 dailyValue = totalVolume / (daysSinceFirst + 1);
            lifetimeValue = dailyValue * 365; // Estimate annual value
        }
        
        userProfile = UserProfile(
            userType,
            activityScore,
            isHighValue,
            isFrequentUser,
            riskLevel > 100 ? 100 : riskLevel,
            lifetimeValue
        );
    }
}

/**
 * @title AnalyticsEngine Contract
 */
contract AnalyticsEngine {
    AnalyticsLib.TrendData private volumeTrend;
    AnalyticsLib.TrendData private transactionTrend;
    AnalyticsLib.TrendData private userTrend;
    
    // Market insights cache
    struct MarketInsights {
        uint256 avgHourlyVolume;
        uint256 avgDailyVolume;
        uint256 peakHourVolume;
        uint256 peakDayVolume;
        int256 volumeTrendValue;
        uint256 marketActivity;
        uint256 lastUpdateTime;
    }
    
    MarketInsights private cachedInsights;
    uint256 private constant CACHE_DURATION = 5 minutes;

    constructor() {
        // Initialize trend tracking
        AnalyticsLib.initializeTrend(volumeTrend, 100);
        AnalyticsLib.initializeTrend(transactionTrend, 100);
        AnalyticsLib.initializeTrend(userTrend, 50);
    }
    
    function getLibraryVersion() external pure returns (string memory) {
        return "ANALYTICS-1.0.0";
    }
    
    // Trend tracking functions
    function addVolumeDataPoint(uint256 volume) external {
        AnalyticsLib.addDataPoint(volumeTrend, volume);
    }
    
    function addTransactionDataPoint(uint256 transactionCount) external {
        AnalyticsLib.addDataPoint(transactionTrend, transactionCount);
    }
    
    function addUserDataPoint(uint256 userCount) external {
        AnalyticsLib.addDataPoint(userTrend, userCount);
    }
    
    function getVolumeTrendDirection(uint256 lookbackPoints) external view returns (int256) {
        return AnalyticsLib.getTrendDirection(volumeTrend, lookbackPoints);
    }
    
    function getTransactionTrendDirection(uint256 lookbackPoints) external view returns (int256) {
        return AnalyticsLib.getTrendDirection(transactionTrend, lookbackPoints);
    }
    
    function getUserTrendDirection(uint256 lookbackPoints) external view returns (int256) {
        return AnalyticsLib.getTrendDirection(userTrend, lookbackPoints);
    }
    
    function getRecentVolumeData(uint256 count) external view returns (
        uint256[] memory recentValues,
        uint256[] memory recentTimestamps
    ) {
        return AnalyticsLib.getRecentValues(volumeTrend, count);
    }
    
    function getRecentTransactionData(uint256 count) external view returns (
        uint256[] memory recentValues,
        uint256[] memory recentTimestamps
    ) {
        return AnalyticsLib.getRecentValues(transactionTrend, count);
    }
    
    function getTrendSummary() external view returns (
        int256 shortTermVolumeTrend,   // Last 5 data points
        int256 mediumTermVolumeTrend,  // Last 20 data points
        int256 longTermVolumeTrend,    // Last 50 data points
        uint256 totalVolumeDataPoints,
        int256 shortTermTxTrend,
        int256 mediumTermTxTrend,
        uint256 totalTxDataPoints
    ) {
        uint256 volumeDataPoints = AnalyticsLib.getTotalDataPoints(volumeTrend);
        uint256 txDataPoints = AnalyticsLib.getTotalDataPoints(transactionTrend);
        
        shortTermVolumeTrend = AnalyticsLib.getTrendDirection(volumeTrend, 5);
        mediumTermVolumeTrend = AnalyticsLib.getTrendDirection(volumeTrend, 20);
        longTermVolumeTrend = AnalyticsLib.getTrendDirection(volumeTrend, 50);
        totalVolumeDataPoints = volumeDataPoints;
        
        shortTermTxTrend = AnalyticsLib.getTrendDirection(transactionTrend, 5);
        mediumTermTxTrend = AnalyticsLib.getTrendDirection(transactionTrend, 20);
        totalTxDataPoints = txDataPoints;
    }
    
    // User segmentation functions
    function analyzeUserProfile(
        uint256 transactionCount,
        uint256 totalVolume,
        uint256 averageTransactionSize,
        uint256 maxTransactionSize,
        uint256 daysSinceFirst,
        uint256 daysSinceLast
    ) external pure returns (
        string memory userType,
        uint256 activityScore,
        bool isHighValue,
        bool isFrequentUser,
        uint256 riskLevel,
        uint256 lifetimeValue
    ) {
        UserSegmentationLib.UserProfile memory userProfile = UserSegmentationLib.analyzeUser(
            transactionCount,
            totalVolume,
            averageTransactionSize,
            maxTransactionSize,
            daysSinceFirst,
            daysSinceLast
        );
        
        return (
            userProfile.userType,
            userProfile.activityScore,
            userProfile.isHighValue,
            userProfile.isFrequentUser,
            userProfile.riskLevel,
            userProfile.lifetimeValue
        );
    }
    
    // Market insights with caching
    function updateMarketInsights(
        uint256 hourlyVolume,
        uint256 dailyVolume,
        uint256 peakDailyVolume
    ) external {
        cachedInsights.avgHourlyVolume = hourlyVolume;
        cachedInsights.avgDailyVolume = dailyVolume;
        cachedInsights.peakHourVolume = hourlyVolume; // Simplified
        cachedInsights.peakDayVolume = peakDailyVolume;
        
        // Get volume trend
        cachedInsights.volumeTrendValue = AnalyticsLib.getTrendDirection(volumeTrend, 10);
        
        // Market activity score (0-100)
        uint256 marketActivity = 50; // Base activity
        
        if (dailyVolume > 0 && peakDailyVolume > 0) {
            uint256 activityRatio = (dailyVolume * 100) / peakDailyVolume;
            marketActivity = activityRatio > 100 ? 100 : activityRatio;
        }
        
        // Adjust for trend
        if (cachedInsights.volumeTrendValue > 0) {
            marketActivity = marketActivity < 90 ? marketActivity + 10 : 100;
        } else if (cachedInsights.volumeTrendValue < 0) {
            marketActivity = marketActivity > 10 ? marketActivity - 10 : 0;
        }
        
        cachedInsights.marketActivity = marketActivity;
        cachedInsights.lastUpdateTime = block.timestamp;
    }
    
    function getMarketInsights() external view returns (
        uint256 avgHourlyVolume,
        uint256 avgDailyVolume,
        uint256 peakHourVolume,
        uint256 peakDayVolume,
        int256 volumeTrendValue,
        uint256 marketActivity,
        bool isCacheValid
    ) {
        bool cacheValid = block.timestamp - cachedInsights.lastUpdateTime < CACHE_DURATION;
        
        return (
            cachedInsights.avgHourlyVolume,
            cachedInsights.avgDailyVolume,
            cachedInsights.peakHourVolume,
            cachedInsights.peakDayVolume,
            cachedInsights.volumeTrendValue,
            cachedInsights.marketActivity,
            cacheValid
        );
    }
    
    // Advanced analytics functions
    function calculateVolatility(uint256 lookbackPoints) external view returns (uint256 volatility) {
        (uint256[] memory values,) = AnalyticsLib.getRecentValues(volumeTrend, lookbackPoints);
        
        if (values.length < 2) return 0;
        
        // Calculate simple volatility as percentage difference from average
        uint256 total = 0;
        for (uint256 i = 0; i < values.length; i++) {
            total += values[i];
        }
        uint256 average = total / values.length;
        
        if (average == 0) return 0;
        
        uint256 maxDeviation = 0;
        for (uint256 i = 0; i < values.length; i++) {
            uint256 deviation = values[i] > average ? 
                ((values[i] - average) * 100) / average : 
                ((average - values[i]) * 100) / average;
            
            if (deviation > maxDeviation) {
                maxDeviation = deviation;
            }
        }
        
        return maxDeviation; // Return as percentage
    }
    
    function getDataPointCounts() external view returns (
        uint256 volumeDataPoints,
        uint256 transactionDataPoints,
        uint256 userDataPoints
    ) {
        return (
            AnalyticsLib.getTotalDataPoints(volumeTrend),
            AnalyticsLib.getTotalDataPoints(transactionTrend),
            AnalyticsLib.getTotalDataPoints(userTrend)
        );
    }
    
    function getPredictiveMetrics() external view returns (
        int256 volumePrediction,      // -1 decrease, 0 stable, 1 increase
        int256 transactionPrediction,
        uint256 confidenceLevel,      // 0-100
        string memory recommendation
    ) {
        // Simple predictive analysis based on trends
        int256 shortTermVolume = AnalyticsLib.getTrendDirection(volumeTrend, 5);
        int256 mediumTermVolume = AnalyticsLib.getTrendDirection(volumeTrend, 15);
        int256 shortTermTx = AnalyticsLib.getTrendDirection(transactionTrend, 5);
        int256 mediumTermTx = AnalyticsLib.getTrendDirection(transactionTrend, 15);
        
        // Volume prediction
        if (shortTermVolume == mediumTermVolume) {
            volumePrediction = shortTermVolume;
            confidenceLevel = 80;
        } else {
            volumePrediction = shortTermVolume; // Favor recent trend
            confidenceLevel = 60;
        }
        
        // Transaction prediction
        if (shortTermTx == mediumTermTx) {
            transactionPrediction = shortTermTx;
            if (confidenceLevel == 80) confidenceLevel = 85;
        } else {
            transactionPrediction = shortTermTx;
            if (confidenceLevel == 80) confidenceLevel = 70;
        }
        
        // Generate recommendation
        if (volumePrediction > 0 && transactionPrediction > 0) {
            recommendation = "BULLISH - Expect increased activity";
        } else if (volumePrediction < 0 && transactionPrediction < 0) {
            recommendation = "BEARISH - Expect decreased activity";
        } else if (volumePrediction == 0 && transactionPrediction == 0) {
            recommendation = "STABLE - Expect consistent activity";
        } else {
            recommendation = "MIXED - Monitor closely for changes";
        }
    }
    
    function getSystemPerformanceScore() external view returns (
        uint256 performanceScore,  // 0-100
        string memory status,
        string[] memory issues
    ) {
        performanceScore = 100; // Start with perfect score
        string[] memory detectedIssues = new string[](5);
        uint256 issueCount = 0;
        
        // Check data availability
        uint256 volumePoints = AnalyticsLib.getTotalDataPoints(volumeTrend);
        uint256 txPoints = AnalyticsLib.getTotalDataPoints(transactionTrend);
        
        if (volumePoints < 10) {
            performanceScore -= 20;
            detectedIssues[issueCount] = "Insufficient volume data";
            issueCount++;
        }
        
        if (txPoints < 10) {
            performanceScore -= 20;
            detectedIssues[issueCount] = "Insufficient transaction data";
            issueCount++;
        }
        
        // Check trend consistency
        int256 volumeTrend5 = AnalyticsLib.getTrendDirection(volumeTrend, 5);
        int256 volumeTrend15 = AnalyticsLib.getTrendDirection(volumeTrend, 15);
        
        if (volumeTrend5 != volumeTrend15) {
            performanceScore -= 10;
            detectedIssues[issueCount] = "Inconsistent volume trends";
            issueCount++;
        }
        
        // Check cache freshness
        if (block.timestamp - cachedInsights.lastUpdateTime > CACHE_DURATION) {
            performanceScore -= 15;
            detectedIssues[issueCount] = "Stale market insights cache";
            issueCount++;
        }
        
        // Determine status
        if (performanceScore >= 90) {
            status = "EXCELLENT";
        } else if (performanceScore >= 75) {
            status = "GOOD";
        } else if (performanceScore >= 60) {
            status = "FAIR";
        } else {
            status = "POOR";
        }
        
        // Resize issues array to actual count
        issues = new string[](issueCount);
        for (uint256 i = 0; i < issueCount; i++) {
            issues[i] = detectedIssues[i];
        }
    }
    
    // Admin functions
    function resetTrendData() external {
        AnalyticsLib.initializeTrend(volumeTrend, 100);
        AnalyticsLib.initializeTrend(transactionTrend, 100);
        AnalyticsLib.initializeTrend(userTrend, 50);
        
        // Reset cached insights
        cachedInsights.avgHourlyVolume = 0;
        cachedInsights.avgDailyVolume = 0;
        cachedInsights.peakHourVolume = 0;
        cachedInsights.peakDayVolume = 0;
        cachedInsights.volumeTrendValue = 0;
        cachedInsights.marketActivity = 50;
        cachedInsights.lastUpdateTime = 0;
    }
    
    function updateTrendCapacity(uint256 volumeCapacity, uint256 txCapacity, uint256 userCapacity) external {
        // Reinitialize with new capacities
        AnalyticsLib.initializeTrend(volumeTrend, volumeCapacity);
        AnalyticsLib.initializeTrend(transactionTrend, txCapacity);
        AnalyticsLib.initializeTrend(userTrend, userCapacity);
    }
}