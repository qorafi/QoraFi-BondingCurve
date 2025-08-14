// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

// --- INTERFACES ---
interface IOracle {
    function getUsdValue(address _token, uint256 _amount) external view returns (uint256);
    function updateAndGetUsdValue(address _token, uint256 _amount) external returns (uint256);
    function isStale(address _token) external view returns (bool);
    function getLastUpdateTime(address _token) external view returns (uint256);
}

interface IRewardManager {
    function handleCollateralChange(address _user, int256 _usdValueChange) external;
}

// --- TOKEN CONTRACT ---
contract USQ is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    constructor() ERC20("QoraFi Stablecoin", "USQ") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(from, amount);
    }
}

// --- PARAMETER VALIDATOR ---
contract ParameterValidator {
    function validateLiquidationThreshold(uint256 _threshold) internal pure {
        require(_threshold >= 110 && _threshold <= 200, "Threshold must be 110-200%");
    }
    
    function validateDebtCeiling(uint256 _ceiling) internal pure {
        require(_ceiling >= 10000 * 1e18 && _ceiling <= 1000000000 * 1e18, "Debt ceiling out of range");
    }
    
    function validateLiquidationBonusBPS(uint256 _bonus) internal pure {
        require(_bonus >= 100 && _bonus <= 2000, "Bonus must be 1-20%");
    }

    function validateStabilityFeeRate(uint256 _rate) internal pure {
        require(_rate <= 1000, "Stability fee rate too high (max 10%)");
    }
}

