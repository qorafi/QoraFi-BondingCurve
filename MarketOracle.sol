// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

// --- INTERFACES ---
interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

interface IERC20Supply {
    function totalSupply() external view returns (uint256);
}

/**
 * @title MarketOracle (Fixed Version)
 * @notice A secure oracle for the BondingCurve with corrected TWAP calculations and enhanced security
 * @dev Requires separate governance and oracle updater addresses for security
 */
contract MarketOracle is AccessControl, ReentrancyGuard {
    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant ORACLE_UPDATER_ROLE = keccak256("ORACLE_UPDATER_ROLE");

    // --- STRUCTS ---
    struct TWAPObservation {
        uint256 price0Cumulative;
        uint256 price1Cumulative;
        uint32 timestamp;
        bool isValid;
    }

    // --- STATE VARIABLES ---
    IERC20Metadata public immutable usdtToken;
    IERC20Supply public immutable qorafiToken;
    IUniswapV2Pair public immutable lpPair;

    uint256 public cachedMarketCap;
    uint256 public lastOracleUpdateTime;
    bool private immutable qorafiIsToken0InPair;
    uint256 public qorafiPriceTwap;
    
    TWAPObservation[] private twapObservations;
    uint256 private observationIndex;
    uint256 public constant MIN_TWAP_OBSERVATIONS = 3;
    uint256 public constant MAX_TWAP_OBSERVATIONS = 24;
    uint256 public constant MAX_OBSERVATION_AGE = 1 hours;
    
    uint256 public maxPriceChangeBPS;
    uint256 public maxMarketCapGrowthBPS;
    uint256 public minOracleUpdateInterval;
    uint256 public minLpLiquidity;
    
    uint256 public mcLowerLimit;
    uint256 public mcUpperLimit;

    // Emergency fallback
    bool public emergencyMode;
    uint256 public fallbackPrice;

    // --- EVENTS ---
    event MarketCapUpdated(uint256 newMarketCap, uint256 newPrice);
    event TWAPObservationAdded(uint256 price0Cumulative, uint256 price1Cumulative, uint32 timestamp);
    event PriceValidationPassed(uint256 oldPrice, uint256 newPrice, uint256 changeBPS);
    event EmergencyModeToggled(bool enabled);
    event FallbackPriceSet(uint256 price);
    event ObservationInvalidated(uint256 index, uint32 timestamp);

    // --- ERRORS ---
    error InvalidAddress();
    error InvalidMarketCapLimits();
    error UpdateTooFrequent();
    error InsufficientObservations();
    error InvalidTimeElapsed();
    error InvalidReserves();
    error InvalidPrices();
    error PriceChangeTooLarge();
    error MarketCapGrowthTooLarge();
    error NoObservations();
    error InvalidPriceChangeLimit();
    error InvalidGrowthLimit();
    error InvalidUpdateInterval();
    error StaleObservations();
    error InsufficientLiquidity();
    error EmergencyModeActive();
    error RolesSameAddress();

    constructor(
        address _usdt, 
        address _qorafi, 
        address _lpPair, 
        uint256 _mcLower, 
        uint256 _mcUpper,
        address _governance,
        address _oracleUpdater
    ) {
        if (_usdt == address(0) || _qorafi == address(0) || _lpPair == address(0)) revert InvalidAddress();
        if (_governance == address(0) || _oracleUpdater == address(0)) revert InvalidAddress();
        if (_governance == _oracleUpdater) revert RolesSameAddress();
        if (_mcLower == 0 || _mcUpper <= _mcLower) revert InvalidMarketCapLimits();
        
        _grantRole(GOVERNANCE_ROLE, _governance);
        _grantRole(ORACLE_UPDATER_ROLE, _oracleUpdater);

        usdtToken = IERC20Metadata(_usdt);
        qorafiToken = IERC20Supply(_qorafi);
        lpPair = IUniswapV2Pair(_lpPair);
        qorafiIsToken0InPair = lpPair.token0() == _qorafi;
        mcLowerLimit = _mcLower;
        mcUpperLimit = _mcUpper;

        maxPriceChangeBPS = 1000; // 10%
        maxMarketCapGrowthBPS = 2000; // 20%
        minOracleUpdateInterval = 5 minutes;
        minLpLiquidity = 1000 * 1e18; // 1000 QoraFi minimum

        (uint256 price0, uint256 price1, uint32 ts) = _getCurrentCumulativePrices();
        twapObservations.push(TWAPObservation({
            price0Cumulative: price0,
            price1Cumulative: price1,
            timestamp: ts,
            isValid: true
        }));
        
        lastOracleUpdateTime = block.timestamp;
    }

    function updateMarketCap() external nonReentrant onlyRole(ORACLE_UPDATER_ROLE) {
        if (emergencyMode) revert EmergencyModeActive();
        if (block.timestamp - lastOracleUpdateTime < minOracleUpdateInterval) revert UpdateTooFrequent();
        
        _updateTWAPObservations();
        uint256 newPrice = _getEnhancedTWAPPrice();
        
        if (qorafiPriceTwap > 0) {
            _validatePriceChange(qorafiPriceTwap, newPrice);
        }

        uint256 totalSupply = qorafiToken.totalSupply();
        require(totalSupply > 0, "Invalid total supply");
        
        uint256 newMarketCap = Math.mulDiv(totalSupply, newPrice, 1e18);
        
        if (cachedMarketCap > 0) {
            _validateMarketCapGrowth(cachedMarketCap, newMarketCap);
        }

        cachedMarketCap = newMarketCap;
        qorafiPriceTwap = newPrice;
        lastOracleUpdateTime = block.timestamp;
        
        emit MarketCapUpdated(newMarketCap, newPrice);
    }

    // --- VIEW FUNCTIONS ---
    function getCachedMarketCap() external view returns (uint256) {
        return cachedMarketCap;
    }

    function checkMarketCapLimits() external view {
        require(cachedMarketCap > 0, "Market cap not initialized");
        require(cachedMarketCap <= mcUpperLimit, "Market cap too high");
        require(cachedMarketCap >= mcLowerLimit, "Market cap too low");
        require(block.timestamp - lastOracleUpdateTime <= 1 hours, "Oracle data stale");
        require(!emergencyMode, "Emergency mode active");
    }

    function isHealthy() external view returns (bool) {
        return !emergencyMode && 
               (block.timestamp - lastOracleUpdateTime <= 1 hours) &&
               twapObservations.length >= MIN_TWAP_OBSERVATIONS;
    }
    
    function _getEnhancedTWAPPrice() private view returns (uint256) {
        if (twapObservations.length < MIN_TWAP_OBSERVATIONS) revert InsufficientObservations();
        
        uint32 currentTime = uint32(block.timestamp);
        uint256 totalWeightedPrice = 0;
        uint256 totalTimeWeight = 0;
        
        for (uint256 i = 1; i < twapObservations.length; i++) {
            TWAPObservation memory current = twapObservations[i];
            TWAPObservation memory previous = twapObservations[i - 1];
            
            if (!current.isValid || !previous.isValid) continue;
            if (currentTime - current.timestamp > MAX_OBSERVATION_AGE || 
                currentTime - previous.timestamp > MAX_OBSERVATION_AGE) continue;
            
            uint32 timeElapsed = current.timestamp - previous.timestamp;
            if (timeElapsed == 0) continue;
            
            uint256 priceCumulativeDiff = qorafiIsToken0InPair ? 
                (current.price0Cumulative - previous.price0Cumulative) : 
                (current.price1Cumulative - previous.price1Cumulative);
            
            uint256 periodPrice = _calculateTwapPrice(priceCumulativeDiff, timeElapsed);
            
            totalWeightedPrice += periodPrice * timeElapsed;
            totalTimeWeight += timeElapsed;
        }
        
        if (totalTimeWeight == 0) revert StaleObservations();
        return totalWeightedPrice / totalTimeWeight;
    }
    
    function _calculateTwapPrice(uint256 priceCumulativeDiff, uint32 timeElapsed) internal view returns (uint256) {
        if (timeElapsed == 0) revert InvalidTimeElapsed();
        
        uint256 avgPriceQ112 = priceCumulativeDiff / timeElapsed;
        
        if (qorafiIsToken0InPair) {
            if (avgPriceQ112 == 0) revert InvalidPrices();
            return Math.mulDiv(uint256(2**112), 10**usdtToken.decimals(), avgPriceQ112);
        } else {
            return Math.mulDiv(avgPriceQ112, 10**usdtToken.decimals(), uint256(2**112));
        }
    }
    
    function _validatePriceChange(uint256 oldPrice, uint256 newPrice) private view {
        if (oldPrice == 0 || newPrice == 0) revert InvalidPrices();
        
        uint256 priceDiff = newPrice > oldPrice ? newPrice - oldPrice : oldPrice - newPrice;
        
        uint256 changePercent = Math.mulDiv(priceDiff, 10000, oldPrice);
        if (changePercent > maxPriceChangeBPS) revert PriceChangeTooLarge();
        
        emit PriceValidationPassed(oldPrice, newPrice, changePercent);
    }

    function _validateMarketCapGrowth(uint256 oldCap, uint256 newCap) private view {
        if (oldCap == 0 || newCap == 0) revert InvalidPrices();
        
        if (newCap > oldCap) {
            uint256 growthPercent = Math.mulDiv(newCap - oldCap, 10000, oldCap);
            if (growthPercent > maxMarketCapGrowthBPS) revert MarketCapGrowthTooLarge();
        }
    }
    
    function _updateTWAPObservations() private {
        (uint256 price0, uint256 price1, uint32 currentTimestamp) = _getCurrentCumulativePrices();
        
        if (twapObservations.length > 0) {
            uint32 lastTimestamp = twapObservations[twapObservations.length - 1].timestamp;
            require(currentTimestamp > lastTimestamp, "No time elapsed");
        }
        
        if (twapObservations.length < MAX_TWAP_OBSERVATIONS) {
            twapObservations.push(TWAPObservation({
                price0Cumulative: price0,
                price1Cumulative: price1,
                timestamp: currentTimestamp,
                isValid: true
            }));
        } else {
            observationIndex = (observationIndex + 1) % MAX_TWAP_OBSERVATIONS;
            emit ObservationInvalidated(observationIndex, twapObservations[observationIndex].timestamp);
            
            twapObservations[observationIndex] = TWAPObservation({
                price0Cumulative: price0,
                price1Cumulative: price1,
                timestamp: currentTimestamp,
                isValid: true
            });
        }
        
        emit TWAPObservationAdded(price0, price1, currentTimestamp);
    }
    
    function _getCurrentCumulativePrices() private view returns (uint256, uint256, uint32) {
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = lpPair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) revert InvalidReserves();
        
        uint256 qorafiReserve = qorafiIsToken0InPair ? uint256(reserve0) : uint256(reserve1);
        if (qorafiReserve < minLpLiquidity) revert InsufficientLiquidity();
        
        uint256 price0Cumulative = lpPair.price0CumulativeLast();
        uint256 price1Cumulative = lpPair.price1CumulativeLast();
        
        uint32 timeElapsed = uint32(block.timestamp) - blockTimestampLast;
        
        if (timeElapsed > 0) {
            price0Cumulative += Math.mulDiv(uint256(reserve1) * 2**112, timeElapsed, reserve0);
            price1Cumulative += Math.mulDiv(uint256(reserve0) * 2**112, timeElapsed, reserve1);
        }
        
        return (price0Cumulative, price1Cumulative, uint32(block.timestamp));
    }

    // --- EMERGENCY FUNCTIONS ---
    function enableEmergencyMode() external onlyRole(GOVERNANCE_ROLE) {
        emergencyMode = true;
        emit EmergencyModeToggled(true);
    }

    function disableEmergencyMode() external onlyRole(GOVERNANCE_ROLE) {
        emergencyMode = false;
        emit EmergencyModeToggled(false);
    }

    function setFallbackPrice(uint256 _price) external onlyRole(GOVERNANCE_ROLE) {
        require(_price > 0, "Invalid price");
        fallbackPrice = _price;
        emit FallbackPriceSet(_price);
    }

    // --- GOVERNANCE FUNCTIONS ---
    function setMaxPriceChange(uint256 _maxChangeBPS) external onlyRole(GOVERNANCE_ROLE) {
        if (_maxChangeBPS == 0 || _maxChangeBPS > 5000) revert InvalidPriceChangeLimit();
        maxPriceChangeBPS = _maxChangeBPS;
    }

    function setMaxMarketCapGrowth(uint256 _maxGrowthBPS) external onlyRole(GOVERNANCE_ROLE) {
        if (_maxGrowthBPS == 0 || _maxGrowthBPS > 10000) revert InvalidGrowthLimit();
        maxMarketCapGrowthBPS = _maxGrowthBPS;
    }

    function setUpdateInterval(uint256 _newInterval) external onlyRole(GOVERNANCE_ROLE) {
        if (_newInterval < 1 minutes || _newInterval > 1 hours) revert InvalidUpdateInterval();
        minOracleUpdateInterval = _newInterval;
    }

    function setMarketCapLimits(uint256 _lower, uint256 _upper) external onlyRole(GOVERNANCE_ROLE) {
        if (_lower == 0 || _upper <= _lower) revert InvalidMarketCapLimits();
        mcLowerLimit = _lower;
        mcUpperLimit = _upper;
    }

    function setMinLpLiquidity(uint256 _minLiquidity) external onlyRole(GOVERNANCE_ROLE) {
        require(_minLiquidity > 0, "Invalid liquidity");
        minLpLiquidity = _minLiquidity;
    }

    function forceUpdatePrice(uint256 _newPrice) external onlyRole(GOVERNANCE_ROLE) {
        require(_newPrice > 0, "Invalid price");
        qorafiPriceTwap = _newPrice;
        
        uint256 totalSupply = qorafiToken.totalSupply();
        cachedMarketCap = Math.mulDiv(totalSupply, _newPrice, 1e18);
        lastOracleUpdateTime = block.timestamp;
        
        emit MarketCapUpdated(cachedMarketCap, _newPrice);
    }

    // --- VIEW FUNCTIONS for Monitoring ---
    function getCurrentPrice() external view returns (uint256) {
        if (emergencyMode && fallbackPrice > 0) {
            return fallbackPrice;
        }
        
        if (twapObservations.length < MIN_TWAP_OBSERVATIONS) return 0;
        
        try this._getEnhancedTWAPPrice() returns (uint256 price) {
            return price;
        } catch {
            return fallbackPrice;
        }
    }

    function getObservationCount() external view returns (uint256) {
        return twapObservations.length;
    }

    function getLatestObservation() external view returns (TWAPObservation memory) {
        if (twapObservations.length == 0) revert NoObservations();
        return twapObservations[twapObservations.length - 1];
    }

    function getObservation(uint256 index) external view returns (TWAPObservation memory) {
        require(index < twapObservations.length, "Index out of bounds");
        return twapObservations[index];
    }
}