// contracts/core/EnhancedBondingCurve.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import "../libraries/SecurityLibraries.sol";
import "../libraries/UtilityLibraries.sol";
import "../interfaces/SecurityInterfaces.sol";

/**
 * @title EnhancedBondingCurve
 * @notice Modular bonding curve using the new library architecture
 * @dev Significantly reduced from legacy 600+ lines to ~300 lines
 */
contract EnhancedBondingCurve is 
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    IBondingCurve
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using SwapLib for address;
    using LiquidityLib for address;
    using TokenHelperLib for address;
    using ValidationLib for *;
    using StatisticsLib for mapping(address => StatisticsLib.UserStats);

    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    // --- STATE ---
    IERC20Upgradeable public usdtToken;
    IERC20Upgradeable public qorafiToken;
    ISecurityManager public securityManager;
    IEnhancedOracle public oracle;
    IRouter public router;
    IEnhancedLedger public ledger;
    
    uint256 public liquidityRatioBPS;
    uint256 public maxSlippageBPS;
    
    // Statistics using library
    mapping(address => StatisticsLib.UserStats) private userStats;
    StatisticsLib.ProtocolStats public protocolStats;
    
    // Supported tokens
    mapping(address => bool) public supportedZapTokens;

    // --- EVENTS ---
    event DepositProcessed(address indexed user, uint256 usdtValue, uint256 qorafiAcquired, uint256 lpTokensReceived);
    event ZapTokenAdded(address indexed token);
    event ZapTokenRemoved(address indexed token);

    // --- ERRORS ---
    error InvalidAmount();
    error SecurityCheckFailed(string reason);
    error SwapFailed();
    error LiquidityFailed();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _usdtToken,
        address _qorafiToken,
        address _router,
        address _securityManager,
        address _oracle,
        address _ledger
    ) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        ValidationLib.validateAddress(_usdtToken);
        ValidationLib.validateAddress(_qorafiToken);
        ValidationLib.validateAddress(_router);
        ValidationLib.validateAddress(_securityManager);

        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);

        usdtToken = IERC20Upgradeable(_usdtToken);
        qorafiToken = IERC20Upgradeable(_qorafiToken);
        router = IRouter(_router);
        securityManager = ISecurityManager(_securityManager);
        oracle = IEnhancedOracle(_oracle);
        ledger = IEnhancedLedger(_ledger);
        
        liquidityRatioBPS = 5000; // 50%
        maxSlippageBPS = 300; // 3%
    }

    // --- CORE DEPOSIT FUNCTIONS ---
    function deposit(
        uint256 amountUSDT,
        uint256 minQorafiOut,
        uint256 minLiquidity,
        uint256 deadline,
        uint16 slippageBps
    ) external override 
        nonReentrant 
        whenNotPaused 
    {
        _validateDeposit(amountUSDT, deadline, slippageBps);
        _performSecurityChecks(msg.sender, amountUSDT);
        
        usdtToken.safeTransferFrom(msg.sender, address(this), amountUSDT);
        _processDeposit(amountUSDT, minQorafiOut, minLiquidity, deadline, slippageBps);
        _updateStatistics(msg.sender, amountUSDT);
    }

    function depositWithBNB(
        uint256 minUsdtOut,
        uint256 minQorafiOut,
        uint256 minLiquidity,
        uint256 deadline,
        uint16 slippageBps
    ) external payable override
        nonReentrant 
        whenNotPaused 
    {
        require(msg.value > 0, "No BNB sent");
        _validateDeposit(0, deadline, slippageBps); // Amount validated after swap
        
        // Swap BNB to USDT using utility library
        uint256 usdtReceived = SwapLib.executeETHToTokenSwap(
            address(router),
            address(usdtToken),
            msg.value,
            minUsdtOut,
            deadline
        );
        
        _performSecurityChecks(msg.sender, usdtReceived);
        _processDeposit(usdtReceived, minQorafiOut, minLiquidity, deadline, slippageBps);
        _updateStatistics(msg.sender, usdtReceived);
    }

    function depositWithToken(
        address tokenIn,
        uint256 amountIn,
        uint256 minUsdtOut,
        uint256 minQorafiOut,
        uint256 minLiquidity,
        uint256 deadline,
        uint16 slippageBps
    ) external override
        nonReentrant 
        whenNotPaused 
    {
        require(supportedZapTokens[tokenIn], "Token not supported");
        require(amountIn > 0, "Invalid amount");
        _validateDeposit(0, deadline, slippageBps);

        IERC20Upgradeable(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        
        // Use utility library for multi-hop swap if needed
        uint256 usdtReceived = tokenIn == router.WETH() 
            ? SwapLib.executeSwap(address(router), tokenIn, address(usdtToken), amountIn, minUsdtOut, deadline)
            : SwapLib.executeMultiHopSwap(address(router), tokenIn, address(usdtToken), amountIn, minUsdtOut, deadline);
        
        _performSecurityChecks(msg.sender, usdtReceived);
        _processDeposit(usdtReceived, minQorafiOut, minLiquidity, deadline, slippageBps);
        _updateStatistics(msg.sender, usdtReceived);
    }

    // --- INTERNAL FUNCTIONS ---
    function _validateDeposit(uint256 amount, uint256 deadline, uint16 slippageBps) internal view {
        if (amount > 0) {
            ValidationLib.validateAmount(amount, 1e6, 5000 * 1e6); // 1 USDT to 5k USDT
        }
        require(deadline > block.timestamp, "Deadline passed");
        require(slippageBps <= maxSlippageBPS, "Slippage too high");
    }

    function _performSecurityChecks(address user, uint256 amount) internal {
        (bool canDeposit, string memory reason) = securityManager.canUserDeposit(user, amount);
        if (!canDeposit) revert SecurityCheckFailed(reason);
        
        securityManager.preDepositCheck(user, amount);
        securityManager.checkCircuitBreaker(amount);
    }

    function _processDeposit(
        uint256 amountUSDT,
        uint256 minQorafiOut,
        uint256 minLiquidity,
        uint256 deadline,
        uint16 slippageBps
    ) internal {
        // Validate oracle health
        require(oracle.isHealthy(), "Oracle unhealthy");
        oracle.checkMarketCapLimits();

        // Split amount for swap and liquidity
        uint256 usdtForLiquidity = MathHelperLib.calculatePercentage(amountUSDT, liquidityRatioBPS);
        uint256 usdtForSwap = amountUSDT - usdtForLiquidity;

        // Execute swap using utility library
        uint256 qorafiAcquired = SwapLib.executeSwap(
            address(router),
            address(usdtToken),
            address(qorafiToken),
            usdtForSwap,
            minQorafiOut,
            deadline
        );

        // Add liquidity using utility library
        (uint256 actualUsdtUsed, uint256 actualQorafiUsed, uint256 lpTokens) = LiquidityLib.addLiquidity(
            address(router),
            address(usdtToken),
            address(qorafiToken),
            usdtForLiquidity,
            qorafiAcquired,
            slippageBps,
            msg.sender,
            deadline
        );

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

        // Safe ledger notification
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
        userStats.updateUserStats(user, amount);
        protocolStats.updateProtocolStats(amount, _getTotalUsers());
        securityManager.postDepositUpdate(user, amount);
    }

    function _getTotalUsers() internal view returns (uint256) {
        // Simplified - would track unique users properly
        return protocolStats.uniqueUsers + 1;
    }

    // --- VIEW FUNCTIONS ---
    function canUserDeposit(address user, uint256 amount) external view override returns (bool canDeposit, string memory reason) {
        return securityManager.canUserDeposit(user, amount);
    }

    function getUserStats(address user) external view override returns (uint256 depositCount, uint256 totalDeposited) {
        (depositCount, totalDeposited,,) = userStats.getUserStats(user);
    }

    function getProtocolStats() external view override returns (uint256 totalDeposits) {
        return protocolStats.totalVolume;
    }

    function getCurrentPrice() external view override returns (uint256) {
        return oracle.getCurrentPrice();
    }

    function estimateDeposit(uint256 usdtAmount) external view override returns (uint256 estimatedQorafiOut, uint256 estimatedLPTokens) {
        uint256 usdtForSwap = MathHelperLib.calculatePercentage(usdtAmount, 10000 - liquidityRatioBPS);
        
        // Estimate swap output
        estimatedQorafiOut = SwapLib.getExpectedSwapOutput(
            address(router),
            address(usdtToken),
            address(qorafiToken),
            usdtForSwap
        );
        
        // Simplified LP token estimation
        estimatedLPTokens = usdtAmount - usdtForSwap;
    }

    // --- GOVERNANCE FUNCTIONS ---
    function setSecurityManager(address _securityManager) external override onlyRole(GOVERNANCE_ROLE) {
        ValidationLib.validateAddress(_securityManager);
        securityManager = ISecurityManager(_securityManager);
    }

    function setOracle(address _oracle) external override onlyRole(GOVERNANCE_ROLE) {
        ValidationLib.validateAddress(_oracle);
        oracle = IEnhancedOracle(_oracle);
    }

    function setLiquidityRatio(uint256 _ratioBPS) external override onlyRole(GOVERNANCE_ROLE) {
        ValidationLib.validateBPS(_ratioBPS);
        liquidityRatioBPS = _ratioBPS;
    }

    function addSupportedZapToken(address token) external onlyRole(GOVERNANCE_ROLE) {
        ValidationLib.validateAddress(token);
        supportedZapTokens[token] = true;
        emit ZapTokenAdded(token);
    }

    function removeSupportedZapToken(address token) external onlyRole(GOVERNANCE_ROLE) {
        supportedZapTokens[token] = false;
        emit ZapTokenRemoved(token);
    }

    function pause() external override onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external override onlyRole(GOVERNANCE_ROLE) {
        _unpause();
    }

    // --- EVENTS (additional) ---
    event LedgerNotificationFailed(address indexed user, uint256 amount, string reason);

    // --- UUPS UPGRADE HOOK ---
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(GOVERNANCE_ROLE) {}

    receive() external payable {}
}