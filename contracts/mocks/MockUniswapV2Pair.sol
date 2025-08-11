// contracts/mocks/MockUniswapV2Pair.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUniswapV2Pair is ERC20 {
    address public token0;
    address public token1;
    
    uint112 private reserve0;
    uint112 private reserve1;
    uint32 private blockTimestampLast;
    
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    
    constructor(address _token0, address _token1) ERC20("Mock LP Token", "MLP") {
        token0 = _token0;
        token1 = _token1;
        blockTimestampLast = uint32(block.timestamp);
    }
    
    function getReserves() external view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        return (reserve0, reserve1, blockTimestampLast);
    }
    
    function setReserves(uint112 _reserve0, uint112 _reserve1) external {
        // Update cumulative prices before changing reserves
        uint32 timeElapsed = uint32(block.timestamp) - blockTimestampLast;
        if (timeElapsed > 0 && reserve0 != 0 && reserve1 != 0) {
            unchecked {
                price0CumulativeLast += uint256((uint256(reserve1) << 112) / reserve0) * timeElapsed;
                price1CumulativeLast += uint256((uint256(reserve0) << 112) / reserve1) * timeElapsed;
            }
        }
        
        reserve0 = _reserve0;
        reserve1 = _reserve1;
        blockTimestampLast = uint32(block.timestamp);
    }
    
    function setCumulativePrices(uint256 _price0Cumulative, uint256 _price1Cumulative) external {
        price0CumulativeLast = _price0Cumulative;
        price1CumulativeLast = _price1Cumulative;
    }
    
    function sync() external {
        // Mock sync function - could update reserves based on token balances
    }
}
