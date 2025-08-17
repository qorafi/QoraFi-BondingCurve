// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {IQoraFiToken} from "../interfaces/IQoraFiToken.sol";


// Minimal interfaces needed (no separate files)
interface IUniswapV2Router02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

/**
 * @title QoraFiToken
 * @notice Self-contained QoraFi token with bonding curve, vesting, and deadline system
 * @dev No external imports needed - everything in one contract like MoonshotToken
 */
contract QoraFiToken is ERC20Burnable, ReentrancyGuard, IQoraFiToken {
    
    // --- Enums and Structs imported from IQoraFiToken interface ---
    
    struct ConstructorParams {
        string name;
        string symbol;
        address creator;
        address treasury;
        address dexTreasury;
        address uniV2Router;
        uint256 totalSupply;
        uint256 virtualTokenReserves;
        uint256 virtualCollateralReserves;
        uint256 feeBasisPoints;
        uint256 dexFeeBasisPoints;
        uint256 migrationFeeFixed;
        uint256 poolCreationFee;
        uint256 mcLowerLimit;
        uint256 mcUpperLimit;
        uint256 tokensMigrationThreshold;
        uint256 deadlineDuration;
    }
    
    
    // --- Constants ---
    IQoraFiToken.CurveType public constant curveType = IQoraFiToken.CurveType.ConstantProductV1;
    uint256 public constant MAX_BPS = 10_000;
    uint256 private constant VESTING_DURATION = 7 days;
    uint256 private constant DAILY_VESTING_DURATION = 1 days;
    uint256 public constant DEADLINE_24H = 24 hours;
    uint256 public constant DEADLINE_48H = 48 hours;
    uint256 public constant DEADLINE_72H = 72 hours;

    // --- Core Token Parameters ---
    uint256 public initialTokenSupply;
    uint256 public virtualTokenReserves;
    uint256 public virtualCollateralReserves;
    uint256 public immutable virtualCollateralReservesInitial;

    // --- Fee Structure ---
    uint256 public immutable feeBPS;
    uint256 public immutable dexFeeBPS;

    // --- Market Cap Limits ---
    uint256 public immutable mcLowerLimit;
    uint256 public immutable mcUpperLimit;
    uint256 public immutable tokensMigrationThreshold;

    // --- Migration Fees ---
    uint256 public immutable fixedMigrationFee;
    uint256 public immutable poolCreationFee;

    // --- Key Addresses ---
    address public immutable creator;
    address public immutable pair;
    address public immutable treasury;
    address public immutable dexTreasury;
    address public immutable factory;

    // --- Trading Controls ---
    bool public tradingStopped;
    bool public sendingToPairNotAllowed = true;
    
    // --- Migration and Vesting State ---
    IQoraFiToken.TokenState public currentState = IQoraFiToken.TokenState.Active;
    uint256 public migrationTimestamp;
    uint256 public totalEthRaised;
    uint256 public launchDeadline;
    uint256 public immutable deadlineDuration;
    bool public saleCancelled;

    // --- Uniswap Integration ---
    IUniswapV2Router02 public immutable uniswapV2Router;

    // --- Buyer Tracking ---
    mapping(address => IQoraFiToken.BuyerInfo) private _buyers;
    address[] public buyersList;

    // --- Events (defined in interface) ---

    // --- Custom Errors ---
    error SaleNotActive();
    error SaleNotSucceeded();
    error MigrationHasNotOccurred();
    error SlippageCheckFailed();
    error NoTokensOwed();
    error InitialTokensAlreadyClaimed();
    error NoVestedTokensAvailable();
    error InvalidParameters();
    error AlreadyMigrated();
    error DeadlineExpired();
    error SaleCancelledError();
    error SaleNotCancelled();
    error NoRefundAvailable();
    error RefundAlreadyClaimed();
    error InvalidState();
    error TradingStopped();
    error OnlyFactory();
    error InsufficientTokenReserves();
    error NotEnoughtETHToBuyTokens();
    error FailedToSendETH();
    error MarketcapThresholdReached();
    error SendingToPairIsNotAllowedBeforeMigration();

    // --- Modifiers ---
    modifier buyChecks() {
        if (tradingStopped) revert TradingStopped();
        if (currentState != IQoraFiToken.TokenState.Active) revert SaleNotActive();
        _;
        _checkMcLower();
        _checkMcUpperLimit();
    }


    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory();
        _;
    }

    modifier onlyMigratedState() {
        if (currentState != IQoraFiToken.TokenState.Migrated) revert MigrationHasNotOccurred();
        _;
    }

    modifier notCancelled() {
        if (saleCancelled) revert SaleCancelledError();
        _;
    }

    /**
     * @notice Constructor - Initialize QoraFi token with all parameters
     */
    constructor(ConstructorParams memory _params) ERC20(_params.name, _params.symbol) {
        _mint(address(this), _params.totalSupply);

        initialTokenSupply = _params.totalSupply;
        virtualCollateralReserves = _params.virtualCollateralReserves;
        virtualCollateralReservesInitial = _params.virtualCollateralReserves;
        virtualTokenReserves = _params.virtualTokenReserves;

        creator = _params.creator;
        feeBPS = _params.feeBasisPoints;
        dexFeeBPS = _params.dexFeeBasisPoints;
        treasury = _params.treasury;
        dexTreasury = _params.dexTreasury;
        fixedMigrationFee = _params.migrationFeeFixed;
        poolCreationFee = _params.poolCreationFee;
        mcLowerLimit = _params.mcLowerLimit;
        mcUpperLimit = _params.mcUpperLimit;
        tokensMigrationThreshold = _params.tokensMigrationThreshold;

        // Set deadline
        deadlineDuration = _params.deadlineDuration;
        require(deadlineDuration == DEADLINE_24H || deadlineDuration == DEADLINE_48H || deadlineDuration == DEADLINE_72H, "Invalid deadline");
        launchDeadline = block.timestamp + deadlineDuration;

        uniswapV2Router = IUniswapV2Router02(_params.uniV2Router);
        factory = msg.sender;
        
        // Pre-calculate pair address
        (address token0, address token1) = address(this) < uniswapV2Router.WETH()
            ? (address(this), uniswapV2Router.WETH())
            : (uniswapV2Router.WETH(), address(this));

        pair = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            address(uniswapV2Router.factory()),
                            keccak256(abi.encodePacked(token0, token1)),
                            hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f"
                        )
                    )
                )
            )
        );
    }

    // --- Trading Functions ---

    /**
     * @notice Buy exact amount of tokens for ETH
     */
    function buyExactOut(
        address _buyer,
        uint256 _tokenAmount,
        uint256 _maxCollateralAmount
    ) external payable onlyFactory buyChecks notCancelled returns (uint256 collateralToPayWithFee, uint256 helioFee, uint256 dexFee) {
        _checkDeadline();
        
        if (balanceOf(address(this)) <= _tokenAmount) revert InsufficientTokenReserves();

        uint256 collateralToSpend = (_tokenAmount * virtualCollateralReserves) / (virtualTokenReserves - _tokenAmount);
        (helioFee, dexFee) = _calculateFee(collateralToSpend);
        collateralToPayWithFee = collateralToSpend + helioFee + dexFee;

        if (collateralToPayWithFee > _maxCollateralAmount) revert SlippageCheckFailed();
        
        _transferCollateral(treasury, helioFee);
        _transferCollateral(dexTreasury, dexFee);
        _updateBuyerInfo(_buyer, msg.value, _tokenAmount);

        virtualTokenReserves -= _tokenAmount;
        virtualCollateralReserves += collateralToSpend;
        totalEthRaised += collateralToSpend;

        uint256 refund;
        if (msg.value > collateralToPayWithFee) {
            refund = msg.value - collateralToPayWithFee;
            _transferCollateral(_buyer, refund);
        } else if (msg.value < collateralToPayWithFee) {
            revert NotEnoughtETHToBuyTokens();
        }

        emit TokensPurchased(_buyer, collateralToSpend, _tokenAmount, getMarketCap());
        
        if (getMarketCap() >= mcUpperLimit) {
            _transitionToSucceeded();
        }
    }

    /**
     * @notice Buy tokens with exact ETH amount
     */
    function buyExactIn(
        address _buyer,
        uint256 _amountOutMin
    ) external payable onlyFactory buyChecks notCancelled returns (uint256 collateralToPayWithFee, uint256 helioFee, uint256 dexFee) {
        _checkDeadline();
        
        collateralToPayWithFee = msg.value;
        (helioFee, dexFee) = _calculateFee(collateralToPayWithFee);
        uint256 collateralToSpendMinusFee = collateralToPayWithFee - helioFee - dexFee;

        _transferCollateral(treasury, helioFee);
        _transferCollateral(dexTreasury, dexFee);

        uint256 tokensOut = (collateralToSpendMinusFee * virtualTokenReserves) /
            (virtualCollateralReserves + collateralToSpendMinusFee);

        if (tokensOut < _amountOutMin) revert SlippageCheckFailed();
        if (balanceOf(address(this)) <= tokensOut) revert InsufficientTokenReserves();

        _updateBuyerInfo(_buyer, msg.value, tokensOut);

        virtualTokenReserves -= tokensOut;
        virtualCollateralReserves += collateralToSpendMinusFee;
        totalEthRaised += collateralToSpendMinusFee;

        emit TokensPurchased(_buyer, collateralToSpendMinusFee, tokensOut, getMarketCap());
        
        if (getMarketCap() >= mcUpperLimit) {
            _transitionToSucceeded();
        }
    }

    /**
     * @notice Simple buy function for factory compatibility
     */
    function buy(address _buyer) external payable onlyFactory {
        this.buyExactIn{value: msg.value}(_buyer, 0);
    }

    /**
     * @notice Sell functions (disabled during bonding curve)
     */
    function sellExactIn(uint256, uint256) external payable onlyFactory returns (uint256, uint256, uint256) {
        revert SaleNotActive(); // No selling during bonding curve
    }
    
    function sellExactOut(uint256, uint256) external payable onlyFactory returns (uint256, uint256, uint256, uint256) {
        revert SaleNotActive(); // No selling during bonding curve
    }

    // --- Deadline and Refund Functions ---

    /**
     * @notice Cancel sale manually (factory only)
     */
    function cancelSale() external onlyFactory {
        if (currentState == IQoraFiToken.TokenState.Migrated) revert AlreadyMigrated();
        saleCancelled = true;
        emit SaleCancelled(block.timestamp, "Manual cancellation");
    }

    /**
     * @notice Check deadline and auto-cancel if expired
     */
    function _checkDeadline() internal {
        if (block.timestamp > launchDeadline && currentState != IQoraFiToken.TokenState.Succeeded && currentState != IQoraFiToken.TokenState.Migrated) {
            saleCancelled = true;
            emit SaleCancelled(block.timestamp, "Deadline expired");
            revert DeadlineExpired();
        }
    }

    /**
     * @notice Manual deadline check
     */
    function checkAndCancelIfExpired() external {
        _checkDeadline();
    }

    /**
     * @notice Claim refund if sale cancelled
     */
    function claimRefund() external nonReentrant {
        if (!saleCancelled) revert SaleNotCancelled();
        
        IQoraFiToken.BuyerInfo storage buyerInfo = _buyers[msg.sender];
        if (buyerInfo.ethContributed == 0) revert NoRefundAvailable();
        if (buyerInfo.refundClaimed) revert RefundAlreadyClaimed();
        
        uint256 refundAmount = buyerInfo.ethContributed;
        buyerInfo.refundClaimed = true;
        
        _transferCollateral(msg.sender, refundAmount);
        emit RefundClaimed(msg.sender, refundAmount);
    }

    /**
     * @notice Emergency refund all buyers (factory only)
     */
    function emergencyRefundAll() external onlyFactory nonReentrant {
        if (!saleCancelled) revert SaleNotCancelled();
        
        for (uint256 i = 0; i < buyersList.length; i++) {
            address buyer = buyersList[i];
            IQoraFiToken.BuyerInfo storage buyerInfo = _buyers[buyer];
            
            if (buyerInfo.ethContributed > 0 && !buyerInfo.refundClaimed) {
                uint256 refundAmount = buyerInfo.ethContributed;
                buyerInfo.refundClaimed = true;
                
                _transferCollateral(buyer, refundAmount);
                emit RefundClaimed(buyer, refundAmount);
            }
        }
    }

    // --- Migration and Vesting Functions ---

    /**
     * @notice Migrate to Uniswap
     */
    function migrate() external onlyFactory returns (uint256 tokensToMigrate, uint256 tokensToBurn, uint256 collateralAmount) {
        if (currentState != IQoraFiToken.TokenState.Succeeded) revert SaleNotSucceeded();
        if (saleCancelled) revert SaleCancelledError();
        
        sendingToPairNotAllowed = false;

        if (IUniswapV2Factory(uniswapV2Router.factory()).getPair(address(this), uniswapV2Router.WETH()) == address(0)) {
            IUniswapV2Factory(uniswapV2Router.factory()).createPair(address(this), uniswapV2Router.WETH());
        }

        uint256 tokensRemaining = balanceOf(address(this));
        this.approve(address(uniswapV2Router), tokensRemaining);

        tokensToMigrate = _tokensToMigrate();
        tokensToBurn = tokensRemaining - tokensToMigrate;

        (uint256 treasuryFee, uint256 dexFee) = _splitFee(fixedMigrationFee);
        _transferCollateral(treasury, treasuryFee + poolCreationFee);
        _transferCollateral(dexTreasury, dexFee);

        _burn(address(this), tokensToBurn);
        collateralAmount = virtualCollateralReserves - virtualCollateralReservesInitial - treasuryFee - dexFee - poolCreationFee;

        (, , uint256 liquidity) = uniswapV2Router.addLiquidityETH{value: collateralAmount}(
            address(this),
            tokensToMigrate,
            tokensToMigrate,
            collateralAmount,
            address(this),
            block.timestamp + 300
        );

        if (address(this).balance > 0) {
            _transferCollateral(treasury, address(this).balance);
        }

        IERC20(pair).transfer(address(0), liquidity);
        
        migrationTimestamp = block.timestamp;
        currentState = IQoraFiToken.TokenState.Migrated;

        emit TokensMigrated(pair, tokensToMigrate, collateralAmount);
        emit StateChanged(IQoraFiToken.TokenState.Succeeded, IQoraFiToken.TokenState.Migrated);
    }

    /**
     * @notice Claim initial tokens (equal to investment value)
     */
    function claimInitialTokens() external onlyMigratedState nonReentrant {
        IQoraFiToken.BuyerInfo storage buyerInfo = _buyers[msg.sender];
        
        if (buyerInfo.ethContributed == 0) revert NoTokensOwed();
        if (buyerInfo.initialTokensClaimed) revert InitialTokensAlreadyClaimed();
        
        uint256 totalTokensAtMigration = buyerInfo.tokensOwed;
        uint256 immediateTokens = _calculateImmediateTokens(buyerInfo.ethContributed, totalTokensAtMigration);
        
        buyerInfo.initialTokensClaimed = true;
        buyerInfo.immediateTokensReceived = immediateTokens;
        
        _mint(msg.sender, immediateTokens);
        emit InitialTokensClaimed(msg.sender, immediateTokens);
    }

    /**
     * @notice Claim vested tokens (daily over 6 days)
     */
    function claimVestedTokens() external onlyMigratedState nonReentrant {
        IQoraFiToken.BuyerInfo storage buyerInfo = _buyers[msg.sender];
        
        if (buyerInfo.tokensOwed == 0) revert NoTokensOwed();
        if (!buyerInfo.initialTokensClaimed) revert InitialTokensAlreadyClaimed();
        
        uint256 availableVested = _calculateAvailableVestedTokens(msg.sender);
        if (availableVested == 0) revert NoVestedTokensAvailable();
        
        buyerInfo.vestedTokensClaimed += availableVested;
        
        _mint(msg.sender, availableVested);
        emit VestedTokensClaimed(msg.sender, availableVested);
    }

    // --- Internal Helper Functions ---

    function _updateBuyerInfo(address _buyer, uint256 _ethAmount, uint256 _tokenAmount) internal {
        IQoraFiToken.BuyerInfo storage buyerInfo = _buyers[_buyer];
        if (buyerInfo.ethContributed == 0) {
            buyersList.push(_buyer);
        }
        buyerInfo.ethContributed += _ethAmount;
        buyerInfo.tokensOwed += _tokenAmount;
    }

    function _calculateImmediateTokens(uint256 ethContributed, uint256 totalTokensOwed) internal view returns (uint256) {
        if (totalSupply() == 0) return 0;
        uint256 migrationPrice = address(this).balance / totalSupply();
        if (migrationPrice == 0) return totalTokensOwed;
        
        uint256 immediateTokens = (ethContributed * 1e18) / migrationPrice;
        
        if (immediateTokens > totalTokensOwed) {
            immediateTokens = totalTokensOwed;
        }
        
        return immediateTokens;
    }

    function _calculateAvailableVestedTokens(address buyer) internal view returns (uint256) {
        IQoraFiToken.BuyerInfo memory buyerInfo = _buyers[buyer];
        
        if (buyerInfo.tokensOwed == 0 || migrationTimestamp == 0 || !buyerInfo.initialTokensClaimed) {
            return 0;
        }
        
        uint256 remainingTokens = buyerInfo.tokensOwed - buyerInfo.immediateTokensReceived;
        
        if (remainingTokens == 0) {
            return 0;
        }
        
        uint256 timeElapsed = block.timestamp - migrationTimestamp;
        
        if (timeElapsed >= VESTING_DURATION) {
            return remainingTokens - buyerInfo.vestedTokensClaimed;
        } else {
            uint256 daysElapsed = timeElapsed / DAILY_VESTING_DURATION;
            uint256 tokensPerDay = remainingTokens / 6;
            uint256 availableVested = tokensPerDay * daysElapsed;
            
            return availableVested > buyerInfo.vestedTokensClaimed ? availableVested - buyerInfo.vestedTokensClaimed : 0;
        }
    }

    function _transitionToSucceeded() internal {
        IQoraFiToken.TokenState oldState = currentState;
        currentState = IQoraFiToken.TokenState.Succeeded;
        emit SaleSucceeded(getMarketCap(), totalEthRaised);
        emit StateChanged(oldState, IQoraFiToken.TokenState.Succeeded);
    }

    function _tokensToMigrate() internal view returns (uint256) {
        uint256 collateralDeductedFee = address(this).balance - fixedMigrationFee - poolCreationFee;
        if (virtualCollateralReserves == 0) return 0;
        return (virtualTokenReserves * collateralDeductedFee) / virtualCollateralReserves;
    }

    function _calculateFee(uint256 _amount) internal view returns (uint256 treasuryFee, uint256 dexFee) {
        treasuryFee = (_amount * feeBPS) / MAX_BPS;
        dexFee = (treasuryFee * dexFeeBPS) / MAX_BPS;
        treasuryFee -= dexFee;
    }

    function _splitFee(uint256 _feeAmount) internal view returns (uint256 treasuryFee, uint256 dexFee) {
        dexFee = (_feeAmount * dexFeeBPS) / MAX_BPS;
        treasuryFee = _feeAmount - dexFee;
    }

    function _transferCollateral(address _to, uint256 _amount) internal {
        if (_amount > 0) {
            (bool sent, ) = _to.call{value: _amount}("");
            if (!sent) revert FailedToSendETH();
        }
    }

    function _checkMcUpperLimit() internal view {
        uint256 mc = getMarketCap();
        if (mc > mcUpperLimit) revert MarketcapThresholdReached();
    }

    function _checkMcLower() internal {
        uint256 mc = getMarketCap();
        if (mc > mcLowerLimit) {
            tradingStopped = true;
        }
    }

    // --- View Functions ---

    function getMarketCap() public view returns (uint256) {
        if (virtualTokenReserves == 0) return 0;
        uint256 mc = (virtualCollateralReserves * 10 ** 18 * totalSupply()) / virtualTokenReserves;
        return mc / 10 ** 18;
    }

    function getState() external view returns (IQoraFiToken.TokenState) {
        return currentState;
    }

    function getBuyerInfo(address _buyer) external view returns (IQoraFiToken.BuyerInfo memory) {
        return _buyers[_buyer];
    }

    function buyers(address _buyer) external view returns (IQoraFiToken.BuyerInfo memory) {
        return _buyers[_buyer];
    }

    function getAvailableVestedTokens(address _buyer) external view returns (uint256) {
        return _calculateAvailableVestedTokens(_buyer);
    }

    function getTotalEthRaised() external view returns (uint256) {
        return totalEthRaised;
    }

    function hasSaleSucceeded() external view returns (bool) {
        return currentState == IQoraFiToken.TokenState.Succeeded || currentState == IQoraFiToken.TokenState.Migrated;
    }

    function getUniswapPair() external view returns (address) {
        return pair;
    }

    function getVestingInfo() external pure returns (uint256, uint256) {
        return (VESTING_DURATION, 0);
    }

    function getBondingCurveParams() external view returns (uint256, uint256, uint256) {
        return (virtualTokenReserves, virtualCollateralReserves, mcUpperLimit);
    }

    function getDeadlineInfo() external view returns (uint256 deadline, uint256 timeRemaining, bool isExpired, bool isCancelled) {
        deadline = launchDeadline;
        timeRemaining = block.timestamp >= launchDeadline ? 0 : launchDeadline - block.timestamp;
        isExpired = block.timestamp > launchDeadline;
        isCancelled = saleCancelled;
    }

    function canClaimRefund(address buyer) external view returns (bool canClaim, uint256 refundAmount) {
        if (!saleCancelled) return (false, 0);
        
        IQoraFiToken.BuyerInfo memory buyerInfo = _buyers[buyer];
        canClaim = buyerInfo.ethContributed > 0 && !buyerInfo.refundClaimed;
        refundAmount = canClaim ? buyerInfo.ethContributed : 0;
    }

    function getTotalRefundsAvailable() external view returns (uint256 totalRefunds, uint256 buyersWithRefunds) {
        if (!saleCancelled) return (0, 0);
        
        for (uint256 i = 0; i < buyersList.length; i++) {
            IQoraFiToken.BuyerInfo memory buyerInfo = _buyers[buyersList[i]];
            if (buyerInfo.ethContributed > 0 && !buyerInfo.refundClaimed) {
                totalRefunds += buyerInfo.ethContributed;
                buyersWithRefunds++;
            }
        }
    }

    function getCurveProgressBps() external view returns (uint256) {
        if (tokensMigrationThreshold == 0) return 0;
        uint256 progress = ((initialTokenSupply - balanceOf(address(this))) * MAX_BPS) / tokensMigrationThreshold;
        return progress < 100 ? 100 : (progress > MAX_BPS ? MAX_BPS : progress);
    }

    function getBuyersList() external view returns (address[] memory) {
        return buyersList;
    }

    function getBuyersCount() external view returns (uint256) {
        return buyersList.length;
    }

    function getTokensForEth(uint256 _ethAmount) external view returns (uint256, uint256) {
        (uint256 helioFee, uint256 dexFee) = _calculateFee(_ethAmount);
        uint256 collateralToSpendMinusFee = _ethAmount - helioFee - dexFee;
        
        if (virtualCollateralReserves == 0 || virtualTokenReserves == 0) return (0, 0);
        
        uint256 tokensOut = (collateralToSpendMinusFee * virtualTokenReserves) /
            (virtualCollateralReserves + collateralToSpendMinusFee);
            
        return (tokensOut, getMarketCap());
    }

    function getAmountOutAndFee(uint256 _amountIn, uint256 _reserveIn, uint256 _reserveOut, bool _paymentTokenIsIn) external view returns (uint256 amountOut, uint256 fee) {
        if (_paymentTokenIsIn) {
            (uint256 helioFee, uint256 dexFee) = _calculateFee(_amountIn);
            fee = helioFee + dexFee;
            if (_reserveIn == 0) return (0, fee);
            amountOut = (_amountIn * _reserveOut) / (_reserveIn + _amountIn);
        } else {
            if (_reserveIn == 0) return (0, 0);
            amountOut = (_amountIn * _reserveOut) / (_reserveIn + _amountIn);
            (uint256 helioFee, uint256 dexFee) = _calculateFee(amountOut);
            fee = helioFee + dexFee;
        }
    }

    function getAmountInAndFee(uint256 _amountOut, uint256 _reserveIn, uint256 _reserveOut, bool _paymentTokenIsOut) external view returns (uint256 amountIn, uint256 fee) {
        if (_paymentTokenIsOut) {
            (uint256 helioFee, uint256 dexFee) = _calculateFee(_amountOut);
            fee = helioFee + dexFee;
            if (_reserveOut == 0 || _reserveOut <= _amountOut) return (0, fee);
            amountIn = (_amountOut * _reserveIn) / (_reserveOut - _amountOut);
        } else {
            if (_reserveOut == 0 || _reserveOut <= _amountOut) return (0, 0);
            amountIn = (_amountOut * _reserveIn) / (_reserveOut - _amountOut);
            (uint256 helioFee, uint256 dexFee) = _calculateFee(amountIn);
            fee = helioFee + dexFee;
        }
    }

    // --- Transfer restrictions ---
    function transfer(address to, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        if (to == pair && sendingToPairNotAllowed) revert SendingToPairIsNotAllowedBeforeMigration();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override(ERC20, IERC20) returns (bool) {
        if (to == pair && sendingToPairNotAllowed) revert SendingToPairIsNotAllowedBeforeMigration();
        return super.transferFrom(from, to, amount);
    }
}