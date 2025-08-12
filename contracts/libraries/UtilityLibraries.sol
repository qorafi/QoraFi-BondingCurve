// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title UtilityLibraries
 * @notice Collection of utility libraries for swap operations, token handling, and mathematical calculations
 * @dev Extracted from main contracts to improve modularity and reduce contract sizes
 */

// --- SWAP OPERATIONS LIBRARY ---
library SwapLib {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Swap errors
    error SwapFailed();
    error InsufficientOutput();
    error InvalidPath();
    error InvalidRouter();

    /**
     * @notice Executes a token-to-token swap with slippage protection
     * @param router Router contract address
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Input amount
     * @param minAmountOut Minimum output amount
     * @param deadline Transaction deadline
     * @return amountOut Actual output amount
     */
    function executeSwap(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        if (router == address(0)) revert InvalidRouter();
        if (amountIn == 0) revert SwapFailed();

        IERC20(tokenIn).safeIncreaseAllowance(router, amountIn);
        
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        try IRouter(router).swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            path,
            address(this),
            deadline
        ) returns (uint256[] memory amounts) {
            amountOut = amounts[amounts.length - 1];
            if (amountOut < minAmountOut) {
                IERC20(tokenIn).safeDecreaseAllowance(router, amountIn);
                revert InsufficientOutput();
            }
        } catch {
            IERC20(tokenIn).safeDecreaseAllowance(router, amountIn);
            revert SwapFailed();
        }
        
        // Reset allowance after successful swap
        IERC20(tokenIn).safeDecreaseAllowance(router, amountIn);
    }

    /**
     * @notice Executes ETH to token swap
     * @param router Router contract address
     * @param tokenOut Output token address
     * @param ethAmount ETH amount to swap
     * @param minAmountOut Minimum output amount
     * @param deadline Transaction deadline
     * @return amountOut Actual output amount
     */
    function executeETHToTokenSwap(
        address router,
        address tokenOut,
        uint256 ethAmount,
        uint256 minAmountOut,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        if (router == address(0)) revert InvalidRouter();
        if (ethAmount == 0) revert SwapFailed();

        address[] memory path = new address[](2);
        path[0] = IRouter(router).WETH();
        path[1] = tokenOut;

        uint256[] memory amounts = IRouter(router).swapExactETHForTokens{value: ethAmount}(
            minAmountOut,
            path,
            address(this),
            deadline
        );

        amountOut = amounts[amounts.length - 1];
    }

    /**
     * @notice Executes multi-hop token swap (token -> WETH -> target)
     * @param router Router contract address
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Input amount
     * @param minAmountOut Minimum output amount
     * @param deadline Transaction deadline
     * @return amountOut Actual output amount
     */
    function executeMultiHopSwap(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) internal returns (uint256 amountOut) {
        if (router == address(0)) revert InvalidRouter();
        if (amountIn == 0) revert SwapFailed();

        IERC20(tokenIn).safeIncreaseAllowance(router, amountIn);
        
        address[] memory path = new address[](3);
        path[0] = tokenIn;
        path[1] = IRouter(router).WETH();
        path[2] = tokenOut;

        try IRouter(router).swapExactTokensForTokens(
            amountIn,
            minAmountOut,
            path,
            address(this),
            deadline
        ) returns (uint256[] memory amounts) {
            amountOut = amounts[amounts.length - 1];
            if (amountOut < minAmountOut) {
                IERC20(tokenIn).safeDecreaseAllowance(router, amountIn);
                revert InsufficientOutput();
            }
        } catch {
            IERC20(tokenIn).safeDecreaseAllowance(router, amountIn);
            revert SwapFailed();
        }
        
        IERC20(tokenIn).safeDecreaseAllowance(router, amountIn);
    }

    /**
     * @notice Gets expected swap output amount
     * @param router Router contract address
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Input amount
     * @return expectedOut Expected output amount
     */
    function getExpectedSwapOutput(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (uint256 expectedOut) {
        if (router == address(0) || amountIn == 0) return 0;

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;

        try IRouter(router).getAmountsOut(amountIn, path) returns (uint256[] memory amounts) {
            return amounts.length >= 2 ? amounts[amounts.length - 1] : 0;
        } catch {
            return 0;
        }
    }
}

