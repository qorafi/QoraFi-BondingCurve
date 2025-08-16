// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title SwapUtilities
 * @notice Swap and liquidity operation utilities
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
     * @param liquidity LP tokens minted
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
        // Validate inputs
        if (tokenA == address(0) || tokenB == address(0)) revert InvalidTokens();
        if (slippageBps > MAX_BPS) revert LiquidityFailed();

        // Set allowances
        IERC20(tokenA).safeIncreaseAllowance(router, amountA);
        IERC20(tokenB).safeIncreaseAllowance(router, amountB);

        // Calculate minimum amounts with slippage
        uint256 minAmountA = Math.mulDiv(amountA, MAX_BPS - slippageBps, MAX_BPS);
        uint256 minAmountB = Math.mulDiv(amountB, MAX_BPS - slippageBps, MAX_BPS);

        // Execute liquidity addition
        (actualAmountA, actualAmountB, liquidity) = _executeLiquidityAdd(
            router,
            tokenA,
            tokenB,
            amountA,
            amountB,
            minAmountA,
            minAmountB,
            recipient,
            deadline
        );

        // Reset allowances
        _resetAllowances(tokenA, tokenB, router, amountA, amountB);
    }

    /**
     * @notice Internal function to execute liquidity addition
     */
    function _executeLiquidityAdd(
        address router,
        address tokenA,
        address tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 minAmountA,
        uint256 minAmountB,
        address recipient,
        uint256 deadline
    ) private returns (uint256 actualAmountA, uint256 actualAmountB, uint256 liquidity) {
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
                revert InsufficientLiquidityMinted();
            }
        } catch {
            revert LiquidityFailed();
        }
    }

    /**
     * @notice Internal function to reset allowances
     */
    function _resetAllowances(
        address tokenA,
        address tokenB,
        address router,
        uint256 amountA,
        uint256 amountB
    ) private {
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

// --- INTERFACES ---
interface IRouter {
    function WETH() external view returns (address);
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external returns (uint256[] memory);
    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline) external payable returns (uint256[] memory);
    function addLiquidity(address tokenA, address tokenB, uint256 amountADesired, uint256 amountBDesired, uint256 amountAMin, uint256 amountBMin, address to, uint256 deadline) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
}

/**
 * @title SwapUtilities Contract
 */
contract SwapUtilities {
    using SafeERC20 for IERC20;
    
    function getLibraryVersion() external pure returns (string memory) {
        return "SWAP-1.0.0";
    }
    
    // Swap functions for testing
    function getExpectedSwapOutput(
        address router,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256) {
        return SwapLib.getExpectedSwapOutput(router, tokenIn, tokenOut, amountIn);
    }
    
    function calculateOptimalAmounts(
        uint256 reserveA,
        uint256 reserveB,
        uint256 desiredA,
        uint256 desiredB
    ) external pure returns (uint256 optimalA, uint256 optimalB) {
        return LiquidityLib.calculateOptimalAmounts(reserveA, reserveB, desiredA, desiredB);
    }
}