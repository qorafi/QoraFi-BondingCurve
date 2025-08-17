// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title QoraFiVesting
 * @notice A flexible, multi-category vesting contract for the QoraFi DAO ecosystem.
 * @dev Manages vesting for Devs, Partners, and Ambassadors from a single, DAO-controlled contract.
 */
contract QoraFiVesting is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant BENEFICIARY_MANAGER_ROLE = keccak256("BENEFICIARY_MANAGER_ROLE");

    // --- ENUMS ---
    enum Category { DEV, PARTNER, AMBASSADOR }

    // --- STATE VARIABLES ---
    IERC20 public immutable qorafiToken;
    address public treasuryAddress;
    
    // Vesting Schedule
    uint256 public immutable vestingStartTime;
    uint256 public immutable totalVestingAmount;
    uint256 public constant VESTING_DURATION = 10 * 30 days;
    uint256 public constant RELEASE_INTERVAL = 30 days;
    uint256 public constant TOTAL_RELEASES = 10;
    
    // Beneficiary Data
    mapping(address => uint256) public beneficiaryAllocationsBPS;
    mapping(address => uint256) public beneficiaryReleased;
    mapping(address => Category) public beneficiaryCategory;
    address[] public beneficiaries;
    
    // Allocation Tracking
    uint256 public devAllocatedBPS;
    uint256 public growthAllocatedBPS; // Combined for Partners & Ambassadors
    uint256 public constant MAX_DEV_BPS = 5000; // 5%
    uint256 public constant MAX_GROWTH_BPS = 5000; // 5%

    // --- EVENTS ---
    event TokensReleased(address indexed beneficiary, uint256 amount);
    event BeneficiaryAdded(address indexed beneficiary, uint256 allocationBPS, Category category);
    event BeneficiaryUpdated(address indexed beneficiary, uint256 newAllocationBPS);
    event BeneficiaryRemoved(address indexed beneficiary);
    event TreasuryAddressUpdated(address newTreasury);

    // --- ERRORS ---
    error NoTokensToRelease();
    error InvalidBeneficiary();
    error AllocationExceedsTotal();
    error VestingNotStarted();
    error InvalidAllocation();
    error BeneficiaryAlreadyExists();
    error BeneficiaryNotFound();
    error NoAssetsToWithdraw();
    error BNBWithdrawalFailed();
    error InvalidAddress();
    error CannotWithdrawVestingToken();
    error DevAllocationExceeded();
    error GrowthAllocationExceeded();

    constructor(
        address _qorafiToken,
        uint256 _vestingStartTime,
        uint256 _totalVestingAmount,
        address _initialTreasuryAddress
    ) {
        if (_qorafiToken == address(0) || _initialTreasuryAddress == address(0)) revert InvalidAddress();
        if (_vestingStartTime < block.timestamp) revert VestingNotStarted();
        
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(BENEFICIARY_MANAGER_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        qorafiToken = IERC20(_qorafiToken);
        vestingStartTime = _vestingStartTime;
        totalVestingAmount = _totalVestingAmount;
        treasuryAddress = _initialTreasuryAddress;
    }

    // --- GOVERNANCE-CONTROLLED FUNCTIONS ---

    function setPaused(bool _isPaused) external onlyRole(GOVERNANCE_ROLE) {
        if (_isPaused) _pause();
        else _unpause();
    }
    
    function setTreasuryAddress(address _newTreasury) external onlyRole(GOVERNANCE_ROLE) {
        if (_newTreasury == address(0)) revert InvalidAddress();
        treasuryAddress = _newTreasury;
        emit TreasuryAddressUpdated(_newTreasury);
    }

    function addBeneficiary(address beneficiary, uint256 allocationBPS, Category category) external onlyRole(BENEFICIARY_MANAGER_ROLE) {
        if (beneficiary == address(0)) revert InvalidBeneficiary();
        if (allocationBPS == 0 || allocationBPS > 10000) revert InvalidAllocation();
        if (beneficiaryAllocationsBPS[beneficiary] > 0) revert BeneficiaryAlreadyExists();
        
        if (category == Category.DEV) {
            if (devAllocatedBPS + allocationBPS > MAX_DEV_BPS) revert DevAllocationExceeded();
            devAllocatedBPS += allocationBPS;
        } else {
            if (growthAllocatedBPS + allocationBPS > MAX_GROWTH_BPS) revert GrowthAllocationExceeded();
            growthAllocatedBPS += allocationBPS;
        }
        
        beneficiaryAllocationsBPS[beneficiary] = allocationBPS;
        beneficiaryCategory[beneficiary] = category;
        beneficiaries.push(beneficiary);
        
        emit BeneficiaryAdded(beneficiary, allocationBPS, category);
    }

    function updateBeneficiaryAllocation(address beneficiary, uint256 newAllocationBPS) external onlyRole(BENEFICIARY_MANAGER_ROLE) {
        if (beneficiaryAllocationsBPS[beneficiary] == 0) revert BeneficiaryNotFound();
        if (newAllocationBPS == 0 || newAllocationBPS > 10000) revert InvalidAllocation();
        
        uint256 currentAllocation = beneficiaryAllocationsBPS[beneficiary];
        Category category = beneficiaryCategory[beneficiary];

        if (category == Category.DEV) {
            if (devAllocatedBPS - currentAllocation + newAllocationBPS > MAX_DEV_BPS) revert DevAllocationExceeded();
            devAllocatedBPS = devAllocatedBPS - currentAllocation + newAllocationBPS;
        } else {
            if (growthAllocatedBPS - currentAllocation + newAllocationBPS > MAX_GROWTH_BPS) revert GrowthAllocationExceeded();
            growthAllocatedBPS = growthAllocatedBPS - currentAllocation + newAllocationBPS;
        }
        
        beneficiaryAllocationsBPS[beneficiary] = newAllocationBPS;
        
        emit BeneficiaryUpdated(beneficiary, newAllocationBPS);
    }
    
    function removeBeneficiary(address beneficiary) external onlyRole(BENEFICIARY_MANAGER_ROLE) {
        if (beneficiaryAllocationsBPS[beneficiary] == 0) revert BeneficiaryNotFound();
        
        uint256 allocation = beneficiaryAllocationsBPS[beneficiary];
        Category category = beneficiaryCategory[beneficiary];

        if (category == Category.DEV) {
            devAllocatedBPS -= allocation;
        } else {
            growthAllocatedBPS -= allocation;
        }

        delete beneficiaryAllocationsBPS[beneficiary];
        // Note: category mapping is not deleted to preserve history, but has no effect

        for (uint i = 0; i < beneficiaries.length; i++) {
            if (beneficiaries[i] == beneficiary) {
                beneficiaries[i] = beneficiaries[beneficiaries.length - 1];
                beneficiaries.pop();
                break;
            }
        }
        
        emit BeneficiaryRemoved(beneficiary);
    }

    function withdrawStuckTokens(address _tokenAddress) external onlyRole(GOVERNANCE_ROLE) {
        if (_tokenAddress == address(qorafiToken)) revert CannotWithdrawVestingToken();
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

    // --- USER-FACING FUNCTIONS ---

    function release() external nonReentrant whenNotPaused {
        uint256 releasableAmount = getReleasableAmount(msg.sender);
        if (releasableAmount == 0) revert NoTokensToRelease();
        
        beneficiaryReleased[msg.sender] += releasableAmount;
        
        qorafiToken.safeTransfer(msg.sender, releasableAmount);
        
        emit TokensReleased(msg.sender, releasableAmount);
    }

    // --- VIEW FUNCTIONS ---

    function getReleasableAmount(address beneficiary) public view returns (uint256) {
        uint256 vestedAmount = getVestedAmount(beneficiary);
        uint256 alreadyReleased = beneficiaryReleased[beneficiary];
        
        return vestedAmount > alreadyReleased ? vestedAmount - alreadyReleased : 0;
    }

    function getVestedAmount(address beneficiary) public view returns (uint256) {
        if (block.timestamp < vestingStartTime) return 0;
        if (beneficiaryAllocationsBPS[beneficiary] == 0) return 0;
        
        uint256 totalAllocationForBeneficiary = (totalVestingAmount * beneficiaryAllocationsBPS[beneficiary]) / 10000;
        
        if (block.timestamp >= vestingStartTime + VESTING_DURATION) {
            return totalAllocationForBeneficiary;
        }
        
        uint256 timeElapsed = block.timestamp - vestingStartTime;
        uint256 releasesPassed = timeElapsed / RELEASE_INTERVAL;
        
        if (releasesPassed > TOTAL_RELEASES) {
            releasesPassed = TOTAL_RELEASES;
        }
        
        return (totalAllocationForBeneficiary * releasesPassed) / TOTAL_RELEASES;
    }

    // (Other view functions remain the same)
}