// --- LIQUIDITY OPERATIONS LIBRARY ---
library LiquidityLib {
    using SafeERC20 for IERC20;
    using Math for uint256;

    // Liquidity errors
    error LiquidityFailed();
    error InsufficientLiquidityMinted();
    error InvalidTokens();

    uint256 public constant MAX_BPS = 10000;

    /**
     * @notice Adds liquidity to a pair with slippage protection
     * @param router Router contract address
     * @param tokenA Token A address
     * @param tokenB Token B address
     * @param amountA Amount of token A
     * @param amountB Amount of token B
     * @param slippageBps Slippage tolerance in BPS
     * @param recipient Recipient of LP tokens
     * @param deadline Transaction deadline
     * @return actualAmountA Actual amount of token A used
     * @return actualAmountB Actual amount of token B used
     * @return liquidity LP tokens minted
     */
    function addLiquidity(
        address router,
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 slippageBps,
        address recipient,
        uint256 deadline
    ) internal returns (uint256 actualAmountA, uint256 actualAmountB, uint256 liquidity) {
        if (tokenA == address(0) || tokenB == address(0)) revert InvalidTokens();
        if (slippageBps > MAX_BPS) revert LiquidityFailed();

        // Set allowances
        IERC20(tokenA).safeIncreaseAllowance(router, amountA);
        IERC20(tokenB).safeIncreaseAllowance(router, amountB);

        // Calculate minimum amounts with slippage
        uint256 minAmountA = Math.mulDiv(amountA, MAX_BPS - slippageBps, MAX_BPS);
        uint256 minAmountB = Math.mulDiv(amountB, MAX_BPS - slippageBps, MAX_BPS);

        try IRouter(router).addLiquidity(
            tokenA,
            tokenB,
            amountA,
            amountB,
            minAmountA,
            minAmountB,
            recipient,
            deadline
        ) returns (uint256 _amountA, uint256 _amountB, uint256 _liquidity) {
            actualAmountA = _amountA;
            actualAmountB = _amountB;
            liquidity = _liquidity;
            
            if (liquidity == 0) {
                // Reset allowances before reverting
                IERC20(tokenA).safeDecreaseAllowance(router, amountA);
                IERC20(tokenB).safeDecreaseAllowance(router, amountB);
                revert InsufficientLiquidityMinted();
            }
        } catch {
            // Reset allowances on failure
            IERC20(tokenA).safeDecreaseAllowance(router, amountA);
            IERC20(tokenB).safeDecreaseAllowance(router, amountB);
            revert LiquidityFailed();
        }

        // Reset remaining allowances
        IERC20(tokenA).safeDecreaseAllowance(router, amountA);
        IERC20(tokenB).safeDecreaseAllowance(router, amountB);
    }

    /**
     * @notice Calculates optimal liquidity amounts
     * @param reserveA Reserve of token A
     * @param reserveB Reserve of token B
     * @param desiredA Desired amount of token A
     * @param desiredB Desired amount of token B
     * @return optimalA Optimal amount of token A
     * @return optimalB Optimal amount of token B
     */
    function calculateOptimalAmounts(
        uint256 reserveA,
        uint256 reserveB,
        uint256 desiredA,
        uint256 desiredB
    ) internal pure returns (uint256 optimalA, uint256 optimalB) {
        if (reserveA == 0 && reserveB == 0) {
            return (desiredA, desiredB);
        }
        
        uint256 amountBOptimal = Math.mulDiv(desiredA, reserveB, reserveA);
        if (amountBOptimal <= desiredB) {
            return (desiredA, amountBOptimal);
        } else {
            uint256 amountAOptimal = Math.mulDiv(desiredB, reserveA, reserveB);
            return (amountAOptimal, desiredB);
        }
    }

    /**
     * @notice Refunds unused tokens after liquidity addition
     * @param tokenA Token A address
     * @param tokenB Token B address
     * @param providedA Amount provided of token A
     * @param providedB Amount provided of token B
     * @param usedA Amount used of token A
     * @param usedB Amount used of token B
     * @param recipient Refund recipient
     */
    function refundUnusedTokens(
        address tokenA,
        address tokenB,
        uint256 providedA,
        uint256 providedB,
        uint256 usedA,
        uint256 usedB,
        address recipient
    ) internal {
        if (providedA > usedA) {
            IERC20(tokenA).safeTransfer(recipient, providedA - usedA);
        }
        if (providedB > usedB) {
            IERC20(tokenB).safeTransfer(recipient, providedB - usedB);
        }
    }
}

