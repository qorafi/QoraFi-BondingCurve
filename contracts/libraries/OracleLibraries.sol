// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title OracleLibraries
 * @notice Collection of oracle-focused libraries for TWAP calculation, price validation, and liquidity monitoring
 * @dev Extracted from MarketOracle to improve modularity and reduce contract size
 */

// --- TWAP CALCULATION LIBRARY ---
library TWAPLib {
    struct TWAPObservation {
        uint256 price0Cumulative;
        uint256 price1Cumulative;
        uint32 timestamp;
        bool isValid;
        uint256 liquiditySnapshot;
    }

    // TWAP errors
    error InsufficientObservations();
    error InvalidTimeElapsed();
    error StaleObservations();
    error NoObservations();

    uint256 public constant MIN_TWAP_OBSERVATIONS = 3;
    uint256 public constant MAX_TWAP_OBSERVATIONS = 24;
    uint256 public constant MAX_OBSERVATION_AGE = 2 hours;
    uint256 public constant MIN_OBSERVATION_INTERVAL = 5 minutes;

    /**
     * @notice Calculates price for a specific time period
     * @param priceCumulativeDiff Price cumulative difference
     * @param timeElapsed Time elapsed in the period
     * @param qorafiIsToken0 Whether Qorafi is token0
     * @param usdtDecimals USDT decimals
     * @return periodPrice Price for the period
     */
    function calculatePeriodPrice(
        uint256 priceCumulativeDiff,
        uint32 timeElapsed,
        bool qorafiIsToken0,
        uint8 usdtDecimals
    ) internal pure returns (uint256 periodPrice) {
        if (timeElapsed == 0) revert InvalidTimeElapsed();
        
        unchecked {
            uint256 avgPriceQ112 = priceCumulativeDiff / timeElapsed;
            
            if (qorafiIsToken0) {
                if (avgPriceQ112 == 0) return 0;
                return Math.mulDiv(uint256(2**112), 10**usdtDecimals, avgPriceQ112);
            } else {
                return Math.mulDiv(avgPriceQ112, 10**usdtDecimals, uint256(2**112));
            }
        }
    }

    /**
     * @notice Invalidates an observation
     * @param observations Array of observations
     * @param index Index to invalidate
     * @param validCount Current valid count
     * @return newValidCount Updated valid count
     */
    function invalidateObservation(
        TWAPObservation[] storage observations,
        uint256 index,
        uint256 validCount
    ) internal returns (uint256 newValidCount) {
        require(index < observations.length, "Index out of bounds");
        if (observations[index].isValid) {
            observations[index].isValid = false;
            return validCount - 1;
        }
        return validCount;
    }

    /**
     * @notice Gets the latest valid observation
     * @param observations Array of observations
     * @return observation Latest observation
     */
    function getLatestObservation(TWAPObservation[] storage observations) internal view returns (TWAPObservation memory observation) {
        if (observations.length == 0) revert NoObservations();
        return observations[observations.length - 1];
    }
}

