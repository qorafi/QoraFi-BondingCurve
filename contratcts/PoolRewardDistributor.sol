// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

// --- INTERFACES ---
interface IQoraFiToken {
    function mint(address to, uint256 amount) external;
}

interface IProofOfLiquidity {
    function qorafiPriceTwap() external view returns (uint256);
    function lastOracleUpdateTime() external view returns (uint256);
    function oracleStalenessThreshold() external view returns (uint256);
}

/**
 * @title PoolRewardDistributor (Hardened Virtual Rewards Version)
 * @notice Manages 5 reward pools with virtual USDT balances, which are claimed as minted QoraFi tokens.
 * @dev This contract is designed to be fully controlled by a DAO via a Timelock.
 */
contract PoolRewardDistributor is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;

    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // --- STRUCTS ---
    struct Pool {
        uint256 totalVirtualUSDT;
        uint256 rewardsPerShare;
        EnumerableSet.AddressSet qualifiedMembers;
    }

    // --- STATE VARIABLES ---
    IQoraFiToken public immutable qorafiToken;
    IProofOfLiquidity public immutable proofOfLiquidity;
    address public usqEngineAddress;
    address public treasuryAddress;
    address public authorizedFunder; // The DelegatorNodeRewardsLedger

    uint256 public constant NUM_POOLS = 5;
    Pool[NUM_POOLS] public pools;

    mapping(address => mapping(uint256 => uint256)) public userRewardDebt;
    mapping(address => uint256) public pendingRewards;
    
    // Fee-on-claim parameters
    uint256 public claimFeeBPS;
    uint256 public usqEngineFeeSplitBPS;
    uint256 public treasuryFeeSplitBPS;

    // Oracle Security
    uint256 public minOraclePrice;
    uint256 public maxOraclePrice;
    
    // Security & Gas Parameters
    uint256 public constant MAX_BATCH_SIZE = 100;
    uint256 public constant MAX_MEMBERS_PER_POOL = 10000;
    uint256 public maxPendingRewardsPerUser;
    uint256 public constant EMERGENCY_ORACLE_STALENESS = 2 days;
    uint256 private constant PRECISION = 1e18;
    uint256 private rewardRemainder;

    // --- EVENTS & ERRORS ---
    event RewardsAdded(uint256 indexed poolId, uint256 indexed amount, uint256 memberCount, uint256 timestamp);
    event MemberQualificationUpdated(address indexed user, uint256 indexed poolId, bool indexed isQualified);
    event RewardsClaimed(address indexed user, uint256 qorafiAmount, uint256 feeAmount);
    event EmergencyRewardsClaimed(address indexed user, uint256 qorafiAmount, uint256 feeAmount);
    event OraclePriceBoundsUpdated(uint256 minPrice, uint256 maxPrice);
    event AuthorizedFunderUpdated(address newFunder);
    event FeeConfigUpdated(uint256 claimFee, uint256 engineSplit, uint256 treasurySplit);
    event UsqEngineAddressUpdated(address newAddress);
    event TreasuryAddressUpdated(address newAddress);
    event PausedStateChanged(bool isPaused);
    event MaxPendingRewardsUpdated(uint256 newMax);
    
    error NotAuthorizedFunder();
    error InvalidPoolId();
    error NotQualified();
    error NoRewardsToClaim();
    error OracleNotReady();
    error OracleIsStale();
    error InvalidAddress();
    error InvalidFeeConfiguration();
    error NoAssetsToWithdraw();
    error BNBWithdrawalFailed();
    error OraclePriceOutOfBounds();
    error InvalidArrayLengths();
    error UserAlreadyInState();
    error BatchTooLarge();
    error InvalidAmount();
    error EmergencyConditionsNotMet();
    error PoolAtMaxCapacity();
    error InvalidPriceBounds();
    error CannotWithdrawCoreToken();

    constructor(
        address _qorafiTokenAddress,
        address _proofOfLiquidityAddress,
        address _usqEngineAddress,
        address _initialTreasuryAddress,
        address _initialAuthorizedFunder
    ) {
        if (_qorafiTokenAddress == address(0) || _proofOfLiquidityAddress == address(0) || _usqEngineAddress == address(0) || _initialTreasuryAddress == address(0) || _initialAuthorizedFunder == address(0)) {
            revert InvalidAddress();
        }

        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);

        qorafiToken = IQoraFiToken(_qorafiTokenAddress);
        proofOfLiquidity = IProofOfLiquidity(_proofOfLiquidityAddress);
        usqEngineAddress = _usqEngineAddress;
        treasuryAddress = _initialTreasuryAddress;
        authorizedFunder = _initialAuthorizedFunder;

        claimFeeBPS = 500;
        usqEngineFeeSplitBPS = 200;
        treasuryFeeSplitBPS = 300;

        minOraclePrice = 1e16;
        maxOraclePrice = 10000 * 1e18;
        maxPendingRewardsPerUser = 1000000 * 1e18; // Default 1M QoraFi
    }

    // --- CORE LOGIC ---

    function addRewardsToPools(uint256 _totalVirtualUSDT) external {
        if (msg.sender != authorizedFunder) revert NotAuthorizedFunder();
        if (_totalVirtualUSDT == 0) revert InvalidAmount();
        
        uint256 totalToDistribute = _totalVirtualUSDT + rewardRemainder;
        uint256 amountPerPool = totalToDistribute / NUM_POOLS;
        rewardRemainder = totalToDistribute % NUM_POOLS;

        for (uint256 i = 0; i < NUM_POOLS; i++) {
            Pool storage pool = pools[i];
            uint256 memberCount = pool.qualifiedMembers.length();
            if (memberCount > 0) {
                pool.rewardsPerShare += Math.mulDiv(amountPerPool, PRECISION, memberCount);
            }
            pool.totalVirtualUSDT += amountPerPool;
            emit RewardsAdded(i, amountPerPool, memberCount, block.timestamp);
        }
    }

    function claimRewards() external nonReentrant whenNotPaused {
        _updatePendingRewards(msg.sender);
        _claimRewards(msg.sender, false);
    }

    function emergencyClaim() external nonReentrant {
        if (!_isEmergencyConditionMet()) revert EmergencyConditionsNotMet();
        try this._updatePendingRewards(msg.sender) {} catch {}
        _claimRewards(msg.sender, true);
    }

    function _claimRewards(address _user, bool isEmergency) private {
        uint256 totalPending = pendingRewards[_user];
        if (totalPending == 0) revert NoRewardsToClaim();

        pendingRewards[_user] = 0;

        uint256 feeAmount = (totalPending * claimFeeBPS) / 10_000;
        uint256 amountToUser = totalPending - feeAmount;
        uint256 usqEngineShare = 0;
        uint256 treasuryShare = 0;

        if (feeAmount > 0 && claimFeeBPS > 0) {
            usqEngineShare = Math.mulDiv(feeAmount, usqEngineFeeSplitBPS, claimFeeBPS);
            treasuryShare = feeAmount - usqEngineShare;
        }

        qorafiToken.mint(_user, amountToUser);
        if (usqEngineShare > 0) {
            qorafiToken.mint(usqEngineAddress, usqEngineShare);
        }
        if (treasuryShare > 0) {
            qorafiToken.mint(treasuryAddress, treasuryShare);
        }

        if (isEmergency) {
            emit EmergencyRewardsClaimed(_user, amountToUser, feeAmount);
        } else {
            emit RewardsClaimed(_user, amountToUser, feeAmount);
        }
    }

    // --- GOVERNANCE-CONTROLLED FUNCTIONS ---

    function setPaused(bool _isPaused) external onlyRole(PAUSER_ROLE) {
        if (_isPaused) _pause();
        else _unpause();
        emit PausedStateChanged(_isPaused);
    }

    function updateMemberQualification(address _user, uint256 _poolId, bool _isQualified) public onlyRole(GOVERNANCE_ROLE) {
        if (_poolId >= NUM_POOLS) revert InvalidPoolId();
        
        _updatePendingRewards(_user);

        bool isAlreadyMember = pools[_poolId].qualifiedMembers.contains(_user);
        if (_isQualified == isAlreadyMember) revert UserAlreadyInState();

        if (_isQualified) {
            if (pools[_poolId].qualifiedMembers.length() >= MAX_MEMBERS_PER_POOL) {
                revert PoolAtMaxCapacity();
            }
            pools[_poolId].qualifiedMembers.add(_user);
            userRewardDebt[_user][_poolId] = pools[_poolId].rewardsPerShare;
        } else {
            pools[_poolId].qualifiedMembers.remove(_user);
            userRewardDebt[_user][_poolId] = 0;
        }
        
        emit MemberQualificationUpdated(_user, _poolId, _isQualified);
    }
    
    function batchUpdateMemberQualification(address[] calldata _users, uint256[] calldata _poolIds, bool[] calldata _areQualified) external onlyRole(GOVERNANCE_ROLE) {
        uint256 len = _users.length;
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge();
        if (len != _poolIds.length || len != _areQualified.length) revert InvalidArrayLengths();

        mapping(address => bool) memory updatedUsers;
        for (uint i = 0; i < len; i++) {
            if (!updatedUsers[_users[i]]) {
                _updatePendingRewards(_users[i]);
                updatedUsers[_users[i]] = true;
            }
            updateMemberQualification(_users[i], _poolIds[i], _areQualified[i]);
        }
    }

    function setAuthorizedFunder(address _newFunder) external onlyRole(GOVERNANCE_ROLE) {
        if (_newFunder == address(0)) revert InvalidAddress();
        authorizedFunder = _newFunder;
        emit AuthorizedFunderUpdated(_newFunder);
    }

    function setFeeConfig(uint256 _claimFeeBPS, uint256 _usqEngineSplitBPS, uint256 _treasurySplitBPS) external onlyRole(GOVERNANCE_ROLE) {
        if (_claimFeeBPS > 1000) revert InvalidFeeConfiguration(); // Max 10%
        if (_usqEngineSplitBPS > _claimFeeBPS || _treasurySplitBPS > _claimFeeBPS) {
            revert InvalidFeeConfiguration();
        }
        if (_usqEngineSplitBPS + _treasurySplitBPS != _claimFeeBPS) revert InvalidFeeConfiguration();
        
        claimFeeBPS = _claimFeeBPS;
        usqEngineFeeSplitBPS = _usqEngineSplitBPS;
        treasuryFeeSplitBPS = _treasurySplitBPS;
        emit FeeConfigUpdated(_claimFeeBPS, _usqEngineSplitBPS, _treasurySplitBPS);
    }
    
    function setUSQEngineAddress(address _newAddress) external onlyRole(GOVERNANCE_ROLE) {
        if (_newAddress == address(0)) revert InvalidAddress();
        usqEngineAddress = _newAddress;
        emit UsqEngineAddressUpdated(_newAddress);
    }

    function setTreasuryAddress(address _newAddress) external onlyRole(GOVERNANCE_ROLE) {
        if (_newAddress == address(0)) revert InvalidAddress();
        treasuryAddress = _newAddress;
        emit TreasuryAddressUpdated(_newAddress);
    }

    function setOraclePriceBounds(uint256 _minPrice, uint256 _maxPrice) external onlyRole(GOVERNANCE_ROLE) {
        if (_minPrice >= _maxPrice) revert InvalidPriceBounds();
        minOraclePrice = _minPrice;
        maxOraclePrice = _maxPrice;
        emit OraclePriceBoundsUpdated(_minPrice, _maxPrice);
    }

    function setMaxPendingRewardsPerUser(uint256 _newMax) external onlyRole(GOVERNANCE_ROLE) {
        if (_newMax == 0) revert InvalidAmount();
        maxPendingRewardsPerUser = _newMax;
        emit MaxPendingRewardsUpdated(_newMax);
    }

    function withdrawStuckTokens(address _tokenAddress) external onlyRole(GOVERNANCE_ROLE) {
        if (_tokenAddress == address(qorafiToken)) revert CannotWithdrawCoreToken();
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

    // --- VIEW & HELPER FUNCTIONS ---

    function getPendingRewards(address _user) public view returns (uint256) {
        uint256 newlyAccrued = 0;
        (bool success, uint256 newRewards) = _tryGetNewlyAccruedRewards(_user);
        if (success) {
            newlyAccrued = newRewards;
        }
        return pendingRewards[_user] + newlyAccrued;
    }

    function _tryGetNewlyAccruedRewards(address _user) internal view returns (bool success, uint256 rewards) {
        try proofOfLiquidity.qorafiPriceTwap() returns (uint256 qorPrice) {
            if (qorPrice == 0) return (false, 0);
            if (block.timestamp - proofOfLiquidity.lastOracleUpdateTime() > proofOfLiquidity.oracleStalenessThreshold()) return (false, 0);
            if (qorPrice < minOraclePrice || qorPrice > maxOraclePrice) return (false, 0);

            uint256 totalPendingVirtualUSDT_Scaled = 0;
            for (uint256 i = 0; i < NUM_POOLS; i++) {
                if (pools[i].qualifiedMembers.contains(_user)) {
                    uint256 userDebt = userRewardDebt[_user][i];
                    uint256 currentRewards = pools[i].rewardsPerShare;
                    if (currentRewards > userDebt) {
                        totalPendingVirtualUSDT_Scaled += currentRewards - userDebt;
                    }
                }
            }
            return (Math.mulDiv(totalPendingVirtualUSDT_Scaled, PRECISION, qorPrice), true);
        } catch {
            return (false, 0);
        }
    }
    
    function _updatePendingRewards(address _user) internal {
        (bool success, uint256 newlyAccrued) = _tryGetNewlyAccruedRewards(_user);
        if (success && newlyAccrued > 0) {
            uint256 newTotal = pendingRewards[_user] + newlyAccrued;
            if (newTotal > maxPendingRewardsPerUser) {
                newTotal = maxPendingRewardsPerUser;
            }
            pendingRewards[_user] = newTotal;
            for (uint256 i = 0; i < NUM_POOLS; i++) {
                if (pools[i].qualifiedMembers.contains(_user)) {
                    userRewardDebt[_user][i] = pools[i].rewardsPerShare;
                }
            }
        }
    }

    function _isEmergencyConditionMet() internal view returns (bool) {
        try proofOfLiquidity.lastOracleUpdateTime() returns (uint256 lastUpdate) {
            return lastUpdate > 0 && block.timestamp - lastUpdate > EMERGENCY_ORACLE_STALENESS;
        } catch {
            return true;
        }
    }

    function getPoolInfo(uint256 _poolId) external view returns (uint256 totalVirtualUSDT, uint256 rewardsPerShare, uint256 memberCount) {
        if (_poolId >= NUM_POOLS) revert InvalidPoolId();
        Pool storage pool = pools[_poolId];
        return (pool.totalVirtualUSDT, pool.rewardsPerShare, pool.qualifiedMembers.length());
    }

    function getUserPoolStatus(address _user) external view returns (bool[NUM_POOLS] memory isQualified, uint256[NUM_POOLS] memory rewardDebts) {
        for (uint256 i = 0; i < NUM_POOLS; i++) {
            isQualified[i] = pools[i].qualifiedMembers.contains(_user);
            rewardDebts[i] = userRewardDebt[_user][i];
        }
    }

    function getContractStats() external view returns (uint256 totalVirtualUSDTAcrossPools, uint256 totalQualifiedMembers, uint256 currentOraclePrice, bool isOracleStale) {
        for (uint256 i = 0; i < NUM_POOLS; i++) {
            totalVirtualUSDTAcrossPools += pools[i].totalVirtualUSDT;
            totalQualifiedMembers += pools[i].qualifiedMembers.length();
        }
        try proofOfLiquidity.qorafiPriceTwap() returns (uint256 price) {
            currentOraclePrice = price;
            isOracleStale = block.timestamp - proofOfLiquidity.lastOracleUpdateTime() > proofOfLiquidity.oracleStalenessThreshold();
        } catch {
            isOracleStale = true;
        }
    }
}