// --- TOKEN HELPER LIBRARY ---
library TokenHelperLib {
    using SafeERC20 for IERC20;

    // Token helper errors
    error TransferFailed();
    error InsufficientBalance();
    error InvalidToken();

    /**
     * @notice Safely transfers tokens with balance check
     * @param token Token address
     * @param from From address
     * @param to To address
     * @param amount Amount to transfer
     */
    function safeTransferWithCheck(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        if (token == address(0)) revert InvalidToken();
        if (amount == 0) return;

        uint256 balance = IERC20(token).balanceOf(from);
        if (balance < amount) revert InsufficientBalance();

        if (from == address(this)) {
            IERC20(token).safeTransfer(to, amount);
        } else {
            IERC20(token).safeTransferFrom(from, to, amount);
        }
    }

    /**
     * @notice Gets token balance safely
     * @param token Token address
     * @param account Account address
     * @return balance Token balance
     */
    function getBalance(address token, address account) internal view returns (uint256 balance) {
        if (token == address(0)) return 0;
        
        try IERC20(token).balanceOf(account) returns (uint256 bal) {
            return bal;
        } catch {
            return 0;
        }
    }

    /**
     * @notice Gets token allowance safely
     * @param token Token address
     * @param owner Owner address
     * @param spender Spender address
     * @return allowance Token allowance
     */
    function getAllowance(address token, address owner, address spender) internal view returns (uint256 allowance) {
        if (token == address(0)) return 0;
        
        try IERC20(token).allowance(owner, spender) returns (uint256 allow) {
            return allow;
        } catch {
            return 0;
        }
    }

    /**
     * @notice Safely resets token allowance to zero
     * @param token Token address
     * @param spender Spender address
     */
    function resetAllowance(address token, address spender) internal {
        if (token == address(0)) return;
        
        uint256 currentAllowance = getAllowance(token, address(this), spender);
        if (currentAllowance > 0) {
            IERC20(token).safeDecreaseAllowance(spender, currentAllowance);
        }
    }

    /**
     * @notice Sets exact allowance (resets first if needed)
     * @param token Token address
     * @param spender Spender address
     * @param amount Allowance amount
     */
    function setExactAllowance(address token, address spender, uint256 amount) internal {
        resetAllowance(token, spender);
        if (amount > 0) {
            IERC20(token).safeIncreaseAllowance(spender, amount);
        }
    }

    /**
     * @notice Gets token decimals safely
     * @param token Token address
     * @return decimals Token decimals (default 18 if not found)
     */
    function getDecimals(address token) internal view returns (uint8 decimals) {
        if (token == address(0)) return 18;
        
        try IERC20Metadata(token).decimals() returns (uint8 dec) {
            return dec;
        } catch {
            return 18;
        }
    }

    /**
     * @notice Converts token amount between different decimal places
     * @param amount Amount to convert
     * @param fromDecimals Source decimals
     * @param toDecimals Target decimals
     * @return convertedAmount Converted amount
     */
    function convertDecimals(
        uint256 amount,
        uint8 fromDecimals,
        uint8 toDecimals
    ) internal pure returns (uint256 convertedAmount) {
        if (fromDecimals == toDecimals) {
            return amount;
        } else if (fromDecimals > toDecimals) {
            return amount / (10 ** (fromDecimals - toDecimals));
        } else {
            return amount * (10 ** (toDecimals - fromDecimals));
        }
    }
}

