// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "./interfaces.sol"; // Create a file with all necessary interfaces
import "./RWA_Wrapper_ERC20.sol";

/**
 * @title RWAFactory
 * @dev The main engine for tokenizing RWAs and creating their trading pools in a single transaction.
 * All administrative functions are intended to be controlled by a DAO/Timelock.
 */
contract RWAFactory is Ownable {
    using SafeERC20 for IERC20;

    // --- Core Contracts ---
    QoraFiRWA public immutable qorafiRwaToken;
    IQoraFiBurnable public immutable qorafiToken;
    IERC20 public immutable usqToken;
    IPancakeSwapRouter02 public immutable pancakeRouter;
    address public immutable WBNB;
    IProofOfLiquidity public immutable proofOfLiquidity;
    address public treasuryAddress;

    // --- Parameters ---
    uint256 public creationFee;
    uint256 public minStakingValue;

    mapping(uint256 => address) public rwaWrappers;
    uint256 public nextTokenId;

    // --- Events ---
    event AssetTokenized(uint256 indexed tokenId, address indexed creator, uint256 initialSupply, address wrapperAddress);
    event PoolCreated(uint256 indexed rwaTokenId, address indexed pairAddress, address indexed liquidityProvider);
    event FeeUpdated(uint256 newFee);
    event MinStakingValueUpdated(uint256 newValue);
    event TreasuryAddressUpdated(address newTreasury);

    constructor(
        address _qorafiRwaAddress,
        address _qorafiTokenAddress,
        address _usqTokenAddress,
        address _pancakeRouterAddress,
        address _proofOfLiquidityAddress,
        address _initialTreasuryAddress,
        uint256 _initialCreationFee,
        uint256 _minStakingValue
    ) Ownable(msg.sender) {
        qorafiRwaToken = QoraFiRWA(_qorafiRwaAddress);
        qorafiToken = IQoraFiBurnable(_qorafiTokenAddress);
        usqToken = IERC20(_usqTokenAddress);
        pancakeRouter = IPancakeSwapRouter02(_pancakeRouterAddress);
        WBNB = pancakeRouter.WETH();
        proofOfLiquidity = IProofOfLiquidity(_proofOfLiquidityAddress);
        treasuryAddress = _initialTreasuryAddress;
        creationFee = _initialCreationFee;
        minStakingValue = _minStakingValue;
        nextTokenId = 1;
    }

    /**
     * @notice The ultimate Zap function to tokenize an asset and create its trading pool with BNB.
     */
    function tokenizeAndCreatePoolWithBNB(
        uint256 _initialRwaSupply,
        uint256 _rwaAmountForLiquidity,
        uint256 _usqAmountForLiquidity,
        string memory _wrapperName,
        string memory _wrapperSymbol,
        uint256 _deadline
    ) external payable returns (address lpPairAddress) {
        // 1. Check Staking Qualification
        require(proofOfLiquidity.getStakedValueInUSDT(msg.sender) >= minStakingValue, "Factory: Not a qualified staker");

        // 2. Charge and Burn QoraFi Fee
        if (creationFee > 0) {
            qorafiToken.burnFrom(msg.sender, creationFee);
        }

        // 3. Mint RWA (ERC-1155) Token
        uint256 tokenId = nextTokenId;
        qorafiRwaToken.mint(msg.sender, tokenId, _initialRwaSupply, "");
        nextTokenId++;

        // 4. Deploy New ERC-20 Wrapper
        RWA_Wrapper_ERC20 wrapper = new RWA_Wrapper_ERC20(address(qorafiRwaToken), tokenId, _wrapperName, _wrapperSymbol);
        rwaWrappers[tokenId] = address(wrapper);
        emit AssetTokenized(tokenId, msg.sender, _initialRwaSupply, address(wrapper));

        // 5. Wrap RWA Tokens for Liquidity
        qorafiRwaToken.safeTransferFrom(msg.sender, address(wrapper), tokenId, _rwaAmountForLiquidity, "");
        wrapper.mintForFactory(address(this), _rwaAmountForLiquidity);

        // 6. Swap BNB for required USQ
        address[] memory path = new address[](2);
        path[0] = WBNB;
        path[1] = address(usqToken);
        uint256[] memory amounts = pancakeRouter.swapExactETHForTokens{value: msg.value}(_usqAmountForLiquidity, path, address(this), _deadline);
        
        // 7. Create PancakeSwap Pool
        IERC20(address(wrapper)).approve(address(pancakeRouter), _rwaAmountForLiquidity);
        usqToken.approve(address(pancakeRouter), amounts[1]);

        (,,uint256 liquidity) = pancakeRouter.addLiquidity(
            address(wrapper), address(usqToken), _rwaAmountForLiquidity, amounts[1], 0, 0, msg.sender, _deadline
        );
        require(liquidity > 0, "Factory: Could not create pool");
        
        if (address(this).balance > 0) {
            payable(msg.sender).transfer(address(this).balance);
        }
        
        address factory = pancakeRouter.factory();
        lpPairAddress = IPancakeSwapFactory(factory).getPair(address(wrapper), address(usqToken));
        emit PoolCreated(tokenId, lpPairAddress, msg.sender);
    }

    // --- GOVERNANCE-CONTROLLED FUNCTIONS ---

    function setCreationFee(uint256 _newFee) external onlyOwner {
        creationFee = _newFee;
        emit FeeUpdated(_newFee);
    }

    function setMinStakingValue(uint256 _newValue) external onlyOwner {
        minStakingValue = _newValue;
        emit MinStakingValueUpdated(_newValue);
    }
    
    function setTreasuryAddress(address _newTreasury) public onlyOwner {
        require(_newTreasury != address(0), "Invalid address");
        treasuryAddress = _newTreasury;
        emit TreasuryAddressUpdated(_newTreasury);
    }

    function withdrawStuckTokens(address _tokenAddress) external onlyOwner {
        require(_tokenAddress != address(qorafiToken) && _tokenAddress != address(usqToken));
        IERC20 token = IERC20(_tokenAddress);
        token.safeTransfer(treasuryAddress, token.balanceOf(address(this)));
    }

    function withdrawStuckBNB() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No BNB to withdraw");
        (bool success, ) = payable(treasuryAddress).call{value: balance}("");
        require(success, "BNB withdrawal failed");
    }

    receive() external payable {}
}