// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title MathUtilities
 * @notice Mathematical calculation utilities
 */

// --- MATH HELPER LIBRARY ---
library MathHelperLib {
    using Math for uint256;

    uint256 public constant MAX_BPS = 10000;
    uint256 public constant PRECISION = 1e18;

    /**
     * @notice Calculates percentage with BPS precision
     * @param amount Base amount
     * @param bps Basis points (1 BPS = 0.01%)
     * @return result Calculated percentage
     */
    function calculatePercentage(uint256 amount, uint256 bps) internal pure returns (uint256 result) {
        return Math.mulDiv(amount, bps, MAX_BPS);
    }

    /**
     * @notice Calculates slippage amount
     * @param amount Base amount
     * @param slippageBps Slippage in BPS
     * @return minAmount Minimum amount after slippage
     */
    function calculateSlippage(uint256 amount, uint256 slippageBps) internal pure returns (uint256 minAmount) {
        return Math.mulDiv(amount, MAX_BPS - slippageBps, MAX_BPS);
    }

    /**
     * @notice Calculates weighted average
     * @param values Array of values
     * @param weights Array of weights
     * @return weightedAvg Weighted average
     */
    function calculateWeightedAverage(
        uint256[] memory values,
        uint256[] memory weights
    ) internal pure returns (uint256 weightedAvg) {
        require(values.length == weights.length, "Array length mismatch");
        
        uint256 totalWeighted = 0;
        uint256 totalWeight = 0;
        
        for (uint256 i = 0; i < values.length; i++) {
            totalWeighted += values[i] * weights[i];
            totalWeight += weights[i];
        }
        
        return totalWeight > 0 ? totalWeighted / totalWeight : 0;
    }

    /**
     * @notice Calculates compound growth
     * @param principal Principal amount
     * @param rate Growth rate in BPS
     * @param periods Number of periods
     * @return finalAmount Final amount after compound growth
     */
    function calculateCompoundGrowth(
        uint256 principal,
        uint256 rate,
        uint256 periods
    ) internal pure returns (uint256 finalAmount) {
        uint256 growthFactor = MAX_BPS + rate;
        uint256 compoundFactor = PRECISION;
        
        for (uint256 i = 0; i < periods; i++) {
            compoundFactor = Math.mulDiv(compoundFactor, growthFactor, MAX_BPS);
        }
        
        return Math.mulDiv(principal, compoundFactor, PRECISION);
    }

    /**
     * @notice Calculates square root using Babylonian method
     * @param x Input value
     * @return y Square root
     */
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /**
     * @notice Safely adds with overflow check
     * @param a First number
     * @param b Second number
     * @return result Sum of a and b
     */
    function safeAdd(uint256 a, uint256 b) internal pure returns (uint256 result) {
        result = a + b;
        require(result >= a, "Addition overflow");
    }

    /**
     * @notice Calculates ratio between two numbers
     * @param numerator Numerator
     * @param denominator Denominator
     * @return ratio Ratio in BPS
     */
    function calculateRatio(uint256 numerator, uint256 denominator) internal pure returns (uint256 ratio) {
        if (denominator == 0) return 0;
        return Math.mulDiv(numerator, MAX_BPS, denominator);
    }

    /**
     * @notice Finds minimum of two numbers
     * @param a First number
     * @param b Second number
     * @return minValue Minimum value
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256 minValue) {
        return a < b ? a : b;
    }

    /**
     * @notice Finds maximum of two numbers
     * @param a First number
     * @param b Second number
     * @return maxValue Maximum value
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256 maxValue) {
        return a > b ? a : b;
    }

    /**
     * @notice Calculates absolute difference between two numbers
     * @param a First number
     * @param b Second number
     * @return diff Absolute difference
     */
    function absDiff(uint256 a, uint256 b) internal pure returns (uint256 diff) {
        return a > b ? a - b : b - a;
    }

    /**
     * @notice Calculates exponential with limited precision
     * @param x Input value (scaled by PRECISION)
     * @return result Exponential result
     */
    function exp(uint256 x) internal pure returns (uint256 result) {
        // Simple approximation for small values
        // e^x ≈ 1 + x + x²/2! + x³/3! + ...
        if (x == 0) return PRECISION;
        if (x >= 20 * PRECISION) return type(uint256).max; // Prevent overflow
        
        result = PRECISION;
        uint256 term = x;
        
        // Add first few terms of Taylor series
        for (uint256 i = 1; i <= 10 && term > 0; i++) {
            result += term;
            term = Math.mulDiv(term, x, i * PRECISION);
        }
    }

    /**
     * @notice Calculates natural logarithm (approximate)
     * @param x Input value (scaled by PRECISION)
     * @return result Natural log result
     */
    function ln(uint256 x) internal pure returns (uint256 result) {
        require(x > 0, "ln(0) undefined");
        if (x == PRECISION) return 0;
        
        // Use Newton's method: ln(x) = y where e^y = x
        uint256 y = x > PRECISION ? x - PRECISION : PRECISION - x;
        
        for (uint256 i = 0; i < 10; i++) {
            uint256 ey = exp(y);
            if (ey == x) break;
            
            if (ey > x) {
                y = Math.mulDiv(y, x, ey);
            } else {
                y += Math.mulDiv(PRECISION, x - ey, ey);
            }
        }
        
        return y;
    }

    /**
     * @notice Calculates power with integer exponent
     * @param base Base value
     * @param exponent Exponent
     * @return result Base raised to exponent
     */
    function pow(uint256 base, uint256 exponent) internal pure returns (uint256 result) {
        if (exponent == 0) return 1;
        if (base == 0) return 0;
        
        result = 1;
        uint256 currentBase = base;
        
        while (exponent > 0) {
            if (exponent % 2 == 1) {
                result = result * currentBase;
            }
            currentBase = currentBase * currentBase;
            exponent /= 2;
        }
    }

    /**
     * @notice Calculates moving average
     * @param currentAverage Current moving average
     * @param newValue New value to include
     * @param count Number of values in average
     * @return newAverage Updated moving average
     */
    function updateMovingAverage(
        uint256 currentAverage,
        uint256 newValue,
        uint256 count
    ) internal pure returns (uint256 newAverage) {
        if (count == 0) return newValue;
        return Math.mulDiv(currentAverage * (count - 1) + newValue, 1, count);
    }

    /**
     * @notice Calculates standard deviation (simplified)
     * @param values Array of values
     * @return stdDev Standard deviation
     */
    function calculateStandardDeviation(uint256[] memory values) internal pure returns (uint256 stdDev) {
        if (values.length <= 1) return 0;
        
        // Calculate mean
        uint256 sum = 0;
        for (uint256 i = 0; i < values.length; i++) {
            sum += values[i];
        }
        uint256 mean = sum / values.length;
        
        // Calculate variance
        uint256 variance = 0;
        for (uint256 i = 0; i < values.length; i++) {
            uint256 diff = absDiff(values[i], mean);
            variance += diff * diff;
        }
        variance = variance / values.length;
        
        // Return square root of variance
        return sqrt(variance);
    }

    /**
     * @notice Interpolates between two values
     * @param startValue Start value
     * @param endValue End value
     * @param ratio Interpolation ratio in BPS (0 = start, 10000 = end)
     * @return interpolatedValue Interpolated value
     */
    function interpolate(
        uint256 startValue,
        uint256 endValue,
        uint256 ratio
    ) internal pure returns (uint256 interpolatedValue) {
        if (ratio >= MAX_BPS) return endValue;
        if (ratio == 0) return startValue;
        
        if (endValue >= startValue) {
            uint256 diff = endValue - startValue;
            return startValue + Math.mulDiv(diff, ratio, MAX_BPS);
        } else {
            uint256 diff = startValue - endValue;
            return startValue - Math.mulDiv(diff, ratio, MAX_BPS);
        }
    }
}

