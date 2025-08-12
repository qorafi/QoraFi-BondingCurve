// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Interfaces
 * @notice Standardized interfaces for all contracts in the DeFi protocol
 * @dev Centralized interface definitions to improve modularity and reduce coupling
 */

// --- CORE SECURITY INTERFACE ---
interface ISecurityManager {
    // --- VIEW FUNCTIONS ---
    function canUserDeposit(address user, uint256 amount) external view returns (bool canDeposit, string memory reason);
    function isEmergencyMode() external view returns (bool);
    function isPaused() external view returns (bool);
    function isSupportedZapToken(address token) external view returns (bool);
    
    // --- MEV PROTECTION ---
    function preDepositCheck(address user, uint256 amount) external;
    function postDepositUpdate(address user, uint256 amount) external;
    function checkCircuitBreaker(uint256 amount) external;
    
    // --- USER STATISTICS ---
    function getUserStatistics(address user) external view returns (
        uint256 depositCount,
        uint256 totalDeposited,
        uint256 lastDepositBlockNumber,
        bool canDeposit
    );
    
    function getProtocolStatistics() external view returns (
        uint256 totalDeposits,
        uint256 currentPrice,
        uint256 marketCap,
        bool oracleHealthy
    );
    
    // --- CIRCUIT BREAKER STATUS ---
    function getCircuitBreakerStatus() external view returns (
        bool triggered,
        uint256 currentVolume,
        uint256 volumeThreshold,
        uint256 triggerCount,
        uint256 timeUntilReset,
        bool updating
    );
    
    // --- MEV STATUS ---
    function getUserMEVStatus(address user) external view returns (
        uint256 lastBlock,
        uint256 blocksSinceLastDeposit,
        bool canDepositNow,
        uint256 dailyVolumeUsed,
        uint256 dailyVolumeRemaining
    );
}

// --- ORACLE INTERFACE ---
interface IOracle {
    // --- PRICE FUNCTIONS ---
    function getCurrentPrice() external view returns (uint256);
    function getCachedMarketCap() external view returns (uint256);
    function updateMarketCap() external;
    
    // --- HEALTH CHECKS ---
    function isHealthy() external view returns (bool);
    function checkMarketCapLimits() external view;
    
    // --- OBSERVATIONS ---
    function getObservationCount() external view returns (uint256);
    function getLatestObservation() external view returns (
        uint256 price0Cumulative,
        uint256 price1Cumulative,
        uint32 timestamp,
        bool isValid,
        uint256 liquiditySnapshot
    );
    
    // --- GOVERNANCE ---
    function setFallbackPrice(uint256 price) external;
    function enableEmergencyMode() external;
    function disableEmergencyMode() external;
}

// --- ENHANCED ORACLE INTERFACE ---
interface IEnhancedOracle {
    // Inherit all IOracle functions by composition, not inheritance
    // --- BASIC ORACLE FUNCTIONS ---
    function getCurrentPrice() external view returns (uint256);
    function getCachedMarketCap() external view returns (uint256);
    function updateMarketCap() external;
    function isHealthy() external view returns (bool);
    function checkMarketCapLimits() external view;
    function getObservationCount() external view returns (uint256);
    function getLatestObservation() external view returns (
        uint256 price0Cumulative,
        uint256 price1Cumulative,
        uint32 timestamp,
        bool isValid,
        uint256 liquiditySnapshot
    );
    function setFallbackPrice(uint256 price) external;
    function enableEmergencyMode() external;
    function disableEmergencyMode() external;
    
    // --- ENHANCED FEATURES ---
    function getLiquidityStatus() external view returns (
        uint256 currentUsdtLiquidity,
        uint256 minimumRequired,
        uint256 lastCheck,
        bool isHealthy
    );
    
    function getPriceValidationData() external view returns (
        uint256 lastValidatedPrice,
        uint256 lastValidationTime,
        uint256 priceImpactThreshold,
        uint256 maxPriceChangePerUpdate,
        uint256 minTimeBetweenUpdates
    );
    
