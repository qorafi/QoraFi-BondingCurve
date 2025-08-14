// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// --- INTERFACES ---
interface IPoolRewardDistributor {
    function addRewardsToPools(uint256 _totalVirtualUSDT) external;
}

/**
 * @title DelegatorNodeRewardsLedger
 * @notice A gas-efficient ledger for referral and user level data, controlled by the DAO.
 * @dev This contract also acts as the bridge to fund the virtual pool rewards.
 */
contract DelegatorNodeRewardsLedger is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // --- STATE VARIABLES ---
    address public bondingCurveAddress;
    address public treasuryAddress;
    IPoolRewardDistributor public poolRewardDistributor;

    // --- Referral and Level Data ---
    mapping(address => address) public referrerOf;
    mapping(address => bool) public hasReferrer;
    mapping(address => uint256) public userTotalDeposited;
    mapping(address => uint256) public userCurrentLevel;
    
    // --- Configuration (Readable by the off-chain server) ---
    uint256[15] public levelDepositRequirements;
    uint256[15] public levelRewardPercentagesBPS;

    uint256 public constant MAX_REFERRAL_LEVELS = 15;
    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant POOL_REWARD_FEE_BPS = 500; // 5%

    // --- EVENTS ---
    event ReferrerSet(address indexed user, address indexed referrer);
    event DepositRecorded(address indexed user, uint256 amountUSDT);
    event UserLevelUpdated(address indexed user, uint256 newLevel);
    event TreasuryAddressUpdated(address newTreasury);
    event BondingCurveAddressUpdated(address newBondingCurve);
    event PoolDistributorUpdated(address newDistributor);
    event LevelConfigUpdated(uint8 level, uint256 depositRequirement, uint256 rewardPercentage);
    event NotifyPoolDistributorFailed(uint256 amount);

    // --- ERRORS ---
    error AlreadyHasReferrer();
    error InvalidReferrer();
    error CannotReferSelf();
    error InvalidLevel();
    error NotAuthorized();
    error NoAssetsToWithdraw();
    error InvalidAddress();
    error PercentageTooHigh();
    error BNBWithdrawalFailed();
    error LevelRequirementsNotSorted();
    error CircularReferral();

    constructor(
        uint256[MAX_REFERRAL_LEVELS] memory _levelDepositRequirements,
        uint256[MAX_REFERRAL_LEVELS] memory _levelRewardPercentagesBPS,
        address _initialTreasuryAddress,
        address _poolRewardDistributorAddress,
        address _initialBondingCurveAddress
    ) {
        if (_initialTreasuryAddress == address(0) || _poolRewardDistributorAddress == address(0) || _initialBondingCurveAddress == address(0)) {
            revert InvalidAddress();
        }
        
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        
        treasuryAddress = _initialTreasuryAddress;
        poolRewardDistributor = IPoolRewardDistributor(_poolRewardDistributorAddress);
        bondingCurveAddress = _initialBondingCurveAddress;

        for (uint8 i = 0; i < MAX_REFERRAL_LEVELS; i++) {
            if (i > 0 && _levelDepositRequirements[i] < _levelDepositRequirements[i-1]) {
                revert LevelRequirementsNotSorted();
            }
            levelDepositRequirements[i] = _levelDepositRequirements[i];
            levelRewardPercentagesBPS[i] = _levelRewardPercentagesBPS[i];
        }
    }

    /**
     * @notice Called by the BondingCurve contract to record a new deposit and fund the virtual reward pools.
     */
    function notifyDeposit(address _user, uint256 _amountUSDT) external nonReentrant {
        if (msg.sender != bondingCurveAddress) revert NotAuthorized();

        // 1. Record the deposit for the referral system's off-chain calculations
        userTotalDeposited[_user] += _amountUSDT;
        _updateUserLevel(_user);
        emit DepositRecorded(_user, _amountUSDT);

        // 2. Calculate and send the virtual reward amount to the Pool Distributor
        uint256 poolRewardAmount = (_amountUSDT * POOL_REWARD_FEE_BPS) / MAX_BPS;
        if (poolRewardAmount > 0) {
            try poolRewardDistributor.addRewardsToPools(poolRewardAmount) {} catch {
                emit NotifyPoolDistributorFailed(poolRewardAmount);
            }
        }
    }
    
    // --- GOVERNANCE-CONTROLLED FUNCTIONS ---

    function setPaused(bool _isPaused) external onlyRole(PAUSER_ROLE) {
        if (_isPaused) _pause();
        else _unpause();
    }

    function setBondingCurveAddress(address _bondingCurveAddress) external onlyRole(GOVERNANCE_ROLE) {
        if (_bondingCurveAddress == address(0)) revert InvalidAddress();
        bondingCurveAddress = _bondingCurveAddress;
        emit BondingCurveAddressUpdated(_bondingCurveAddress);
    }
    
    function setPoolRewardDistributor(address _newDistributor) external onlyRole(GOVERNANCE_ROLE) {
        if (_newDistributor == address(0)) revert InvalidAddress();
        poolRewardDistributor = IPoolRewardDistributor(_newDistributor);
        emit PoolDistributorUpdated(_newDistributor);
    }

    function setTreasuryAddress(address _newTreasury) external onlyRole(GOVERNANCE_ROLE) {
        if (_newTreasury == address(0)) revert InvalidAddress();
        treasuryAddress = _newTreasury;
        emit TreasuryAddressUpdated(_newTreasury);
    }

    function setLevelDepositRequirement(uint8 _level, uint256 _amount) external onlyRole(GOVERNANCE_ROLE) {
        if (_level == 0 || _level > MAX_REFERRAL_LEVELS) revert InvalidLevel();
        // Add validation to ensure sorting is maintained
        if (_level > 1 && _amount < levelDepositRequirements[_level - 2]) revert LevelRequirementsNotSorted();
        if (_level < MAX_REFERRAL_LEVELS && _amount > levelDepositRequirements[_level]) revert LevelRequirementsNotSorted();
        
        levelDepositRequirements[_level - 1] = _amount;
        emit LevelConfigUpdated(_level, _amount, levelRewardPercentagesBPS[_level - 1]);
    }

    function setLevelRewardPercentageBPS(uint8 _level, uint256 _percentageBPS) external onlyRole(GOVERNANCE_ROLE) {
        if (_level == 0 || _level > MAX_REFERRAL_LEVELS) revert InvalidLevel();
        if (_percentageBPS > MAX_BPS) revert PercentageTooHigh();
        levelRewardPercentagesBPS[_level - 1] = _percentageBPS;
        emit LevelConfigUpdated(_level, levelDepositRequirements[_level - 1], _percentageBPS);
    }

    function withdrawStuckTokens(address _tokenAddress) external onlyRole(GOVERNANCE_ROLE) {
        IERC20 token = IERC20(_tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) revert NoAssetsToWithdraw();
        token.safeTransfer(treasuryAddress, balance);
    }

    function withdrawStuckBNB() external onlyRole(GOVERNANCE_ROLE) {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoAssetsToWithdraw();
        (bool success, ) = payable(treasuryAddress).call{value: balance}("");
        if (!success) revert BNBWithdrawalFailed();
    }

    // --- PUBLIC USER FUNCTIONS ---

    function setReferrer(address _referrer) external whenNotPaused {
        if (msg.sender == _referrer) revert CannotReferSelf();
        if (hasReferrer[msg.sender]) revert AlreadyHasReferrer();
        if (_referrer == address(0) || !hasReferrer[_referrer]) revert InvalidReferrer();

        // Circular referral check
        address current = _referrer;
        for (uint i = 0; i < MAX_REFERRAL_LEVELS; i++) {
            if (current == msg.sender) revert CircularReferral();
            if (hasReferrer[current]) {
                current = referrerOf[current];
            } else {
                break;
            }
        }

        referrerOf[msg.sender] = _referrer;
        hasReferrer[msg.sender] = true;
        emit ReferrerSet(msg.sender, _referrer);
    }
    
    // --- INTERNAL FUNCTIONS ---

    function _updateUserLevel(address _user) internal {
        uint256 totalDeposits = userTotalDeposited[_user];
        uint256 newLevel = 0;
        
        // Gas Optimization: Binary search for level
        uint256 low = 0;
        uint256 high = MAX_REFERRAL_LEVELS - 1;
        while (low <= high) {
            uint256 mid = (low + high) / 2;
            if (totalDeposits >= levelDepositRequirements[mid]) {
                newLevel = mid + 1;
                low = mid + 1;
            } else {
                if (mid == 0) break; // Avoid underflow
                high = mid - 1;
            }
        }
        
        if (userCurrentLevel[_user] != newLevel) {
            userCurrentLevel[_user] = newLevel;
            emit UserLevelUpdated(_user, newLevel);
        }
    }
    
    receive() external payable {}
}