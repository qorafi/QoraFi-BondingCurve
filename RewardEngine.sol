// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

// --- INTERFACES ---
interface IBondingOracle {
    function getCurrentPrice() external view returns (uint256);
    function isHealthy() external view returns (bool);
    function getCachedMarketCap() external view returns (uint256);
    function getPriceValidationData() external view returns (
        uint256 lastValidatedPrice,
        uint256 lastValidationTime,
        uint256 priceImpactThreshold,
        uint256 maxPriceChangePerUpdate,
        uint256 minTimeBetweenUpdates
    );
}

interface ISecondaryOracle {
    function getPrice() external view returns (uint256);
    function isActive() external view returns (bool);
}

interface IQoraFiToken is IERC20 {
    function mint(address to, uint256 amount) external;
}

interface IUniswapV2Pair is IERC20 {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

/**
 * @title RewardEngine
 * @notice Manages the calculation and distribution of LP staking rewards for the Proof of Liquidity system.
 */
contract RewardEngine is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IQoraFiToken;

    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");
    bytes32 public constant POL_VAULT_ROLE = keccak256("POL_VAULT_ROLE");

    // --- STATE VARIABLES ---
    IQoraFiToken public immutable qorafiToken;
    IUniswapV2Pair public immutable stakingToken;
    IBondingOracle public bondingOracle;
    ISecondaryOracle public secondaryOracle;
    address public treasuryAddress;
    
    // Reward State
    uint256 public rewardsDuration;
    uint256 public periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;
    uint256 public minStakeDuration;
    uint256 public totalCollateralValueForRewards;

    // User State Tracking
    mapping(address => uint256) public userCollateralValue;
    mapping(address => uint256) public depositTimestamp;
    mapping(address => bool) public isEligible;
    
    uint256 public emergencyPenaltyBPS;
    uint256 public constant MAX_BPS = 10_000;
    
    // Oracle Fallback & Caching
    bool public useSecondaryOracle;
    uint256 public manualPrice;
    uint256 public manualPriceTimestamp;
    bool public manualPriceActive;
    mapping(uint256 => uint256) public dailyLPPrice;
    mapping(uint256 => bool) public priceUpdatedToday;
    uint256 public oracleStalenessThreshold;
    uint256 public priceDeviationThreshold;
    uint256 public constant MAX_BATCH_SIZE = 50;
    
    // Token order in LP pair
    bool public qorafiIsToken0;

    // --- EVENTS ---
    event RewardsClaimed(address indexed user, uint256 amount);
    event UserEligibilityChanged(address indexed user, bool eligible);
    event CollateralValueUpdated(address indexed user, uint256 oldValue, uint256 newValue);
    event RewardsNotified(uint256 amount, uint256 duration);
    event OracleFallbackActivated(string reason, uint256 fallbackPrice);
    event EmergencyRewardsWithdrawn(address indexed recipient, uint256 amount);
    event OracleConfigUpdated(uint256 newStalenessThreshold, uint256 newDeviationThreshold);

    constructor(
        address _qorafiTokenAddress,
        address _stakingTokenAddress,
        address _bondingOracleAddress,
        address _polVaultAddress,
        address _treasuryAddress
    ) {
        require(_qorafiTokenAddress != address(0), "Invalid QoraFi token address");
        require(_stakingTokenAddress != address(0), "Invalid staking token address");
        require(_bondingOracleAddress != address(0), "Invalid bonding oracle address");
        require(_polVaultAddress != address(0), "Invalid vault address");
        require(_treasuryAddress != address(0), "Invalid treasury address");

        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(REWARD_MANAGER_ROLE, msg.sender);
        _grantRole(POL_VAULT_ROLE, _polVaultAddress);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        qorafiToken = IQoraFiToken(_qorafiTokenAddress);
        stakingToken = IUniswapV2Pair(_stakingTokenAddress);
        bondingOracle = IBondingOracle(_bondingOracleAddress);
        treasuryAddress = _treasuryAddress;
        minStakeDuration = 1 days;
        emergencyPenaltyBPS = 1000; // 10%
        oracleStalenessThreshold = 2 hours;
        priceDeviationThreshold = 1000; // 10%
        
        // Determine token order in LP pair
        try IUniswapV2Pair(_stakingTokenAddress).token0() returns (address token0) {
            qorafiIsToken0 = (token0 == _qorafiTokenAddress);
        } catch {
            // Default to false if call fails
            qorafiIsToken0 = false;
        }
    }

