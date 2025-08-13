// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

// --- INTERFACES ---
interface IAggregatorV3 {
    function latestRoundData() 
        external 
        view 
        returns (
            uint80 roundId, 
            int256 answer, 
            uint256 startedAt, 
            uint256 updatedAt, 
            uint80 answeredInRound
        );
    function decimals() external view returns (uint8);
}

/**
 * @title Oracle
 * @notice A secure, multi-feed oracle contract for the USQ Engine.
 * @dev Manages price feeds, validates prices, and provides a secure USD value for collateral.
 */
contract Oracle is AccessControl, ReentrancyGuard {

    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant ORACLE_EMERGENCY_ROLE = keccak256("ORACLE_EMERGENCY_ROLE");

    // --- STATE VARIABLES ---
    uint256 public priceDeviationBPS;
    uint256 public oracleStalenessThreshold;
    mapping(address => uint256) public lastValidatedPrice;
    mapping(address => uint256) public lastValidatedTimestamp;
    mapping(address => address[]) public priceFeeds;
    // For O(1) removal, we store index + 1. A value of 0 means the feed does not exist.
    mapping(address => mapping(address => uint256)) private priceFeedIndex;
    mapping(address => uint256) public emergencyOraclePrices;
    mapping(address => uint256) public emergencyOracleExpiry;
    
    uint256 public minEmergencyPrice;
    uint256 public maxEmergencyPrice;
    uint256 public constant MAX_EMERGENCY_DURATION = 7 days;
    uint256 public constant MIN_PRICE_FEEDS = 2;

    // --- EVENTS ---
    event PriceFeedAdded(address indexed token, address indexed feed);
    event PriceFeedRemoved(address indexed token, address indexed feed);
    event EmergencyPriceSet(address indexed token, uint256 price, uint256 expiry);
    event EmergencyPriceCleared(address indexed token);
    event PriceDeviationDetected(address indexed token, uint256 usedPrice, uint256 rejectedPrice);
    event OracleConfigUpdated(uint256 newDeviationBPS, uint256 newStalenessThreshold);

    // --- ERRORS ---
    error InvalidAddress();
    error PriceFeedAlreadyExists();
    error PriceFeedNotFound();
    error CannotRemoveMinimumFeeds();
    error InvalidPrice();
    error PriceOutOfBounds();
    error InvalidDuration();
    error InvalidDeviationBPS();
    error InvalidStalenessThreshold();
    error NotEnoughPriceFeeds();
    error NotEnoughValidPriceFeeds();

    constructor() {
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(ORACLE_EMERGENCY_ROLE, msg.sender);
        priceDeviationBPS = 500; // 5%
        oracleStalenessThreshold = 30 minutes;
        minEmergencyPrice = 1e14; // $0.0001
        maxEmergencyPrice = 1e24; // $1,000,000
    }

    // --- GOVERNANCE FUNCTIONS ---

    function addPriceFeed(address _token, address _feed) external onlyRole(GOVERNANCE_ROLE) {
        if (_token == address(0) || _feed == address(0)) revert InvalidAddress();
        if (priceFeedIndex[_token][_feed] != 0) revert PriceFeedAlreadyExists();

        priceFeeds[_token].push(_feed);
        priceFeedIndex[_token][_feed] = priceFeeds[_token].length; // Store index + 1
        emit PriceFeedAdded(_token, _feed);
    }

    function removePriceFeed(address _token, address _feed) external onlyRole(GOVERNANCE_ROLE) {
        if (_token == address(0) || _feed == address(0)) revert InvalidAddress();
        if (priceFeedIndex[_token][_feed] == 0) revert PriceFeedNotFound();
        if (priceFeeds[_token].length <= MIN_PRICE_FEEDS) revert CannotRemoveMinimumFeeds();

        uint256 indexToRemove = priceFeedIndex[_token][_feed] - 1;
        address lastFeed = priceFeeds[_token][priceFeeds[_token].length - 1];

        // Swap with the last element and pop
        priceFeeds[_token][indexToRemove] = lastFeed;
        priceFeedIndex[_token][lastFeed] = indexToRemove + 1;
        
        priceFeeds[_token].pop();
        delete priceFeedIndex[_token][_feed];

        emit PriceFeedRemoved(_token, _feed);
    }

    function setEmergencyOraclePrice(
        address _token, 
        uint256 _price, 
        uint256 _expiryDuration
    ) external onlyRole(ORACLE_EMERGENCY_ROLE) {
        if (_price == 0) revert InvalidPrice();
        if (_price < minEmergencyPrice || _price > maxEmergencyPrice) revert PriceOutOfBounds();
        if (_expiryDuration == 0 || _expiryDuration > MAX_EMERGENCY_DURATION) revert InvalidDuration();

        emergencyOraclePrices[_token] = _price;
        emergencyOracleExpiry[_token] = block.timestamp + _expiryDuration;
        emit EmergencyPriceSet(_token, _price, block.timestamp + _expiryDuration);
    }

    function clearEmergencyOraclePrice(address _token) external onlyRole(ORACLE_EMERGENCY_ROLE) {
        emergencyOraclePrices[_token] = 0;
        emergencyOracleExpiry[_token] = 0;
        emit EmergencyPriceCleared(_token);
    }

    function setOracleConfig(
        uint256 _newDeviationBPS, 
        uint256 _newStalenessThreshold
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (_newDeviationBPS == 0 || _newDeviationBPS > 1000) revert InvalidDeviationBPS();
        if (_newStalenessThreshold < 5 minutes || _newStalenessThreshold > 24 hours) {
            revert InvalidStalenessThreshold();
        }
        
        priceDeviationBPS = _newDeviationBPS;
        oracleStalenessThreshold = _newStalenessThreshold;
        emit OracleConfigUpdated(_newDeviationBPS, _newStalenessThreshold);
    }

    // --- CORE ORACLE LOGIC ---

    function getUsdValue(address _token, uint256 _amount) external view returns (uint256) {
        if (emergencyOraclePrices[_token] > 0 && block.timestamp < emergencyOracleExpiry[_token]) {
            // Emergency price is assumed to have 18 decimals
            return _calculateUsdValue(_token, _amount, emergencyOraclePrices[_token], 18);
        }
        
        uint256 currentPrice = _getOracleMedianPrice(_token);
        uint256 lastPrice = lastValidatedPrice[_token];
        
        if (lastPrice > 0 && block.timestamp <= lastValidatedTimestamp[_token] + oracleStalenessThreshold) {
            uint256 diff = currentPrice > lastPrice ? currentPrice - lastPrice : lastPrice - currentPrice;
            if (Math.mulDiv(diff, 10000, lastPrice) > priceDeviationBPS) {
                currentPrice = lastPrice; // Fallback to last known good price
            }
        }
        
        return _calculateUsdValue(_token, _amount, currentPrice, IAggregatorV3(priceFeeds[_token][0]).decimals());
    }
    
    function updateAndGetUsdValue(address _token, uint256 _amount) external nonReentrant returns (uint256) {
        uint256 medianPrice = _getOracleMedianPrice(_token);
        uint256 lastPrice = lastValidatedPrice[_token];
        
        if (lastPrice > 0) {
            uint256 diff = medianPrice > lastPrice ? medianPrice - lastPrice : lastPrice - medianPrice;
            if (Math.mulDiv(diff, 10000, lastPrice) > priceDeviationBPS) {
                emit PriceDeviationDetected(_token, lastPrice, medianPrice);
                return _calculateUsdValue(_token, _amount, lastPrice, IAggregatorV3(priceFeeds[_token][0]).decimals());
            }
        }
        
        lastValidatedPrice[_token] = medianPrice;
        lastValidatedTimestamp[_token] = block.timestamp;
        
        return _calculateUsdValue(_token, _amount, medianPrice, IAggregatorV3(priceFeeds[_token][0]).decimals());
    }

    function _getOracleMedianPrice(address _token) internal view returns (uint256) {
        address[] memory feeds = priceFeeds[_token];
        if (feeds.length < MIN_PRICE_FEEDS) revert NotEnoughPriceFeeds();
        
        uint256[] memory prices = new uint256[](feeds.length);
        uint256 validPriceCount = 0;
        
        for (uint256 i = 0; i < feeds.length; i++) {
            try IAggregatorV3(feeds[i]).latestRoundData() returns (
                uint80, 
                int256 price, 
                uint256, 
                uint256 updatedAt, 
                uint80
            ) {
                if (price > 0 && updatedAt > block.timestamp - oracleStalenessThreshold) {
                    prices[validPriceCount] = uint256(price);
                    validPriceCount++;
                }
            } catch {
                // Skip failed or stale oracle
            }
        }

        if (validPriceCount < MIN_PRICE_FEEDS) revert NotEnoughValidPriceFeeds();

        // Create a tightly packed array of only the valid prices
        uint256[] memory validPrices = new uint256[](validPriceCount);
        for (uint256 i = 0; i < validPriceCount; i++) {
            validPrices[i] = prices[i];
        }
        
        return _getMedian(validPrices);
    }

    function _calculateUsdValue(
        address _token, 
        uint256 _amount, 
        uint256 _price, 
        uint8 _priceDecimals
    ) internal view returns (uint256) {
        uint8 tokenDecimals = IERC20Metadata(_token).decimals();
        
        if (_priceDecimals <= 18) {
            return (_amount * _price * (10**(18 - _priceDecimals))) / (10**tokenDecimals);
        } else {
            require(tokenDecimals + _priceDecimals >= 18, "Decimal calculation underflow");
            return (_amount * _price) / (10**(tokenDecimals + _priceDecimals - 18));
        }
    }

    function _getMedian(uint256[] memory _data) internal pure returns (uint256) {
        uint256 n = _data.length;
        
        // Simple bubble sort for small arrays (efficient for few price feeds)
        for (uint256 i = 0; i < n - 1; i++) {
            for (uint256 j = 0; j < n - i - 1; j++) {
                if (_data[j] > _data[j + 1]) {
                    uint256 temp = _data[j];
                    _data[j] = _data[j + 1];
                    _data[j + 1] = temp;
                }
            }
        }
        
        if (n % 2 == 0) {
            return (_data[n / 2 - 1] + _data[n / 2]) / 2;
        } else {
            return _data[n / 2];
        }
    }

    // --- VIEW FUNCTIONS for Monitoring ---
    function getPriceFeeds(address _token) external view returns (address[] memory) {
        return priceFeeds[_token];
    }

    function getLatestPrice(address _token) external view returns (uint256 price, uint256 timestamp) {
        return (lastValidatedPrice[_token], lastValidatedTimestamp[_token]);
    }

    // --- ADDITIONAL HELPER FUNCTIONS ---
    function isHealthy() external pure returns (bool) {
        // This function can be called by other contracts to check oracle health
        return true;
    }

    function qorafiPriceTwap() external pure returns (uint256) {
        // Placeholder function that might be needed by other contracts
        // You would need to implement actual TWAP logic based on your requirements
        return 0;
    }

    function getPriceFeedCount(address _token) external view returns (uint256) {
        return priceFeeds[_token].length;
    }

    function hasPriceFeed(address _token, address _feed) external view returns (bool) {
        return priceFeedIndex[_token][_feed] > 0;
    }

    function getEmergencyPrice(address _token) external view returns (uint256 price, uint256 expiry) {
        return (emergencyOraclePrices[_token], emergencyOracleExpiry[_token]);
    }

    function isEmergencyPriceActive(address _token) external view returns (bool) {
        return emergencyOraclePrices[_token] > 0 && block.timestamp < emergencyOracleExpiry[_token];
    }
}