// --- PRICE VALIDATION LIBRARY ---
library PriceValidationLib {
    struct PriceValidationData {
        uint256 lastValidatedPrice;
        uint256 lastValidationTime;
        uint256 priceImpactThreshold;
        uint256 maxPriceChangePerUpdate;
        uint256 minTimeBetweenUpdates;
    }

    // Price validation errors
    error PriceChangeTooLarge();
    error PriceImpactTooHigh();
    error InvalidPrices();
    error MarketCapGrowthTooLarge();

    /**
     * @notice Updates price validation parameters
     * @param validation Price validation data
     * @param priceImpactThreshold New price impact threshold
     * @param maxPriceChangePerUpdate New max price change per update
     * @param minTimeBetweenUpdates New minimum time between updates
     */
    function updateValidationParams(
        PriceValidationData storage validation,
        uint256 priceImpactThreshold,
        uint256 maxPriceChangePerUpdate,
        uint256 minTimeBetweenUpdates
    ) internal {
        validation.priceImpactThreshold = priceImpactThreshold;
        validation.maxPriceChangePerUpdate = maxPriceChangePerUpdate;
        validation.minTimeBetweenUpdates = minTimeBetweenUpdates;
    }

    /**
     * @notice Validates price change between updates
     * @param validation Price validation data
     * @param oldPrice Previous price
     * @param newPrice New price
     * @param newTokenMode Whether new token mode is active
     * @param maxChangeBPS Maximum change in BPS
     */
    function validatePriceChange(
        PriceValidationData storage validation,
        uint256 oldPrice,
        uint256 newPrice,
        bool newTokenMode,
        uint256 maxChangeBPS
    ) internal {
        if (oldPrice == 0 || newPrice == 0) revert InvalidPrices();
        
        uint256 priceDiff = newPrice > oldPrice ? newPrice - oldPrice : oldPrice - newPrice;
        
        // Use new token specific max change if in new token mode
        uint256 maxChange = newTokenMode ? validation.maxPriceChangePerUpdate : maxChangeBPS;
        uint256 changePercent = Math.mulDiv(priceDiff, 10000, oldPrice);
        
        if (changePercent > maxChange) revert PriceChangeTooLarge();
        
        // Update validation data
        validation.lastValidatedPrice = newPrice;
        validation.lastValidationTime = block.timestamp;
    }

    /**
     * @notice Validates price impact
     * @param validation Price validation data
     * @param newPrice New price to validate
     */
    function validatePriceImpact(PriceValidationData storage validation, uint256 newPrice) internal view {
        if (validation.lastValidatedPrice == 0) return;
        
        // Calculate price impact from last validated price
        uint256 priceImpact = calculatePriceImpact(validation.lastValidatedPrice, newPrice);
        
        if (priceImpact > validation.priceImpactThreshold) {
            revert PriceImpactTooHigh();
        }
    }

    /**
     * @notice Validates market cap growth
     * @param oldCap Previous market cap
     * @param newCap New market cap
     * @param maxGrowthBPS Maximum growth in BPS
     */
    function validateMarketCapGrowth(uint256 oldCap, uint256 newCap, uint256 maxGrowthBPS) internal pure {
        if (oldCap == 0 || newCap == 0) revert InvalidPrices();
        
        if (newCap > oldCap) {
            uint256 growthPercent = Math.mulDiv(newCap - oldCap, 10000, oldCap);
            if (growthPercent > maxGrowthBPS) revert MarketCapGrowthTooLarge();
        }
    }

    /**
     * @notice Calculates price impact between two prices
     * @param oldPrice Previous price
     * @param newPrice New price
     * @return impact Price impact in BPS
     */
    function calculatePriceImpact(uint256 oldPrice, uint256 newPrice) internal pure returns (uint256 impact) {
        if (oldPrice == 0 || newPrice == 0) return 0;
        
        uint256 priceDiff = newPrice > oldPrice ? newPrice - oldPrice : oldPrice - newPrice;
        return Math.mulDiv(priceDiff, 10000, oldPrice);
    }
}