    // --- GOVERNANCE FUNCTIONS ---
    function setPaused(bool _paused) external onlyRole(GOVERNANCE_ROLE) {
        if (_paused) _pause();
        else _unpause();
    }

    function setMinStakeDuration(uint256 _newDuration) external onlyRole(GOVERNANCE_ROLE) {
        minStakeDuration = _newDuration;
    }

    function setEmergencyPenaltyBPS(uint256 _newPenaltyBPS) external onlyRole(GOVERNANCE_ROLE) {
        require(_newPenaltyBPS <= MAX_BPS, "Penalty cannot exceed 100%");
        emergencyPenaltyBPS = _newPenaltyBPS;
    }

    function notifyRewardAmount(uint256 _rewardsAmount, uint256 _duration) external onlyRole(REWARD_MANAGER_ROLE) {
        require(_duration > 0, "Duration must be greater than zero");
        _updateAllRewards();
        if (block.timestamp >= periodFinish) {
            rewardRate = _rewardsAmount / _duration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * rewardRate;
            rewardRate = (_rewardsAmount + leftover) / _duration;
        }
        require(rewardRate > 0, "Reward rate must be > 0");
        require(qorafiToken.balanceOf(address(this)) >= _rewardsAmount, "Not enough reward tokens");
        rewardsDuration = _duration;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + _duration;
        emit RewardsNotified(_rewardsAmount, _duration);
    }
    
    /**
     * @notice Set the bonding oracle contract address
     * @param _bondingOracleAddress Address of the bonding oracle contract
     */
    function setBondingOracle(address _bondingOracleAddress) external onlyRole(GOVERNANCE_ROLE) {
        require(_bondingOracleAddress != address(0), "Invalid bonding oracle address");
        bondingOracle = IBondingOracle(_bondingOracleAddress);
    }

    function setSecondaryOracle(address _secondaryOracleAddress) external onlyRole(GOVERNANCE_ROLE) {
        secondaryOracle = ISecondaryOracle(_secondaryOracleAddress);
    }

    function setUseSecondaryOracle(bool _use) external onlyRole(GOVERNANCE_ROLE) {
        useSecondaryOracle = _use;
    }

    function setManualPrice(uint256 _price) external onlyRole(GOVERNANCE_ROLE) {
        manualPrice = _price;
        manualPriceTimestamp = block.timestamp;
        manualPriceActive = true;
    }

    function setOracleStalenessThreshold(uint256 _threshold) external onlyRole(GOVERNANCE_ROLE) {
        oracleStalenessThreshold = _threshold;
        emit OracleConfigUpdated(_threshold, priceDeviationThreshold);
    }

    function setPriceDeviationThreshold(uint256 _threshold) external onlyRole(GOVERNANCE_ROLE) {
        require(_threshold <= MAX_BPS, "Threshold cannot exceed 100%");
        priceDeviationThreshold = _threshold;
        emit OracleConfigUpdated(oracleStalenessThreshold, _threshold);
    }

    function emergencyWithdrawRewards() external onlyRole(GOVERNANCE_ROLE) whenPaused {
        uint256 balance = qorafiToken.balanceOf(address(this));
        qorafiToken.safeTransfer(treasuryAddress, balance);
        emit EmergencyRewardsWithdrawn(treasuryAddress, balance);
    }

