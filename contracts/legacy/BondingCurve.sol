// contracts/legacy/BondingCurve.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/MathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/**
 * @title BondingCurve (Legacy Implementation)
 * @notice Original bonding curve contract (~600 lines) - kept for reference
 * @dev This is the original implementation before modularization
 */

// --- EXTERNAL INTERFACES ---
interface ISecurityManager {
    function canUserDeposit(address user, uint256 amount) external view returns (bool canDeposit, string memory reason);
    function preDepositCheck(address user, uint256 amount) external;
    function postDepositUpdate(address user, uint256 amount) external;
    function checkCircuitBreaker(uint256 amount) external;
    function isEmergencyMode() external view returns (bool);
    function isPaused() external view returns (bool);
    function isSupportedZapToken(address token) external view returns (bool);
}

interface IOracle {
    function getCurrentPrice() external view returns (uint256);
    function isHealthy() external view returns (bool);
    function checkMarketCapLimits() external view;
}

interface IRouter {
    function WETH() external view returns (address);
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory);
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external payable returns (uint256[] memory);
    function addLiquidity(address tokenA, address tokenB, uint256 amountADesired, uint256 amountBDesired, uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
}

interface ILedger {
    function notifyDeposit(address user, uint256 amount) external;
}

contract BondingCurve is Initializable, AccessControlUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using MathUpgradeable for uint256;

    // --- CONSTANTS ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    
    uint256 private constant MIN_DEPOSIT = 1e6; // 1 USDT
    uint256 private constant MAX_DEPOSIT = 5000e6; // 5k USDT for new token
    uint256 private constant MIN_DEADLINE = 5 minutes;
    uint256 private constant MAX_DEADLINE = 1 hours;
    uint256 private constant MAX_BPS = 10000;

    // --- STATE VARIABLES ---
    IERC20Upgradeable public usdtToken;
    IERC20Upgradeable public qorafiToken;
    ISecurityManager public securityManager;
    IOracle public oracle;
    IRouter public router;
    ILedger public ledger;
    
    uint256 public liquidityRatioBPS; // Percentage of deposit for liquidity (vs swap)
    uint256 public maxSlippageBPS;
    
    // Manual price fallback
    uint256 public manualPrice;
    uint256 public manualPriceTimestamp;
    bool public manualPriceActive;
    
    // Simple tracking
    mapping(address => uint256) public userDepositCounts;
    mapping(address => uint256) public userTotalDeposited;
    uint256 public totalProtocolDeposits;

    // --- EVENTS ---
    event DepositProcessed(address indexed user, uint256 usdtValue, uint256 qorafiAcquired, uint256 lpTokensReceived);
    event SwapExecuted(address indexed user, uint256 usdtIn, uint256 qorafiOut);
    event LiquidityAdded(address indexed user, uint256 usdtAmount, uint256 qorafiAmount, uint256 lpTokens);
    event SecurityManagerUpdated(address indexed newSecurityManager);
    event OracleUpdated(address indexed newOracle);
    event LedgerNotificationFailed(address indexed user, uint256 amount, string reason);
    event LedgerSyncSuccess(address indexed user, uint256 amount);

    // --- ERRORS ---
    error InvalidAmount();
    error InvalidDeadline();
    error SecurityCheckFailed(string reason);
    error OracleUnhealthy();
    error SwapFailed();
    error InsufficientOutput();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _usdtToken,
        address _qorafiToken,
        address _router,
        address _securityManager,
        address _ledger
    ) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);

        usdtToken = IERC20Upgradeable(_usdtToken);
        qorafiToken = IERC20Upgradeable(_qorafiToken);
        router = IRouter(_router);
        securityManager = ISecurityManager(_securityManager);
        ledger = ILedger(_ledger);
        
        liquidityRatioBPS = 5000; // 50% for liquidity, 50% for swap
        maxSlippageBPS = 300; // 3% max slippage
    }

    // --- MODIFIERS ---
    modifier securityChecks(uint256 amount) {
        // Check with external SecurityManager
        (bool canDeposit, string memory reason) = securityManager.canUserDeposit(msg.sender, amount);
        if (!canDeposit) revert SecurityCheckFailed(reason);
        
        // Pre-deposit checks
        securityManager.preDepositCheck(msg.sender, amount);
        securityManager.checkCircuitBreaker(amount);
        
        _;
        
        // Post-deposit updates
        securityManager.postDepositUpdate(msg.sender, amount);
    }

    modifier validAmount(uint256 amount) {
        if (amount < MIN_DEPOSIT || amount > MAX_DEPOSIT) revert InvalidAmount();
        _;
    }

    modifier validDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert InvalidDeadline();
        if (deadline > block.timestamp + MAX_DEADLINE) revert InvalidDeadline();
        if (deadline < block.timestamp + MIN_DEADLINE) revert InvalidDeadline();
        _;
    }

    // --- GOVERNANCE ---
    function setSecurityManager(address _securityManager) external onlyRole(GOVERNANCE_ROLE) {
        securityManager = ISecurityManager(_securityManager);
        emit SecurityManagerUpdated(_securityManager);
    }

    function setOracle(address _oracle) external onlyRole(GOVERNANCE_ROLE) {
        oracle = IOracle(_oracle);
        emit OracleUpdated(_oracle);
    }

    function setManualPrice(uint256 _price) external onlyRole(GOVERNANCE_ROLE) {
        manualPrice = _price;
        manualPriceTimestamp = block.timestamp;
        manualPriceActive = true;
    }

    function setLiquidityRatio(uint256 _ratioBPS) external onlyRole(GOVERNANCE_ROLE) {
        require(_ratioBPS <= MAX_BPS, "Invalid ratio");
        liquidityRatioBPS = _ratioBPS;
    }

    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GOVERNANCE_ROLE) {
        _unpause();
    }

    // --- CORE DEPOSIT FUNCTIONS ---
    function deposit(
        uint256 _amountUSDT,
        uint256 _minQorafiOut,
        uint256 _minLiquidity,
        uint256 _deadline,
        uint16 _slippageBps
    ) external 
        nonReentrant 
        whenNotPaused 
        validAmount(_amountUSDT)
        validDeadline(_deadline)
        securityChecks(_amountUSDT)
    {
        usdtToken.safeTransferFrom(msg.sender, address(this), _amountUSDT);
        _processDeposit(_amountUSDT, _minQorafiOut, _minLiquidity, _deadline, _slippageBps);
        _updateStats(msg.sender, _amountUSDT);
    }

    function depositWithBNB(
        uint256 _minUsdtOut,
        uint256 _minQorafiOut,
        uint256 _minLiquidity,
        uint256 _deadline,
        uint16 _slippageBps
    ) external payable nonReentrant whenNotPaused validDeadline(_deadline) {
        require(msg.value > 0, "No BNB sent");
        
        uint256 usdtReceived = _swapBNBToUSDT(msg.value, _minUsdtOut, _deadline);
        
        // Apply security checks after we know the USDT amount
        if (usdtReceived < MIN_DEPOSIT || usdtReceived > MAX_DEPOSIT) revert InvalidAmount();
        
        (bool canDeposit, string memory reason) = securityManager.canUserDeposit(msg.sender, usdtReceived);
        if (!canDeposit) revert SecurityCheckFailed(reason);
        
        securityManager.preDepositCheck(msg.sender, usdtReceived);
        securityManager.checkCircuitBreaker(usdtReceived);
        
        _processDeposit(usdtReceived, _minQorafiOut, _minLiquidity, _deadline, _slippageBps);
        
        securityManager.postDepositUpdate(msg.sender, usdtReceived);
        _updateStats(msg.sender, usdtReceived);
    }

    function depositWithToken(
        address _tokenIn,
        uint256 _amountIn,
        uint256 _minUsdtOut,
        uint256 _minQorafiOut,
        uint256 _minLiquidity,
        uint256 _deadline,
        uint16 _slippageBps
    ) external nonReentrant whenNotPaused validDeadline(_deadline) {
        require(securityManager.isSupportedZapToken(_tokenIn), "Token not supported");
        require(_amountIn > 0, "Invalid amount");

        IERC20Upgradeable(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);
        IERC20Upgradeable(_tokenIn).safeIncreaseAllowance(address(router), _amountIn);
        
        uint256 usdtReceived = _swapTokenToUSDT(_tokenIn, _amountIn, _minUsdtOut, _deadline);
        IERC20Upgradeable(_tokenIn).safeDecreaseAllowance(address(router), _amountIn);
        
        // Apply security checks
        if (usdtReceived < MIN_DEPOSIT || usdtReceived > MAX_DEPOSIT) revert InvalidAmount();
        
        (bool canDeposit, string memory reason) = securityManager.canUserDeposit(msg.sender, usdtReceived);
        if (!canDeposit) revert SecurityCheckFailed(reason);
        
        securityManager.preDepositCheck(msg.sender, usdtReceived);
        securityManager.checkCircuitBreaker(usdtReceived);
        
        _processDeposit(usdtReceived, _minQorafiOut, _minLiquidity, _deadline, _slippageBps);
        
        securityManager.postDepositUpdate(msg.sender, usdtReceived);
        _updateStats(msg.sender, usdtReceived);
    }

    // --- INTERNAL FUNCTIONS ---
    function _processDeposit(
        uint256 _amountUSDT,
        uint256 _minQorafiOut,
        uint256 _minLiquidity,
        uint256 _deadline,
        uint16 _slippageBps
    ) internal {
        // OPTIMIZED: Single oracle health check that includes market cap limits
        if (address(oracle) != address(0)) {
            try oracle.isHealthy() returns (bool healthy) {
                if (!healthy) revert OracleUnhealthy();
            } catch {
                revert OracleUnhealthy();
            }
            
            // Only check market cap limits if oracle is healthy
            try oracle.checkMarketCapLimits() {} catch {
                revert OracleUnhealthy();
            }
        }

        // SAFE LEDGER NOTIFICATION: Explicit error handling with event
        bool ledgerNotified = false;
        try ledger.notifyDeposit(msg.sender, _amountUSDT) {
            ledgerNotified = true;
        } catch Error(string memory reason) {
            emit LedgerNotificationFailed(msg.sender, _amountUSDT, reason);
        } catch (bytes memory) {
            emit LedgerNotificationFailed(msg.sender, _amountUSDT, "Unknown error");
        }

        // Split amount
        uint256 usdtForLiquidity = MathUpgradeable.mulDiv(_amountUSDT, liquidityRatioBPS, MAX_BPS);
        uint256 usdtForSwap = _amountUSDT - usdtForLiquidity;

        // Execute swap
        uint256 qorafiAcquired = _executeSwap(usdtForSwap, _minQorafiOut, _deadline);
        emit SwapExecuted(msg.sender, usdtForSwap, qorafiAcquired);

        // Add liquidity
        uint256 lpTokens = _addLiquidity(usdtForLiquidity, qorafiAcquired, _minLiquidity, _deadline, _slippageBps);

        emit DepositProcessed(msg.sender, _amountUSDT, qorafiAcquired, lpTokens);
        
        // Emit ledger sync status for monitoring
        if (ledgerNotified) {
            emit LedgerSyncSuccess(msg.sender, _amountUSDT);
        }
    }

    function _executeSwap(uint256 usdtAmount, uint256 minQorafiOut, uint256 deadline) internal returns (uint256) {
        // Get expected output
        uint256 expectedQorafi = _getExpectedSwapOutput(usdtAmount);
        if (expectedQorafi == 0) revert SwapFailed();

        // Calculate minimum with slippage
        uint256 minWithSlippage = MathUpgradeable.mulDiv(expectedQorafi, MAX_BPS - maxSlippageBPS, MAX_BPS);
        uint256 actualMin = minQorafiOut > minWithSlippage ? minQorafiOut : minWithSlippage;

        // SAFE ALLOWANCE PATTERN - Set exact amount, always reset to 0
        usdtToken.safeIncreaseAllowance(address(router), usdtAmount);
        
        address[] memory path = new address[](2);
        path[0] = address(usdtToken);
        path[1] = address(qorafiToken);

        uint256 qorafiReceived;
        try router.swapExactTokensForTokens(
            usdtAmount,
            actualMin,
            path,
            address(this),
            deadline
        ) returns (uint256[] memory amounts) {
            qorafiReceived = amounts[amounts.length - 1];
            if (qorafiReceived < actualMin) {
                // Reset allowance before reverting
                usdtToken.safeDecreaseAllowance(address(router), usdtAmount);
                revert InsufficientOutput();
            }
        } catch {
            // CRITICAL: Always reset allowance on failure
            usdtToken.safeDecreaseAllowance(address(router), usdtAmount);
            revert SwapFailed();
        }
        
        // Reset allowance after successful swap
        usdtToken.safeDecreaseAllowance(address(router), usdtAmount);
        
        return qorafiReceived;
    }

    function _addLiquidity(
        uint256 usdtAmount,
        uint256 qorafiAmount,
        uint256 minLiquidity,
        uint256 deadline,
        uint16 slippageBps
    ) internal returns (uint256) {
        require(slippageBps <= maxSlippageBPS, "Slippage too high");

        // SAFE ALLOWANCE PATTERN - Set exact amounts, always reset
        usdtToken.safeIncreaseAllowance(address(router), usdtAmount);
        qorafiToken.safeIncreaseAllowance(address(router), qorafiAmount);

        uint256 lpTokens;
        uint256 amountA;
        uint256 amountB;
        
        try router.addLiquidity(
            address(usdtToken),
            address(qorafiToken),
            usdtAmount,
            qorafiAmount,
            MathUpgradeable.mulDiv(usdtAmount, MAX_BPS - slippageBps, MAX_BPS),
            MathUpgradeable.mulDiv(qorafiAmount, MAX_BPS - slippageBps, MAX_BPS),
            msg.sender,
            deadline
        ) returns (uint256 _amountA, uint256 _amountB, uint256 _lpTokens) {
            amountA = _amountA;
            amountB = _amountB;
            lpTokens = _lpTokens;
            
            if (lpTokens < minLiquidity) {
                // Reset allowances before reverting
                usdtToken.safeDecreaseAllowance(address(router), usdtAmount);
                qorafiToken.safeDecreaseAllowance(address(router), qorafiAmount);
                revert InsufficientOutput();
            }
        } catch {
            // CRITICAL: Always reset allowances on failure
            usdtToken.safeDecreaseAllowance(address(router), usdtAmount);
            qorafiToken.safeDecreaseAllowance(address(router), qorafiAmount);
            revert SwapFailed();
        }

        // Reset allowances after successful liquidity addition
        usdtToken.safeDecreaseAllowance(address(router), usdtAmount);
        qorafiToken.safeDecreaseAllowance(address(router), qorafiAmount);

        // Refund unused tokens
        if (usdtAmount > amountA) {
            usdtToken.safeTransfer(msg.sender, usdtAmount - amountA);
        }
        if (qorafiAmount > amountB) {
            qorafiToken.safeTransfer(msg.sender, qorafiAmount - amountB);
        }

        emit LiquidityAdded(msg.sender, amountA, amountB, lpTokens);
        return lpTokens;
    }

    function _swapBNBToUSDT(uint256 bnbAmount, uint256 minUsdtOut, uint256 deadline) internal returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = address(usdtToken);

        uint256[] memory amounts = router.swapExactETHForTokens{value: bnbAmount}(
            minUsdtOut,
            path,
            address(this),
            deadline
        );

        return amounts[amounts.length - 1];
    }

    function _swapTokenToUSDT(address tokenIn, uint256 amountIn, uint256 minUsdtOut, uint256 deadline) internal returns (uint256) {
        address[] memory path;
        
        if (tokenIn == router.WETH()) {
            path = new address[](2);
            path[0] = tokenIn;
            path[1] = address(usdtToken);
        } else {
            path = new address[](3);
            path[0] = tokenIn;
            path[1] = router.WETH();
            path[2] = address(usdtToken);
        }

        uint256[] memory amounts = router.swapExactTokensForTokens(
            amountIn,
            minUsdtOut,
            path,
            address(this),
            deadline
        );

        return amounts[amounts.length - 1];
    }

    function _getExpectedSwapOutput(uint256 usdtIn) internal view returns (uint256) {
        address[] memory path = new address[](2);
        path[0] = address(usdtToken);
        path[1] = address(qorafiToken);

        try router.getAmountsOut(usdtIn, path) returns (uint256[] memory amounts) {
            return amounts.length >= 2 ? amounts[amounts.length - 1] : 0;
        } catch {
            return 0;
        }
    }

    function _updateStats(address user, uint256 amount) internal {
        userDepositCounts[user]++;
        userTotalDeposited[user] += amount;
        totalProtocolDeposits += amount;
    }

    // --- VIEW FUNCTIONS ---
    function canUserDeposit(address user, uint256 amount) external view returns (bool canDeposit, string memory reason) {
        return securityManager.canUserDeposit(user, amount);
    }

    function getUserStats(address user) external view returns (uint256 depositCount, uint256 totalDeposited) {
        return (userDepositCounts[user], userTotalDeposited[user]);
    }

    function getProtocolStats() external view returns (uint256 totalDeposits) {
        return totalProtocolDeposits;
    }

    function getCurrentPrice() external view returns (uint256) {
        if (manualPriceActive && block.timestamp - manualPriceTimestamp <= 2 hours) {
            return manualPrice;
        }
        
        if (address(oracle) != address(0)) {
            try oracle.getCurrentPrice() returns (uint256 price) {
                return price;
            } catch {}
        }
        
        return manualPrice;
    }

    function estimateDeposit(uint256 usdtAmount) external view returns (uint256 estimatedQorafiOut, uint256 estimatedLPTokens) {
        uint256 usdtForSwap = MathUpgradeable.mulDiv(usdtAmount, MAX_BPS - liquidityRatioBPS, MAX_BPS);
        estimatedQorafiOut = _getExpectedSwapOutput(usdtForSwap);
        estimatedLPTokens = MathUpgradeable.mulDiv(usdtAmount - usdtForSwap, 1e18, 1e6); // Simplified
        
        return (estimatedQorafiOut, estimatedLPTokens);
    }

    receive() external payable {}
}