// --- LIQUIDITY MONITORING LIBRARY ---
library LiquidityMonitorLib {
    // Liquidity monitoring errors
    error InsufficientLiquidity();
    error LiquidityBelowThreshold();
    error InvalidReserves();

    /**
     * @notice Validates liquidity depth for pricing
     * @param currentLiquidity Current liquidity amount
     * @param minimumRequired Minimum required liquidity
     */
    function validateLiquidityDepth(uint256 currentLiquidity, uint256 minimumRequired) internal pure {
        if (currentLiquidity < minimumRequired) {
            revert LiquidityBelowThreshold();
        }
    }

    /**
     * @notice Gets current USDT liquidity from pair reserves
     * @param reserve0 Reserve of token0
     * @param reserve1 Reserve of token1
     * @param qorafiIsToken0 Whether Qorafi is token0
     * @return usdtLiquidity USDT liquidity amount
     */
    function getCurrentUSDTLiquidity(
        uint112 reserve0,
        uint112 reserve1,
        bool qorafiIsToken0
    ) internal pure returns (uint256 usdtLiquidity) {
        if (reserve0 == 0 || reserve1 == 0) revert InvalidReserves();
        return qorafiIsToken0 ? uint256(reserve1) : uint256(reserve0);
    }

    /**
     * @notice Validates reserves are sufficient for pricing
     * @param reserve0 Reserve of token0
     * @param reserve1 Reserve of token1
     * @param qorafiIsToken0 Whether Qorafi is token0
     * @param minQorafiLiquidity Minimum Qorafi liquidity
     * @param minUsdtLiquidity Minimum USDT liquidity
     */
    function validateReserves(
        uint112 reserve0,
        uint112 reserve1,
        bool qorafiIsToken0,
        uint256 minQorafiLiquidity,
        uint256 minUsdtLiquidity
    ) internal pure {
        if (reserve0 == 0 || reserve1 == 0) revert InvalidReserves();
        
        uint256 qorafiReserve = qorafiIsToken0 ? uint256(reserve0) : uint256(reserve1);
        uint256 usdtReserve = qorafiIsToken0 ? uint256(reserve1) : uint256(reserve0);
        
        if (qorafiReserve < minQorafiLiquidity) revert InsufficientLiquidity();
        if (usdtReserve < minUsdtLiquidity) revert InsufficientLiquidity();
    }

    /**
     * @notice Checks liquidity health status
     * @param currentLiquidity Current liquidity
     * @param minimumRequired Minimum required liquidity
     * @param lastCheck Last check timestamp
     * @param checkInterval Check interval
     * @return isHealthy Whether liquidity is healthy
     * @return shouldUpdate Whether check should be updated
     */
    function checkLiquidityHealth(
        uint256 currentLiquidity,
        uint256 minimumRequired,
        uint256 lastCheck,
        uint256 checkInterval
    ) internal view returns (bool isHealthy, bool shouldUpdate) {
        isHealthy = currentLiquidity >= minimumRequired;
        shouldUpdate = block.timestamp >= lastCheck + checkInterval;
    }

    /**
     * @notice Calculates liquidity change percentage
     * @param oldLiquidity Previous liquidity
     * @param newLiquidity New liquidity
     * @return changePercent Change percentage in BPS
     */
    function calculateLiquidityChange(
        uint256 oldLiquidity,
        uint256 newLiquidity
    ) internal pure returns (uint256 changePercent) {
        if (oldLiquidity == 0) return 0;
        
        uint256 liquidityDiff = newLiquidity > oldLiquidity 
            ? newLiquidity - oldLiquidity 
            : oldLiquidity - newLiquidity;
        
        return Math.mulDiv(liquidityDiff, 10000, oldLiquidity);
    }
}

// --- FLASH LOAN DETECTION LIBRARY ---
library FlashLoanDetectionLib {
    // Flash loan detection errors
    error FlashLoanDetected();
    error TooManyUpdatesPerBlock();

    /**
     * @notice Checks for potential flash loan attack
     * @param blockUpdates Mapping of block number to update count
     * @param blockNumber Current block number
     * @param maxUpdatesPerBlock Maximum updates allowed per block
     * @param detectionWindow Detection window in blocks
     */
    function checkFlashLoanActivity(
        mapping(uint256 => uint256) storage blockUpdates,
        uint256 blockNumber,
        uint256 maxUpdatesPerBlock,
        uint256 detectionWindow
    ) internal {
        blockUpdates[blockNumber]++;
        
        if (blockUpdates[blockNumber] > maxUpdatesPerBlock) {
            revert TooManyUpdatesPerBlock();
        }
        
        // Check for suspicious activity across detection window
        uint256 totalUpdates = 0;
        for (uint256 i = 0; i < detectionWindow && i <= blockNumber; i++) {
            totalUpdates += blockUpdates[blockNumber - i];
        }
        
        // If total updates in window exceed threshold, flag as potential attack
        if (totalUpdates > maxUpdatesPerBlock * detectionWindow) {
            revert FlashLoanDetected();
        }
    }

    /**
     * @notice Validates update frequency for new token protection
     * @param lastUpdateTime Last update timestamp
     * @param minInterval Minimum interval between updates
     * @param newTokenMode Whether new token mode is active
     */
    function validateUpdateFrequency(
        uint256 lastUpdateTime,
        uint256 minInterval,
        bool newTokenMode
    ) internal view {
        if (newTokenMode) {
            require(block.timestamp >= lastUpdateTime + minInterval, "Update too frequent");
        }
    }

    /**
     * @notice Gets update statistics for monitoring
     * @param blockUpdates Mapping of block updates
     * @param blockNumber Current block number
     * @param windowSize Window size to check
     * @return currentBlockUpdates Updates in current block
     * @return windowUpdates Total updates in window
     */
    function getUpdateStats(
        mapping(uint256 => uint256) storage blockUpdates,
        uint256 blockNumber,
        uint256 windowSize
    ) internal view returns (uint256 currentBlockUpdates, uint256 windowUpdates) {
        currentBlockUpdates = blockUpdates[blockNumber];
        
        for (uint256 i = 0; i < windowSize && i <= blockNumber; i++) {
            windowUpdates += blockUpdates[blockNumber - i];
        }
    }
}