// --- MATH HELPER LIBRARY ---
library MathHelperLib {
    using Math for uint256;

    uint256 public constant MAX_BPS = 10000;
    uint256 public constant PRECISION = 1e18;

    /**
     * @notice Calculates percentage with BPS precision
     * @param amount Base amount
     * @param bps Basis points (1 BPS = 0.01%)
     * @return result Calculated percentage
     */
    function calculatePercentage(uint256 amount, uint256 bps) internal pure returns (uint256 result) {
        return Math.mulDiv(amount, bps, MAX_BPS);
    }

    /**
     * @notice Calculates slippage amount
     * @param amount Base amount
     * @param slippageBps Slippage in BPS
     * @return minAmount Minimum amount after slippage
     */
    function calculateSlippage(uint256 amount, uint256 slippageBps) internal pure returns (uint256 minAmount) {
        return Math.mulDiv(amount, MAX_BPS - slippageBps, MAX_BPS);
    }

    /**
     * @notice Calculates weighted average
     * @param values Array of values
     * @param weights Array of weights
     * @return weightedAvg Weighted average
     */
    function calculateWeightedAverage(
        uint256[] memory values,
        uint256[] memory weights
    ) internal pure returns (uint256 weightedAvg) {
        require(values.length == weights.length, "Array length mismatch");
        
        uint256 totalWeighted = 0;
        uint256 totalWeight = 0;
        
        for (uint256 i = 0; i < values.length; i++) {
            totalWeighted += values[i] * weights[i];
            totalWeight += weights[i];
        }
        
        return totalWeight > 0 ? totalWeighted / totalWeight : 0;
    }

    /**
     * @notice Calculates compound growth
     * @param principal Principal amount
     * @param rate Growth rate in BPS
     * @param periods Number of periods
     * @return finalAmount Final amount after compound growth
     */
    function calculateCompoundGrowth(
        uint256 principal,
        uint256 rate,
        uint256 periods
    ) internal pure returns (uint256 finalAmount) {
        uint256 growthFactor = MAX_BPS + rate;
        uint256 compoundFactor = PRECISION;
        
        for (uint256 i = 0; i < periods; i++) {
            compoundFactor = Math.mulDiv(compoundFactor, growthFactor, MAX_BPS);
        }
        
        return Math.mulDiv(principal, compoundFactor, PRECISION);
    }

    /**
     * @notice Calculates square root using Babylonian method
     * @param x Input value
     * @return y Square root
     */
    function sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    /**
     * @notice Safely adds with overflow check
     * @param a First number
     * @param b Second number
     * @return result Sum of a and b
     */
    function safeAdd(uint256 a, uint256 b) internal pure returns (uint256 result) {
        result = a + b;
        require(result >= a, "Addition overflow");
    }

    /**
     * @notice Calculates ratio between two numbers
     * @param numerator Numerator
     * @param denominator Denominator
     * @return ratio Ratio in BPS
     */
    function calculateRatio(uint256 numerator, uint256 denominator) internal pure returns (uint256 ratio) {
        if (denominator == 0) return 0;
        return Math.mulDiv(numerator, MAX_BPS, denominator);
    }

    /**
     * @notice Finds minimum of two numbers
     * @param a First number
     * @param b Second number
     * @return min Minimum value
     */
    function min(uint256 a, uint256 b) internal pure returns (uint256 min) {
        return a < b ? a : b;
    }

    /**
     * @notice Finds maximum of two numbers
     * @param a First number
     * @param b Second number
     * @return max Maximum value
     */
    function max(uint256 a, uint256 b) internal pure returns (uint256 max) {
        return a > b ? a : b;
    }
}

