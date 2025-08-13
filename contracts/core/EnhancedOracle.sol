// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";

// Import our modular libraries
import "../libraries/OracleLibraries.sol";
import "../interfaces/SecurityInterfaces.sol";

/**
 * @title EnhancedOracle
 * @notice Advanced oracle using modular libraries - reduced from 800 to ~400 lines
 * @dev Focuses on core oracle functionality with enhanced new token protections
 */
contract EnhancedOracle is 
    Initializable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable,
    IEnhancedOracle
{
    using PriceValidationLib for PriceValidationLib.PriceValidationData;
    using LiquidityMonitorLib for *;
    using FlashLoanDetectionLib for *;

    // --- CONSTANTS ---
    uint256 private constant MIN_TWAP_OBSERVATIONS = TWAPLib.MIN_TWAP_OBSERVATIONS;
    uint256 private constant MAX_OBSERVATIONS = TWAPLib.MAX_TWAP_OBSERVATIONS;
    uint256 private constant MAX_OBSERVATION_AGE = TWAPLib.MAX_OBSERVATION_AGE;

    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant ORACLE_UPDATER_ROLE = keccak256("ORACLE_UPDATER_ROLE");

    // --- STATE VARIABLES ---
    IERC20Metadata public usdtToken;
    IERC20Metadata public qorafiToken;
    IUniswapV2Pair public lpPair;

    uint256 public cachedMarketCap;
    uint256 public lastOracleUpdateTime;
    bool private qorafiIsToken0InPair;
    uint256 public qorafiPriceTwap;
    
    TWAPLib.TWAPObservation[] private twapObservations;
    uint256 private observationIndex;
    uint256 public validObservationCount;
    uint8 private usdtDecimals;

    PriceValidationLib.PriceValidationData public priceValidation;

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
    mapping(uint256 => uint256) public blockPriceUpdates;
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
    event FlashLoanDetected(uint256 blockNumber, uint256 updateCount);
    event NewTokenModeToggled(bool enabled);

    // --- ERRORS ---
    error InvalidAddress();
    error InvalidMarketCapLimits();
    error UpdateTooFrequent();
    error EmergencyModeActive();
    error RolesSameAddress();

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
        qorafiToken = IERC20Metadata(_qorafi);
        lpPair = IUniswapV2Pair(_lpPair);
        qorafiIsToken0InPair = lpPair.token0() == _qorafi;
        mcLowerLimit = _mcLower;
        mcUpperLimit = _mcUpper;
        usdtDecimals = usdtToken.decimals();

        // Conservative settings for new token
        maxPriceChangeBPS = 2000; // 20%
        maxMarketCapGrowthBPS = 3000; // 30%
        minOracleUpdateInterval = 5 minutes;
        minLpLiquidity = 1000 * 1e18;
        
        // New token specific settings
        newTokenMode = true;
        flashLoanDetectionWindow = 3;
        maxUpdatesPerBlock = 1;
        minimumUsdtLiquidity = 10000 * (10 ** usdtDecimals); // $10k minimum
        liquidityCheckInterval = 1 hours;
        
        // Initialize price validation
        priceValidation = PriceValidationLib.PriceValidationData({
            lastValidatedPrice: 0,
            lastValidationTime: 0,
            priceImpactThreshold: 1000, // 10%
            maxPriceChangePerUpdate: 1500, // 15%
            minTimeBetweenUpdates: 5 minutes
        });

        // Initialize with first observation
        _initializeFirstObservation();
        
        lastOracleUpdateTime = block.timestamp;
        lastLiquidityCheck = block.timestamp;
    }

    function _initializeFirstObservation() internal {
        (uint256 price0, uint256 price1, uint32 ts) = CumulativePriceLib.getCurrentCumulativePrices(
            address(lpPair),
            qorafiIsToken0InPair,
            minLpLiquidity,
            minimumUsdtLiquidity
        );
        
        (uint112 reserve0, uint112 reserve1,) = lpPair.getReserves();
        uint256 currentLiquidity = LiquidityMonitorLib.getCurrentUSDTLiquidity(
            reserve0, 
            reserve1, 
            qorafiIsToken0InPair
        );
        
        // Create first observation using library struct
        TWAPLib.TWAPObservation memory newObs = TWAPLib.TWAPObservation({
            price0Cumulative: price0,
            price1Cumulative: price1,
            timestamp: ts,
            isValid: true,
            liquiditySnapshot: currentLiquidity
        });
        
        twapObservations.push(newObs);
        observationIndex = 0;
        validObservationCount = 1;
    }

    // --- CORE ORACLE FUNCTIONS ---
    function updateMarketCap() external override nonReentrant onlyRole(ORACLE_UPDATER_ROLE) {
        if (emergencyMode) revert EmergencyModeActive();
        if (block.timestamp - lastOracleUpdateTime < minOracleUpdateInterval) revert UpdateTooFrequent();
        
        // Flash loan protection using library
        FlashLoanDetectionLib.checkFlashLoanActivity(
            blockPriceUpdates,
            block.number,
            maxUpdatesPerBlock,
            flashLoanDetectionWindow
        );
        
        // Validate liquidity depth
        _validateLiquidityDepth();
        
        // Update observations using library
        _updateTWAPObservations();
        
        // Calculate new price using enhanced TWAP
        uint256 newPrice = _calculateTWAPPrice();
        
        // Enhanced price validation using library
        if (qorafiPriceTwap > 0) {
            priceValidation.validatePriceChange(qorafiPriceTwap, newPrice, newTokenMode, maxPriceChangeBPS);
            priceValidation.validatePriceImpact(newPrice);
        }

        // Get total supply using standard ERC20 interface
        uint256 totalSupply;
        try IERC20(address(qorafiToken)).totalSupply() returns (uint256 supply) {
            totalSupply = supply;
        } catch {
            revert("Failed to get total supply");
        }
        require(totalSupply > 0, "Invalid total supply");
        
        uint256 newMarketCap = Math.mulDiv(totalSupply, newPrice, 1e18);
        
        // Validate market cap growth using library
        if (cachedMarketCap > 0) {
            PriceValidationLib.validateMarketCapGrowth(cachedMarketCap, newMarketCap, maxMarketCapGrowthBPS);
        }

        // Update state
        cachedMarketCap = newMarketCap;
        qorafiPriceTwap = newPrice;
        lastOracleUpdateTime = block.timestamp;
        
        emit MarketCapUpdated(newMarketCap, newPrice);
    }

    function _validateLiquidityDepth() internal {
        (uint112 reserve0, uint112 reserve1,) = lpPair.getReserves();
        uint256 currentLiquidity = LiquidityMonitorLib.getCurrentUSDTLiquidity(
            reserve0, 
            reserve1, 
            qorafiIsToken0InPair
        );
        
        LiquidityMonitorLib.validateLiquidityDepth(currentLiquidity, minimumUsdtLiquidity);
        
        // Update liquidity check timestamp using library
        ( , bool shouldUpdate) = LiquidityMonitorLib.checkLiquidityHealth(
            currentLiquidity,
            minimumUsdtLiquidity,
            lastLiquidityCheck,
            liquidityCheckInterval
        );
        
        if (shouldUpdate) {
            lastLiquidityCheck = block.timestamp;
        }
    }

    function _updateTWAPObservations() internal {
        (uint256 price0, uint256 price1, uint32 currentTimestamp) = CumulativePriceLib.getCurrentCumulativePrices(
            address(lpPair),
            qorafiIsToken0InPair,
            minLpLiquidity,
            minimumUsdtLiquidity
        );
        
        (uint112 reserve0, uint112 reserve1,) = lpPair.getReserves();
        uint256 currentLiquidity = LiquidityMonitorLib.getCurrentUSDTLiquidity(
            reserve0, 
            reserve1, 
            qorafiIsToken0InPair
        );
        
        // Create new observation using library struct
        TWAPLib.TWAPObservation memory newObs = TWAPLib.TWAPObservation({
            price0Cumulative: price0,
            price1Cumulative: price1,
            timestamp: currentTimestamp,
            isValid: true,
            liquiditySnapshot: currentLiquidity
        });
        
        // Add to circular buffer
        if (twapObservations.length < MAX_OBSERVATIONS) {
            twapObservations.push(newObs);
            observationIndex = twapObservations.length - 1;
        } else {
            observationIndex = (observationIndex + 1) % MAX_OBSERVATIONS;
            twapObservations[observationIndex] = newObs;
        }
        
        if (validObservationCount < MAX_OBSERVATIONS) {
            validObservationCount++;
        }
        
        emit TWAPObservationAdded(price0, price1, currentTimestamp, currentLiquidity);
    }

    // --- VIEW FUNCTIONS ---
    function getCurrentPrice() external view override returns (uint256) {
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
        return _calculateTWAPPrice();
    }
    
    function _calculateTWAPPrice() internal view returns (uint256) {
        if (validObservationCount < 2) {
            return fallbackPrice;
        }
        
        // Get the latest and oldest observations
        TWAPLib.TWAPObservation memory latest = twapObservations[observationIndex];
        uint256 oldestIndex = validObservationCount < MAX_OBSERVATIONS 
            ? 0 
            : (observationIndex + 1) % MAX_OBSERVATIONS;
        TWAPLib.TWAPObservation memory oldest = twapObservations[oldestIndex];
        
        uint32 timeElapsed = latest.timestamp - oldest.timestamp;
        if (timeElapsed == 0) return fallbackPrice;
        
        // Use library function to calculate period price
        if (qorafiIsToken0InPair) {
            uint256 price1Diff = latest.price1Cumulative - oldest.price1Cumulative;
            return TWAPLib.calculatePeriodPrice(price1Diff, timeElapsed, qorafiIsToken0InPair, usdtDecimals);
        } else {
            uint256 price0Diff = latest.price0Cumulative - oldest.price0Cumulative;
            return TWAPLib.calculatePeriodPrice(price0Diff, timeElapsed, qorafiIsToken0InPair, usdtDecimals);
        }
    }

    function getCachedMarketCap() external view override returns (uint256) {
        return cachedMarketCap;
    }

    function isHealthy() external view override returns (bool) {
        if (emergencyMode) return false;
        if (block.timestamp - lastOracleUpdateTime > MAX_OBSERVATION_AGE) return false;
        if (validObservationCount < MIN_TWAP_OBSERVATIONS) return false;
        
        // Check liquidity health using library
        (uint112 reserve0, uint112 reserve1,) = lpPair.getReserves();
        uint256 currentLiquidity = LiquidityMonitorLib.getCurrentUSDTLiquidity(
            reserve0, 
            reserve1, 
            qorafiIsToken0InPair
        );
        
        (bool isLiquidityHealthy,) = LiquidityMonitorLib.checkLiquidityHealth(
            currentLiquidity,
            minimumUsdtLiquidity,
            lastLiquidityCheck,
            liquidityCheckInterval
        );
        
        return isLiquidityHealthy;
    }

    function checkMarketCapLimits() external view override {
        require(cachedMarketCap > 0, "Market cap not initialized");
        require(cachedMarketCap <= mcUpperLimit, "Market cap too high");
        require(cachedMarketCap >= mcLowerLimit, "Market cap too low");
        require(block.timestamp - lastOracleUpdateTime <= MAX_OBSERVATION_AGE, "Oracle data stale");
        require(!emergencyMode, "Emergency mode active");
        
        // Additional liquidity check
        (uint112 reserve0, uint112 reserve1,) = lpPair.getReserves();
        uint256 currentLiquidity = LiquidityMonitorLib.getCurrentUSDTLiquidity(
            reserve0, 
            reserve1, 
            qorafiIsToken0InPair
        );
        require(currentLiquidity >= minimumUsdtLiquidity, "Insufficient liquidity");
    }

    function getObservationCount() external view override returns (uint256) {
        return twapObservations.length;
    }

    function getLatestObservation() external view override returns (
        uint256 price0Cumulative,
        uint256 price1Cumulative,
        uint32 timestamp,
        bool isValid,
        uint256 liquiditySnapshot
    ) {
        TWAPLib.TWAPObservation memory obs = twapObservations.length > 0 
            ? TWAPLib.getLatestObservation(twapObservations)
            : TWAPLib.TWAPObservation(0, 0, 0, false, 0);
        return (obs.price0Cumulative, obs.price1Cumulative, obs.timestamp, obs.isValid, obs.liquiditySnapshot);
    }

    function getLiquidityStatus() external view override returns (
        uint256 currentUsdtLiquidity,
        uint256 minimumRequired,
        uint256 lastCheck,
        bool isCurrentlyHealthy
    ) {
        (uint112 reserve0, uint112 reserve1,) = lpPair.getReserves();
        uint256 current = LiquidityMonitorLib.getCurrentUSDTLiquidity(reserve0, reserve1, qorafiIsToken0InPair);
        (bool healthy,) = LiquidityMonitorLib.checkLiquidityHealth(
            current,
            minimumUsdtLiquidity,
            lastLiquidityCheck,
            liquidityCheckInterval
        );
        
        return (current, minimumUsdtLiquidity, lastCheck, healthy);
    }

    function getPriceValidationData() external view override returns (
        uint256 lastValidatedPrice,
        uint256 lastValidationTime,
        uint256 priceImpactThreshold,
        uint256 maxPriceChangePerUpdate,
        uint256 minTimeBetweenUpdates
    ) {
        return (
            priceValidation.lastValidatedPrice,
            priceValidation.lastValidationTime,
            priceValidation.priceImpactThreshold,
            priceValidation.maxPriceChangePerUpdate,
            priceValidation.minTimeBetweenUpdates
        );
    }

    function getNewTokenSettings() external view override returns (
        bool newTokenModeActive,
        uint256 flashLoanWindow,
        uint256 maxUpdatesLimit,
        uint256 minUsdtLiquidity
    ) {
        return (newTokenMode, flashLoanDetectionWindow, maxUpdatesPerBlock, minimumUsdtLiquidity);
    }

    // --- NEW MISSING FUNCTIONS ADDED ---

    function emergencyResetObservations() external onlyRole(GOVERNANCE_ROLE) {
        // Reset observations array but keep at least one
        delete twapObservations;
        validObservationCount = 0;
        observationIndex = 0;
        
        // Reinitialize with current observation
        _initializeFirstObservation();
        
        emit TWAPObservationAdded(
            twapObservations[0].price0Cumulative,
            twapObservations[0].price1Cumulative,
            twapObservations[0].timestamp,
            twapObservations[0].liquiditySnapshot
        );
    }

    function getFlashLoanStats(uint256 blockNumber) external view returns (
        uint256 updatesInBlock,
        uint256 updatesInWindow,
        bool isRisky
    ) {
        updatesInBlock = blockPriceUpdates[blockNumber];
        
        // Calculate window updates
        for (uint256 i = 0; i < flashLoanDetectionWindow && i <= blockNumber; i++) {
            updatesInWindow += blockPriceUpdates[blockNumber - i];
        }
        
        isRisky = updatesInWindow > maxUpdatesPerBlock * flashLoanDetectionWindow;
    }

    function getOracleHealth() external view returns (
        bool healthStatus,
        string memory reason,
        uint256 lastUpdate,
        uint256 validObservations
    ) {
        lastUpdate = lastOracleUpdateTime;
        validObservations = validObservationCount;
        
        if (emergencyMode) {
            return (false, "Emergency mode active", lastUpdate, validObservations);
        }
        if (block.timestamp - lastOracleUpdateTime > MAX_OBSERVATION_AGE) {
            return (false, "Oracle data stale", lastUpdate, validObservations);
        }
        if (validObservationCount < MIN_TWAP_OBSERVATIONS) {
            return (false, "Insufficient observations", lastUpdate, validObservations);
        }
        
        // Check liquidity
        (uint112 reserve0, uint112 reserve1,) = lpPair.getReserves();
        uint256 currentLiquidity = LiquidityMonitorLib.getCurrentUSDTLiquidity(
            reserve0, reserve1, qorafiIsToken0InPair
        );
        
        if (currentLiquidity < minimumUsdtLiquidity) {
            return (false, "Insufficient liquidity", lastUpdate, validObservations);
        }
        
        return (true, "Healthy", lastUpdate, validObservations);
    }

    function getMarketMetrics() external view returns (
        uint256 currentPrice,
        uint256 marketCap,
        uint256 priceChange24h,
        uint256 volumeWeightedPrice,
        uint256 liquidityUSD
    ) {
        currentPrice = this.getCurrentPrice();
        marketCap = cachedMarketCap;
        
        // Simplified implementations for missing data
        priceChange24h = 0; // Would need 24h price history
        volumeWeightedPrice = currentPrice; // Simplified
        
        // Calculate current liquidity in USD
        (uint112 reserve0, uint112 reserve1,) = lpPair.getReserves();
        uint256 usdtLiquidity = LiquidityMonitorLib.getCurrentUSDTLiquidity(
            reserve0, reserve1, qorafiIsToken0InPair
        );
        liquidityUSD = usdtLiquidity * 2; // Both sides of the pair
    }

    function getLiquidityChangeRate() external view returns (uint256) {
        if (twapObservations.length < 2) return 0;
        
        TWAPLib.TWAPObservation memory latest = twapObservations[observationIndex];
        uint256 oldestIndex = validObservationCount < MAX_OBSERVATIONS 
            ? 0 
            : (observationIndex + 1) % MAX_OBSERVATIONS;
        TWAPLib.TWAPObservation memory oldest = twapObservations[oldestIndex];
        
        return LiquidityMonitorLib.calculateLiquidityChange(
            oldest.liquiditySnapshot,
            latest.liquiditySnapshot
        );
    }

    function getObservationWindow(uint256 start, uint256 count) external view returns (
        TWAPLib.TWAPObservation[] memory observations
    ) {
        require(start < twapObservations.length, "Start index out of bounds");
        
        uint256 actualCount = count;
        if (start + count > twapObservations.length) {
            actualCount = twapObservations.length - start;
        }
        
        observations = new TWAPLib.TWAPObservation[](actualCount);
        for (uint256 i = 0; i < actualCount; i++) {
            observations[i] = twapObservations[start + i];
        }
    }

    // Add getter for validObservationCount as function for tests
    function getValidObservationCount() external view returns (uint256) {
        return validObservationCount;
    }

    // --- GOVERNANCE FUNCTIONS ---
    function enableEmergencyMode() external override onlyRole(GOVERNANCE_ROLE) {
        emergencyMode = true;
        emit EmergencyModeToggled(true);
    }

    function disableEmergencyMode() external override onlyRole(GOVERNANCE_ROLE) {
        emergencyMode = false;
        emit EmergencyModeToggled(false);
    }

    function setFallbackPrice(uint256 _price) external override onlyRole(GOVERNANCE_ROLE) {
        require(_price > 0, "Invalid price");
        fallbackPrice = _price;
        emit FallbackPriceSet(_price);
    }

    function setNewTokenMode(bool _enabled) external override onlyRole(GOVERNANCE_ROLE) {
        newTokenMode = _enabled;
        
        if (_enabled) {
            maxUpdatesPerBlock = 1;
            priceValidation.maxPriceChangePerUpdate = 2000; // 20%
            priceValidation.priceImpactThreshold = 1000; // 10%
        } else {
            maxUpdatesPerBlock = 3;
            priceValidation.maxPriceChangePerUpdate = 1000; // 10%
            priceValidation.priceImpactThreshold = 1500; // 15%
        }
        
        emit NewTokenModeToggled(_enabled);
    }

    function setPriceValidationParams(
        uint256 _priceImpactThreshold,
        uint256 _maxPriceChangePerUpdate
    ) external override onlyRole(GOVERNANCE_ROLE) {
        priceValidation.updateValidationParams(
            _priceImpactThreshold,
            _maxPriceChangePerUpdate,
            priceValidation.minTimeBetweenUpdates
        );
    }

    function setMarketCapLimits(uint256 _mcLower, uint256 _mcUpper) external onlyRole(GOVERNANCE_ROLE) {
        require(_mcLower > 0 && _mcUpper > _mcLower, "Invalid limits");
        mcLowerLimit = _mcLower;
        mcUpperLimit = _mcUpper;
    }

    function forceUpdatePrice(uint256 _newPrice) external override onlyRole(GOVERNANCE_ROLE) {
        require(_newPrice > 0, "Invalid price");
        
        if (newTokenMode && qorafiPriceTwap > 0) {
            uint256 maxChange = Math.mulDiv(qorafiPriceTwap, 5000, 10000); // 50% max
            require(_newPrice >= qorafiPriceTwap - maxChange && _newPrice <= qorafiPriceTwap + maxChange, "Change too large");
        }
        
        qorafiPriceTwap = _newPrice;
        
        // Get total supply using standard ERC20 interface
        uint256 totalSupply;
        try IERC20(address(qorafiToken)).totalSupply() returns (uint256 supply) {
            totalSupply = supply;
        } catch {
            revert("Failed to get total supply");
        }
        cachedMarketCap = Math.mulDiv(totalSupply, _newPrice, 1e18);
        lastOracleUpdateTime = block.timestamp;
        
        priceValidation.lastValidatedPrice = _newPrice;
        priceValidation.lastValidationTime = block.timestamp;
        
        emit MarketCapUpdated(cachedMarketCap, _newPrice);
    }

    function invalidateObservation(uint256 index, string calldata reason) external override onlyRole(GOVERNANCE_ROLE) {
        uint256 newValidCount = TWAPLib.invalidateObservation(twapObservations, index, validObservationCount);
        validObservationCount = newValidCount;
        emit ObservationInvalidated(index, twapObservations[index].timestamp, reason);
    }

    // --- UUPS UPGRADE HOOK ---
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(GOVERNANCE_ROLE) {}
}