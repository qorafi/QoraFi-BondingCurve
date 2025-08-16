// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title QoraFiAirdrop
 * @author Gemini
 * @notice Weekly Merkle-based airdrop contract for QoraFi token rewards
 * @dev Implements secure, gas-efficient weekly airdrops using Merkle trees
 */
contract QoraFiAirdrop is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant AIRDROP_MANAGER_ROLE = keccak256("AIRDROP_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // --- STRUCTS ---
    /**
     * @notice Represents a weekly airdrop cycle
     * @param merkleRoot The Merkle root for eligible users this week
     * @param rewardPerUser Equal reward amount per eligible user (in wei)
     * @param totalEligible Total number of eligible users
     * @param totalClaimed Number of users who have claimed
     * @param startTime When this cycle started
     * @param endTime When this cycle ends
     * @param isActive Whether claims are currently allowed
     */
    struct AirdropCycle {
        bytes32 merkleRoot;
        uint256 rewardPerUser;
        uint256 totalEligible;
        uint256 totalClaimed;
        uint256 startTime;
        uint256 endTime;
        bool isActive;
    }

    // --- STATE VARIABLES ---
    IERC20 public immutable qorafiToken;
    
    uint256 public currentCycle;
    mapping(uint256 => AirdropCycle) public cycles;
    
    // cycle => user => claimed (bitmap would be more gas efficient for large user bases)
    mapping(uint256 => mapping(address => bool)) public hasClaimed;
    
    // Statistics
    uint256 public totalTokensDistributed;
    uint256 public totalUniqueBeneficiaries;
    mapping(address => bool) public hasEverClaimed;

    // --- CONSTANTS ---
    uint256 public constant CYCLE_DURATION = 7 days;
    uint256 public constant MIN_CYCLE_DURATION = 1 days; // Minimum for emergency cycles

    // --- EVENTS ---
    event CycleStarted(
        uint256 indexed cycle,
        bytes32 indexed merkleRoot,
        uint256 rewardPerUser,
        uint256 totalEligible,
        uint256 startTime,
        uint256 endTime
    );
    
    event TokensClaimed(
        uint256 indexed cycle,
        address indexed user,
        uint256 amount
    );
    
    event CycleEnded(
        uint256 indexed cycle,
        uint256 totalClaimed,
        uint256 totalEligible,
        uint256 unclaimedTokens
    );
    
    event TokensDeposited(address indexed from, uint256 amount);
    event TokensWithdrawn(address indexed to, uint256 amount);
    event EmergencyCycleStarted(uint256 indexed cycle, uint256 duration);

    // --- ERRORS ---
    error CycleNotActive();
    error CycleAlreadyActive();
    error AlreadyClaimed();
    error InvalidProof();
    error InsufficientBalance();
    error InvalidCycleDuration();
    error CycleNotFound();
    error InvalidMerkleRoot();
    error InvalidEligibleCount();

    /**
     * @param _qorafiToken Address of the QoraFi token contract
     */
    constructor(address _qorafiToken) {
        require(_qorafiToken != address(0), "Invalid token address");
        
        qorafiToken = IERC20(_qorafiToken);
        
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(AIRDROP_MANAGER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    // --- MODIFIERS ---
    modifier validCycle(uint256 _cycle) {
        if (cycles[_cycle].merkleRoot == bytes32(0)) revert CycleNotFound();
        _;
    }

    // --- CORE AIRDROP FUNCTIONS ---

    /**
     * @notice Claims tokens for the current active cycle
     * @param _proof Merkle proof demonstrating eligibility
     */
    function claim(bytes32[] calldata _proof) external nonReentrant whenNotPaused {
        _claimForCycle(currentCycle, _proof);
    }

    /**
     * @notice Claims tokens for a specific cycle (useful for late claims)
     * @param _cycle The cycle number to claim from
     * @param _proof Merkle proof demonstrating eligibility
     */
    function claimForCycle(uint256 _cycle, bytes32[] calldata _proof) 
        external 
        nonReentrant 
        whenNotPaused 
        validCycle(_cycle)
    {
        _claimForCycle(_cycle, _proof);
    }

    /**
     * @notice Internal claim logic
     */
    function _claimForCycle(uint256 _cycle, bytes32[] calldata _proof) internal {
        AirdropCycle storage cycle = cycles[_cycle];
        
        // Check if cycle exists and is active
        if (!cycle.isActive) revert CycleNotActive();
        
        // Check if user has already claimed for this cycle
        if (hasClaimed[_cycle][msg.sender]) revert AlreadyClaimed();
        
        // Verify Merkle proof
        bytes32 leaf = keccak256(abi.encodePacked(msg.sender));
        if (!MerkleProof.verify(_proof, cycle.merkleRoot, leaf)) {
            revert InvalidProof();
        }
        
        // Mark as claimed
        hasClaimed[_cycle][msg.sender] = true;
        cycle.totalClaimed++;
        
        // Track statistics
        if (!hasEverClaimed[msg.sender]) {
            hasEverClaimed[msg.sender] = true;
            totalUniqueBeneficiaries++;
        }
        totalTokensDistributed += cycle.rewardPerUser;
        
        // Transfer tokens
        qorafiToken.safeTransfer(msg.sender, cycle.rewardPerUser);
        
        emit TokensClaimed(_cycle, msg.sender, cycle.rewardPerUser);
    }

    // --- ADMIN FUNCTIONS ---

    /**
     * @notice Starts a new weekly airdrop cycle
     * @param _merkleRoot Merkle root of eligible users
     * @param _totalEligible Total number of eligible users in the tree
     */
    function startNewCycle(bytes32 _merkleRoot, uint256 _totalEligible) 
        external 
        onlyRole(AIRDROP_MANAGER_ROLE) 
        whenNotPaused 
    {
        _startCycle(_merkleRoot, _totalEligible, CYCLE_DURATION);
    }

    /**
     * @notice Starts an emergency cycle with custom duration
     * @param _merkleRoot Merkle root of eligible users
     * @param _totalEligible Total number of eligible users
     * @param _duration Custom cycle duration (minimum 1 day)
     */
    function startEmergencyCycle(
        bytes32 _merkleRoot, 
        uint256 _totalEligible,
        uint256 _duration
    ) external onlyRole(GOVERNANCE_ROLE) {
        if (_duration < MIN_CYCLE_DURATION) revert InvalidCycleDuration();
        
        _startCycle(_merkleRoot, _totalEligible, _duration);
        emit EmergencyCycleStarted(currentCycle, _duration);
    }

    /**
     * @notice Internal function to start a new cycle
     */
    function _startCycle(bytes32 _merkleRoot, uint256 _totalEligible, uint256 _duration) internal {
        // Validate inputs
        if (_merkleRoot == bytes32(0)) revert InvalidMerkleRoot();
        if (_totalEligible == 0) revert InvalidEligibleCount();
        
        // End current cycle if active
        if (currentCycle > 0 && cycles[currentCycle].isActive) {
            _endCurrentCycle();
        }
        
        // Calculate reward per user
        uint256 contractBalance = qorafiToken.balanceOf(address(this));
        if (contractBalance == 0) revert InsufficientBalance();
        
        uint256 rewardPerUser = contractBalance / _totalEligible;
        if (rewardPerUser == 0) revert InsufficientBalance();
        
        // Increment cycle counter
        currentCycle++;
        
        // Create new cycle
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + _duration;
        
        cycles[currentCycle] = AirdropCycle({
            merkleRoot: _merkleRoot,
            rewardPerUser: rewardPerUser,
            totalEligible: _totalEligible,
            totalClaimed: 0,
            startTime: startTime,
            endTime: endTime,
            isActive: true
        });
        
        emit CycleStarted(
            currentCycle,
            _merkleRoot,
            rewardPerUser,
            _totalEligible,
            startTime,
            endTime
        );
    }

    /**
     * @notice Manually end the current active cycle
     */
    function endCurrentCycle() external onlyRole(AIRDROP_MANAGER_ROLE) {
        _endCurrentCycle();
    }

    /**
     * @notice Internal function to end current cycle
     */
    function _endCurrentCycle() internal {
        if (currentCycle == 0) return;
        
        AirdropCycle storage cycle = cycles[currentCycle];
        if (!cycle.isActive) return;
        
        cycle.isActive = false;
        
        uint256 unclaimedTokens = (cycle.totalEligible - cycle.totalClaimed) * cycle.rewardPerUser;
        
        emit CycleEnded(
            currentCycle,
            cycle.totalClaimed,
            cycle.totalEligible,
            unclaimedTokens
        );
    }

    /**
     * @notice Deposits QoraFi tokens to fund airdrops
     * @param _amount Amount of tokens to deposit
     */
    function depositTokens(uint256 _amount) external {
        qorafiToken.safeTransferFrom(msg.sender, address(this), _amount);
        emit TokensDeposited(msg.sender, _amount);
    }

    /**
     * @notice Emergency withdrawal of tokens (governance only)
     * @param _amount Amount to withdraw
     */
    function emergencyWithdraw(uint256 _amount) external onlyRole(GOVERNANCE_ROLE) {
        qorafiToken.safeTransfer(msg.sender, _amount);
        emit TokensWithdrawn(msg.sender, _amount);
    }

    /**
     * @notice Pauses/unpauses the contract
     */
    function setPaused(bool _paused) external onlyRole(PAUSER_ROLE) {
        if (_paused) _pause();
        else _unpause();
    }

    // --- VIEW FUNCTIONS ---

    /**
     * @notice Gets details of a specific cycle
     */
    function getCycleInfo(uint256 _cycle) external view returns (AirdropCycle memory) {
        return cycles[_cycle];
    }

    /**
     * @notice Checks if a user is eligible for a specific cycle (requires proof)
     * @param _cycle Cycle number
     * @param _user User address
     * @param _proof Merkle proof
     */
    function isEligible(uint256 _cycle, address _user, bytes32[] calldata _proof) 
        external 
        view 
        returns (bool) 
    {
        if (cycles[_cycle].merkleRoot == bytes32(0)) return false;
        
        bytes32 leaf = keccak256(abi.encodePacked(_user));
        return MerkleProof.verify(_proof, cycles[_cycle].merkleRoot, leaf);
    }

    /**
     * @notice Gets current contract statistics
     */
    function getContractStats() external view returns (
        uint256 totalDistributed,
        uint256 uniqueBeneficiaries,
        uint256 contractBalance,
        uint256 activeCycle
    ) {
        return (
            totalTokensDistributed,
            totalUniqueBeneficiaries,
            qorafiToken.balanceOf(address(this)),
            currentCycle
        );
    }

    /**
     * @notice Checks if current cycle is active and hasn't expired
     */
    function isCurrentCycleActive() external view returns (bool) {
        if (currentCycle == 0) return false;
        
        AirdropCycle storage cycle = cycles[currentCycle];
        return cycle.isActive && block.timestamp <= cycle.endTime;
    }

    /**
     * @notice Gets time remaining in current cycle
     */
    function getCurrentCycleTimeRemaining() external view returns (uint256) {
        if (currentCycle == 0) return 0;
        
        AirdropCycle storage cycle = cycles[currentCycle];
        if (!cycle.isActive || block.timestamp >= cycle.endTime) return 0;
        
        return cycle.endTime - block.timestamp;
    }
}