// --- MAIN ENGINE CONTRACT ---
contract USQEngine is AccessControl, ReentrancyGuard, Pausable, ParameterValidator {
    using SafeERC20 for IERC20;
    using SafeERC20 for USQ;

    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant COLLATERAL_MANAGER_ROLE = keccak256("COLLATERAL_MANAGER_ROLE");
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // Define the role constants locally to avoid external access issues
    bytes32 private constant USQ_MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 private constant USQ_BURNER_ROLE = keccak256("BURNER_ROLE");

    // --- STRUCTS ---
    struct CollateralInfo {
        address token;
        uint128 liquidationThreshold;
        uint128 debtCeiling;
        uint256 totalDebtMinted;
        uint256 stabilityFeeRate;
        uint256 lastFeeAccrual;
        uint256 feeAccumulator;
        bool isEnabled;
    }

    struct DynamicLiquidationParams {
        uint256 baseBonus;
        uint256 maxUrgencyBonus;
        uint256 maxSizeBonus;
        uint256 minHealthFactorForUrgency;
    }

    struct RateLimit {
        uint256 amount;
        uint256 resetTime;
    }
    
    struct EmergencyState {
        bool globalSettlement;
        uint256 settlementPrice;
        uint256 settlementTime;
    }

    // --- STATE VARIABLES ---
    USQ public immutable usq;
    IOracle public oracle;
    IRewardManager public rewardManager;
    address public treasuryAddress;
    TimelockController public timelock;
    
    address[] public collateralTokens;
    mapping(address => CollateralInfo) public collateralInfo;
    mapping(address => uint256) private collateralTokenIndex;

    mapping(address => mapping(address => uint256)) public collateralDeposited;
    mapping(address => uint256) public usqMinted;
    mapping(address => RateLimit) public userMintLimits;
    mapping(address => RateLimit) public userWithdrawLimits;

    // Protocol-wide safety
    uint256 public globalDebtCeiling;
    uint256 public totalUSQMinted;
    uint256 public totalBadDebt;
    uint256 public protocolRevenue;

    // Governance Parameters
    DynamicLiquidationParams public liquidationParams;
    uint256 public maxLiquidationPercentage;
    
    // Emergency & Pausing
    EmergencyState public emergencyState;
    bool public mintingPaused;
    bool public withdrawalsPaused;
    bool public liquidationsPaused;
    
    // Rate Limiting
    uint256 public constant RATE_LIMIT_WINDOW = 24 hours;
    uint256 public constant MAX_MINT_PER_DAY = 50000 * 1e18;
    uint256 public constant MAX_WITHDRAW_PER_DAY = 100000 * 1e18;

    // Caching System
    mapping(address => uint256) private _cachedCollateralValues;
    mapping(address => uint256) private _cacheTimestamp;
    uint256 public constant CACHE_DURATION = 5 minutes;
    
    uint256 public constant HEALTH_FACTOR_PRECISION = 1e18;
    
    // Flash Loan Protection
    mapping(address => uint256) private lastInteractionBlock;
    
    // --- EVENTS ---
    event CollateralAdded(address indexed token, uint256 liquidationThreshold, uint256 debtCeiling, uint256 stabilityFeeRate);
    event CollateralRemoved(address indexed token);
    event LiquidationParametersUpdated(uint256 baseBonus, uint256 maxUrgencyBonus, uint256 maxSizeBonus);
    event GlobalDebtCeilingUpdated(uint256 newCeiling);
    event BadDebtRecorded(address indexed user, uint256 amount);
    event TimelockSet(address indexed timelockAddress);
    event OracleSet(address indexed oracleAddress);
    event RewardManagerSet(address indexed rewardManagerAddress);
    event CollateralDeposited(address indexed user, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed user, address indexed token, uint256 amount);
    event USQMinted(address indexed user, uint256 amount, address indexed againstCollateral);
    event USQRepaid(address indexed user, uint256 amount, address indexed fromCollateral);
    event Liquidated(address indexed liquidator, address indexed user, address indexed collateralSeized, uint256 debtCovered, uint256 collateralAmountSeized);
    event TreasuryAddressUpdated(address newTreasury);
    event CollateralDebtCeilingUpdated(address indexed token, uint256 newCeiling);
    event StabilityFeeAccrued(address indexed token, uint256 feeAmount, uint256 newAccumulator);
    event EmergencyShutdownInitiated(uint256 settlementPrice);

    constructor(address _initialTreasuryAddress) {
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(COLLATERAL_MANAGER_ROLE, msg.sender);
        _grantRole(LIQUIDATOR_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        usq = new USQ();
        treasuryAddress = _initialTreasuryAddress;
        
        // FIXED: Use local constants instead of trying to access USQ contract constants
        usq.grantRole(USQ_MINTER_ROLE, address(this));
        usq.grantRole(USQ_BURNER_ROLE, address(this));

        liquidationParams = DynamicLiquidationParams({
            baseBonus: 1000,
            maxUrgencyBonus: 500,
            maxSizeBonus: 200,
            minHealthFactorForUrgency: HEALTH_FACTOR_PRECISION / 2
        });
        maxLiquidationPercentage = 5000;
        globalDebtCeiling = 100_000_000 * 1e18;
    }

    // --- MODIFIERS ---
    modifier notInEmergencyShutdown() {
        require(!emergencyState.globalSettlement, "Global settlement active");
        _;
    }
    
    modifier rateLimitedMint(uint256 _amount) {
        RateLimit storage limit = userMintLimits[msg.sender];
        if (block.timestamp > limit.resetTime + RATE_LIMIT_WINDOW) {
            limit.amount = 0;
            limit.resetTime = block.timestamp;
        }
        require(limit.amount + _amount <= MAX_MINT_PER_DAY, "Daily mint limit exceeded");
        _;
        limit.amount += _amount;
    }

    modifier rateLimitedWithdraw(uint256 _usdValue) {
        RateLimit storage limit = userWithdrawLimits[msg.sender];
        if (block.timestamp > limit.resetTime + RATE_LIMIT_WINDOW) {
            limit.amount = 0;
            limit.resetTime = block.timestamp;
        }
        require(limit.amount + _usdValue <= MAX_WITHDRAW_PER_DAY, "Daily withdrawal limit exceeded");
        _;
        limit.amount += _usdValue;
    }

    modifier flashLoanProtection() {
        require(block.number > lastInteractionBlock[msg.sender], "Flash loan protection: one action per block");
        _;
        lastInteractionBlock[msg.sender] = block.number;
    }

    modifier validOracle(address _token) {
        require(!oracle.isStale(_token), "Oracle data is stale");
        _;
    }

    // --- GOVERNANCE FUNCTIONS ---
    function setTimelock(address _timelock) external onlyRole(GOVERNANCE_ROLE) {
        require(address(timelock) == address(0), "Timelock already set");
        require(_timelock != address(0), "Invalid timelock address");
        timelock = TimelockController(payable(_timelock));
        grantRole(GOVERNANCE_ROLE, _timelock);
        emit TimelockSet(_timelock);
    }

    function finalizeGovernanceTransfer() external onlyRole(GOVERNANCE_ROLE) {
        require(address(timelock) != address(0), "Timelock not set");
        renounceRole(GOVERNANCE_ROLE, msg.sender);
    }
    
    function setOracle(address _oracleAddress) external onlyRole(GOVERNANCE_ROLE) {
        require(_oracleAddress != address(0), "Invalid address");
        oracle = IOracle(_oracleAddress);
        emit OracleSet(_oracleAddress);
    }

    function setRewardManager(address _rewardManagerAddress) external onlyRole(GOVERNANCE_ROLE) {
        require(_rewardManagerAddress != address(0), "Invalid address");
        rewardManager = IRewardManager(_rewardManagerAddress);
        emit RewardManagerSet(_rewardManagerAddress);
    }

    function setTreasuryAddress(address _newTreasury) external onlyRole(GOVERNANCE_ROLE) {
        require(_newTreasury != address(0), "Invalid address");
        treasuryAddress = _newTreasury;
        emit TreasuryAddressUpdated(_newTreasury);
    }

    function addCollateral(address _token, uint128 _liquidationThreshold, uint128 _debtCeiling, uint256 _stabilityFeeRate) external onlyRole(COLLATERAL_MANAGER_ROLE) {
        require(_token != address(0), "Invalid token");
        validateLiquidationThreshold(_liquidationThreshold);
        validateDebtCeiling(_debtCeiling);
        validateStabilityFeeRate(_stabilityFeeRate);
        require(!collateralInfo[_token].isEnabled, "Already enabled");

        collateralTokenIndex[_token] = collateralTokens.length;
        collateralTokens.push(_token);
        collateralInfo[_token] = CollateralInfo({
            token: _token,
            liquidationThreshold: _liquidationThreshold,
            debtCeiling: _debtCeiling,
            totalDebtMinted: 0,
            stabilityFeeRate: _stabilityFeeRate,
            lastFeeAccrual: block.timestamp,
            feeAccumulator: 1e18,
            isEnabled: true
        });

        emit CollateralAdded(_token, _liquidationThreshold, _debtCeiling, _stabilityFeeRate);
    }

    function removeCollateral(address _token) external onlyRole(COLLATERAL_MANAGER_ROLE) {
        require(collateralInfo[_token].isEnabled, "Not enabled");
        collateralInfo[_token].isEnabled = false;

        uint256 indexToRemove = collateralTokenIndex[_token];
        address lastToken = collateralTokens[collateralTokens.length - 1];
        
        collateralTokens[indexToRemove] = lastToken;
        collateralTokenIndex[lastToken] = indexToRemove;
        
        collateralTokens.pop();
        delete collateralTokenIndex[_token];

        emit CollateralRemoved(_token);
    }

    function setDebtCeiling(address _token, uint128 _newCeiling) external onlyRole(COLLATERAL_MANAGER_ROLE) {
        require(collateralInfo[_token].isEnabled, "Not enabled");
        validateDebtCeiling(_newCeiling);
        collateralInfo[_token].debtCeiling = _newCeiling;
        emit CollateralDebtCeilingUpdated(_token, _newCeiling);
    }

    function setLiquidationParameters(uint256 _baseBonus, uint256 _maxUrgencyBonus, uint256 _maxSizeBonus) external onlyRole(GOVERNANCE_ROLE) {
        validateLiquidationBonusBPS(_baseBonus);
        require(_maxUrgencyBonus <= 1000, "Max urgency bonus too high");
        require(_maxSizeBonus <= 500, "Max size bonus too high");
        
        liquidationParams.baseBonus = _baseBonus;
        liquidationParams.maxUrgencyBonus = _maxUrgencyBonus;
        liquidationParams.maxSizeBonus = _maxSizeBonus;
        emit LiquidationParametersUpdated(_baseBonus, _maxUrgencyBonus, _maxSizeBonus);
    }

    function setGlobalDebtCeiling(uint256 _newCeiling) external onlyRole(GOVERNANCE_ROLE) {
        require(_newCeiling >= totalUSQMinted, "Ceiling below current debt");
        globalDebtCeiling = _newCeiling;
        emit GlobalDebtCeilingUpdated(_newCeiling);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // --- CORE USER FUNCTIONS ---
    function depositCollateral(address _collateralToken, uint256 _amount) external nonReentrant whenNotPaused notInEmergencyShutdown flashLoanProtection {
        require(_amount > 0, "Amount must be > 0");
        require(collateralInfo[_collateralToken].isEnabled, "Collateral not enabled");
        
        accrueStabilityFee(_collateralToken);
        
        if (address(rewardManager) != address(0)) {
            uint256 usdValue = oracle.getUsdValue(_collateralToken, _amount);
            rewardManager.handleCollateralChange(msg.sender, int256(usdValue));
        }
        
        IERC20(_collateralToken).safeTransferFrom(msg.sender, address(this), _amount);
        collateralDeposited[msg.sender][_collateralToken] += _amount;
        _invalidateCache(msg.sender);
        emit CollateralDeposited(msg.sender, _collateralToken, _amount);
    }

    function withdrawCollateral(address _collateralToken, uint256 _amount) external nonReentrant whenNotPaused notInEmergencyShutdown flashLoanProtection rateLimitedWithdraw(oracle.getUsdValue(_collateralToken, _amount)) {
        require(_amount > 0, "Amount must be > 0");
        uint256 currentBalance = collateralDeposited[msg.sender][_collateralToken];
        require(_amount <= currentBalance, "Not enough collateral");
        
        accrueStabilityFee(_collateralToken);
        
        uint256 usdValue = oracle.getUsdValue(_collateralToken, _amount);
        if (address(rewardManager) != address(0)) {
            rewardManager.handleCollateralChange(msg.sender, -int256(usdValue));
        }
        
        uint256 newBalance = currentBalance - _amount;
        uint256 newTotalCollateralValue = getTotalCollateralValueInUsd(msg.sender) - usdValue;

        uint256 debtValue = usqMinted[msg.sender];
        if (debtValue > 0) {
            uint256 averageThreshold = _getAverageLiquidationThreshold(msg.sender, newTotalCollateralValue);
            uint256 newCollateralRatio = Math.mulDiv(newTotalCollateralValue, 100, debtValue);
            require(Math.mulDiv(newCollateralRatio, HEALTH_FACTOR_PRECISION, averageThreshold) >= HEALTH_FACTOR_PRECISION, "Unhealthy position");
        }
        
        collateralDeposited[msg.sender][_collateralToken] = newBalance;
        _invalidateCache(msg.sender);
        IERC20(_collateralToken).safeTransfer(msg.sender, _amount);
        emit CollateralWithdrawn(msg.sender, _collateralToken, _amount);
    }
    
    function mintUSQ(uint256 _amount, address _againstCollateral) external nonReentrant whenNotPaused notInEmergencyShutdown flashLoanProtection rateLimitedMint(_amount) {
        require(_amount > 0, "Amount must be > 0");
        require(collateralInfo[_againstCollateral].isEnabled, "Collateral not enabled");
        require(collateralDeposited[msg.sender][_againstCollateral] > 0, "No collateral of this type");
        
        accrueStabilityFee(_againstCollateral);
        
        require(totalUSQMinted + _amount <= globalDebtCeiling, "Global debt ceiling reached");
        
        CollateralInfo storage info = collateralInfo[_againstCollateral];
        uint256 newTotalDebt = info.totalDebtMinted + _amount;
        require(newTotalDebt <= info.debtCeiling, "Collateral debt ceiling reached");
        
        usqMinted[msg.sender] += _amount;
        totalUSQMinted += _amount;
        
        require(getHealthFactor(msg.sender) >= HEALTH_FACTOR_PRECISION, "Unhealthy position");
        
        info.totalDebtMinted = newTotalDebt;
        usq.mint(msg.sender, _amount);
        _invalidateCache(msg.sender);
        emit USQMinted(msg.sender, _amount, _againstCollateral);
    }

    function repayUSQ(uint256 _amount, address _fromCollateral) external nonReentrant whenNotPaused notInEmergencyShutdown {
        require(_amount > 0, "Amount must be > 0");
        require(usqMinted[msg.sender] >= _amount, "Repay amount exceeds debt");
        require(collateralInfo[_fromCollateral].isEnabled, "Collateral not enabled");
        
        accrueStabilityFee(_fromCollateral);
        
        usq.safeTransferFrom(msg.sender, address(this), _amount);
        usq.burn(address(this), _amount);
        
        usqMinted[msg.sender] -= _amount;
        collateralInfo[_fromCollateral].totalDebtMinted -= _amount;
        totalUSQMinted -= _amount;
        _invalidateCache(msg.sender);
        emit USQRepaid(msg.sender, _amount, _fromCollateral);
    }

    function liquidate(address _user, address _collateralToSeize, uint256 _debtToCover) external nonReentrant whenNotPaused notInEmergencyShutdown onlyRole(LIQUIDATOR_ROLE) {
        require(getHealthFactor(_user) < HEALTH_FACTOR_PRECISION, "Position not liquidatable");
        require(_debtToCover > 0 && _debtToCover <= usqMinted[_user], "Invalid debt amount");
        
        uint256 maxLiquidatable = (usqMinted[_user] * maxLiquidationPercentage) / 10000;
        require(_debtToCover <= maxLiquidatable, "Exceeds max liquidation amount");
        
        accrueStabilityFee(_collateralToSeize);
        
        uint256 collateralPrice;
        try oracle.updateAndGetUsdValue(_collateralToSeize, 10**IERC20Metadata(_collateralToSeize).decimals()) returns (uint256 price) {
            collateralPrice = price;
        } catch {
            revert("Oracle failure - liquidation suspended");
        }
        
        uint256 dynamicBonus = calculateDynamicLiquidationBonus(_user, _debtToCover, getHealthFactor(_user));
        uint256 collateralNeeded = Math.mulDiv(Math.mulDiv(_debtToCover, 10000 + dynamicBonus, 10000), 10**IERC20Metadata(_collateralToSeize).decimals(), collateralPrice);
        
        uint256 availableCollateral = collateralDeposited[_user][_collateralToSeize];
        if (availableCollateral < collateralNeeded) {
            uint256 collateralValue = oracle.getUsdValue(_collateralToSeize, availableCollateral);
            uint256 debtCoveredByCollateral = collateralValue;
            if (debtCoveredByCollateral < _debtToCover) {
                uint256 badDebt = _debtToCover - debtCoveredByCollateral;
                totalBadDebt += badDebt;
                emit BadDebtRecorded(_user, badDebt);
                _debtToCover = debtCoveredByCollateral;
            }
            collateralNeeded = availableCollateral;
        }

        if (address(rewardManager) != address(0)) {
            uint256 usdValue = oracle.getUsdValue(_collateralToSeize, collateralNeeded);
            rewardManager.handleCollateralChange(_user, -int256(usdValue));
        }

        usq.safeTransferFrom(msg.sender, address(this), _debtToCover);
        usq.burn(address(this), _debtToCover);
        
        usqMinted[_user] -= _debtToCover;
        collateralDeposited[_user][_collateralToSeize] -= collateralNeeded;
        collateralInfo[_collateralToSeize].totalDebtMinted -= _debtToCover;
        
        _invalidateCache(_user);
        IERC20(_collateralToSeize).safeTransfer(msg.sender, collateralNeeded);
        emit Liquidated(msg.sender, _user, _collateralToSeize, _debtToCover, collateralNeeded);
    }

    // --- EMERGENCY FUNCTIONS ---
    function initializeEmergencyShutdown() external onlyRole(EMERGENCY_ROLE) {
        require(!emergencyState.globalSettlement, "Already in emergency shutdown");
        
        uint256 totalCollateralValue = 0;
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            address token = collateralTokens[i];
            uint256 tokenBalance = IERC20(token).balanceOf(address(this));
            totalCollateralValue += oracle.getUsdValue(token, tokenBalance);
        }
        
        uint256 settlementPrice = totalUSQMinted > 0 ? Math.mulDiv(totalCollateralValue, 1e18, totalUSQMinted) : 1e18;
        
        emergencyState.globalSettlement = true;
        emergencyState.settlementPrice = settlementPrice;
        emergencyState.settlementTime = block.timestamp;
        
        _pause();
        
        emit EmergencyShutdownInitiated(settlementPrice);
    }

    function emergencySettlePosition() external nonReentrant {
        require(emergencyState.globalSettlement, "Not in emergency settlement");
        uint256 userDebt = usqMinted[msg.sender];
        require(userDebt > 0, "No debt to settle");
        
        uint256 settlementValue = Math.mulDiv(userDebt, emergencyState.settlementPrice, 1e18);
        
        usq.safeTransferFrom(msg.sender, address(this), userDebt);
        usq.burn(address(this), userDebt);
        
        usqMinted[msg.sender] = 0;
        totalUSQMinted -= userDebt;
        
        for (uint i = 0; i < collateralTokens.length; i++) {
            address token = collateralTokens[i];
            uint256 totalToken = IERC20(token).balanceOf(address(this));
            uint256 userShare = Math.mulDiv(totalToken, settlementValue, totalUSQMinted + userDebt);
            if (userShare > 0) {
                IERC20(token).safeTransfer(msg.sender, userShare);
            }
        }
        _invalidateCache(msg.sender);
    }

    // --- VIEW FUNCTIONS ---
    
    function getHealthFactor(address _user) public view returns (uint256) {
        uint256 totalCollateralValue = getTotalCollateralValueInUsd(_user);
        uint256 debtValue = usqMinted[_user];
        if (debtValue == 0) return type(uint256).max;
        uint256 averageLiquidationThreshold = _getAverageLiquidationThreshold(_user, totalCollateralValue);
        if (averageLiquidationThreshold == 0) return type(uint256).max;
        uint256 collateralRatio = Math.mulDiv(totalCollateralValue, 100, debtValue);
        return Math.mulDiv(collateralRatio, HEALTH_FACTOR_PRECISION, averageLiquidationThreshold);
    }
    
    function _getAverageLiquidationThreshold(address _user, uint256 _totalCollateralValue) internal view returns (uint256) {
        if (_totalCollateralValue == 0) return 0;
        uint256 weightedTotalThreshold = 0;
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            address token = collateralTokens[i];
            uint256 amount = collateralDeposited[_user][token];
            if (amount > 0) {
                uint256 value = oracle.getUsdValue(token, amount);
                weightedTotalThreshold += value * collateralInfo[token].liquidationThreshold;
            }
        }
        return weightedTotalThreshold / _totalCollateralValue;
    }

    function getTotalCollateralValueInUsd(address _user) public view returns (uint256) {
        (uint256 cachedValue, bool isValid) = _getCachedCollateralValue(_user);
        if (isValid) return cachedValue;

        uint256 totalValue = 0;
        for (uint256 i = 0; i < collateralTokens.length; i++) {
            address token = collateralTokens[i];
            uint256 amount = collateralDeposited[_user][token];
            if (amount > 0) {
                totalValue += oracle.getUsdValue(token, amount);
            }
        }
        // This function is view, so it cannot update state. Caching must be done in state-changing functions.
        return totalValue;
    }

    function calculateDynamicLiquidationBonus(address /*_user*/, uint256 _debtAmount, uint256 _healthFactor) public view returns (uint256) {
        uint256 bonus = liquidationParams.baseBonus;
        
        if (_healthFactor < liquidationParams.minHealthFactorForUrgency) {
            uint256 urgencyMultiplier = Math.mulDiv(
                liquidationParams.minHealthFactorForUrgency - _healthFactor,
                liquidationParams.maxUrgencyBonus,
                liquidationParams.minHealthFactorForUrgency
            );
            bonus += urgencyMultiplier;
        }
        
        if (_debtAmount > 100000 * 1e18) {
            uint256 sizeMultiplier = Math.min(
                Math.mulDiv(_debtAmount, liquidationParams.maxSizeBonus, 1000000 * 1e18),
                liquidationParams.maxSizeBonus
            );
            bonus += sizeMultiplier;
        }
        
        return bonus;
    }

    function accrueStabilityFee(address _collateralToken) public {
        CollateralInfo storage info = collateralInfo[_collateralToken];
        require(info.isEnabled, "Collateral not enabled");
        
        uint256 timeElapsed = block.timestamp - info.lastFeeAccrual;
        
        if (timeElapsed > 0 && info.stabilityFeeRate > 0) {
            uint256 feeRate = info.stabilityFeeRate * timeElapsed / 365 days;
            uint256 newAccumulator = Math.mulDiv(info.feeAccumulator, 1e18 + feeRate, 1e18);
            
            uint256 feeAmount = Math.mulDiv(
                info.totalDebtMinted, 
                newAccumulator - info.feeAccumulator, 
                1e18
            );
            
            if (feeAmount > 0) {
                protocolRevenue += feeAmount;
                info.totalDebtMinted += feeAmount;
                totalUSQMinted += feeAmount;
                usq.mint(treasuryAddress, feeAmount);
            }
            
            info.feeAccumulator = newAccumulator;
            info.lastFeeAccrual = block.timestamp;
            
            emit StabilityFeeAccrued(_collateralToken, feeAmount, newAccumulator);
        }
    }

    // --- Caching Functions ---
    function _getCachedCollateralValue(address _user) internal view returns (uint256, bool) {
        if (block.timestamp <= _cacheTimestamp[_user] + CACHE_DURATION) {
            return (_cachedCollateralValues[_user], true);
        }
        return (0, false);
    }

    function _updateCachedCollateralValue(address _user, uint256 _value) internal {
        _cachedCollateralValues[_user] = _value;
        _cacheTimestamp[_user] = block.timestamp;
    }

    function _invalidateCache(address _user) internal {
        _cacheTimestamp[_user] = 0;
    }

    receive() external payable {}
}