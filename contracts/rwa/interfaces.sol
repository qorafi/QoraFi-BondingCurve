// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// --- INTERFACES for RWAFactory ---

interface QoraFiRWA {
    function mint(address to, uint256 id, uint256 amount, bytes memory data) external;
    // --- FIX: Added the missing ERC1155 transfer function ---
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
}

interface IQoraFiBurnable is IERC20 {
    function burnFrom(address from, uint256 amount) external;
}

interface IProofOfLiquidity {
    function getStakedValueInUSDT(address user) external view returns (uint256);
}

interface IPancakeSwapRouter02 {
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);
}

interface IPancakeSwapFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}