    // --- VAULT-ONLY FUNCTIONS ---
    function handleStakeChange(address _user, int256 _lpAmountChange) external onlyRole(POL_VAULT_ROLE) {
        _updateReward(_user);
        
        uint256 lpPrice = _getLPTokenPrice();
        uint256 absLpAmountChange = _lpAmountChange > 0 ? uint256(_lpAmountChange) : uint256(-_lpAmountChange);
        uint256 usdValueChange = Math.mulDiv(absLpAmountChange, lpPrice, 1e18);
        
        uint256 oldValue = userCollateralValue[_user];
        uint256 newValue;

        if (_lpAmountChange > 0) {
            newValue = oldValue + usdValueChange;
            if (depositTimestamp[_user] == 0) {
                depositTimestamp[_user] = block.timestamp;
            }
        } else {
            newValue = oldValue > usdValueChange ? oldValue - usdValueChange : 0;
        }
        
        userCollateralValue[_user] = newValue;
        emit CollateralValueUpdated(_user, oldValue, newValue);

        bool wasEligible = isEligible[_user];
        bool isNowEligible = _checkEligibility(_user);

        if (wasEligible != isNowEligible) {
            isEligible[_user] = isNowEligible;
            if (isNowEligible) {
                totalCollateralValueForRewards += newValue;
            } else {
                if (totalCollateralValueForRewards >= oldValue) {
                    totalCollateralValueForRewards -= oldValue;
                } else {
                    totalCollateralValueForRewards = 0;
                }
            }
            emit UserEligibilityChanged(_user, isNowEligible);
        } else if (isNowEligible) {
            if (_lpAmountChange > 0) {
                totalCollateralValueForRewards += usdValueChange;
            } else {
                if (totalCollateralValueForRewards >= usdValueChange) {
                    totalCollateralValueForRewards -= usdValueChange;
                } else {
                    totalCollateralValueForRewards = 0;
                }
            }
        }

        if (newValue == 0) {
            depositTimestamp[_user] = 0;
        }
    }

    function handleEmergencyUnstake(address _user) external onlyRole(POL_VAULT_ROLE) {
        _updateReward(_user);
        uint256 currentRewards = rewards[_user];
        uint256 penalty = Math.mulDiv(currentRewards, emergencyPenaltyBPS, MAX_BPS);
        rewards[_user] = currentRewards - penalty;
    }

