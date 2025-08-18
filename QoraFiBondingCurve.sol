// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

// Import individual library files - UPDATED IMPORTS
import {MEVLib, ValidationLib} from "../libraries/MEVProtection.sol";
import "../libraries/CircuitBreaker.sol";
import "../libraries/EmergencySystem.sol";
import "../libraries/SwapUtilities.sol";
import "../libraries/TokenUtilities.sol";
import "../libraries/MathUtilities.sol";
import "../libraries/StatisticsCore.sol";
import "../libraries/AnalyticsEngine.sol";
import {
    ISecurityManager,
    IBondingCurve,
    IBondingOracle,
    IEnhancedLedger
} from "../interfaces/SecurityInterfaces.sol";

interface IUniswapRouter {
    function WETH() external pure returns (address);
}

/**
 * @title QoraFiBondingCurve
 * @notice Modular bonding curve using the new library architecture - NON-PROXY VERSION
 */
contract QoraFiBondingCurve is
    AccessControl,
    ReentrancyGuard,
    Pausable,
    IBondingCurve
{
    using SafeERC20 for IERC20;

    // --- ROLES ---
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    // --- STATE ---
    IERC20 public immutable usdtToken;
    IERC20 public immutable qorafiToken;
    IUniswapRouter public immutable router;
    
    ISecurityManager public securityManager;
    IBondingOracle public oracle;
    IEnhancedLedger public ledger;
    
    uint256 public liquidityRatioBPS;
    uint256 public maxSlippageBPS;
    
    mapping(address => StatisticsLib.UserStats) private userStats;
    StatisticsLib.ProtocolStats public protocolStats;
    // Token management for multi-chain support
    enum TokenType {
        NATIVE_WRAPPED,    // WBNB, WETH, etc. (goes direct to USDT)
        STABLECOIN,        // USDC, DAI (direct to USDT)  
        OTHER_TOKEN        // Everything else (via native token)
    }
    
    mapping(address => bool) public supportedZapTokens;     // All supported tokens
    mapping(address => bool) public hasDirectPairToUSDT;    // Direct USDT pairs (USDC, DAI)
    mapping(address => TokenType) public tokenTypes;        // Token classification
    
    // Chain-specific configuration
    address public nativeWrappedToken;  // WBNB on BSC, WETH on Base, etc.

    // Security state
    using MEVLib for MEVLib.MEVConfig;
    MEVLib.MEVConfig private mevProtection;
    mapping(address => uint256) private userNonceMapping;
    uint256 private constant MAX_SLIPPAGE_BPS = 1000;
    uint256 private constant MIN_DEPOSIT_AMOUNT = 1e18;
    uint256 private constant MAX_DEPOSIT_AMOUNT = 10000 * 1e18;
    
    bool public emergencyStop;
    uint256 public totalDailyVolume;
    uint256 public dailyVolumeLimit;
    uint256 public lastVolumeResetDay;

    // --- EVENTS ---
    event DepositProcessed(address indexed user, uint256 usdtValue, uint256 qorafiAcquired, uint256 lpTokensReceived);
    event ZapTokenAdded(address indexed token, TokenType tokenType, bool hasDirectPair);
    event ZapTokenRemoved(address indexed token);
    event TokenTypeUpdated(address indexed token, TokenType oldType, TokenType newType);
    event DirectPairUpdated(address indexed token, bool hasDirectPair);
    event NativeWrappedTokenSet(address indexed token);
    event LedgerNotificationFailed(address indexed user, uint256 amount, string reason);
    event SecurityManagerUpdated(address indexed oldManager, address indexed newManager);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event LedgerUpdated(address indexed oldLedger, address indexed newLedger);
    event EmergencyStopActivated(address indexed activator, string reason);
    event VolumeExceeded(uint256 attemptedVolume, uint256 limit);
    event SecurityValidationFailed(address indexed user, string reason);

    // --- ERRORS ---
    error InvalidAmount();
    error SecurityCheckFailed(string reason);
    error SwapFailed();
    error LiquidityFailed();
    error EmergencyStopActive();
    error DailyVolumeExceeded();
    error InvalidSlippageParameter();
    error DepositAmountOutOfBounds();
    error OracleValidationFailed();

    constructor(
        address _usdtToken,
        address _qorafiToken,
        address _router,
        address _securityManager,
        address _oracle,
        address _ledger,
        address _admin
    ) {
        ValidationLib.validateAddress(_usdtToken);
        ValidationLib.validateAddress(_qorafiToken);
        ValidationLib.validateAddress(_router);
        ValidationLib.validateAddress(_securityManager);
        ValidationLib.validateAddress(_admin);

        usdtToken = IERC20(_usdtToken);
        qorafiToken = IERC20(_qorafiToken);
        router = IUniswapRouter(_router);
        
        securityManager = ISecurityManager(_securityManager);
        oracle = IBondingOracle(_oracle);
        ledger = IEnhancedLedger(_ledger);
        
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        
        liquidityRatioBPS = 5000;
        maxSlippageBPS = 300;
        dailyVolumeLimit = 1000000 * 1e18;
        lastVolumeResetDay = block.timestamp / 86400;
        
        // Initialize MEV protection
        mevProtection.minDepositInterval = 2; // 2 blocks minimum
        mevProtection.maxDepositPerBlock = 100000 * 1e18; // $100k per block
        mevProtection.maxDepositPerUser = 50000 * 1e18; // $50k per user per day
        
        // Initialize chain-specific tokens
        _initializeChainSpecificTokens();
    }

    // Helper function to safely call securityManager from view function
    function getSecurityManagerCanDeposit(address user, uint256 amount) external view returns (bool, string memory) {
        return securityManager.canUserDeposit(user, amount);
    }
    
    // --- CHAIN-SPECIFIC INITIALIZATION ---
    function _initializeChainSpecificTokens() internal {
        uint256 chainId = block.chainid;
        
        require(chainId == 56 || chainId == 97, "Only BSC Mainnet and Testnet supported");
        
        if (chainId == 56) {          // BSC Mainnet
            nativeWrappedToken = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // WBNB
            _addChainToken(0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d, TokenType.STABLECOIN, true);  // USDC
            _addChainToken(0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3, TokenType.STABLECOIN, true);  // DAI
        } else if (chainId == 97) {   // BSC Testnet  
            nativeWrappedToken = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd; // WBNB
        }
        
        // Set native token configuration
        tokenTypes[nativeWrappedToken] = TokenType.NATIVE_WRAPPED;
        supportedZapTokens[nativeWrappedToken] = true;
        hasDirectPairToUSDT[nativeWrappedToken] = true;
        emit NativeWrappedTokenSet(nativeWrappedToken);
    }

    function _addChainToken(address token, TokenType tokenType, bool hasDirectPair) internal {
        supportedZapTokens[token] = true;
        tokenTypes[token] = tokenType;
        hasDirectPairToUSDT[token] = hasDirectPair;
        emit ZapTokenAdded(token, tokenType, hasDirectPair);
    }

    modifier enhancedMEVProtection(uint256 amount) {
        mevProtection.checkPreDeposit(msg.sender, amount);
        _;
        mevProtection.updatePostDeposit(msg.sender, amount);
    }

    modifier notInEmergencyStop() {
        if (emergencyStop) {
            revert EmergencyStopActive();
        }
        _;
    }

    // --- CORE DEPOSIT FUNCTIONS ---
    /**
     * @notice Deposit USDT to acquire QoraFi tokens and LP tokens via bonding curve
     * @param amountUSDT Amount of USDT to deposit
     * @param minQorafiOut Minimum QoraFi tokens to receive (slippage protection)
     * @param deadline Transaction deadline timestamp
     * @param slippageBps Slippage tolerance in basis points (100 = 1%)
     */
    function deposit(
        uint256 amountUSDT,
        uint256 minQorafiOut,
        uint256, // minLiquidity - unused
        uint256 deadline,
        uint16 slippageBps
    ) external override
        nonReentrant
        whenNotPaused
        enhancedMEVProtection(amountUSDT)
        notInEmergencyStop
    {
        _validateDepositParameters(amountUSDT, deadline, slippageBps);
        _checkDailyVolumeLimit(amountUSDT);
        _performSecurityChecks(msg.sender, amountUSDT);
        
        _updateDailyVolume(amountUSDT);
        userNonceMapping[msg.sender]++;
        
        usdtToken.safeTransferFrom(msg.sender, address(this), amountUSDT);
        _processDeposit(amountUSDT, minQorafiOut, deadline, slippageBps);
        _updateStatistics(msg.sender, amountUSDT);
    }

    /**
     * @notice Deposit BNB to acquire QoraFi tokens and LP tokens (BNB → USDT → QoraFi)
     * @param minUsdtOut Minimum USDT to receive from BNB swap
     * @param minQorafiOut Minimum QoraFi tokens to receive
     * @param deadline Transaction deadline timestamp
     * @param slippageBps Slippage tolerance in basis points
     */
    function depositWithBNB(
        uint256 minUsdtOut,
        uint256 minQorafiOut,
        uint256, // minLiquidity - unused
        uint256 deadline,
        uint16 slippageBps
    ) external payable override
        nonReentrant
        whenNotPaused
        enhancedMEVProtection(msg.value)
        notInEmergencyStop
    {
        require(msg.value > 0, "No BNB sent");
        _validateDepositParameters(0, deadline, slippageBps);
        userNonceMapping[msg.sender]++;
        
        // Swap BNB to USDT
        uint256 usdtReceived = SwapLib.executeETHToTokenSwap(
            address(router),
            address(usdtToken),
            msg.value,
            minUsdtOut,
            deadline
        );
        require(usdtReceived > 0, "Swap failed");
        
        _validateDepositAmount(usdtReceived);
        _checkDailyVolumeLimit(usdtReceived);
        _performSecurityChecks(msg.sender, usdtReceived);
        _updateDailyVolume(usdtReceived);
        
        _processDeposit(usdtReceived, minQorafiOut, deadline, slippageBps);
        _updateStatistics(msg.sender, usdtReceived);
    }

    /**
     * @notice Deposit any supported token to acquire QoraFi tokens and LP tokens
     * @param tokenIn Input token address (must be supported)
     * @param amountIn Amount of input token
     * @param minUsdtOut Minimum USDT to receive from token swap
     * @param minQorafiOut Minimum QoraFi tokens to receive
     * @param deadline Transaction deadline timestamp
     * @param slippageBps Slippage tolerance in basis points
     */
    function depositWithToken(
        address tokenIn,
        uint256 amountIn,
        uint256 minUsdtOut,
        uint256 minQorafiOut,
        uint256, // minLiquidity - unused
        uint256 deadline,
        uint16 slippageBps
    ) external override
        nonReentrant
        whenNotPaused
        enhancedMEVProtection(amountIn)
        notInEmergencyStop
    {
        require(supportedZapTokens[tokenIn], "Token not supported");
        require(amountIn > 0, "Invalid amount");
        _validateDepositParameters(0, deadline, slippageBps);

        userNonceMapping[msg.sender]++;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        
        // Swap token to USDT based on token type
        uint256 usdtReceived;
        TokenType tokenType = tokenTypes[tokenIn];
        
        if (tokenType == TokenType.NATIVE_WRAPPED || hasDirectPairToUSDT[tokenIn]) {
            // Direct swap to USDT for native wrapped tokens or tokens with direct pairs
            usdtReceived = SwapLib.executeSwap(
                address(router), 
                tokenIn, 
                address(usdtToken), 
                amountIn, 
                minUsdtOut, 
                deadline
            );
        } else {
            // Multi-hop swap via native token for other tokens
            usdtReceived = SwapLib.executeMultiHopSwap(
                address(router), 
                tokenIn, 
                address(usdtToken), 
                amountIn, 
                minUsdtOut, 
                deadline
            );
        }
        require(usdtReceived > 0, "Swap failed");
        
        _validateDepositAmount(usdtReceived);
        _checkDailyVolumeLimit(usdtReceived);
        _performSecurityChecks(msg.sender, usdtReceived);
        _updateDailyVolume(usdtReceived);
        
        _processDeposit(usdtReceived, minQorafiOut, deadline, slippageBps);
        _updateStatistics(msg.sender, usdtReceived);
    }

    // --- INTERNAL FUNCTIONS ---
    function _validateDepositParameters(uint256 amount, uint256 deadline, uint16 slippageBps) internal view {
        if (amount > 0) {
            _validateDepositAmount(amount);
        }
        require(deadline > block.timestamp, "Deadline passed");
        require(deadline <= block.timestamp + 1 hours, "Deadline too far");
        
        if (slippageBps > MAX_SLIPPAGE_BPS) {
            revert InvalidSlippageParameter();
        }
    }

    function _validateDepositAmount(uint256 amount) internal pure {
        if (amount < MIN_DEPOSIT_AMOUNT || amount > MAX_DEPOSIT_AMOUNT) {
            revert DepositAmountOutOfBounds();
        }
    }

    function _checkDailyVolumeLimit(uint256 amount) internal {
        uint256 currentDay = block.timestamp / 86400;
        uint256 currentDayVolume = (currentDay == lastVolumeResetDay) ? totalDailyVolume : 0;
        
        if (currentDayVolume + amount > dailyVolumeLimit) {
            emit VolumeExceeded(currentDayVolume + amount, dailyVolumeLimit);
            revert DailyVolumeExceeded();
        }
    }

    function _updateDailyVolume(uint256 amount) internal {
        uint256 currentDay = block.timestamp / 86400;
        
        if (currentDay != lastVolumeResetDay) {
            totalDailyVolume = amount;
            lastVolumeResetDay = currentDay;
        } else {
            totalDailyVolume += amount;
        }
    }

    function _performSecurityChecks(address user, uint256 amount) internal {
        if (address(securityManager) == address(0)) {
            revert SecurityCheckFailed("Security manager not set");
        }

        (bool canDepositCheck, string memory reason) = securityManager.canUserDeposit(user, amount);
        if (!canDepositCheck) {
            emit SecurityValidationFailed(user, reason);
            revert SecurityCheckFailed(reason);
        }
        
        securityManager.preDepositCheck(user, amount);
        securityManager.checkCircuitBreaker(amount);
    }

    function _processDeposit(
        uint256 amountUSDT,
        uint256 minQorafiOut,
        uint256 deadline,
        uint16 slippageBps
    ) internal {
        if (address(oracle) != address(0)) {
            require(oracle.isHealthy(), "Oracle unhealthy");
        }

        uint256 usdtForLiquidity = MathHelperLib.calculatePercentage(amountUSDT, liquidityRatioBPS);
        uint256 usdtForSwap = amountUSDT - usdtForLiquidity;

        require(usdtForSwap > 0 && usdtForLiquidity > 0, "Invalid amount split");

        // Execute swap
        uint256 qorafiAcquired = SwapLib.executeSwap(
            address(router),
            address(usdtToken),
            address(qorafiToken),
            usdtForSwap,
            minQorafiOut,
            deadline
        );
        require(qorafiAcquired >= minQorafiOut, "Insufficient QoraFi received");

        // Add liquidity
        (uint256 actualUsdtUsed, uint256 actualQorafiUsed, uint256 lpTokens) = 
            LiquidityLib.addLiquidity(
                address(router),
                address(usdtToken),
                address(qorafiToken),
                usdtForLiquidity,
                qorafiAcquired,
                slippageBps,
                msg.sender,
                deadline
            );
        require(lpTokens > 0, "No liquidity tokens received");

        // Refund unused tokens
        LiquidityLib.refundUnusedTokens(
            address(usdtToken),
            address(qorafiToken),
            usdtForLiquidity,
            qorafiAcquired,
            actualUsdtUsed,
            actualQorafiUsed,
            msg.sender
        );

        _notifyLedger(msg.sender, amountUSDT);
        emit DepositProcessed(msg.sender, amountUSDT, qorafiAcquired, lpTokens);
    }

    function _notifyLedger(address user, uint256 amount) internal {
        if (address(ledger) != address(0)) {
            (bool success, string memory errorReason) = LedgerLib.safeNotifyLedger(
                address(ledger), 
                user, 
                amount
            );
            
            if (!success) {
                emit LedgerNotificationFailed(user, amount, errorReason);
            }
        }
    }

    function _updateStatistics(address user, uint256 amount) internal {
        StatisticsLib.updateUserStats(userStats, user, amount);
        StatisticsLib.updateProtocolStats(protocolStats, amount, _getTotalUsers());
        
        if (address(securityManager) != address(0)) {
            securityManager.postDepositUpdate(user, amount);
        }
    }

    function _getTotalUsers() internal view returns (uint256) {
        return protocolStats.uniqueUsers + 1;
    }

    // --- VIEW FUNCTIONS ---
    /**
     * @notice Check if user can deposit specified amount
     * @param user User address to check
     * @param amount Amount user wants to deposit
     * @return canDepositResult Whether user can deposit
     * @return reason Reason if cannot deposit
     */
    function canUserDeposit(address user, uint256 amount) external view override returns (bool canDepositResult, string memory reason) {
        if (emergencyStop) {
            return (false, "Emergency stop active");
        }
        
        (bool mevValid, string memory mevReason) = mevProtection.validateDeposit(user, amount);
        if (!mevValid) {
            return (false, mevReason);
        }
        
        if (amount < MIN_DEPOSIT_AMOUNT || amount > MAX_DEPOSIT_AMOUNT) {
            return (false, "Amount out of bounds");
        }
        
        uint256 currentDay = block.timestamp / 86400;
        uint256 currentDayVolume = (currentDay == lastVolumeResetDay) ? totalDailyVolume : 0;
        if (currentDayVolume + amount > dailyVolumeLimit) {
            return (false, "Daily volume limit exceeded");
        }
        
        if (address(securityManager) != address(0)) {
            // Note: Cannot call external security manager from view function
            // Security checks are performed during actual deposit execution
            return (true, "Security checks deferred to execution");
        }
        
        return (true, "OK");
    }

    function getUserStats(address user) external view override returns (uint256 depositCount, uint256 totalDeposited) {
        (depositCount, totalDeposited,,,,,,) = StatisticsLib.getUserStats(userStats, user);
    }

    function getProtocolStats() external view override returns (uint256 totalDeposits) {
        return protocolStats.totalVolume;
    }

    function getCurrentPrice() external view override returns (uint256) {
        if (address(oracle) != address(0)) {
            return oracle.getCurrentPrice();
        }
        return 0;
    }

    /**
     * @notice Estimate QoraFi and LP tokens for given USDT amount
     * @param usdtAmount USDT amount to simulate
     * @return estimatedQorafiOut Estimated QoraFi tokens
     * @return estimatedLPTokens Estimated LP tokens
     */
    function estimateDeposit(uint256 usdtAmount) external view override returns (uint256 estimatedQorafiOut, uint256 estimatedLPTokens) {
        if (usdtAmount < MIN_DEPOSIT_AMOUNT || usdtAmount > MAX_DEPOSIT_AMOUNT) {
            return (0, 0);
        }
        
        uint256 usdtForSwap = MathHelperLib.calculatePercentage(usdtAmount, 10000 - liquidityRatioBPS);
        estimatedQorafiOut = SwapLib.getExpectedSwapOutput(
            address(router),
            address(usdtToken),
            address(qorafiToken),
            usdtForSwap
        );
        estimatedLPTokens = usdtAmount - usdtForSwap;
    }

    /**
     * @notice Get MEV protection status for user
     * @param user User address to check
     * @return canDeposit Whether user can deposit now
     * @return blocksToWait Blocks until next allowed deposit
     * @return dailyRemaining Daily deposit limit remaining
     */
    function getMEVStatus(address user) external view returns (
        bool canDeposit,
        uint256 blocksToWait,
        uint256 dailyRemaining
    ) {
        (, string memory reason) = mevProtection.validateDeposit(user, 0);
        canDeposit = keccak256(bytes(reason)) == keccak256(bytes("OK"));
        
        (blocksToWait,) = mevProtection.getWaitTimes(user);
        
        (,,,, dailyRemaining) = mevProtection.getUserStatus(user);
    }

    // --- GOVERNANCE FUNCTIONS ---
    /**
     * @notice Update security manager contract
     * @param _securityManager New security manager address
     */
    function setSecurityManager(address _securityManager) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        ValidationLib.validateAddress(_securityManager);
        address oldManager = address(securityManager);
        securityManager = ISecurityManager(_securityManager);
        emit SecurityManagerUpdated(oldManager, _securityManager);
    }

    function setOracle(address _oracle) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        ValidationLib.validateAddress(_oracle);
        address oldOracle = address(oracle);
        oracle = IBondingOracle(_oracle);
        emit OracleUpdated(oldOracle, _oracle);
    }

    function setLedger(address _ledger) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ValidationLib.validateAddress(_ledger);
        address oldLedger = address(ledger);
        ledger = IEnhancedLedger(_ledger);
        emit LedgerUpdated(oldLedger, _ledger);
    }

    function setManualPrice(uint256 priceValue) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        require(priceValue > 0, "Invalid price");
        if (address(oracle) != address(0)) {
            oracle.setFallbackPrice(priceValue);
        }
    }

    function setLiquidityRatio(uint256 _ratioBPS) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        ValidationLib.validateBPS(_ratioBPS);
        require(_ratioBPS >= 1000 && _ratioBPS <= 9000, "Ratio must be 10%-90%");
        liquidityRatioBPS = _ratioBPS;
    }

    function addSupportedZapToken(
        address token, 
        TokenType tokenType, 
        bool hasDirectPair
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        ValidationLib.validateAddress(token);
        require(token != address(usdtToken) && token != address(qorafiToken), "Cannot add core tokens");
        require(token != nativeWrappedToken, "Native token already configured");
        
        supportedZapTokens[token] = true;
        tokenTypes[token] = tokenType;
        hasDirectPairToUSDT[token] = hasDirectPair;
        
        emit ZapTokenAdded(token, tokenType, hasDirectPair);
    }

    function removeSupportedZapToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != nativeWrappedToken, "Cannot remove native token");
        supportedZapTokens[token] = false;
        delete tokenTypes[token];
        delete hasDirectPairToUSDT[token];
        emit ZapTokenRemoved(token);
    }

    function setTokenType(address token, TokenType newTokenType) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(supportedZapTokens[token], "Token not supported");
        TokenType oldType = tokenTypes[token];
        tokenTypes[token] = newTokenType;
        emit TokenTypeUpdated(token, oldType, newTokenType);
    }

    function setDirectPairToUSDT(address token, bool hasDirectPair) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(supportedZapTokens[token], "Token not supported");
        hasDirectPairToUSDT[token] = hasDirectPair;
        emit DirectPairUpdated(token, hasDirectPair);
    }

    function getTokenInfo(address token) external view returns (
        bool isSupported,
        TokenType tokenType,
        bool hasDirectPair
    ) {
        return (
            supportedZapTokens[token],
            tokenTypes[token],
            hasDirectPairToUSDT[token]
        );
    }

    function setEmergencyStop(bool _emergencyStop, string calldata reason) external onlyRole(EMERGENCY_ROLE) {
        emergencyStop = _emergencyStop;
        if (_emergencyStop) {
            emit EmergencyStopActivated(msg.sender, reason);
        }
    }

    function setDailyVolumeLimit(uint256 _limit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_limit >= 100000 * 1e18, "Limit too low");
        dailyVolumeLimit = _limit;
    }

    function setMaxSlippage(uint256 _maxSlippageBPS) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_maxSlippageBPS >= 100 && _maxSlippageBPS <= 1000, "Invalid slippage range");
        maxSlippageBPS = _maxSlippageBPS;
    }

    function pause() external override onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function emergencyWithdrawToken(address token, uint256 amount) external onlyRole(EMERGENCY_ROLE) {
        require(emergencyStop, "Emergency stop not active");
        require(token != address(usdtToken) && token != address(qorafiToken), "Cannot withdraw core tokens during emergency");
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    receive() external payable {}
}