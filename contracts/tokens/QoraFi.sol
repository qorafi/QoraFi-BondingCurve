// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/**
 * @title QoraFi
 * @dev The final QoraFi token with decentralized governance, daily minting limits, and a multi-destination fee system.
 * @notice The security of this contract relies on the Timelock contract.
 */
contract QoraFi is ERC20Votes, ERC20Burnable, AccessControl, Pausable, ReentrancyGuard {
 using SafeERC20 for IERC20;

 // --- ROLES ---
 bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

 // --- CONSTANTS ---
 uint256 public immutable MAX_SUPPLY = 1_000_000 * (10**18);
 uint256 public constant MAX_BPS = 10_000;
 uint256 public constant MAX_TOTAL_MINTING_FEE_BPS = 500; // Max TOTAL fee is 5%
 uint256 public constant MAX_INDIVIDUAL_FEE_BPS = 300; // Max individual fee is 3%
 uint256 public constant MAX_DAILY_MINT_LIMIT_BPS = 100; // Max daily limit is 1% of total supply

 // --- STATE VARIABLES ---
 uint256 public dailyMintLimit;
 mapping(uint256 => uint256) public dailyMinted;

 address public usqEngineAddress;
 address public developmentWalletAddress;
 address public airdropContractAddress;
 address public treasuryAddress;

 uint256 public usqEngineFeeBPS;
 uint256 public developmentFeeBPS;
 uint256 public airdropFeeBPS;

 bool private initialMintingExecuted;

 // --- ERRORS ---
 error MaxSupplyExceeded();
 error InvalidAddress();
 error FeeExceedsMaxLimit();
 error IndividualFeeExceedsMaxLimit();
 error NoAssetsToWithdraw();
 error CannotWithdrawSelf();
 error BNBWithdrawalFailed();
 error DailyMintLimitExceeded();
 error MinterMustBeContract();
 error DailyMintLimitTooHigh();
 error AmountMustBeGreaterThanZero();
 error InvalidArrayLengths();
 error InitialMintingAlreadyExecuted();
 error FeeDestinationsNotSet();

 // --- EVENTS ---
 event MintingFeePaid(address indexed destination, uint256 amount);
 event FeeSplitsUpdated(uint256 usqEngineBPS, uint256 developmentBPS, uint256 airdropBPS);
 event FeeDestinationsUpdated(address usqEngine, address developmentWallet, address airdropContract);
 event TreasuryAddressUpdated(address newTreasury);
 event DailyMintLimitUpdated(uint256 newLimit);
 event InitialMintingExecuted(address indexed deployer, address indexed vestingContract, uint256 deployerAmount, uint256 vestingAmount);

 constructor(
 string memory name_,
 string memory symbol_,
 address _initialTreasuryAddress
 )
 ERC20(name_, symbol_)
 ERC20Votes()
 EIP712(name_, "1")
 {
 require(_initialTreasuryAddress != address(0), "Invalid treasury address");

 _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

 treasuryAddress = _initialTreasuryAddress;
 dailyMintLimit = (MAX_SUPPLY * 250) / MAX_BPS; // 0.25% of total supply
 }

    /**
     * @notice Executes the one-time initial minting for tokenomics distribution.
     * @dev This function can only be called once by the contract deployer (admin).
     * @param _vestingContract The address of the deployed vesting contract.
     */
 function executeInitialMinting(address _vestingContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
 if (initialMintingExecuted) revert InitialMintingAlreadyExecuted();
 if (_vestingContract == address(0)) revert InvalidAddress();

 initialMintingExecuted = true;

 uint256 deployerPremintAmount = MAX_SUPPLY / 10; // 10% to deployer for LP
 uint256 teamAndGrowthAllocation = MAX_SUPPLY / 10; // 10% for Team, Partners & Ambassadors

 _mint(msg.sender, deployerPremintAmount);
 _mint(_vestingContract, teamAndGrowthAllocation);

 emit InitialMintingExecuted(msg.sender, _vestingContract, deployerPremintAmount, teamAndGrowthAllocation);
 }

 // --- GOVERNANCE-CONTROLLED FUNCTIONS ---

    /** @notice Pauses or unpauses the contract. Can only be called by the admin. */
 function setPaused(bool _paused) public onlyRole(DEFAULT_ADMIN_ROLE) {
 if (_paused) _pause();
 else _unpause();
 }

    /** @notice Grants the MINTER_ROLE to a contract address. */
 function grantMinterRole(address minter) public onlyRole(DEFAULT_ADMIN_ROLE) {
 if (minter.code.length == 0) revert MinterMustBeContract();
 _grantRole(MINTER_ROLE, minter);
 }

    /** @notice Sets the fee percentages for minting operations. */
 function setFeeSplits(uint256 _usqEngineBPS, uint256 _developmentBPS, uint256 _airdropBPS) public onlyRole(DEFAULT_ADMIN_ROLE) {
 uint256 totalFee = _usqEngineBPS + _developmentBPS + _airdropBPS;
 if (totalFee > MAX_TOTAL_MINTING_FEE_BPS) revert FeeExceedsMaxLimit();
 if (_usqEngineBPS > MAX_INDIVIDUAL_FEE_BPS || _developmentBPS > MAX_INDIVIDUAL_FEE_BPS || _airdropBPS > MAX_INDIVIDUAL_FEE_BPS) {
 revert IndividualFeeExceedsMaxLimit();
 }
 usqEngineFeeBPS = _usqEngineBPS;
 developmentFeeBPS = _developmentBPS;
 airdropFeeBPS = _airdropBPS;
 emit FeeSplitsUpdated(_usqEngineBPS, _developmentBPS, _airdropBPS);
 }

    /** @notice Sets the destination addresses for minting fees. */
 function setFeeDestinations(address _usqEngine, address _developmentWallet, address _airdropContract) public onlyRole(DEFAULT_ADMIN_ROLE) {
 if (_usqEngine == address(0) || _developmentWallet == address(0) || _airdropContract == address(0)) revert InvalidAddress();
 usqEngineAddress = _usqEngine;
 developmentWalletAddress = _developmentWallet;
 airdropContractAddress = _airdropContract;
 emit FeeDestinationsUpdated(_usqEngine, _developmentWallet, _airdropContract);
 }

    /** @notice Sets the daily minting limit for the protocol. */
 function setDailyMintLimit(uint256 _newLimit) public onlyRole(DEFAULT_ADMIN_ROLE) {
 if (_newLimit > (MAX_SUPPLY * MAX_DAILY_MINT_LIMIT_BPS) / MAX_BPS) revert DailyMintLimitTooHigh();
 dailyMintLimit = _newLimit;
 emit DailyMintLimitUpdated(_newLimit);
 }

    /** @notice Updates the treasury address for recovering stuck assets. */
 function setTreasuryAddress(address _newTreasury) public onlyRole(DEFAULT_ADMIN_ROLE) {
 if (_newTreasury == address(0)) revert InvalidAddress();
 treasuryAddress = _newTreasury;
 emit TreasuryAddressUpdated(_newTreasury);
 }

    /** @notice Recovers any ERC20 tokens accidentally sent to this contract. */
 function withdrawStuckTokens(address _tokenAddress) public onlyRole(DEFAULT_ADMIN_ROLE) {
 if (_tokenAddress == address(this)) revert CannotWithdrawSelf();
 IERC20 token = IERC20(_tokenAddress);
 uint256 balance = token.balanceOf(address(this));
 if (balance == 0) revert NoAssetsToWithdraw();
 token.safeTransfer(treasuryAddress, balance);
 }

    /** @notice Recovers any BNB accidentally sent to this contract. */
 function withdrawStuckBNB() public onlyRole(DEFAULT_ADMIN_ROLE) {
 uint256 balance = address(this).balance;
 if (balance == 0) revert NoAssetsToWithdraw();
 (bool success, ) = payable(treasuryAddress).call{value: balance}("");
 if (!success) revert BNBWithdrawalFailed();
 }

 // --- CORE FUNCTIONS ---

    /** @notice Mints new tokens to a specified address, applying protocol fees. */
 function mint(address to, uint256 amount) public virtual onlyRole(MINTER_ROLE) whenNotPaused nonReentrant {
 if (to == address(0)) revert InvalidAddress();
 if (amount == 0) revert AmountMustBeGreaterThanZero();

 _mintWithFees(amount);
 _mint(to, amount);
 }

    /** @notice Mints new tokens to multiple recipients in a single transaction. */
 function mintBatch(address[] calldata recipients, uint256[] calldata amounts) public onlyRole(MINTER_ROLE) whenNotPaused nonReentrant {
 if (recipients.length != amounts.length) revert InvalidArrayLengths();
 if (recipients.length == 0) revert AmountMustBeGreaterThanZero();

 uint256 totalBaseAmount = 0;
 for (uint256 i = 0; i < amounts.length; i++) {
 if (recipients[i] == address(0)) revert InvalidAddress();
 if (amounts[i] == 0) revert AmountMustBeGreaterThanZero();
 totalBaseAmount += amounts[i];
 }

 _mintWithFees(totalBaseAmount);

 for (uint256 i = 0; i < recipients.length; i++) {
 _mint(recipients[i], amounts[i]);
 }
 }

 /**
     * @dev Internal helper to handle shared logic for fee calculation and minting checks.
     */
 function _mintWithFees(uint256 baseAmount) private {
        if (usqEngineAddress == address(0) || developmentWalletAddress == address(0) || airdropContractAddress == address(0)) {
            revert FeeDestinationsNotSet();
        }

 uint256 usqFee = (baseAmount * usqEngineFeeBPS) / MAX_BPS;
 uint256 devFee = (baseAmount * developmentFeeBPS) / MAX_BPS;
 uint256 airdropFee = (baseAmount * airdropFeeBPS) / MAX_BPS;
 uint256 totalFee = usqFee + devFee + airdropFee;
 uint256 totalAmountToMint = baseAmount + totalFee;

 uint256 day = block.timestamp / 1 days;
 if (dailyMinted[day] + totalAmountToMint > dailyMintLimit) {
 revert DailyMintLimitExceeded();
 }
 dailyMinted[day] += totalAmountToMint;

 if (totalSupply() + totalAmountToMint > MAX_SUPPLY) revert MaxSupplyExceeded();

 if (usqFee > 0) {
 _mint(usqEngineAddress, usqFee);
 emit MintingFeePaid(usqEngineAddress, usqFee);
 }
 if (devFee > 0) {
 _mint(developmentWalletAddress, devFee);
 emit MintingFeePaid(developmentWalletAddress, devFee);
 }
 if (airdropFee > 0) {
 _mint(airdropContractAddress, airdropFee);
 emit MintingFeePaid(airdropContractAddress, airdropFee);
 }
 }

 // --- VIEW FUNCTIONS ---
    /** @notice Gets the remaining amount of tokens that can be minted today. */
 function getRemainingDailyMint() public view returns (uint256) {
 uint256 day = block.timestamp / 1 days;
 uint256 todayMinted = dailyMinted[day];
 return todayMinted >= dailyMintLimit ? 0 : dailyMintLimit - todayMinted;
 }

    /** @notice Gets the total fee percentage in basis points. */
 function getTotalFees() public view returns (uint256) {
 return usqEngineFeeBPS + developmentFeeBPS + airdropFeeBPS;
 }

    /** @notice Gets the current day's identifier (timestamp / 1 days). */
 function getCurrentDay() public view returns (uint256) {
 return block.timestamp / 1 days;
 }

    /** @notice Gets the total amount minted for a specific day. */
 function getDailyMinted(uint256 day) public view returns (uint256) {
 return dailyMinted[day];
 }

    /** @notice Gets the total amount minted for the current day. */
 function getTodaysMinted() public view returns (uint256) {
 return dailyMinted[getCurrentDay()];
 }

 // --- REQUIRED OVERRIDES for ERC20Votes & Pausable ---
 function _update(address from, address to, uint256 value)
 internal
 override(ERC20, ERC20Votes)
 whenNotPaused
 {
 super._update(from, to, value);
 }

 /**
     * @notice Allows the contract to receive native currency (e.g., BNB) so it can be recovered by governance.
     */
 receive() external payable {}
}
