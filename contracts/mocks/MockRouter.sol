// contracts/mocks/MockRouter.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockRouter {
    using SafeERC20 for IERC20;
    
    address public immutable WETH;
    
    // Mock exchange rates (for testing)
    mapping(address => mapping(address => uint256)) public exchangeRates;
    
    constructor(address _weth) {
        WETH = _weth;
    }
    
    function setExchangeRate(address tokenA, address tokenB, uint256 rate) external {
        exchangeRates[tokenA][tokenB] = rate;
        if (rate > 0) {
            exchangeRates[tokenB][tokenA] = (1e18 * 1e18) / rate;
        }
    }
    
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "Router: EXPIRED");
        require(path.length >= 2, "Router: INVALID_PATH");
        
        amounts = getAmountsOut(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "Router: INSUFFICIENT_OUTPUT_AMOUNT");
        
        // Transfer input tokens
        IERC20(path[0]).safeTransferFrom(msg.sender, address(this), amountIn);
        
        // Transfer output tokens
        IERC20(path[path.length - 1]).safeTransfer(to, amounts[amounts.length - 1]);
    }
    
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts) {
        require(deadline >= block.timestamp, "Router: EXPIRED");
        require(path[0] == WETH, "Router: INVALID_PATH");
        
        amounts = getAmountsOut(msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "Router: INSUFFICIENT_OUTPUT_AMOUNT");
        
        // Transfer output tokens
        IERC20(path[path.length - 1]).safeTransfer(to, amounts[amounts.length - 1]);
    }
    
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(deadline >= block.timestamp, "Router: EXPIRED");
        
        // Simplified liquidity calculation
        amountA = amountADesired;
        amountB = amountBDesired;
        liquidity = (amountA + amountB) / 2; // Simplified
        
        require(amountA >= amountAMin, "Router: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "Router: INSUFFICIENT_B_AMOUNT");
        
        // Transfer tokens
        IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountA);
        IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountB);
        
        // Mock LP token transfer (would need actual LP token contract)
        // For testing, we'll just return the values
    }
    
    function getAmountsOut(uint256 amountIn, address[] memory path) public view returns (uint256[] memory amounts) {
        require(path.length >= 2, "Router: INVALID_PATH");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        
        for (uint256 i; i < path.length - 1; i++) {
            uint256 rate = exchangeRates[path[i]][path[i + 1]];
            if (rate == 0) rate = 1e18; // Default 1:1 rate
            amounts[i + 1] = (amounts[i] * rate) / 1e18;
        }
    }
    
    // Allow contract to receive ETH
    receive() external payable {}
}