    // --- PUBLIC USER & KEEPER FUNCTIONS ---
    function claimRewards() external nonReentrant whenNotPaused {
        _updateReward(msg.sender);
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            qorafiToken.mint(msg.sender, reward);
            emit RewardsClaimed(msg.sender, reward);
        }
    }

    function batchUpdateRewards(address[] calldata users) external {
        require(users.length <= MAX_BATCH_SIZE, "Batch size too large");
        for (uint i = 0; i < users.length; i++) {
            _updateReward(users[i]);
        }
    }

    // --- PRICE UPDATE FUNCTION ---
    function updateDailyPrice() external {
        _getLPTokenPrice();
    }

    // --- VIEW FUNCTIONS ---
    function getPendingRewards(address _user) public view returns (uint256) {
        if (!isEligible[_user]) return rewards[_user];
        return _earnedView(_user);
    }

    function getRewardAPR() external view returns (uint256) {
        if (totalCollateralValueForRewards == 0) return 0;
        return Math.mulDiv(rewardRate * 365 days * 100, 1e18, totalCollateralValueForRewards);
    }

    function getUserInfo(address _user) external view returns (
        uint256 collateralValue,
        uint256 pendingRewards,
        uint256 depositTime,
        bool eligible,
        uint256 timeUntilEligible
    ) {
        collateralValue = userCollateralValue[_user];
        pendingRewards = getPendingRewards(_user);
        depositTime = depositTimestamp[_user];
        eligible = isEligible[_user];

        if (depositTime > 0 && !eligible) {
            uint256 eligibleTime = depositTime + minStakeDuration;
            timeUntilEligible = eligibleTime > block.timestamp ? eligibleTime - block.timestamp : 0;
        }
    }

    function getCurrentLpPrice() external view returns (uint256) {
        uint256 today = block.timestamp / 1 days;
        if (priceUpdatedToday[today]) {
            return dailyLPPrice[today];
        }
        
        // Return the cached price from previous day if available
        uint256 yesterday = today - 1;
        if (priceUpdatedToday[yesterday]) {
            return dailyLPPrice[yesterday];
        }
        
        // Fall back to real-time LP calculation
        return _calculateLPTokenValue();
    }

    // --- INTERNAL REWARD LOGIC ---
    function _updateReward(address _user) internal {
        rewardPerTokenStored = _rewardPerToken();
        lastUpdateTime = Math.min(block.timestamp, periodFinish);

        if (isEligible[_user]) {
            rewards[_user] = _earned(_user);
        }
        userRewardPerTokenPaid[_user] = rewardPerTokenStored;
    }

    function _updateAllRewards() internal {
        rewardPerTokenStored = _rewardPerToken();
        lastUpdateTime = Math.min(block.timestamp, periodFinish);
    }

    function _rewardPerToken() internal view returns (uint256) {
        if (totalCollateralValueForRewards == 0) return rewardPerTokenStored;
        uint256 timePassed = Math.min(block.timestamp, periodFinish) - lastUpdateTime;
        return rewardPerTokenStored + Math.mulDiv(timePassed * rewardRate, 1e18, totalCollateralValueForRewards);
    }

    function _earned(address _user) internal view returns (uint256) {
        uint256 collateralValue = userCollateralValue[_user];
        return Math.mulDiv(collateralValue, (_rewardPerToken() - userRewardPerTokenPaid[_user]), 1e18) + rewards[_user];
    }

    // Separate view function for earned rewards that doesn't modify state
    function _earnedView(address _user) internal view returns (uint256) {
        uint256 collateralValue = userCollateralValue[_user];
        return Math.mulDiv(collateralValue, (_rewardPerToken() - userRewardPerTokenPaid[_user]), 1e18) + rewards[_user];
    }

    function _checkEligibility(address _user) internal view returns (bool) {
        return depositTimestamp[_user] > 0 && 
               block.timestamp >= depositTimestamp[_user] + minStakeDuration &&
               userCollateralValue[_user] > 0;
    }

    // Get LP token price using bonding oracle
    function _getLPTokenPrice() internal returns (uint256) {
        uint256 today = block.timestamp / 1 days;
        if (priceUpdatedToday[today]) {
            return dailyLPPrice[today];
        }

        uint256 price = _calculateLPTokenValue();
        
        uint256 yesterday = today - 1;
        if (priceUpdatedToday[yesterday] && dailyLPPrice[yesterday] > 0) {
            require(_validatePriceDeviation(price, dailyLPPrice[yesterday]), "Price deviation too high");
        }
        
        dailyLPPrice[today] = price;
        priceUpdatedToday[today] = true;
        return price;
    }

    /**
     * @notice Calculate LP token value using QoraFi price from bonding oracle
     * @return LP token value in USD (18 decimals)
     */
    function _calculateLPTokenValue() internal view returns (uint256) {
        require(address(bondingOracle) != address(0), "Bonding oracle not set");
        require(bondingOracle.isHealthy(), "Bonding oracle unhealthy");
        
        // Get QoraFi price from bonding oracle
        uint256 qorafiPrice = bondingOracle.getCurrentPrice();
        require(qorafiPrice > 0, "Invalid QoraFi price");
        
        // Get LP pair reserves
        (uint112 reserve0, uint112 reserve1,) = stakingToken.getReserves();
        require(reserve0 > 0 && reserve1 > 0, "Invalid reserves");
        
        // Determine which reserve is QoraFi and which is USDT based on token order
        uint256 usdtReserve;
        uint256 qorafiReserve;
        
        if (qorafiIsToken0) {
            qorafiReserve = uint256(reserve0);
            usdtReserve = uint256(reserve1);
        } else {
            usdtReserve = uint256(reserve0);
            qorafiReserve = uint256(reserve1);
        }
        
        // Calculate total pool value: USDT + (QoraFi * price)
        uint256 qorafiValueInUSD = Math.mulDiv(qorafiReserve, qorafiPrice, 1e18);
        uint256 totalPoolValue = usdtReserve + qorafiValueInUSD;
        
        // Calculate LP token value: total pool value / total LP supply
        uint256 totalSupply = stakingToken.totalSupply();
        require(totalSupply > 0, "Invalid LP supply");
        
        return Math.mulDiv(totalPoolValue, 1e18, totalSupply);
    }

    function _validatePriceDeviation(uint256 newPrice, uint256 lastPrice) internal view returns (bool) {
        if (lastPrice == 0) return true;
        
        uint256 deviation;
        if (newPrice > lastPrice) {
            deviation = ((newPrice - lastPrice) * MAX_BPS) / lastPrice;
        } else {
            deviation = ((lastPrice - newPrice) * MAX_BPS) / lastPrice;
        }
        
        return deviation <= priceDeviationThreshold;
    }
}