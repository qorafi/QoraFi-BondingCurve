// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// --- INTERFACES ---
interface IQoraFiToken is IERC20 {
    // No special functions needed, inherits from IERC20
}

/**
 * @title RewardManager
 * @notice Manages the calculation and distribution of liquidity mining rewards for the USQ Engine.
 * @dev This contract is designed to be the single source of truth for reward accounting.
 */
contract RewardManager is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IQoraFiToken;

    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant REWARD_MANAGER_ROLE = keccak256("REWARD_MANAGER_ROLE");
    bytes32 public constant USQ_ENGINE_ROLE = keccak256("USQ_ENGINE_ROLE");

    // --- STATE VARIABLES ---
    IQoraFiToken public immutable qorafiToken;
    address public usqEngineAddress;
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

    // --- EVENTS ---
    event RewardsClaimed(address indexed user, uint256 amount);
    event UserEligibilityChanged(address indexed user, bool eligible);
    event CollateralValueUpdated(address indexed user, uint256 oldValue, uint256 newValue);
    event RewardsNotified(uint256 amount, uint256 duration);
    event RewardsRescued(address indexed recipient, uint256 amount);

    constructor(address _qorafiTokenAddress, address _usqEngineAddress, address _treasuryAddress) {
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(REWARD_MANAGER_ROLE, msg.sender);
        _grantRole(USQ_ENGINE_ROLE, _usqEngineAddress);

        qorafiToken = IQoraFiToken(_qorafiTokenAddress);
        usqEngineAddress = _usqEngineAddress;
        treasuryAddress = _treasuryAddress;
        minStakeDuration = 1 days;
    }

    // --- GOVERNANCE FUNCTIONS ---

    function setPaused(bool _paused) external onlyRole(GOVERNANCE_ROLE) {
        if (_paused) _pause();
        else _unpause();
    }

    function setMinStakeDuration(uint256 _newDuration) external onlyRole(GOVERNANCE_ROLE) {
        minStakeDuration = _newDuration;
    }

    function notifyRewardAmount(uint256 _rewardsAmount, uint256 _duration) external onlyRole(REWARD_MANAGER_ROLE) {
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
    
    function emergencyWithdrawRewards() external onlyRole(GOVERNANCE_ROLE) whenPaused {
        uint256 balance = qorafiToken.balanceOf(address(this));
        qorafiToken.safeTransfer(treasuryAddress, balance);
        emit RewardsRescued(treasuryAddress, balance);
    }

    // --- ENGINE-ONLY FUNCTIONS ---

    function handleCollateralChange(address _user, int256 _usdValueChange) external onlyRole(USQ_ENGINE_ROLE) {
        _updateReward(_user);

        uint256 oldValue = userCollateralValue[_user];
        uint256 newValue;

        if (_usdValueChange > 0) {
            newValue = oldValue + uint256(_usdValueChange);
            if (depositTimestamp[_user] == 0) {
                depositTimestamp[_user] = block.timestamp;
            }
        } else {
            uint256 change = uint256(-_usdValueChange);
            newValue = oldValue > change ? oldValue - change : 0;
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
            if (_usdValueChange > 0) {
                totalCollateralValueForRewards += uint256(_usdValueChange);
            } else {
                uint256 change = uint256(-_usdValueChange);
                if (totalCollateralValueForRewards >= change) {
                    totalCollateralValueForRewards -= change;
                } else {
                    totalCollateralValueForRewards = 0;
                }
            }
        }

        if (newValue == 0) {
            depositTimestamp[_user] = 0;
        }
    }

    // --- PUBLIC USER FUNCTIONS ---

    function claimRewards() external nonReentrant whenNotPaused {
        _updateReward(msg.sender);
        uint256 reward = rewards[msg.sender];
        if (reward > 0) {
            rewards[msg.sender] = 0;
            qorafiToken.safeTransfer(msg.sender, reward);
            emit RewardsClaimed(msg.sender, reward);
        }
    }

    // --- VIEW FUNCTIONS ---

    function getPendingRewards(address _user) public view returns (uint256) {
        if (!isEligible[_user]) return rewards[_user]; // Return stored rewards if not currently eligible
        return _earned(_user);
    }

    function getRewardAPR() external view returns (uint256) {
        if (totalCollateralValueForRewards == 0) return 0;
        return Math.mulDiv(rewardRate * 365 days * 100, 1e18, totalCollateralValueForRewards);
    }
    
    function getUserInfo(address _user) external view returns (
        uint256 collateralValue,
        uint256 pendingRewardsValue,
        uint256 depositTime,
        bool eligible,
        uint256 timeUntilEligible
    ) {
        collateralValue = userCollateralValue[_user];
        pendingRewardsValue = getPendingRewards(_user);
        depositTime = depositTimestamp[_user];
        eligible = isEligible[_user];

        if (depositTime > 0 && !eligible) {
            uint256 eligibleTime = depositTime + minStakeDuration;
            timeUntilEligible = eligibleTime > block.timestamp ? eligibleTime - block.timestamp : 0;
        }
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

    function _checkEligibility(address _user) internal view returns (bool) {
        return depositTimestamp[_user] > 0 && 
               block.timestamp >= depositTimestamp[_user] + minStakeDuration &&
               userCollateralValue[_user] > 0;
    }
}