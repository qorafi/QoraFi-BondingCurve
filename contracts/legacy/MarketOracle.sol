// contracts/legacy/MarketOracle.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

/**
 * @title MarketOracle (Legacy Implementation)
 * @notice Original oracle contract (~800 lines) - kept for reference
 * @dev This is the original implementation before modularization
 */

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

contract MarketOracle is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, UUPSUpgradeable {
    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant ORACLE_UPDATER_ROLE = keccak256("ORACLE_UPDATER_ROLE");

    // --- STRUCTS ---
    // Optimized struct packing: uint32 and bool fit into a single 32-byte slot.
    struct TWAPObservation {
        uint256 price0Cumulative;
        uint256 price1Cumulative;
        uint32 timestamp;
        bool isValid;
        uint256 liquiditySnapshot; // Track liquidity at time of observation
    }

    struct PriceValidationData {
        uint256 lastValidatedPrice;
        uint256 lastValidationTime;
        uint256 priceImpactThreshold;
        uint256 maxPriceChangePerUpdate;
        uint256 minTimeBetweenUpdates;
    }

    // --- STATE VARIABLES ---
    IERC20Metadata public usdtToken;
    IERC20Supply public qorafiToken;
    IUniswapV2Pair public lpPair;

    uint256 public cachedMarketCap;
    uint256 public lastOracleUpdateTime;
    bool private qorafiIsToken0InPair;
    uint256 public qorafiPriceTwap;
    
    TWAPObservation[] private twapObservations;
    uint256 private observationIndex;
    uint256 public validObservationCount;
    uint8 private usdtDecimals;

    PriceValidationData public priceValidation;

    uint256 public constant MIN_TWAP_OBSERVATIONS = 3;
    uint256 public constant MAX_TWAP_OBSERVATIONS = 24;
    uint256 public constant MAX_OBSERVATION_AGE = 2 hours; // Increased for new token
    uint256 public constant MIN_OBSERVATION_INTERVAL = 5 minutes; // Minimum time between observations
    uint256 public constant MIN_LIQUIDITY_USD = 10000; // Minimum $10k liquidity for pricing
    
    uint256 public maxPriceChangeBPS;
    uint256 public maxMarketCapGrowthBPS;
    uint256 public minOracleUpdateInterval;
    uint256 public minLpLiquidity;
    
    uint256 public mcLowerLimit;
    uint256 public mcUpperLimit;

    bool public emergencyMode;
    uint256 public fallbackPrice;
    
    // New token specific protection
    bool public newTokenMode;
    uint256 public flashLoanDetectionWindow;
    mapping(uint256 => uint256) public blockPriceUpdates; // Track updates per block
    uint256 public maxUpdatesPerBlock;
    
    // Liquidity monitoring
    uint256 public minimumUsdtLiquidity;
    uint256 public lastLiquidityCheck;
    uint256 public liquidityCheckInterval;

    // --- EVENTS ---
    event MarketCapUpdated(uint256 newMarketCap, uint256 newPrice);
    event TWAPObservationAdded(uint256 price0Cumulative, uint256 price1Cumulative, uint32 timestamp, uint256 liquidity);
    event PriceValidationPassed(uint256 oldPrice, uint256 newPrice, uint256 changeBPS);
    event EmergencyModeToggled(bool enabled);
    event FallbackPriceSet(uint256 price);
    event ObservationInvalidated(uint256 index, uint32 timestamp, string reason);
    event LiquidityThresholdBreached(uint256 currentLiquidity, uint256 minimumRequired);
    event PriceImpactDetected(uint256 priceImpact, uint256 threshold);
    event FlashLoanAttackDetected(uint256 blockNumber, uint256 updateCount);
    event NewTokenModeToggled(bool enabled);

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
    error PriceImpactExceedsThreshold();
    error FlashLoanDetectionTriggered();
    error TooManyBlockUpdates();
    error LiquidityBelowThreshold();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _usdt, 
        address _qorafi, 
        address _lpPair, 
        uint256 _mcLower, 
        uint256 _mcUpper,
        address _governance,
        address _oracleUpdater
    ) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

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
        usdtDecimals = usdtToken.decimals();

        // More conservative settings for new token
        maxPriceChangeBPS = 2000; // 20% max price change per update
        maxMarketCapGrowthBPS = 3000; // 30% max market cap growth
        minOracleUpdateInterval = 5 minutes;
        minLpLiquidity = 1000 * 1e18;
        
        // New token specific settings
        newTokenMode = true;
        flashLoanDetectionWindow = 3; // 3 blocks
        maxUpdatesPerBlock = 1; // Only 1 update per block for new token
        minimumUsdtLiquidity = MIN_LIQUIDITY_USD * (10 ** usdtDecimals);
        liquidityCheckInterval = 1 hours;
        
        // Price validation settings
        priceValidation = PriceValidationData({
            lastValidatedPrice: 0,
            lastValidationTime: 0,
            priceImpactThreshold: 1000, // 10% price impact threshold
            maxPriceChangePerUpdate: 1500, // 15% max change per update for new token
            minTimeBetweenUpdates: MIN_OBSERVATION_INTERVAL
        });

        // Initialize with first observation
        (uint256 price0, uint256 price1, uint32 ts) = _getCurrentCumulativePrices();
        uint256 currentLiquidity = _getCurrentLiquidityUSDT();
        
        twapObservations.push(TWAPObservation({
            price0Cumulative: price0,
            price1Cumulative: price1,
            timestamp: ts,
            isValid: true,
            liquiditySnapshot: currentLiquidity
        }));
        validObservationCount = 1;
        
        lastOracleUpdateTime = block.timestamp;
        lastLiquidityCheck = block.timestamp;
    }

    function updateMarketCap() external nonReentrant onlyRole(ORACLE_UPDATER_ROLE) {
        if (emergencyMode) revert EmergencyModeActive();
        if (block.timestamp - lastOracleUpdateTime < minOracleUpdateInterval) revert UpdateTooFrequent();
        
        // Flash loan protection - limit updates per block
        if (newTokenMode) {
            blockPriceUpdates[block.number]++;
            if (blockPriceUpdates[block.number] > maxUpdatesPerBlock) {
                emit FlashLoanAttackDetected(block.number, blockPriceUpdates[block.number]);
                revert TooManyBlockUpdates();
            }
        }
        
        // Validate liquidity depth before price update
        _validateLiquidityDepth();
        
        _updateTWAPObservations();
        uint256 newPrice = _getEnhancedTWAPPrice();
        
        // Enhanced price validation for new token
        if (qorafiPriceTwap > 0) {
            _validatePriceChange(qorafiPriceTwap, newPrice);
            
            // Check price impact separately and emit event here (outside view function)
            if (priceValidation.lastValidatedPrice > 0) {
                uint256 priceImpact = _calculatePriceImpact(priceValidation.lastValidatedPrice, newPrice);
                if (priceImpact > priceValidation.priceImpactThreshold) {
                    emit PriceImpactDetected(priceImpact, priceValidation.priceImpactThreshold);
                    revert PriceImpactExceedsThreshold();
                }
            }
        }

        uint256 totalSupply = qorafiToken.totalSupply();
        require(totalSupply > 0, "Invalid total supply");
        
        uint256 newMarketCap = Math.mulDiv(totalSupply, newPrice, 1e18);
        
        if (cachedMarketCap > 0) {
            _validateMarketCapGrowth(cachedMarketCap, newMarketCap);
        }

        // Update state
        cachedMarketCap = newMarketCap;
        qorafiPriceTwap = newPrice;
        lastOracleUpdateTime = block.timestamp;
        
        // Update price validation data
        priceValidation.lastValidatedPrice = newPrice;
        priceValidation.lastValidationTime = block.timestamp;
        
        emit MarketCapUpdated(newMarketCap, newPrice);
    }

    // --- ENHANCED VALIDATION FUNCTIONS ---
    function _validateLiquidityDepth() internal {
        uint256 currentLiquidity = _getCurrentLiquidityUSDT();
        
        if (currentLiquidity < minimumUsdtLiquidity) {
            emit LiquidityThresholdBreached(currentLiquidity, minimumUsdtLiquidity);
            revert LiquidityBelowThreshold();
        }
        
        // Update liquidity check timestamp
        if (block.timestamp >= lastLiquidityCheck + liquidityCheckInterval) {
            lastLiquidityCheck = block.timestamp;
        }
    }

    function _validatePriceImpact(uint256 newPrice) internal view {
        if (priceValidation.lastValidatedPrice == 0) return;
        
        // Calculate price impact from last validated price
        uint256 priceImpact = _calculatePriceImpact(priceValidation.lastValidatedPrice, newPrice);
        
        if (priceImpact > priceValidation.priceImpactThreshold) {
            revert PriceImpactExceedsThreshold();
        }
    }

    function _calculatePriceImpact(uint256 oldPrice, uint256 newPrice) internal pure returns (uint256) {
        if (oldPrice == 0 || newPrice == 0) return 0;
        
        uint256 priceDiff = newPrice > oldPrice ? newPrice - oldPrice : oldPrice - newPrice;
        return Math.mulDiv(priceDiff, 10000, oldPrice);
    }

    function _getCurrentLiquidityUSDT() internal view returns (uint256) {
        (uint112 reserve0, uint112 reserve1,) = lpPair.getReserves();
        
        uint256 usdtReserve = qorafiIsToken0InPair ? uint256(reserve1) : uint256(reserve0);
        return usdtReserve;
    }

    // --- VIEW FUNCTIONS ---
    function getCachedMarketCap() external view returns (uint256) {
        return cachedMarketCap;
    }

    function checkMarketCapLimits() external view {
        require(cachedMarketCap > 0, "Market cap not initialized");
        require(cachedMarketCap <= mcUpperLimit, "Market cap too high");
        require(cachedMarketCap >= mcLowerLimit, "Market cap too low");
        require(block.timestamp - lastOracleUpdateTime <= MAX_OBSERVATION_AGE, "Oracle data stale");
        require(!emergencyMode, "Emergency mode active");
        
        // Additional check for liquidity
        uint256 currentLiquidity = _getCurrentLiquidityUSDT();
        require(currentLiquidity >= minimumUsdtLiquidity, "Insufficient liquidity");
    }

    function isHealthy() external view returns (bool) {
        if (emergencyMode) return false;
        if (block.timestamp - lastOracleUpdateTime > MAX_OBSERVATION_AGE) return false;
        if (validObservationCount < MIN_TWAP_OBSERVATIONS) return false;
        
        // Check liquidity health
        try this.getCurrentLiquidityUSDTExternal() returns (uint256 liquidity) {
            if (liquidity < minimumUsdtLiquidity) return false;
        } catch {
            return false;
        }
        
        return true;
    }

    // External wrapper for internal function to make it accessible for try/catch
    function getCurrentLiquidityUSDTExternal() external view returns (uint256) {
        return _getCurrentLiquidityUSDT();
    }
    
    function _getEnhancedTWAPPrice() private view returns (uint256) {
        uint256 observationsLength = twapObservations.length;
        if (observationsLength < MIN_TWAP_OBSERVATIONS) revert InsufficientObservations();
        
        uint32 currentTime = uint32(block.timestamp);
        uint256 totalWeightedPrice = 0;
        uint256 totalTimeWeight = 0;
        bool _qorafiIsToken0 = qorafiIsToken0InPair;
        
        TWAPObservation memory previous = twapObservations[0];
        
        for (uint256 i = 1; i < observationsLength; i++) {
            TWAPObservation memory current = twapObservations[i];
            
            if (!current.isValid || !previous.isValid) {
                previous = current;
                continue;
            }
            
            // Enhanced validation for observation age and quality
            if (currentTime - current.timestamp > MAX_OBSERVATION_AGE || 
                currentTime - previous.timestamp > MAX_OBSERVATION_AGE) {
                previous = current;
                continue;
            }
            
            uint32 timeElapsed = current.timestamp - previous.timestamp;
            
            // Enforce minimum time between observations to prevent manipulation
            if (timeElapsed < MIN_OBSERVATION_INTERVAL) {
                previous = current;
                continue;
            }
            
            // Check liquidity consistency between observations
            if (newTokenMode && previous.liquiditySnapshot > 0 && current.liquiditySnapshot > 0) {
                uint256 liquidityChange = current.liquiditySnapshot > previous.liquiditySnapshot 
                    ? current.liquiditySnapshot - previous.liquiditySnapshot 
                    : previous.liquiditySnapshot - current.liquiditySnapshot;
                
                // If liquidity changed by more than 50%, be more cautious
                if (Math.mulDiv(liquidityChange, 10000, previous.liquiditySnapshot) > 5000) {
                    // Reduce weight of this observation
                    timeElapsed = timeElapsed / 2;
                }
            }
            
            uint256 priceCumulativeDiff = _qorafiIsToken0 ? 
                (current.price0Cumulative - previous.price0Cumulative) : 
                (current.price1Cumulative - previous.price1Cumulative);
            
            uint256 periodPrice = _calculateTwapPrice(priceCumulativeDiff, timeElapsed);
            
            totalWeightedPrice += periodPrice * timeElapsed;
            totalTimeWeight += timeElapsed;
            
            previous = current;
        }
        
        if (totalTimeWeight == 0) revert StaleObservations();
        return totalWeightedPrice / totalTimeWeight;
    }
    
    function _calculateTwapPrice(uint256 priceCumulativeDiff, uint32 timeElapsed) internal view returns (uint256) {
        if (timeElapsed == 0) revert InvalidTimeElapsed();
        
        unchecked {
            uint256 avgPriceQ112 = priceCumulativeDiff / timeElapsed;
            
            if (qorafiIsToken0InPair) {
                if (avgPriceQ112 == 0) revert InvalidPrices();
                return Math.mulDiv(uint256(2**112), 10**usdtDecimals, avgPriceQ112);
            } else {
                return Math.mulDiv(avgPriceQ112, 10**usdtDecimals, uint256(2**112));
            }
        }
    }
    
    function _validatePriceChange(uint256 oldPrice, uint256 newPrice) private {
        if (oldPrice == 0 || newPrice == 0) revert InvalidPrices();
        
        uint256 priceDiff = newPrice > oldPrice ? newPrice - oldPrice : oldPrice - newPrice;
        
        // Use new token specific max change if in new token mode
        uint256 maxChange = newTokenMode ? priceValidation.maxPriceChangePerUpdate : maxPriceChangeBPS;
        uint256 changePercent = Math.mulDiv(priceDiff, 10000, oldPrice);
        
        if (changePercent > maxChange) revert PriceChangeTooLarge();
        
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
        uint256 currentLiquidity = _getCurrentLiquidityUSDT();
        
        if (twapObservations.length > 0) {
            uint32 lastTimestamp = twapObservations[twapObservations.length - 1].timestamp;
            require(currentTimestamp > lastTimestamp, "No time elapsed");
            
            // Enforce minimum time between observations
            require(currentTimestamp - lastTimestamp >= MIN_OBSERVATION_INTERVAL, "Update too frequent");
        }
        
        if (twapObservations.length < MAX_TWAP_OBSERVATIONS) {
            twapObservations.push(TWAPObservation({
                price0Cumulative: price0,
                price1Cumulative: price1,
                timestamp: currentTimestamp,
                isValid: true,
                liquiditySnapshot: currentLiquidity
            }));
            validObservationCount++;
        } else {
            if (!twapObservations[observationIndex].isValid) {
                validObservationCount++;
            }
            observationIndex = (observationIndex + 1) % MAX_TWAP_OBSERVATIONS;
            emit ObservationInvalidated(observationIndex, twapObservations[observationIndex].timestamp, "Buffer full");
            
            twapObservations[observationIndex] = TWAPObservation({
                price0Cumulative: price0,
                price1Cumulative: price1,
                timestamp: currentTimestamp,
                isValid: true,
                liquiditySnapshot: currentLiquidity
            });
        }
        
        emit TWAPObservationAdded(price0, price1, currentTimestamp, currentLiquidity);
    }
    
    function _getCurrentCumulativePrices() private view returns (uint256, uint256, uint32) {
        (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast) = lpPair.getReserves();
        if (reserve0 == 0 || reserve1 == 0) revert InvalidReserves();
        
        // Enhanced liquidity validation for new token
        uint256 qorafiReserve = qorafiIsToken0InPair ? uint256(reserve0) : uint256(reserve1);
        uint256 usdtReserve = qorafiIsToken0InPair ? uint256(reserve1) : uint256(reserve0);
        
        if (qorafiReserve < minLpLiquidity) revert InsufficientLiquidity();
        if (usdtReserve < minimumUsdtLiquidity) revert InsufficientLiquidity();
        
        uint256 price0Cumulative = lpPair.price0CumulativeLast();
        uint256 price1Cumulative = lpPair.price1CumulativeLast();
        
        uint32 timeElapsed;
        uint32 currentTime;
        
        assembly {
            currentTime := timestamp()
            timeElapsed := sub(currentTime, blockTimestampLast)
        }
        
        if (timeElapsed > 0) {
            unchecked {
                price0Cumulative += Math.mulDiv(uint256(reserve1) * 2**112, timeElapsed, reserve0);
                price1Cumulative += Math.mulDiv(uint256(reserve0) * 2**112, timeElapsed, reserve1);
            }
        }
        
        return (price0Cumulative, price1Cumulative, currentTime);
    }

    // --- GOVERNANCE & EMERGENCY FUNCTIONS ---
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

    function setMaxPriceChange(uint256 _maxChangeBPS) external onlyRole(GOVERNANCE_ROLE) {
        if (_maxChangeBPS == 0 || _maxChangeBPS > 5000) revert InvalidPriceChangeLimit();
        maxPriceChangeBPS = _maxChangeBPS;
        
        // Also update price validation data for new token mode
        if (newTokenMode) {
            priceValidation.maxPriceChangePerUpdate = _maxChangeBPS;
        }
    }

    function setNewTokenMode(bool _enabled) external onlyRole(GOVERNANCE_ROLE) {
        newTokenMode = _enabled;
        
        if (_enabled) {
            // Activate stricter protections
            maxUpdatesPerBlock = 1;
            priceValidation.maxPriceChangePerUpdate = 2000; // 20%
            priceValidation.priceImpactThreshold = 1000; // 10%
        } else {
            // Relax protections as token matures
            maxUpdatesPerBlock = 3;
            priceValidation.maxPriceChangePerUpdate = 1000; // 10%
            priceValidation.priceImpactThreshold = 1500; // 15%
        }
        
        emit NewTokenModeToggled(_enabled);
    }

    function getCurrentPrice() external view returns (uint256) {
        if (emergencyMode && fallbackPrice > 0) {
            return fallbackPrice;
        }
        
        if (twapObservations.length < MIN_TWAP_OBSERVATIONS) return fallbackPrice;
        
        try this.safeGetTWAPPrice() returns (uint256 price) {
            return price;
        } catch {
            return fallbackPrice;
        }
    }

    function safeGetTWAPPrice() external view returns (uint256) {
        return _getEnhancedTWAPPrice();
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

    // --- UUPS UPGRADE HOOK ---
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(GOVERNANCE_ROLE) {}
}