/**
 * @title MathUtilities Contract
 */
contract MathUtilities {
    function getLibraryVersion() external pure returns (string memory) {
        return "MATH-1.0.0";
    }
    
    // Math helper functions for testing
    function calculatePercentage(uint256 amount, uint256 bps) external pure returns (uint256) {
        return MathHelperLib.calculatePercentage(amount, bps);
    }
    
    function calculateSlippage(uint256 amount, uint256 slippageBps) external pure returns (uint256) {
        return MathHelperLib.calculateSlippage(amount, slippageBps);
    }
    
    function sqrt(uint256 x) external pure returns (uint256) {
        return MathHelperLib.sqrt(x);
    }
    
    function calculateWeightedAverage(
        uint256[] memory values,
        uint256[] memory weights
    ) external pure returns (uint256) {
        return MathHelperLib.calculateWeightedAverage(values, weights);
    }
    
    function calculateCompoundGrowth(
        uint256 principal,
        uint256 rate,
        uint256 periods
    ) external pure returns (uint256) {
        return MathHelperLib.calculateCompoundGrowth(principal, rate, periods);
    }
    
    function calculateRatio(uint256 numerator, uint256 denominator) external pure returns (uint256) {
        return MathHelperLib.calculateRatio(numerator, denominator);
    }
    
    function min(uint256 a, uint256 b) external pure returns (uint256) {
        return MathHelperLib.min(a, b);
    }
    
    function max(uint256 a, uint256 b) external pure returns (uint256) {
        return MathHelperLib.max(a, b);
    }
    
    function absDiff(uint256 a, uint256 b) external pure returns (uint256) {
        return MathHelperLib.absDiff(a, b);
    }
    
    function pow(uint256 base, uint256 exponent) external pure returns (uint256) {
        return MathHelperLib.pow(base, exponent);
    }
    
    function updateMovingAverage(
        uint256 currentAverage,
        uint256 newValue,
        uint256 count
    ) external pure returns (uint256) {
        return MathHelperLib.updateMovingAverage(currentAverage, newValue, count);
    }
    
    function calculateStandardDeviation(uint256[] memory values) external pure returns (uint256) {
        return MathHelperLib.calculateStandardDeviation(values);
    }
    
    function interpolate(
        uint256 startValue,
        uint256 endValue,
        uint256 ratio
    ) external pure returns (uint256) {
        return MathHelperLib.interpolate(startValue, endValue, ratio);
    }
    
    function exp(uint256 x) external pure returns (uint256) {
        return MathHelperLib.exp(x);
    }
    
    function ln(uint256 x) external pure returns (uint256) {
        return MathHelperLib.ln(x);
    }
}