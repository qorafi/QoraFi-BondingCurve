// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// --- INTERFACES ---
interface IQoraFiToken {
    function mint(address to, uint256 amount) external;
}

/**
 * @title DelegatorDistributor (Hardened Version)
 * @notice Distributes QoraFi tokens via Merkle proofs with enhanced security and DAO control.
 * @dev Implements role-based access, pause functionality, claim windows, and batch claims for multiple distribution periods.
 */
contract DelegatorDistributor is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MERKLE_UPDATER_ROLE = keccak256("MERKLE_UPDATER_ROLE");

    // --- STRUCTS ---
    struct Distribution {
        bytes32 merkleRoot;
        uint256 claimWindowEnd;
        uint256 maxClaimAmount;
    }

    // --- STATE VARIABLES ---
    IQoraFiToken public immutable qorafiToken;
    address public treasuryAddress;
    
    mapping(uint256 => Distribution) public distributions;
    uint256 public latestDistributionId;
    
    mapping(uint256 => mapping(uint256 => uint256)) private claimedBitMaps;

    // Enhanced Monitoring
    uint256 public totalClaimedAmount;
    uint256 public totalUniqueClaimants;
    mapping(address => bool) private hasEverClaimed;

    uint256 public constant MAX_BATCH_SIZE = 100;

    // --- EVENTS ---
    event NewDistributionStarted(uint256 indexed distributionId, bytes32 newRoot, uint256 windowEnd, uint256 maxAmount);
    event Claimed(uint256 indexed distributionId, uint256 index, address indexed account, uint256 amount);
    event TreasuryAddressUpdated(address newTreasury);
    event PausedStateChanged(bool isPaused);

    // --- ERRORS ---
    error InvalidProof();
    error AlreadyClaimed();
    error CannotWithdrawCoreToken();
    error NoAssetsToWithdraw();
    error InvalidAddress();
    error BNBWithdrawalFailed();
    error ClaimWindowClosed();
    error AmountExceedsMax();
    error InvalidMerkleRoot();
    error InvalidArrayLengths();
    error InvalidAmount();
    error BatchTooLarge();
    error InvalidClaimWindow();
    error InvalidDistributionId();

    constructor(address _qorafiTokenAddress, address _initialTreasuryAddress) {
        if (_qorafiTokenAddress == address(0)) revert InvalidAddress();
        if (_initialTreasuryAddress == address(0)) revert InvalidAddress();
        
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MERKLE_UPDATER_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        qorafiToken = IQoraFiToken(_qorafiTokenAddress);
        treasuryAddress = _initialTreasuryAddress;
    }

    // --- GOVERNANCE-CONTROLLED FUNCTIONS ---

    /**
     * @notice Allows the DAO to start a new distribution period.
     * @param _merkleRoot The new Merkle root.
     * @param _claimWindowEnd The timestamp when the claim period ends.
     * @param _maxClaimAmount The maximum amount any single claim can be for.
     */
    function startNewDistribution(bytes32 _merkleRoot, uint256 _claimWindowEnd, uint256 _maxClaimAmount) public onlyRole(MERKLE_UPDATER_ROLE) {
        if (_merkleRoot == bytes32(0)) revert InvalidMerkleRoot();
        if (_claimWindowEnd <= block.timestamp) revert InvalidClaimWindow();
        
        latestDistributionId++;
        distributions[latestDistributionId] = Distribution({
            merkleRoot: _merkleRoot,
            claimWindowEnd: _claimWindowEnd,
            maxClaimAmount: _maxClaimAmount
        });

        emit NewDistributionStarted(latestDistributionId, _merkleRoot, _claimWindowEnd, _maxClaimAmount);
    }

    /**
     * @notice Pauses or unpauses the claim functions.
     */
    function setPaused(bool _isPaused) public onlyRole(PAUSER_ROLE) {
        if (_isPaused) {
            _pause();
        } else {
            _unpause();
        }
        emit PausedStateChanged(_isPaused);
    }

    /**
     * @notice Allows the DAO to set the Treasury address for recovering stuck assets.
     */
    function setTreasuryAddress(address _newTreasury) public onlyRole(GOVERNANCE_ROLE) {
        if (_newTreasury == address(0)) revert InvalidAddress();
        treasuryAddress = _newTreasury;
        emit TreasuryAddressUpdated(_newTreasury);
    }

    /**
     * @notice Allows the DAO to withdraw any ERC20 tokens accidentally sent to this contract.
     */
    function withdrawStuckTokens(address _tokenAddress) external onlyRole(GOVERNANCE_ROLE) {
        if (_tokenAddress == address(qorafiToken)) revert CannotWithdrawCoreToken();
        
        IERC20 token = IERC20(_tokenAddress);
        uint256 balance = token.balanceOf(address(this));
        if (balance == 0) revert NoAssetsToWithdraw();

        token.safeTransfer(treasuryAddress, balance);
    }

    /**
     * @notice Allows the DAO to withdraw any BNB accidentally sent to this contract.
     */
    function withdrawStuckBNB() external onlyRole(GOVERNANCE_ROLE) {
        uint256 balance = address(this).balance;
        if (balance == 0) revert NoAssetsToWithdraw();
        (bool success, ) = payable(treasuryAddress).call{value: balance}("");
        if (!success) revert BNBWithdrawalFailed();
    }

    // --- USER-FACING FUNCTIONS ---

    /**
     * @notice Allows a user to claim their rewards by providing a Merkle proof.
     */
    function claim(
        uint256 distributionId,
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) public nonReentrant whenNotPaused {
        _claim(distributionId, index, account, amount, merkleProof);
    }

    /**
     * @notice Allows a user to claim multiple rewards in a single transaction.
     */
    function claimBatch(
        uint256[] calldata distributionIds,
        uint256[] calldata indices,
        address[] calldata accounts,
        uint256[] calldata amounts,
        bytes32[][] calldata merkleProofs
    ) external nonReentrant whenNotPaused {
        uint256 len = indices.length;
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge();
        if (len != accounts.length || len != amounts.length || len != merkleProofs.length || len != distributionIds.length) {
            revert InvalidArrayLengths();
        }

        for (uint256 i = 0; i < len; i++) {
            _claim(distributionIds[i], indices[i], accounts[i], amounts[i], merkleProofs[i]);
        }
    }
    
    // --- INTERNAL LOGIC ---

    function _claim(
        uint256 distributionId,
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) private {
        Distribution storage distribution = distributions[distributionId];
        if (distribution.merkleRoot == bytes32(0)) revert InvalidDistributionId();
        if (amount == 0) revert InvalidAmount();
        if (block.timestamp > distribution.claimWindowEnd) revert ClaimWindowClosed();
        if (amount > distribution.maxClaimAmount) revert AmountExceedsMax();
        if (isClaimed(distributionId, index)) revert AlreadyClaimed();

        bytes32 leaf = keccak256(abi.encodePacked(index, account, amount));

        if (!MerkleProof.verify(merkleProof, distribution.merkleRoot, leaf)) {
            revert InvalidProof();
        }

        _setClaimed(distributionId, index);

        // Update monitoring stats
        totalClaimedAmount += amount;
        if (!hasEverClaimed[account]) {
            hasEverClaimed[account] = true;
            totalUniqueClaimants++;
        }

        qorafiToken.mint(account, amount);
        emit Claimed(distributionId, index, account, amount);
    }
    
    // --- HELPER AND VIEW FUNCTIONS ---

    function isClaimed(uint256 distributionId, uint256 index) public view returns (bool) {
        uint256 bitmapIndex = index / 256;
        uint256 bit = 1 << (index % 256);
        return (claimedBitMaps[distributionId][bitmapIndex] & bit) != 0;
    }
    
    function canClaim(
        uint256 distributionId,
        uint256 index,
        address account,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external view returns (bool, string memory) {
        if (paused()) return (false, "Contract is paused");
        Distribution storage distribution = distributions[distributionId];
        if (distribution.merkleRoot == bytes32(0)) return (false, "Invalid distribution ID");
        if (amount == 0) return (false, "Amount is zero");
        if (block.timestamp > distribution.claimWindowEnd) return (false, "Claim window is closed");
        if (amount > distribution.maxClaimAmount) return (false, "Amount exceeds maximum");
        if (isClaimed(distributionId, index)) return (false, "Already claimed");

        bytes32 leaf = keccak256(abi.encodePacked(index, account, amount));
        if (!MerkleProof.verify(merkleProof, distribution.merkleRoot, leaf)) {
            return (false, "Invalid Merkle proof");
        }

        return (true, "Claim is valid");
    }

    function _setClaimed(uint256 distributionId, uint256 index) private {
        uint256 bitmapIndex = index / 256;
        uint256 bit = 1 << (index % 256);
        claimedBitMaps[distributionId][bitmapIndex] |= bit;
    }

    receive() external payable {}
}
