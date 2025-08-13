// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";

// --- INTERFACES ---

interface IProofOfLiquidity {
    function getPastStakedAmount(address user, uint256 blockNumber) external view returns (uint256);
}

interface IUniswapV2Pair {
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
}

/**
 * @title QoraFiGovernor (OpenZeppelin v5 Compatible)
 * @notice A governor that securely counts votes from both wallet balances and staked LP tokens using a snapshot system.
 * @dev All administrative functions are intended to be controlled by a DAO via a Timelock.
 */
contract QoraFiGovernor is 
    Governor, 
    GovernorSettings, 
    GovernorCountingSimple, 
    GovernorVotes, 
    GovernorTimelockControl, 
    ReentrancyGuard,
    AccessControl 
{
    
    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant SNAPSHOT_ROLE = keccak256("SNAPSHOT_ROLE");

    // --- STRUCTS ---
    struct LpSnapshot {
        uint256 blockNumber;
        uint256 totalSupply;
        uint256 qorafiInPool;
        uint256 timestamp;
    }

    // --- STATE VARIABLES ---
    IProofOfLiquidity public immutable stakingContract;
    IUniswapV2Pair public immutable lpPair;
    uint256 public quorumValue;

    // Snapshot system for historical LP token ratios
    LpSnapshot[] public snapshots;

    // --- CONSTANTS ---
    uint256 public constant MIN_QUORUM = 1000 * 1e18; // 1K tokens minimum
    uint256 public constant MAX_QUORUM = 10_000_000 * 1e18; // 10M tokens maximum
    uint256 public constant MAX_SNAPSHOTS = 1000;
    uint256 public constant SNAPSHOT_DELAY = 1 hours; // Minimum time between snapshots

    // --- EVENTS & ERRORS ---
    event QuorumUpdated(uint256 oldQuorum, uint256 newQuorum);
    event LpSnapshotCreated(uint256 indexed blockNumber, uint256 totalSupply, uint256 qorafiInPool);
    event SnapshotRoleGranted(address indexed account);
    event SnapshotRoleRevoked(address indexed account);

    error InvalidQuorum();
    error SnapshotTooSoon();
    error NoSnapshotFound();
    error SnapshotQueryForFutureBlock();
    error InvalidAddress();
    error SnapshotAlreadyExists();

    constructor(
        IVotes _token,
        TimelockController _timelock,
        IProofOfLiquidity _stakingContract,
        IUniswapV2Pair _lpPair,
        uint48 _initialVotingDelay,      // Changed to uint48 for v5 compatibility
        uint32 _initialVotingPeriod,     // Changed to uint32 for v5 compatibility  
        uint256 _initialProposalThreshold,
        uint256 _initialQuorumValue
    )
        Governor("QoraFiGovernor")
        GovernorSettings(_initialVotingDelay, _initialVotingPeriod, _initialProposalThreshold)
        GovernorVotes(_token)
        GovernorTimelockControl(_timelock)
    {
        if (address(_token) == address(0) || address(_timelock) == address(0) || address(_stakingContract) == address(0) || address(_lpPair) == address(0)) {
            revert InvalidAddress();
        }
        stakingContract = _stakingContract;
        lpPair = _lpPair;
        
        _setQuorumInternal(_initialQuorumValue);
        
        // Grant the main governance role to the Timelock contract
        _grantRole(GOVERNANCE_ROLE, address(_timelock));
        
        // Grant the snapshot role to the deployer for initial setup
        _grantRole(SNAPSHOT_ROLE, msg.sender);

        // Create initial snapshot for early governance functionality
        _createInitialSnapshot();
    }
    
    function _createInitialSnapshot() internal {
        uint256 currentBlock = block.number;
        uint256 currentTime = block.timestamp;
        uint256 lpTotalSupply = lpPair.totalSupply();
        uint256 qorafiInPool = IERC20(address(token())).balanceOf(address(lpPair));

        snapshots.push(LpSnapshot({
            blockNumber: currentBlock,
            totalSupply: lpTotalSupply,
            qorafiInPool: qorafiInPool,
            timestamp: currentTime
        }));
        emit LpSnapshotCreated(currentBlock, lpTotalSupply, qorafiInPool);
    }

    /**
     * @notice Creates a new snapshot of the LP token's QoraFi ratio.
     */
    function createLpSnapshot() external nonReentrant onlyRole(SNAPSHOT_ROLE) {
        uint256 currentBlock = block.number;
        uint256 currentTime = block.timestamp;

        if (snapshots.length > 0) {
            if (snapshots[snapshots.length - 1].timestamp + SNAPSHOT_DELAY > currentTime) {
                revert SnapshotTooSoon();
            }
        }

        uint256 lpTotalSupply = lpPair.totalSupply();
        uint256 qorafiInPool = IERC20(address(token())).balanceOf(address(lpPair));
        
        if (snapshots.length >= MAX_SNAPSHOTS) {
            for (uint i = 0; i < snapshots.length - 1; i++) {
                snapshots[i] = snapshots[i+1];
            }
            snapshots[snapshots.length - 1] = LpSnapshot({
                blockNumber: currentBlock,
                totalSupply: lpTotalSupply,
                qorafiInPool: qorafiInPool,
                timestamp: currentTime
            });
        } else {
            snapshots.push(LpSnapshot({
                blockNumber: currentBlock,
                totalSupply: lpTotalSupply,
                qorafiInPool: qorafiInPool,
                timestamp: currentTime
            }));
        }
        emit LpSnapshotCreated(currentBlock, lpTotalSupply, qorafiInPool);
    }

    /**
     * @dev Overrides the vote counting mechanism to include staked LP tokens
     */
    function _getVotes(address account, uint256 blockNumber, bytes memory /* params */)
        internal
        view
        override(Governor, GovernorVotes)
        returns (uint256)
    {
        uint256 walletVotes = super._getVotes(account, blockNumber, "");
        uint256 stakedLpAmount = stakingContract.getPastStakedAmount(account, blockNumber);
        
        if (stakedLpAmount == 0) {
            return walletVotes;
        }
        
        LpSnapshot memory snapshot = _getHistoricalLpRatio(blockNumber);
        
        uint256 stakedQorafiVotes = 0;
        if (snapshot.totalSupply > 0) {
            stakedQorafiVotes = Math.mulDiv(stakedLpAmount, snapshot.qorafiInPool, snapshot.totalSupply);
        }
        
        return walletVotes + stakedQorafiVotes;
    }

    /**
     * @dev Finds the most recent snapshot at or before a given block number
     */
    function _getHistoricalLpRatio(uint256 blockNumber) internal view returns (LpSnapshot memory) {
        if (blockNumber > block.number) revert SnapshotQueryForFutureBlock();
        
        uint256 len = snapshots.length;
        if (len == 0) revert NoSnapshotFound();
        
        if (snapshots[0].blockNumber > blockNumber) revert NoSnapshotFound();
        if (snapshots[len - 1].blockNumber <= blockNumber) return snapshots[len - 1];

        uint256 left = 0;
        uint256 right = len - 1;
        
        while (left < right) {
            uint256 mid = left + (right - left + 1) / 2;
            if (snapshots[mid].blockNumber <= blockNumber) {
                left = mid;
            } else {
                right = mid - 1;
            }
        }
        return snapshots[left];
    }

    /**
     * @dev Overrides the quorum to use a fixed token amount
     */
    function quorum(uint256 /* blockNumber */)
        public
        view
        override(Governor)
        returns (uint256)
    {
        return quorumValue;
    }

    /**
     * @notice Allows governance to update the quorum value
     */
    function setQuorum(uint256 newQuorumValue) public onlyRole(GOVERNANCE_ROLE) {
        _setQuorumInternal(newQuorumValue);
    }

    function _setQuorumInternal(uint256 newQuorumValue) internal {
        if (newQuorumValue < MIN_QUORUM || newQuorumValue > MAX_QUORUM) {
            revert InvalidQuorum();
        }
        uint256 oldQuorum = quorumValue;
        quorumValue = newQuorumValue;
        emit QuorumUpdated(oldQuorum, newQuorumValue);
    }

    /**
     * @notice Grant snapshot role
     */
    function grantSnapshotRole(address account) external onlyRole(GOVERNANCE_ROLE) {
        if (account == address(0)) revert InvalidAddress();
        _grantRole(SNAPSHOT_ROLE, account);
        emit SnapshotRoleGranted(account);
    }

    /**
     * @notice Revoke snapshot role
     */
    function revokeSnapshotRole(address account) external onlyRole(GOVERNANCE_ROLE) {
        if (account == address(0)) revert InvalidAddress();
        _revokeRole(SNAPSHOT_ROLE, account);
        emit SnapshotRoleRevoked(account);
    }

    // --- VIEW FUNCTIONS ---

    function getSnapshotCount() external view returns (uint256) {
        return snapshots.length;
    }

    function getRecentSnapshots(uint256 count) external view returns (LpSnapshot[] memory) {
        uint256 len = snapshots.length;
        if (len == 0) return new LpSnapshot[](0);

        uint256 returnCount = count > len ? len : count;
        LpSnapshot[] memory result = new LpSnapshot[](returnCount);
        
        unchecked {
            for (uint256 i = 0; i < returnCount; i++) {
                result[i] = snapshots[len - 1 - i];
            }
        }
        return result;
    }

    function canCreateSnapshot() external view returns (bool) {
        if (snapshots.length == 0) return true;
        uint256 lastSnapshotTime = snapshots[snapshots.length - 1].timestamp;
        return block.timestamp >= lastSnapshotTime + SNAPSHOT_DELAY;
    }

    function getVotingPowerBreakdown(address account, uint256 blockNumber) 
        external 
        view 
        returns (uint256 walletVotes, uint256 stakedVotes, uint256 totalVotes) 
    {
        walletVotes = GovernorVotes._getVotes(account, blockNumber, "");
        
        uint256 stakedLpAmount = stakingContract.getPastStakedAmount(account, blockNumber);
        if (stakedLpAmount > 0) {
            LpSnapshot memory snapshot = _getHistoricalLpRatio(blockNumber);
            if (snapshot.totalSupply > 0) {
                stakedVotes = Math.mulDiv(stakedLpAmount, snapshot.qorafiInPool, snapshot.totalSupply);
            }
        }
        
        totalVotes = walletVotes + stakedVotes;
    }

    function isSnapshotRequired() external view returns (bool required, uint256 timeSinceLastSnapshot) {
        if (snapshots.length == 0) return (true, 0);
        
        uint256 lastSnapshotTime = snapshots[snapshots.length - 1].timestamp;
        timeSinceLastSnapshot = block.timestamp > lastSnapshotTime ? block.timestamp - lastSnapshotTime : 0;
        
        required = timeSinceLastSnapshot >= SNAPSHOT_DELAY;
    }

    // --- REQUIRED OVERRIDES FOR MULTIPLE INHERITANCE ---
    
    /**
     * @dev Required override for _cancel due to multiple inheritance
     * Both Governor and GovernorTimelockControl define this function
     */
    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }
    
    /**
     * @dev Required override for _executeOperations due to multiple inheritance
     */
    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }
    
    /**
     * @dev Required override for _queueOperations due to multiple inheritance
     * This function has different return types in the inheritance chain
     */
    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }
    
    function votingDelay()
        public view override(Governor, GovernorSettings) 
        returns (uint256) 
    { 
        return super.votingDelay(); 
    }
    
    function votingPeriod()
        public view override(Governor, GovernorSettings) 
        returns (uint256) 
    { 
        return super.votingPeriod(); 
    }
    
    function proposalThreshold()
        public view override(Governor, GovernorSettings)
        returns (uint256)
    {
        return super.proposalThreshold();
    }
    
    function state(uint256 proposalId)
        public view override(Governor, GovernorTimelockControl) 
        returns (ProposalState) 
    { 
        return super.state(proposalId); 
    }
    
    function proposalNeedsQueuing(uint256 proposalId)
        public view override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }
    
    function _executor()
        internal view override(Governor, GovernorTimelockControl)
        returns (address)
    {
        return super._executor();
    }
    
    function supportsInterface(bytes4 interfaceId)
        public view override(Governor, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}