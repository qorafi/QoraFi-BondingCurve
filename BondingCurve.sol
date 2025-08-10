// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "./SecurityManager.sol";

// --- INTERFACES ---
interface IMarketOracle {
    function getCachedMarketCap() external view returns (uint256);
    function checkMarketCapLimits() external view;
    function getCurrentPrice() external view returns (uint256);
    function isHealthy() external view returns (bool);
}

interface ISecondaryOracle {
    function getPrice() external view returns (uint256);
    function isActive() external view returns (bool);
}

interface IPancakeSwapRouter02 {
    function WETH() external view returns (address);
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory);
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external payable returns (uint256[] memory);
    function addLiquidity(address tokenA, address tokenB, uint256 amountADesired, uint256 amountBDesired, uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
}

interface IDelegatorNodeRewardsLedger {
    function notifyDeposit(address _user, uint256 _amountUSDT) external;
}

/**
 * @title BondingCurve (Enhanced & Hardened)
 * @notice Handles deposits, swaps and liquidity formation with enhanced security and oracle fallback mechanisms
 * @dev Depends on SecurityManager for access control, reentrancy, pause, antiMEV primitives and key storage variables
 */
contract BondingCurve is SecurityManager {
    using SafeERC20 for IERC20;

    // --- CONSTANTS ---
    uint256 private constant MIN_DEADLINE_BUFFER = 5 minutes;
    uint256 private constant MAX_DEADLINE_BUFFER = 1 hours;
    uint256 private constant ORACLE_STALENESS_THRESHOLD = 2 hours;
    uint256 private constant MIN_DEPOSIT_AMOUNT = 1e6; // 1 USDT (assuming 6 decimals)
    uint256 private constant MAX_SINGLE_DEPOSIT = 1000000e6; // 1M USDT
    uint256 private constant PRICE_DEVIATION_THRESHOLD = 1000; // 10% in BPS
    uint256 private constant GAS_LIMIT_EXTERNAL_CALL = 50000;

    // --- STATE VARIABLES ---
    IPancakeSwapRouter02 public immutable router;
    IDelegatorNodeRewardsLedger public immutable delegatorNodeRewardsLedger;
    IMarketOracle public oracle;
    ISecondaryOracle public secondaryOracle;
    
    // Oracle fallback settings
    bool public useSecondaryOracle;
    uint256 public manualPrice;
    uint256 public manualPriceTimestamp;
    bool public manualPriceActive;

    // Enhanced security
    mapping(address => uint256) public userDepositCounts;
    mapping(address => uint256) public userTotalDeposited;
    uint256 public totalProtocolDeposits;

    // --- EVENTS ---
    event OracleSet(address indexed oracleAddress);
    event SecondaryOracleSet(address indexed secondaryOracleAddress);
    event LiquidityRatioUpdated(uint256 newRatioBPS);
    event DepositProcessed(address indexed user, uint256 usdtValue, uint256 qorafiAcquired, uint256 lpTokensReceived);
    event NotifyLedgerFailed(address indexed user, uint256 amount);
    event SwapExecuted(address indexed user, uint256 usdtIn, uint256 qorafiOut);
    event LiquidityAdded(address indexed user, uint256 usdtAmount, uint256 qorafiAmount, uint256 lpTokens);
    event SweepTokens(address indexed token, address indexed to, uint256 amount);
    event OracleHealthCheck(uint256 marketCap, uint256 currentPrice, bool isHealthy);
    event OracleFallbackActivated(string reason, uint256 fallbackPrice);
    event ManualPriceSet(uint256 price, uint256 timestamp);
    event UserStatisticsUpdated(address indexed user, uint256 depositCount, uint256 totalDeposited);

    // --- ERRORS ---
    error InvalidDeadline();
    error OracleNotHealthy();
    error PriceDeviationTooHigh();
    error DepositAmountOutOfBounds();
    error AllOraclesDown();
    error ManualPriceStale();
    error InsufficientSlippageProtection();

    // --- CONSTRUCTOR ---
    constructor(
        address _usdtTokenAddress,
        address _qorafiTokenAddress,
        address _routerAddress,
        address _delegatorNodeRewardsLedgerAddress,
        address _initialTreasuryWallet
    ) SecurityManager(_usdtTokenAddress, _qorafiTokenAddress, _initialTreasuryWallet) {
        require(_routerAddress != address(0), "BondingCurve: Invalid router");
        require(_delegatorNodeRewardsLedgerAddress != address(0), "BondingCurve: Invalid ledger");
        
        router = IPancakeSwapRouter02(_routerAddress);
        delegatorNodeRewardsLedger = IDelegatorNodeRewardsLedger(_delegatorNodeRewardsLedgerAddress);
    }

    // --- GOVERNANCE FUNCTIONS ---
    function setOracle(address _oracleAddress) external onlyRole(GOVERNANCE_ROLE) {
        require(_oracleAddress != address(0), "BondingCurve: Invalid oracle address");
        oracle = IMarketOracle(_oracleAddress);
        emit OracleSet(_oracleAddress);
    }

    function setSecondaryOracle(address _secondaryOracleAddress) external onlyRole(GOVERNANCE_ROLE) {
        require(_secondaryOracleAddress != address(0), "BondingCurve: Invalid secondary oracle address");
        secondaryOracle = ISecondaryOracle(_secondaryOracleAddress);
        emit SecondaryOracleSet(_secondaryOracleAddress);
    }

    function setUseSecondaryOracle(bool _use) external onlyRole(GOVERNANCE_ROLE) {
        useSecondaryOracle = _use;
    }

    function setManualPrice(uint256 _price) external onlyRole(GOVERNANCE_ROLE) {
        require(_price > 0, "BondingCurve: Invalid manual price");
        manualPrice = _price;
        manualPriceTimestamp = block.timestamp;
        manualPriceActive = true;
        emit ManualPriceSet(_price, block.timestamp);
    }

    function deactivateManualPrice() external onlyRole(GOVERNANCE_ROLE) {
        manualPriceActive = false;
    }

    function setLiquidityRatio(uint256 _newRatioBPS) external onlyRole(GOVERNANCE_ROLE) {
        require(_newRatioBPS > 0 && _newRatioBPS < MAX_BPS, "BondingCurve: Invalid liquidity ratio");
        liquidityRatioBPS = _newRatioBPS;
        emit LiquidityRatioUpdated(_newRatioBPS);
    }

    function sweepTokens(address token, address to, uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        require(to != address(0), "BondingCurve: Invalid recipient");
        require(token != address(0), "BondingCurve: Invalid token");
        require(amount > 0, "BondingCurve: Invalid amount");
        IERC20(token).safeTransfer(to, amount);
        emit SweepTokens(token, to, amount);
    }

    // --- CORE DEPOSIT FUNCTIONS ---
    function deposit(
        uint256 _amountUSDT, 
        uint256 _minQorafiOut, 
        uint256 _minLiquidity, 
        uint256 _deadline, 
        uint16 _slippageBps
    ) external nonReentrant whenNotPaused antiMEV(_amountUSDT) {
        _validateInputs(_amountUSDT, _deadline);
        _checkCircuitBreaker(_amountUSDT);
        
        usdtToken.safeTransferFrom(msg.sender, address(this), _amountUSDT);
        _startBondingProcess(_amountUSDT, _minQorafiOut, _minLiquidity, _deadline, _slippageBps);
        _updateUserStatistics(msg.sender, _amountUSDT);
    }

    function depositWithBNB(
        uint256 _minUsdtOut, 
        uint256 _minQorafiOut, 
        uint256 _minLiquidity, 
        uint256 _deadline, 
        uint16 _slippageBps
    ) external payable nonReentrant whenNotPaused {
        _validateDeadline(_deadline);
        require(msg.value > 0, "BondingCurve: No BNB sent");

        uint256 usdtReceived = _swapBNBToUSDT(msg.value, _minUsdtOut, _deadline);
        _validateInputs(usdtReceived, _deadline);
        
        _checkCircuitBreaker(usdtReceived);
        _preDepositAntiMEVCheck(msg.sender, usdtReceived);

        _startBondingProcess(usdtReceived, _minQorafiOut, _minLiquidity, _deadline, _slippageBps);
        
        _postDepositAntiMEVUpdate(msg.sender, usdtReceived);
        _updateUserStatistics(msg.sender, usdtReceived);
    }

    function depositWithToken(
        address _tokenIn,
        uint256 _amountIn,
        uint256 _minUsdtOut,
        uint256 _minQorafiOut,
        uint256 _minLiquidity,
        uint256 _deadline,
        uint16 _slippageBps
    ) external nonReentrant whenNotPaused {
        if (!supportedZapTokens[_tokenIn]) revert TokenNotSupported();
        require(_amountIn > 0, "BondingCurve: Invalid token amount");
        _validateDeadline(_deadline);

        IERC20(_tokenIn).safeTransferFrom(msg.sender, address(this), _amountIn);
        
        IERC20(_tokenIn).safeIncreaseAllowance(address(router), _amountIn);
        
        uint256 usdtReceived = _swapTokenToUSDT(_tokenIn, _amountIn, _minUsdtOut, _deadline);
        
        IERC20(_tokenIn).safeDecreaseAllowance(address(router), _amountIn);
        
        _validateInputs(usdtReceived, _deadline);
        _checkCircuitBreaker(usdtReceived);
        _preDepositAntiMEVCheck(msg.sender, usdtReceived);

        _startBondingProcess(usdtReceived, _minQorafiOut, _minLiquidity, _deadline, _slippageBps);
        
        _postDepositAntiMEVUpdate(msg.sender, usdtReceived);
        _updateUserStatistics(msg.sender, usdtReceived);
    }

    // --- INTERNAL VALIDATION ---
    function _validateInputs(uint256 _amount, uint256 _deadline) internal pure {
        if (_amount < MIN_DEPOSIT_AMOUNT || _amount > MAX_SINGLE_DEPOSIT) {
            revert DepositAmountOutOfBounds();
        }
        _validateDeadline(_deadline);
    }

    function _validateDeadline(uint256 _deadline) internal view {
        if (block.timestamp > _deadline) revert DeadlineExpired();
        if (_deadline > block.timestamp + MAX_DEADLINE_BUFFER) revert InvalidDeadline();
        if (_deadline < block.timestamp + MIN_DEADLINE_BUFFER) revert InvalidDeadline();
    }

    function _updateUserStatistics(address user, uint256 amount) internal {
        userDepositCounts[user]++;
        userTotalDeposited[user] += amount;
        totalProtocolDeposits += amount;
        emit UserStatisticsUpdated(user, userDepositCounts[user], userTotalDeposited[user]);
    }

    // --- ENHANCED ORACLE LOGIC ---
    function _getReliablePrice() internal view returns (uint256) {
        if (manualPriceActive) {
            if (block.timestamp - manualPriceTimestamp <= ORACLE_STALENESS_THRESHOLD) {
                return manualPrice;
            } else {
                revert ManualPriceStale();
            }
        }

        if (address(oracle) != address(0)) {
            try oracle.isHealthy() returns (bool healthy) {
                if (healthy) {
                    try oracle.getCurrentPrice() returns (uint256 primaryPrice) {
                        if (primaryPrice > 0) {
                            if (useSecondaryOracle && address(secondaryOracle) != address(0)) {
                                try secondaryOracle.isActive() returns (bool secondaryActive) {
                                    if (secondaryActive) {
                                        try secondaryOracle.getPrice() returns (uint256 secondaryPrice) {
                                            if (secondaryPrice > 0) {
                                                uint256 deviation = _calculatePriceDeviation(primaryPrice, secondaryPrice);
                                                if (deviation > PRICE_DEVIATION_THRESHOLD) {
                                                    revert PriceDeviationTooHigh();
                                                }
                                            }
                                        } catch {}
                                    }
                                } catch {}
                            }
                            return primaryPrice;
                        }
                    } catch {}
                }
            } catch {}
        }

        if (useSecondaryOracle && address(secondaryOracle) != address(0)) {
            try secondaryOracle.isActive() returns (bool active) {
                if (active) {
                    try secondaryOracle.getPrice() returns (uint256 secondaryPrice) {
                        if (secondaryPrice > 0) {
                            return secondaryPrice;
                        }
                    } catch {}
                }
            } catch {}
        }

        revert AllOraclesDown();
    }

    function _calculatePriceDeviation(uint256 price1, uint256 price2) internal pure returns (uint256) {
        uint256 higher = price1 > price2 ? price1 : price2;
        uint256 lower = price1 > price2 ? price2 : price1;
        return Math.mulDiv(higher - lower, MAX_BPS, lower);
    }

    // --- INTERNAL LOGIC ---
    function _startBondingProcess(
        uint256 _amountUSDT,
        uint256 _minQorafiOut,
        uint256 _minLiquidity,
        uint256 _deadline,
        uint16 _slippageBps
    ) internal {
        uint256 currentPrice = _getReliablePrice();
        
        if (address(oracle) != address(0)) {
            try oracle.checkMarketCapLimits() {
                try oracle.getCachedMarketCap() returns (uint256 marketCap) {
                    emit OracleHealthCheck(marketCap, currentPrice, true);
                } catch {
                    emit OracleHealthCheck(0, currentPrice, false);
                }
            } catch {
                revert OracleNotHealthy();
            }
        }

        (uint256 usdtForLiquidity, uint256 qorafiAcquired) = _swapAndSplit(_amountUSDT, _minQorafiOut, _deadline);
        uint256 lpTokensReceived = _addLiquidityAndSend(usdtForLiquidity, qorafiAcquired, _minLiquidity, _deadline, _slippageBps);

        emit DepositProcessed(msg.sender, _amountUSDT, qorafiAcquired, lpTokensReceived);
    }

    function _swapAndSplit(uint256 _amountUSDT, uint256 _minQorafiOut, uint256 _deadline)
        private
        returns (uint256 usdtForLiquidity, uint256 qorafiAcquired)
    {
        try delegatorNodeRewardsLedger.notifyDeposit{gas: GAS_LIMIT_EXTERNAL_CALL}(msg.sender, _amountUSDT) {} catch Error(string memory) {
            emit NotifyLedgerFailed(msg.sender, _amountUSDT);
        } catch {
            emit NotifyLedgerFailed(msg.sender, _amountUSDT);
        }

        usdtForLiquidity = Math.mulDiv(_amountUSDT, liquidityRatioBPS, MAX_BPS);
        uint256 usdtForSwap = _amountUSDT - usdtForLiquidity;

        uint256 expectedQorafi = _getExpectedSwapOutput(usdtForSwap);
        require(expectedQorafi > 0, "BondingCurve: Expected swap output is zero");

        uint256 minQorafiWithSlippage = Math.mulDiv(expectedQorafi, MAX_BPS - maxSlippageBPS, MAX_BPS);
        uint256 actualMinQorafi = _minQorafiOut > minQorafiWithSlippage ? _minQorafiOut : minQorafiWithSlippage;

        usdtToken.safeIncreaseAllowance(address(router), usdtForSwap);
        
        address[] memory path = new address[](2);
        path[0] = address(usdtToken);
        path[1] = address(qorafiToken);

        uint256[] memory amounts = router.swapExactTokensForTokens(
            usdtForSwap, 
            actualMinQorafi, 
            path, 
            address(this), 
            _deadline
        );
        
        usdtToken.safeDecreaseAllowance(address(router), usdtForSwap);

        qorafiAcquired = amounts[amounts.length - 1];
        require(qorafiAcquired >= actualMinQorafi, "Insufficient Qorafi received");

        emit SwapExecuted(msg.sender, usdtForSwap, qorafiAcquired);
        return (usdtForLiquidity, qorafiAcquired);
    }

    function _addLiquidityAndSend(
        uint256 _usdtForLiquidity,
        uint256 _qorafiAcquired,
        uint256 _minLiquidity,
        uint256 _deadline,
        uint16 _slippageBps
    ) private returns (uint256) {
        if (_slippageBps > maxSlippageBPS) revert InvalidSlippage();
        require(_usdtForLiquidity > 0 && _qorafiAcquired > 0, "Invalid liquidity amounts");

        uint256 amountUsdtMin = Math.mulDiv(_usdtForLiquidity, MAX_BPS - _slippageBps, MAX_BPS);
        uint256 amountQorafiMin = Math.mulDiv(_qorafiAcquired, MAX_BPS - _slippageBps, MAX_BPS);

        usdtToken.safeIncreaseAllowance(address(router), _usdtForLiquidity);
        qorafiToken.safeIncreaseAllowance(address(router), _qorafiAcquired);

        (uint256 amountA, uint256 amountB, uint256 lpTokens) = router.addLiquidity(
            address(usdtToken), 
            address(qorafiToken), 
            _usdtForLiquidity, 
            _qorafiAcquired,
            amountUsdtMin, 
            amountQorafiMin, 
            msg.sender, 
            _deadline
        );

        usdtToken.safeDecreaseAllowance(address(router), _usdtForLiquidity);
        qorafiToken.safeDecreaseAllowance(address(router), _qorafiAcquired);

        require(lpTokens >= _minLiquidity, "BondingCurve: Insufficient LP tokens received");
        
        if (_usdtForLiquidity > amountA) {
            usdtToken.safeTransfer(msg.sender, _usdtForLiquidity - amountA);
        }
        if (_qorafiAcquired > amountB) {
            qorafiToken.safeTransfer(msg.sender, _qorafiAcquired - amountB);
        }

        emit LiquidityAdded(msg.sender, amountA, amountB, lpTokens);
        return lpTokens;
    }

    function _swapBNBToUSDT(uint256 _bnbAmount, uint256 _minUsdtOut, uint256 _deadline) internal returns (uint256) {
        require(_bnbAmount > 0, "Invalid BNB amount");
        
        address[] memory path = new address[](2);
        path[0] = router.WETH();
        path[1] = address(usdtToken);
        
        uint256[] memory amounts = router.swapExactETHForTokens{value: _bnbAmount}(
            _minUsdtOut, 
            path, 
            address(this), 
            _deadline
        );
        
        uint256 usdtReceived = amounts[amounts.length - 1];
        require(usdtReceived >= _minUsdtOut, "Insufficient USDT received");
        
        return usdtReceived;
    }

    function _swapTokenToUSDT(address _tokenIn, uint256 _amountIn, uint256 _minUsdtOut, uint256 _deadline) internal returns (uint256) {
        require(_amountIn > 0, "Invalid input amount");
        
        address[] memory path;
        if (_tokenIn == router.WETH()) {
            path = new address[](2);
            path[0] = _tokenIn;
            path[1] = address(usdtToken);
        } else {
            path = new address[](3);
            path[0] = _tokenIn;
            path[1] = router.WETH();
            path[2] = address(usdtToken);
        }

        uint256[] memory amounts = router.swapExactTokensForTokens(
            _amountIn, 
            _minUsdtOut, 
            path, 
            address(this), 
            _deadline
        );
        
        uint256 usdtReceived = amounts[amounts.length - 1];
        require(usdtReceived >= _minUsdtOut, "Insufficient USDT received");
        
        return usdtReceived;
    }

    function _getExpectedSwapOutput(uint256 _usdtIn) internal view returns (uint256) {
        if (_usdtIn == 0) return 0;
        
        address[] memory path = new address[](2);
        path[0] = address(usdtToken);
        path[1] = address(qorafiToken);
        
        try router.getAmountsOut(_usdtIn, path) returns (uint256[] memory amounts) {
            if (amounts.length >= 2 && amounts[amounts.length - 1] > 0) {
                return amounts[amounts.length - 1];
            }
            return 0;
        } catch {
            return 0;
        }
    }

    // --- VIEW FUNCTIONS ---
    function getOracleStatus() external view returns (
        bool primaryHealthy,
        bool secondaryActive,
        bool manualActive,
        uint256 primaryPrice,
        uint256 secondaryPrice,
        uint256 manualPrice_
    ) {
        bool _primaryHealthy = false;
        uint256 _primaryPrice = 0;
        bool _secondaryActive = false;
        uint256 _secondaryPrice = 0;

        if (address(oracle) != address(0)) {
            try oracle.isHealthy() returns (bool healthy) {
                _primaryHealthy = healthy;
                if (healthy) {
                    try oracle.getCurrentPrice() returns (uint256 price) {
                        _primaryPrice = price;
                    } catch {}
                }
            } catch {}
        }

        if (address(secondaryOracle) != address(0)) {
            try secondaryOracle.isActive() returns (bool active) {
                _secondaryActive = active;
                if (active) {
                    try secondaryOracle.getPrice() returns (uint256 price) {
                        _secondaryPrice = price;
                    } catch {}
                }
            } catch {}
        }

        return (
            _primaryHealthy,
            _secondaryActive,
            manualPriceActive && (block.timestamp - manualPriceTimestamp <= ORACLE_STALENESS_THRESHOLD),
            _primaryPrice,
            _secondaryPrice,
            manualPrice
        );
    }

    function getUserStatistics(address user) external view returns (
        uint256 depositCount,
        uint256 totalDeposited,
        uint256 lastDepositBlock,
        bool canDeposit
    ) {
        (bool _canDeposit,) = this.canUserDeposit(user, MIN_DEPOSIT_AMOUNT);
        return (
            userDepositCounts[user],
            userTotalDeposited[user],
            lastDepositBlock[user],
            _canDeposit
        );
    }

    function getProtocolStatistics() external view returns (
        uint256 totalDeposits,
        uint256 currentPrice,
        uint256 marketCap,
        bool oracleHealthy
    ) {
        uint256 _currentPrice = 0;
        uint256 _marketCap = 0;
        bool _healthy = false;

        try this._getReliablePrice() returns (uint256 price) {
            _currentPrice = price;
        } catch {}

        if (address(oracle) != address(0)) {
            try oracle.isHealthy() returns (bool healthy) {
                _healthy = healthy;
                if (healthy) {
                    try oracle.getCachedMarketCap() returns (uint256 cap) {
                        _marketCap = cap;
                    } catch {}
                }
            } catch {}
        }

        return (totalProtocolDeposits, _currentPrice, _marketCap, _healthy);
    }

    receive() external payable {}
}
