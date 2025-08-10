// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

// --- INTERFACES ---
interface IRewardEngine {
    function handleStakeChange(address user, int256 lpAmountChange) external;
    function handleEmergencyUnstake(address user) external;
}

interface IUniswapV2Pair is IERC20 {
    // Inherits from IERC20
}

/**
 * @title ProofOfLiquidity (Vault)
 * @notice A secure vault contract for holding users' staked QoraFi/USDT LP tokens.
 * @dev This contract's sole responsibility is to manage the staking and unstaking of LP tokens.
 */
contract ProofOfLiquidity is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IUniswapV2Pair;

    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // --- STATE VARIABLES ---
    IUniswapV2Pair public immutable stakingToken;
    IRewardEngine public rewardEngine;
    
    mapping(address => uint256) public stakedAmount;
    uint256 public totalStaked;

    // --- EVENTS ---
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount, bool emergency);
    event RewardEngineSet(address indexed engine);
    event RewardEngineCallFailed(address indexed user, string operation);

    // --- ERRORS ---
    error ZeroAmount();
    error InsufficientStake();
    error InvalidAddress();

    constructor(address _stakingTokenAddress) {
        require(_stakingTokenAddress != address(0), "Invalid staking token address");
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);

        stakingToken = IUniswapV2Pair(_stakingTokenAddress);
    }

    // --- GOVERNANCE FUNCTIONS ---
    function setPaused(bool _isPaused) external onlyRole(PAUSER_ROLE) {
        if (_isPaused) _pause();
        else _unpause();
    }

    function setRewardEngine(address _engineAddress) external onlyRole(GOVERNANCE_ROLE) {
        if (_engineAddress == address(0)) revert InvalidAddress();
        rewardEngine = IRewardEngine(_engineAddress);
        emit RewardEngineSet(_engineAddress);
    }

    // --- USER-FACING FUNCTIONS ---
    
    function stake(uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert ZeroAmount();
        
        if (address(rewardEngine) != address(0)) {
            try rewardEngine.handleStakeChange(msg.sender, int256(_amount)) {}
            catch { emit RewardEngineCallFailed(msg.sender, "stake"); }
        }
        
        stakingToken.safeTransferFrom(msg.sender, address(this), _amount);
        stakedAmount[msg.sender] += _amount;
        totalStaked += _amount;
        emit Staked(msg.sender, _amount);
    }

    function unstake(uint256 _amount) external nonReentrant whenNotPaused {
        if (_amount == 0) revert ZeroAmount();
        uint256 currentBalance = stakedAmount[msg.sender];
        if (_amount > currentBalance) revert InsufficientStake();
        
        if (address(rewardEngine) != address(0)) {
            try rewardEngine.handleStakeChange(msg.sender, -int256(_amount)) {}
            catch { emit RewardEngineCallFailed(msg.sender, "unstake"); }
        }
        
        stakedAmount[msg.sender] = currentBalance - _amount;
        totalStaked -= _amount;
        stakingToken.safeTransfer(msg.sender, _amount);
        emit Unstaked(msg.sender, _amount, false);
    }
    
    function emergencyUnstake() external nonReentrant {
        uint256 amount = stakedAmount[msg.sender];
        if (amount == 0) revert InsufficientStake();
        
        // Update state first for true emergency functionality
        stakedAmount[msg.sender] = 0;
        totalStaked -= amount;
        
        // Try to notify reward engine but do not block on failure
        if (address(rewardEngine) != address(0)) {
            try rewardEngine.handleEmergencyUnstake(msg.sender) {}
            catch { emit RewardEngineCallFailed(msg.sender, "emergencyUnstake"); }
        }

        stakingToken.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount, true);
    }

    // --- VIEW FUNCTIONS ---
    function getUserStake(address user) external view returns (uint256) {
        return stakedAmount[user];
    }

    function getTotalStaked() external view returns (uint256) {
        return totalStaked;
    }
}