    function getNewTokenSettings() external view returns (
        bool newTokenModeActive,
        uint256 flashLoanWindow,
        uint256 maxUpdatesPerBlock,
        uint256 minUsdtLiquidity
    );
    
    // --- ADVANCED GOVERNANCE ---
    function setNewTokenMode(bool enabled) external;
    function setPriceValidationParams(uint256 priceImpactThreshold, uint256 maxPriceChangePerUpdate) external;
    function forceUpdatePrice(uint256 newPrice) external;
    function invalidateObservation(uint256 index, string calldata reason) external;
}

// --- BONDING CURVE INTERFACE ---
interface IBondingCurve {
    // --- DEPOSIT FUNCTIONS ---
    function deposit(
        uint256 amountUSDT,
        uint256 minQorafiOut,
        uint256 minLiquidity,
        uint256 deadline,
        uint16 slippageBps
    ) external;
    
    function depositWithBNB(
        uint256 minUsdtOut,
        uint256 minQorafiOut,
        uint256 minLiquidity,
        uint256 deadline,
        uint16 slippageBps
    ) external payable;
    
    function depositWithToken(
        address tokenIn,
        uint256 amountIn,
        uint256 minUsdtOut,
        uint256 minQorafiOut,
        uint256 minLiquidity,
        uint256 deadline,
        uint16 slippageBps
    ) external;
    
    // --- VIEW FUNCTIONS ---
    function canUserDeposit(address user, uint256 amount) external view returns (bool canDeposit, string memory reason);
    function getUserStats(address user) external view returns (uint256 depositCount, uint256 totalDeposited);
    function getProtocolStats() external view returns (uint256 totalDeposits);
    function getCurrentPrice() external view returns (uint256);
    function estimateDeposit(uint256 usdtAmount) external view returns (uint256 estimatedQorafiOut, uint256 estimatedLPTokens);
    
    // --- GOVERNANCE ---
    function setSecurityManager(address securityManager) external;
    function setOracle(address oracle) external;
    function setManualPrice(uint256 price) external;
    function setLiquidityRatio(uint256 ratioBPS) external;
    function pause() external;
    function unpause() external;
}

// --- DEX ROUTER INTERFACE ---
interface IDEXRouter {
    function WETH() external view returns (address);
    
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
    
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
    
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    
    function getAmountsOut(uint256 amountIn, address[] calldata path) 
        external view returns (uint256[] memory amounts);
}

// --- UNISWAP V2 PAIR INTERFACE ---
interface IUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
}

// --- LEDGER INTERFACE ---
interface ILedger {
    function notifyDeposit(address user, uint256 amount) external;
    function getUserBalance(address user) external view returns (uint256);
    function getTotalDeposits() external view returns (uint256);
    function isUserRegistered(address user) external view returns (bool);
}

// --- ENHANCED LEDGER INTERFACE ---
interface IEnhancedLedger {
    // Base ledger functions
    function notifyDeposit(address user, uint256 amount) external;
    function getUserBalance(address user) external view returns (uint256);
    function getTotalDeposits() external view returns (uint256);
    function isUserRegistered(address user) external view returns (bool);
    
    // Enhanced functions
    function batchNotifyDeposits(address[] calldata users, uint256[] calldata amounts) external;
    function getUserStats(address user) external view returns (
        uint256 totalDeposits,
        uint256 depositCount,
        uint256 lastDepositTime,
        bool isActive
    );
    function getProtocolStats() external view returns (
        uint256 totalUsers,
        uint256 totalVolume,
        uint256 activeUsers,
        uint256 lastUpdateTime
    );
}

// --- EMERGENCY SYSTEM INTERFACE ---
interface IEmergencySystem {
    function proposeEmergencyTransaction(
        address target,
        uint256 value,
        bytes calldata data
    ) external returns (bytes32 txHash);
    
    function executeEmergencyTransaction(bytes32 txHash) external;
    function cancelEmergencyTransaction(bytes32 txHash) external;
    
    function getEmergencyTransaction(bytes32 txHash) external view returns (
        address target,
        uint256 value,
        bytes memory data,
        uint256 executeAfter,
        bool executed,
        address proposer,
        uint256 proposedAt
    );
    