// --- STATISTICS LIBRARY ---
library StatisticsLib {
    /**
     * @notice Updates running statistics for a user
     * @param userStats Mapping of user statistics
     * @param user User address
     * @param amount Transaction amount
     */
    function updateUserStats(
        mapping(address => UserStats) storage userStats,
        address user,
        uint256 amount
    ) internal {
        UserStats storage stats = userStats[user];
        stats.transactionCount++;
        stats.totalVolume += amount;
        stats.lastTransactionTime = block.timestamp;
        stats.lastTransactionBlock = block.number;
    }

    /**
     * @notice Updates protocol-wide statistics
     * @param protocolStats Protocol statistics storage
     * @param amount Transaction amount
     * @param userCount Current user count
     */
    function updateProtocolStats(
        ProtocolStats storage protocolStats,
        uint256 amount,
        uint256 userCount
    ) internal {
        protocolStats.totalTransactions++;
        protocolStats.totalVolume += amount;
        protocolStats.uniqueUsers = userCount;
        protocolStats.lastUpdateTime = block.timestamp;
    }

    /**
     * @notice Gets user statistics
     * @param userStats Mapping of user statistics
     * @param user User address
     * @return transactionCount Number of transactions
     * @return totalVolume Total volume transacted
     * @return lastTransactionTime Last transaction timestamp
     * @return lastTransactionBlock Last transaction block
     */
    function getUserStats(
        mapping(address => UserStats) storage userStats,
        address user
    ) internal view returns (
        uint256 transactionCount,
        uint256 totalVolume,
        uint256 lastTransactionTime,
        uint256 lastTransactionBlock
    ) {
        UserStats storage stats = userStats[user];
        return (
            stats.transactionCount,
            stats.totalVolume,
            stats.lastTransactionTime,
            stats.lastTransactionBlock
        );
    }

    struct UserStats {
        uint256 transactionCount;
        uint256 totalVolume;
        uint256 lastTransactionTime;
        uint256 lastTransactionBlock;
    }

    struct ProtocolStats {
        uint256 totalTransactions;
        uint256 totalVolume;
        uint256 uniqueUsers;
        uint256 lastUpdateTime;
    }
}

// --- LEDGER INTEGRATION LIBRARY ---
library LedgerLib {
    // Ledger errors
    error LedgerNotificationFailed();
    error InvalidLedgerAddress();

    /**
     * @notice Safely notifies ledger with error handling
     * @param ledger Ledger contract address
     * @param user User address
     * @param amount Transaction amount
     * @return success Whether notification was successful
     * @return errorReason Error reason if failed
     */
    function safeNotifyLedger(
        address ledger,
        address user,
        uint256 amount
    ) internal returns (bool success, string memory errorReason) {
        if (ledger == address(0)) {
            return (false, "Invalid ledger address");
        }

        try ILedger(ledger).notifyDeposit(user, amount) {
            return (true, "");
        } catch Error(string memory reason) {
            return (false, reason);
        } catch (bytes memory) {
            return (false, "Unknown error");
        }
    }

    /**
     * @notice Batch notify ledger for multiple transactions
     * @param ledger Ledger contract address
     * @param users Array of user addresses
     * @param amounts Array of amounts
     * @return successCount Number of successful notifications
     */
    function batchNotifyLedger(
        address ledger,
        address[] memory users,
        uint256[] memory amounts
    ) internal returns (uint256 successCount) {
        require(users.length == amounts.length, "Array length mismatch");
        
        for (uint256 i = 0; i < users.length; i++) {
            (bool success, ) = safeNotifyLedger(ledger, users[i], amounts[i]);
            if (success) {
                successCount++;
            }
        }
    }

    /**
     * @notice Validates ledger contract interface
     * @param ledger Ledger contract address
     * @return isValid Whether ledger implements required interface
     */
    function validateLedgerInterface(address ledger) internal returns (bool isValid) {
        if (ledger == address(0)) return false;
        
        try ILedger(ledger).notifyDeposit(address(0), 0) {
            return true;
        } catch {
            return false;
        }
    }
}

// --- INTERFACES ---
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

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}