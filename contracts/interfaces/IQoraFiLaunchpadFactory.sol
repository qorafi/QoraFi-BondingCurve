// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/**
 * @title IQoraFiLaunchpadFactory
 * @notice Interface for QoraFi Launchpad Factory with token creation and management
 */
interface IQoraFiLaunchpadFactory {
    
    // --- Events ---
    event NewQoraFiToken(
        address indexed token, 
        address indexed creator, 
        string indexed name,
        string symbol,
        uint256 deadlineDuration,
        bytes signature
    );
    event LaunchFeeUpdated(uint256 oldFee, uint256 newFee);
    event FeesWithdrawn(address indexed to, uint256 amount);
    event SignerUpdated(address indexed oldSigner, address indexed newSigner);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event DexTreasuryUpdated(address indexed oldDexTreasury, address indexed newDexTreasury);
    event DefaultParametersUpdated();
    event MigrationPermissionUpdated(address indexed account, bool canMigrate);
    event TokenSaleCancelled(address indexed token, string reason);

    // --- Errors ---
    error InvalidLaunchFee();
    error InvalidSignature();
    error SignatureAlreadyUsed();
    error InvalidAddress();
    error TokenNotDeployed();
    error NoFeesToWithdraw();
    error FeeWithdrawalFailed();
    error UnauthorizedMigration();
    error InvalidParameters();
    error InvalidDeadlineDuration();

    // --- Admin Functions ---
    function setLaunchFee(uint256 _newFee) external;
    function setTreasury(address _newTreasury) external;
    function setDexTreasury(address _newDexTreasury) external;
    function setSigner(address _newSigner) external;
    function setDefaultParameters(
        uint256 _totalSupply,
        uint256 _virtualTokenReserves,
        uint256 _virtualCollateralReserves,
        uint256 _feeBasisPoints,
        uint256 _dexFeeBasisPoints,
        uint256 _migrationFeeFixed,
        uint256 _poolCreationFee,
        uint256 _mcLowerLimit,
        uint256 _mcUpperLimit,
        uint256 _tokensMigrationThreshold
    ) external;
    function setMigrationPermission(address _account, bool _canMigrate) external;
    function withdrawFees() external;

    // --- Token Creation ---
    function createQoraFiToken(
        string calldata _name,
        string calldata _symbol,
        uint256 _deadlineDuration,
        uint256 _nonce,
        bytes calldata _signature
    ) external payable returns (address tokenAddress);

    // --- Trading Proxy Functions ---
    function buyFromLaunchpad(address _token) external payable;
    function buyExactOutFromLaunchpad(
        address _token,
        uint256 _tokenAmount,
        uint256 _maxCollateralAmount
    ) external payable;
    function buyExactInFromLaunchpad(
        address _token,
        uint256 _amountOutMin
    ) external payable;
    function migrateFromLaunchpad(address _token) external;

    // --- Admin Functions for Cancelled Sales ---
    function cancelTokenSale(address _token) external;
    function emergencyRefundAllBuyers(address _token) external;
    function checkTokenDeadline(address _token) external view returns (
        uint256 deadline,
        uint256 timeRemaining,
        bool isExpired,
        bool isCancelled
    );
    function batchCheckDeadlines(address[] calldata _tokens) external;

    // --- View Functions ---
    function getDeployedTokensCount() external view returns (uint256);
    function getDeployedToken(uint256 _index) external view returns (address);
    function getAllDeployedTokens() external view returns (address[] memory);
    function isSignatureUsed(bytes calldata _signature) external view returns (bool);
    function getTokensByCreator(address _creator) external view returns (address[] memory creatorTokens);
    function getActiveTokens() external view returns (address[] memory activeTokens);

    // --- Emergency Functions ---
    function emergencyTokenRecovery(address _token, uint256 _amount) external;

    // --- Public State Variables (auto-generated getters) ---
    function treasury() external view returns (address);
    function dexTreasury() external view returns (address);
    function signer() external view returns (address);
    function launchFee() external view returns (uint256);
    function uniV2Router() external view returns (address);
    function defaultTotalSupply() external view returns (uint256);
    function defaultVirtualTokenReserves() external view returns (uint256);
    function defaultVirtualCollateralReserves() external view returns (uint256);
    function defaultFeeBasisPoints() external view returns (uint256);
    function defaultDexFeeBasisPoints() external view returns (uint256);
    function defaultMigrationFeeFixed() external view returns (uint256);
    function defaultPoolCreationFee() external view returns (uint256);
    function defaultMcLowerLimit() external view returns (uint256);
    function defaultMcUpperLimit() external view returns (uint256);
    function defaultTokensMigrationThreshold() external view returns (uint256);
    function isDeployedToken(address) external view returns (bool);
    function deployedTokens(uint256) external view returns (address);
    function usedSignatures(bytes32) external view returns (bool);
    function canMigrate(address) external view returns (bool);
}