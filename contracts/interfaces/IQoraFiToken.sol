// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IQoraFiToken
 * @notice Interface for QoraFi token with bonding curve, vesting, and deadline system
 */
interface IQoraFiToken is IERC20 {
    
    // --- Enums ---
    enum TokenState { Active, Succeeded, Migrated }
    enum CurveType { ConstantProductV1 }
    
    // --- Structs ---
    struct BuyerInfo {
        uint256 ethContributed;
        uint256 tokensOwed;
        bool initialTokensClaimed;
        uint256 immediateTokensReceived;
        uint256 vestedTokensClaimed;
        bool refundClaimed;
    }
    
    // --- Events ---
    event TokensPurchased(address indexed buyer, uint256 ethAmount, uint256 tokenAmount, uint256 newMarketCap);
    event SaleSucceeded(uint256 finalMarketCap, uint256 totalEthRaised);
    event TokensMigrated(address indexed uniswapPair, uint256 liquidityTokens, uint256 liquidityEth);
    event InitialTokensClaimed(address indexed buyer, uint256 amount);
    event VestedTokensClaimed(address indexed buyer, uint256 amount);
    event StateChanged(TokenState indexed oldState, TokenState indexed newState);
    event SaleCancelled(uint256 timestamp, string reason);
    event RefundClaimed(address indexed buyer, uint256 amount);

    // --- Trading Functions ---
    function buyExactOut(
        address _buyer,
        uint256 _tokenAmount,
        uint256 _maxCollateralAmount
    ) external payable returns (uint256 collateralToPayWithFee, uint256 helioFee, uint256 dexFee);

    function buyExactIn(
        address _buyer,
        uint256 _amountOutMin
    ) external payable returns (uint256 collateralToPayWithFee, uint256 helioFee, uint256 dexFee);

    function buy(address _buyer) external payable;

    function sellExactIn(uint256, uint256) external payable returns (uint256, uint256, uint256);
    
    function sellExactOut(uint256, uint256) external payable returns (uint256, uint256, uint256, uint256);

    // --- Deadline and Refund Functions ---
    function cancelSale() external;
    function checkAndCancelIfExpired() external;
    function claimRefund() external;
    function emergencyRefundAll() external;

    // --- Migration and Vesting Functions ---
    function migrate() external returns (uint256 tokensToMigrate, uint256 tokensToBurn, uint256 collateralAmount);
    function claimInitialTokens() external;
    function claimVestedTokens() external;

    // --- View Functions ---
    function getMarketCap() external view returns (uint256);
    function getState() external view returns (TokenState);
    function getBuyerInfo(address _buyer) external view returns (BuyerInfo memory);
    function getAvailableVestedTokens(address _buyer) external view returns (uint256);
    function getTotalEthRaised() external view returns (uint256);
    function hasSaleSucceeded() external view returns (bool);
    function getUniswapPair() external view returns (address);
    function getVestingInfo() external pure returns (uint256, uint256);
    function getBondingCurveParams() external view returns (uint256, uint256, uint256);
    function getDeadlineInfo() external view returns (uint256 deadline, uint256 timeRemaining, bool isExpired, bool isCancelled);
    function canClaimRefund(address buyer) external view returns (bool canClaim, uint256 refundAmount);
    function getTotalRefundsAvailable() external view returns (uint256 totalRefunds, uint256 buyersWithRefunds);
    function getCurveProgressBps() external view returns (uint256);
    function getBuyersList() external view returns (address[] memory);
    function getBuyersCount() external view returns (uint256);
    function getTokensForEth(uint256 _ethAmount) external view returns (uint256, uint256);
    function getAmountOutAndFee(uint256 _amountIn, uint256 _reserveIn, uint256 _reserveOut, bool _paymentTokenIsIn) external view returns (uint256 amountOut, uint256 fee);
    function getAmountInAndFee(uint256 _amountOut, uint256 _reserveIn, uint256 _reserveOut, bool _paymentTokenIsOut) external view returns (uint256 amountIn, uint256 fee);

    // --- Public State Variables (auto-generated getters) ---
    function curveType() external pure returns (CurveType);
    function MAX_BPS() external pure returns (uint256);
    function DEADLINE_24H() external pure returns (uint256);
    function DEADLINE_48H() external pure returns (uint256);
    function DEADLINE_72H() external pure returns (uint256);
    function initialTokenSupply() external view returns (uint256);
    function virtualTokenReserves() external view returns (uint256);
    function virtualCollateralReserves() external view returns (uint256);
    function virtualCollateralReservesInitial() external view returns (uint256);
    function feeBPS() external view returns (uint256);
    function dexFeeBPS() external view returns (uint256);
    function mcLowerLimit() external view returns (uint256);
    function mcUpperLimit() external view returns (uint256);
    function tokensMigrationThreshold() external view returns (uint256);
    function fixedMigrationFee() external view returns (uint256);
    function poolCreationFee() external view returns (uint256);
    function creator() external view returns (address);
    function pair() external view returns (address);
    function treasury() external view returns (address);
    function dexTreasury() external view returns (address);
    function factory() external view returns (address);
    function tradingStopped() external view returns (bool);
    function sendingToPairNotAllowed() external view returns (bool);
    function currentState() external view returns (TokenState);
    function migrationTimestamp() external view returns (uint256);
    function totalEthRaised() external view returns (uint256);
    function launchDeadline() external view returns (uint256);
    function deadlineDuration() external view returns (uint256);
    function saleCancelled() external view returns (bool);
    function buyers(address) external view returns (BuyerInfo memory);
}