// --- CUMULATIVE PRICE LIBRARY ---
library CumulativePriceLib {
    /**
     * @notice Gets current cumulative prices from a Uniswap V2 pair
     * @param pair The Uniswap V2 pair interface
     * @param qorafiIsToken0 Whether Qorafi is token0 in the pair
     * @param minQorafiLiquidity Minimum Qorafi liquidity required
     * @param minUsdtLiquidity Minimum USDT liquidity required
     * @return price0Cumulative Current price0 cumulative
     * @return price1Cumulative Current price1 cumulative
     * @return currentTime Current timestamp
     */
    function getCurrentCumulativePrices(
        address pair,
        bool qorafiIsToken0,
        uint256 minQorafiLiquidity,
        uint256 minUsdtLiquidity
    ) internal view returns (uint256 price0Cumulative, uint256 price1Cumulative, uint32 currentTime) {
        // Get reserves and validate
        (bool success, bytes memory data) = pair.staticcall(
            abi.encodeWithSignature("getReserves()")
        );
        require(success, "Failed to get reserves");
        
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = abi.decode(data, (uint112, uint112, uint32));
        
        // Validate liquidity using LiquidityMonitorLib
        LiquidityMonitorLib.validateReserves(
            reserve0,
            reserve1,
            qorafiIsToken0,
            minQorafiLiquidity,
            minUsdtLiquidity
        );
        
        // Get cumulative prices
        (success, data) = pair.staticcall(
            abi.encodeWithSignature("price0CumulativeLast()")
        );
        require(success, "Failed to get price0Cumulative");
        price0Cumulative = abi.decode(data, (uint256));
        
        (success, data) = pair.staticcall(
            abi.encodeWithSignature("price1CumulativeLast()")
        );
        require(success, "Failed to get price1Cumulative");
        price1Cumulative = abi.decode(data, (uint256));
        
        uint32 timeElapsed;
        assembly {
            currentTime := timestamp()
            timeElapsed := sub(currentTime, blockTimestampLast)
        }
        
        // Calculate current cumulative prices if time has elapsed
        if (timeElapsed > 0) {
            unchecked {
                price0Cumulative += Math.mulDiv(uint256(reserve1) * 2**112, timeElapsed, reserve0);
                price1Cumulative += Math.mulDiv(uint256(reserve0) * 2**112, timeElapsed, reserve1);
            }
        }
    }
}
/**
 * @title OracleLibraries
 * @notice Main contract that bundles all oracle libraries for deployment and testing
 */
contract OracleLibraries {
    function getLibraryVersion() external pure returns (string memory) {
        return "1.0.0";
    }
    
    // Expose key functions for testing
    function calculatePeriodPrice(
        uint256 priceCumulativeDiff,
        uint32 timeElapsed,
        bool qorafiIsToken0,
        uint8 usdtDecimals
    ) external pure returns (uint256) {
        return TWAPLib.calculatePeriodPrice(
            priceCumulativeDiff,
            timeElapsed,
            qorafiIsToken0,
            usdtDecimals
        );
    }
    
    function calculatePriceImpact(uint256 oldPrice, uint256 newPrice) external pure returns (uint256) {
        return PriceValidationLib.calculatePriceImpact(oldPrice, newPrice);
    }
    
    function validateLiquidityDepth(uint256 currentLiquidity, uint256 minimumRequired) external pure {
        LiquidityMonitorLib.validateLiquidityDepth(currentLiquidity, minimumRequired);
    }
}