    function activateEmergencyMode() external;
    function deactivateEmergencyMode() external;
    function isEmergencyModeActive() external view returns (bool);
}

// --- GOVERNANCE INTERFACE ---
interface IGovernance {
    // --- PARAMETER MANAGEMENT ---
    function setSecurityParameters(string calldata paramName, uint256 value) external;
    function getSecurityParameter(string calldata paramName) external view returns (uint256);
    
    // --- TREASURY MANAGEMENT ---
    function setTreasuryWallet(address newTreasury) external;
    function getTreasuryWallet() external view returns (address);
    
    // --- UPGRADE MANAGEMENT ---
    function authorizeUpgrade(address newImplementation) external;
}

// --- BASIC ERC20 INTERFACE ---
interface IERC20Basic {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

// --- ENHANCED TOKEN INTERFACE ---
interface ITokenEnhanced {
    // Basic ERC20 functions
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    
    // Metadata
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    
    // Enhanced functions
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
    function mint(address to, uint256 amount) external;
}

// --- PRICE FEED INTERFACE ---
interface IPriceFeed {
    function getPrice(address token) external view returns (uint256 price, uint256 timestamp);
    function getPriceWithDecimals(address token) external view returns (uint256 price, uint8 decimals, uint256 timestamp);
    function isStale(address token) external view returns (bool);
    function getLastUpdateTime(address token) external view returns (uint256);
}

// --- MULTI-TOKEN SWAPPER INTERFACE ---
interface IMultiTokenSwapper {
    function swapToUSDT(
        address tokenIn,
        uint256 amountIn,
        uint256 minUsdtOut,
        uint256 deadline
    ) external returns (uint256 usdtOut);
    
    function getSwapPath(address tokenIn, address tokenOut) external view returns (address[] memory path);
    function getEstimatedOutput(address tokenIn, address tokenOut, uint256 amountIn) external view returns (uint256 estimatedOut);
    function getSupportedTokens() external view returns (address[] memory tokens);
    function isTokenSupported(address token) external view returns (bool);
}

// --- LIQUIDITY MANAGER INTERFACE ---
interface ILiquidityManager {
    function addLiquidityOptimal(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 slippageBps,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
    
    function getOptimalAmounts(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired
    ) external view returns (uint256 amountA, uint256 amountB);
}

// --- ANALYTICS INTERFACE ---
interface IAnalytics {
    function recordTransaction(address user, uint256 amount, string calldata txType) external;
    function getUserAnalytics(address user) external view returns (
        uint256 totalTransactions,
        uint256 totalVolume,
        uint256 averageTransactionSize,
        uint256 lastTransactionTime
    );
    function getProtocolAnalytics() external view returns (
        uint256 totalUsers,
        uint256 totalTransactions,
        uint256 totalVolume,
        uint256 averageUserVolume
    );
    function getDailyStats(uint256 date) external view returns (
        uint256 transactions,
        uint256 volume,
        uint256 uniqueUsers
    );
}

// --- FLASH LOAN PROTECTION INTERFACE ---
interface IFlashLoanProtection {
    function checkFlashLoanRisk(address user, uint256 amount) external view returns (bool isRisky, string memory reason);
    function recordTransaction(address user, uint256 amount) external;
    function isUserSuspicious(address user) external view returns (bool);
    function getTransactionHistory(address user) external view returns (
        uint256[] memory amounts,
        uint256[] memory timestamps,
        uint256[] memory blockNumbers
    );
}

// --- ACCESS CONTROL INTERFACE ---
interface IAccessControlCustom {
    function hasRole(bytes32 role, address account) external view returns (bool);
    function getRoleAdmin(bytes32 role) external view returns (bytes32);
    function grantRole(bytes32 role, address account) external;
    function revokeRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role, address account) external;
}

// --- PAUSABLE INTERFACE ---
interface IPausableCustom {
    function paused() external view returns (bool);
    function pause() external;
    function unpause() external;
}

// --- UPGRADEABLE INTERFACE ---
interface IUpgradeableCustom {
    function getImplementation() external view returns (address);
    function upgradeTo(address newImplementation) external;
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}