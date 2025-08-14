// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../libraries/SecurityLibraries.sol";
import "../interfaces/SecurityInterfaces.sol";

/**
 * @title SecurityGovernance
 * @notice Dedicated governance contract for managing security parameters and emergency procedures
 * @dev Separated from main contracts to provide focused governance functionality
 */
contract SecurityGovernance is 
    Initializable, 
    AccessControlUpgradeable, 
    ReentrancyGuardUpgradeable, 
    UUPSUpgradeable,
    IGovernance,
    IEmergencySystem
{
    using EmergencyLib for mapping(bytes32 => EmergencyLib.EmergencyTransaction);
    using ValidationLib for *;

    // --- ROLES ---
    bytes32 public constant GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    bytes32 public constant PARAM_MANAGER_ROLE = keccak256("PARAM_MANAGER_ROLE");
    bytes32 public constant UPGRADE_ROLE = keccak256("UPGRADE_ROLE");

    // --- STATE ---
    mapping(string => uint256) public securityParameters;
    mapping(bytes32 => EmergencyLib.EmergencyTransaction) public emergencyTransactions;
    mapping(address => ContractSettings) public managedContracts;
    
    address public treasuryWallet;
    uint256 public emergencyTransactionDelay;
    uint256 public totalProposals;
    uint256 public executedProposals;
    uint256 public cancelledProposals;
    
    // Multi-sig governance
    mapping(bytes32 => Proposal) public proposals;
    mapping(bytes32 => mapping(address => bool)) public proposalVotes;
    uint256 public requiredSignatures;
    uint256 public proposalValidityPeriod;

    // Role member tracking (manual implementation)
    mapping(bytes32 => address[]) private roleMembers;
    mapping(bytes32 => mapping(address => uint256)) private roleMemberIndex;

    // --- STRUCTS ---
    struct ContractSettings {
        bool isManaged;
        address contractAddress;
        string contractType; // "SecurityManager", "Oracle", "BondingCurve"
        uint256 lastUpdate;
        bool paused;
    }

    struct Proposal {
        address proposer;
        bytes32 parameterHash;
        string parameterName;
        uint256 newValue;
        uint256 proposedAt;
        uint256 validUntil;
        uint256 signatures;
        bool executed;
        bool cancelled;
        ProposalType proposalType;
    }

    enum ProposalType {
        PARAMETER_CHANGE,
        EMERGENCY_ACTION,
        CONTRACT_UPGRADE,
        TREASURY_CHANGE,
        ROLE_CHANGE
    }

    // --- EVENTS ---
    event ParameterChangeProposed(bytes32 indexed proposalId, string parameterName, uint256 oldValue, uint256 newValue, address proposer);
    event ParameterChangeExecuted(bytes32 indexed proposalId, string parameterName, uint256 newValue, address executor);
    event ProposalSigned(bytes32 indexed proposalId, address signer, uint256 totalSignatures);
    event ProposalCancelled(bytes32 indexed proposalId, address canceller);
    event EmergencyTransactionProposed(bytes32 indexed txHash, address indexed proposer, address target, uint256 value, bytes data, uint256 executeAfter);
    event EmergencyTransactionExecuted(bytes32 indexed txHash, address indexed executor);
    event EmergencyTransactionCancelled(bytes32 indexed txHash, address indexed canceller);
    event ContractManagementAdded(address indexed contractAddr, string contractType);
    event ContractManagementRemoved(address indexed contractAddr);
    event TreasuryWalletChanged(address indexed oldTreasury, address indexed newTreasury);
    event RequiredSignaturesChanged(uint256 oldRequired, uint256 newRequired);

    // --- ERRORS ---
    error ProposalNotFound();
    error ProposalExpired();
    error ProposalAlreadyExecuted();
    error InsufficientSignatures();
    error AlreadySigned();
    error NotManagedContract();
    error InvalidProposalType();
    error InvalidSignatureRequirement();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _treasuryWallet,
        uint256 _emergencyTransactionDelay,
        uint256 _requiredSignatures
    ) public initializer {
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        ValidationLib.validateAddress(_treasuryWallet);
        ValidationLib.validateDelay(_emergencyTransactionDelay, 1 hours, 7 days);
        
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
        _grantRole(PARAM_MANAGER_ROLE, msg.sender);
        _grantRole(UPGRADE_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        // Initialize role tracking for msg.sender
        _initializeRoleTracking(GOVERNANCE_ROLE, msg.sender);
        _initializeRoleTracking(EMERGENCY_ROLE, msg.sender);
        _initializeRoleTracking(PARAM_MANAGER_ROLE, msg.sender);
        _initializeRoleTracking(UPGRADE_ROLE, msg.sender);

        treasuryWallet = _treasuryWallet;
        emergencyTransactionDelay = _emergencyTransactionDelay;
        requiredSignatures = _requiredSignatures;
        proposalValidityPeriod = 7 days;

        // Initialize default security parameters
        _initializeDefaultParameters();
    }

    function _initializeDefaultParameters() internal {
        securityParameters["maxPriceChangeBPS"] = 2000; // 20%
        securityParameters["maxMarketCapGrowthBPS"] = 3000; // 30%
        securityParameters["minOracleUpdateInterval"] = 5 minutes;
        securityParameters["circuitBreakerCooldown"] = 2 hours;
        securityParameters["mevMinInterval"] = 5; // blocks
        securityParameters["mevMaxPerBlock"] = 50000 * 10**18; // 50k USDT
        securityParameters["mevMaxPerUser"] = 25000 * 10**18; // 25k USDT
        securityParameters["maxGasPrice"] = 20 gwei;
        securityParameters["liquidityRatioBPS"] = 5000; // 50%
        securityParameters["maxSlippageBPS"] = 300; // 3%
    }

    // --- ROLE MANAGEMENT (Custom implementation, not from IGovernance) ---
    function grantRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (!hasRole(role, account)) {
            // Add to our manual tracking
            roleMembers[role].push(account);
            roleMemberIndex[role][account] = roleMembers[role].length - 1;
        }
        super.grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) public override onlyRole(getRoleAdmin(role)) {
        if (hasRole(role, account)) {
            // Remove from our manual tracking
            uint256 index = roleMemberIndex[role][account];
            uint256 lastIndex = roleMembers[role].length - 1;
            
            if (index != lastIndex) {
                address lastMember = roleMembers[role][lastIndex];
                roleMembers[role][index] = lastMember;
                roleMemberIndex[role][lastMember] = index;
            }
            
            roleMembers[role].pop();
            delete roleMemberIndex[role][account];
        }
        super.revokeRole(role, account);
    }

    function hasRole(bytes32 role, address account) public view override returns (bool) {
        return super.hasRole(role, account);
    }

    // Manual implementation of getRoleMemberCount
    function getRoleMemberCount(bytes32 role) public view returns (uint256) {
        return roleMembers[role].length;
    }

    // Manual implementation of getRoleMember
    function getRoleMember(bytes32 role, uint256 index) public view returns (address) {
        require(index < roleMembers[role].length, "Role member index out of bounds");
        return roleMembers[role][index];
    }

    // --- INTERFACE IMPLEMENTATIONS (IGovernance) ---
    function setSecurityParameters(string calldata paramName, uint256 value) external override onlyRole(PARAM_MANAGER_ROLE) {
        bytes32 proposalId = this.proposeParameterChange(paramName, value);
        // Auto-execute if caller has GOVERNANCE_ROLE
        if (hasRole(GOVERNANCE_ROLE, msg.sender) && requiredSignatures == 1) {
            _executeParameterChange(proposalId);
        }
    }

    function getSecurityParameter(string calldata paramName) external view override returns (uint256) {
        return securityParameters[paramName];
    }

    function setTreasuryWallet(address _newTreasury) external override onlyRole(GOVERNANCE_ROLE) {
        ValidationLib.validateAddress(_newTreasury);
        address oldTreasury = treasuryWallet;
        treasuryWallet = _newTreasury;
        emit TreasuryWalletChanged(oldTreasury, _newTreasury);
    }

    function getTreasuryWallet() external view override returns (address) {
        return treasuryWallet;
    }

    function authorizeUpgrade(address newImplementation) external override onlyRole(UPGRADE_ROLE) {
        _authorizeUpgrade(newImplementation);
    }

    // --- ADDITIONAL GOVERNANCE FUNCTIONS ---
    function getImplementation() external view returns (address) {
        return _getImplementation();
    }

    // --- PARAMETER MANAGEMENT ---
    function proposeParameterChange(
        string calldata parameterName,
        uint256 newValue
    ) external onlyRole(PARAM_MANAGER_ROLE) returns (bytes32 proposalId) {
        bytes32 paramHash = keccak256(abi.encodePacked(parameterName));
        proposalId = keccak256(abi.encodePacked(paramHash, newValue, block.timestamp, msg.sender));
        
        proposals[proposalId] = Proposal({
            proposer: msg.sender,
            parameterHash: paramHash,
            parameterName: parameterName,
            newValue: newValue,
            proposedAt: block.timestamp,
            validUntil: block.timestamp + proposalValidityPeriod,
            signatures: 1, // Proposer's signature counts
            executed: false,
            cancelled: false,
            proposalType: ProposalType.PARAMETER_CHANGE
        });

        proposalVotes[proposalId][msg.sender] = true;
        totalProposals++;

        emit ParameterChangeProposed(
            proposalId,
            parameterName,
            securityParameters[parameterName],
            newValue,
            msg.sender
        );

        return proposalId;
    }

    function signProposal(bytes32 proposalId) external onlyRole(PARAM_MANAGER_ROLE) {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.proposer == address(0)) revert ProposalNotFound();
        if (block.timestamp > proposal.validUntil) revert ProposalExpired();
        if (proposal.executed || proposal.cancelled) revert ProposalAlreadyExecuted();
        if (proposalVotes[proposalId][msg.sender]) revert AlreadySigned();

        proposalVotes[proposalId][msg.sender] = true;
        proposal.signatures++;

        emit ProposalSigned(proposalId, msg.sender, proposal.signatures);

        // Auto-execute if enough signatures
        if (proposal.signatures >= requiredSignatures) {
            _executeParameterChange(proposalId);
        }
    }

    function executeParameterChange(bytes32 proposalId) external onlyRole(GOVERNANCE_ROLE) {
        _executeParameterChange(proposalId);
    }

    function _executeParameterChange(bytes32 proposalId) internal {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.proposer == address(0)) revert ProposalNotFound();
        if (block.timestamp > proposal.validUntil) revert ProposalExpired();
        if (proposal.executed || proposal.cancelled) revert ProposalAlreadyExecuted();
        if (proposal.signatures < requiredSignatures) revert InsufficientSignatures();

        proposal.executed = true;
        executedProposals++;

        // uint256 oldValue = securityParameters[proposal.parameterName]; // FIX: Unused local variable
        securityParameters[proposal.parameterName] = proposal.newValue;

        emit ParameterChangeExecuted(proposalId, proposal.parameterName, proposal.newValue, msg.sender);

        // Propagate changes to managed contracts
        _propagateParameterChange(proposal.parameterName, proposal.newValue);
    }

    function cancelProposal(bytes32 proposalId) external onlyRole(GOVERNANCE_ROLE) {
        Proposal storage proposal = proposals[proposalId];
        
        if (proposal.proposer == address(0)) revert ProposalNotFound();
        if (proposal.executed || proposal.cancelled) revert ProposalAlreadyExecuted();

        proposal.cancelled = true;
        cancelledProposals++;

        emit ProposalCancelled(proposalId, msg.sender);
    }

    function _propagateParameterChange(string memory /*parameterName*/, uint256 /*newValue*/) internal pure {
        // This would call specific functions on managed contracts to update their parameters
        // Implementation depends on the specific interfaces of the managed contracts
        
        // bytes32 paramHash = keccak256(abi.encodePacked(parameterName)); // FIX: Unused local variable
        
        // Example: Update SecurityManager parameters
        // bytes32 securityManagerHash = keccak256(abi.encodePacked("SecurityManager")); // FIX: Unused local variable
        // if (managedContracts[securityManagerAddress].contractType == "SecurityManager") {
        //     ISecurityManager(contractAddress).updateParameter(parameterName, newValue);
        // }
    }

    // --- EMERGENCY SYSTEM (IEmergencySystem) ---
    function proposeEmergencyTransaction(
        address target,
        uint256 value,
        bytes calldata data
    ) external override onlyRole(EMERGENCY_ROLE) returns (bytes32) {
        bytes32 txHash = emergencyTransactions.proposeTransaction(
            target,
            value,
            data,
            emergencyTransactionDelay,
            msg.sender
        );

        emit EmergencyTransactionProposed(
            txHash,
            msg.sender,
            target,
            value,
            data,
            block.timestamp + emergencyTransactionDelay
        );
        
        return txHash;
    }

    function executeEmergencyTransaction(bytes32 txHash) external override onlyRole(GOVERNANCE_ROLE) {
        bool success = emergencyTransactions.executeTransaction(txHash);
        require(success, "Emergency transaction failed");
        
        emit EmergencyTransactionExecuted(txHash, msg.sender);
    }

    function cancelEmergencyTransaction(bytes32 txHash) external override onlyRole(GOVERNANCE_ROLE) {
        emergencyTransactions.cancelTransaction(txHash);
        emit EmergencyTransactionCancelled(txHash, msg.sender);
    }

    function getEmergencyTransaction(bytes32 txHash) external view override returns (
        address target,
        uint256 value,
        bytes memory data,
        uint256 executeAfter,
        bool executed,
        address proposer,
        uint256 proposedAt
    ) {
        return emergencyTransactions.getTransaction(txHash);
    }

    function activateEmergencyMode() external override onlyRole(EMERGENCY_ROLE) {
        // Activate emergency mode on all managed contracts
        address[] memory contractAddresses = _getManagedContractAddresses();
        
        for (uint256 i = 0; i < contractAddresses.length; i++) {
            if (managedContracts[contractAddresses[i]].isManaged) {
                (bool success, ) = contractAddresses[i].call(
                    abi.encodeWithSignature("activateEmergencyMode()")
                );
                // Continue even if some calls fail, but capture the result
                if (!success) {
                    // Optionally emit an event or handle the failure
                }
            }
        }
    }

    function deactivateEmergencyMode() external override onlyRole(GOVERNANCE_ROLE) {
        // Deactivate emergency mode on all managed contracts
        address[] memory contractAddresses = _getManagedContractAddresses();
        
        for (uint256 i = 0; i < contractAddresses.length; i++) {
            if (managedContracts[contractAddresses[i]].isManaged) {
                (bool success, ) = contractAddresses[i].call(
                    abi.encodeWithSignature("deactivateEmergencyMode()")
                );
                // Continue even if some calls fail, but capture the result
                if (!success) {
                    // Optionally emit an event or handle the failure
                }
            }
        }
    }

    function isEmergencyModeActive() external view override returns (bool) {
        // Check if any managed contract is in emergency mode
        address[] memory contractAddresses = _getManagedContractAddresses();
        
        for (uint256 i = 0; i < contractAddresses.length; i++) {
            if (managedContracts[contractAddresses[i]].isManaged) {
                (bool success, bytes memory result) = contractAddresses[i].staticcall(
                    abi.encodeWithSignature("isEmergencyMode()")
                );
                if (success && result.length > 0) {
                    bool isEmergency = abi.decode(result, (bool));
                    if (isEmergency) return true;
                }
            }
        }
        return false;
    }

    // --- CONTRACT MANAGEMENT ---
    function addManagedContract(
        address contractAddr,
        string calldata contractType
    ) external onlyRole(GOVERNANCE_ROLE) {
        ValidationLib.validateAddress(contractAddr);
        
        managedContracts[contractAddr] = ContractSettings({
            isManaged: true,
            contractAddress: contractAddr,
            contractType: contractType,
            lastUpdate: block.timestamp,
            paused: false
        });

        emit ContractManagementAdded(contractAddr, contractType);
    }

    function removeManagedContract(address contractAddr) external onlyRole(GOVERNANCE_ROLE) {
        require(managedContracts[contractAddr].isManaged, "Contract not managed");
        
        delete managedContracts[contractAddr];
        emit ContractManagementRemoved(contractAddr);
    }

    function pauseManagedContract(address contractAddr) external onlyRole(EMERGENCY_ROLE) {
        if (!managedContracts[contractAddr].isManaged) revert NotManagedContract();
        
        managedContracts[contractAddr].paused = true;
        
        // Call pause function on the contract
        (bool success,) = contractAddr.call(abi.encodeWithSignature("pause()"));
        require(success, "Pause call failed");
    }

    function unpauseManagedContract(address contractAddr) external onlyRole(GOVERNANCE_ROLE) {
        if (!managedContracts[contractAddr].isManaged) revert NotManagedContract();
        
        managedContracts[contractAddr].paused = false;
        
        // Call unpause function on the contract
        (bool success,) = contractAddr.call(abi.encodeWithSignature("unpause()"));
        require(success, "Unpause call failed");
    }

    // --- GOVERNANCE SETTINGS ---
    function setRequiredSignatures(uint256 _requiredSignatures) external onlyRole(GOVERNANCE_ROLE) {
        if (_requiredSignatures == 0) revert InvalidSignatureRequirement();
        
        uint256 governanceRoleCount = getRoleMemberCount(PARAM_MANAGER_ROLE);
        if (_requiredSignatures > governanceRoleCount) revert InvalidSignatureRequirement();
        
        uint256 oldRequired = requiredSignatures;
        requiredSignatures = _requiredSignatures;
        emit RequiredSignaturesChanged(oldRequired, _requiredSignatures);
    }

    function setProposalValidityPeriod(uint256 _validityPeriod) external onlyRole(GOVERNANCE_ROLE) {
        require(_validityPeriod >= 1 days && _validityPeriod <= 30 days, "Invalid validity period");
        proposalValidityPeriod = _validityPeriod;
    }

    function setEmergencyTransactionDelay(uint256 _delay) external onlyRole(GOVERNANCE_ROLE) {
        ValidationLib.validateDelay(_delay, 1 hours, 7 days);
        emergencyTransactionDelay = _delay;
    }

    // --- VIEW FUNCTIONS ---
    function getProposal(bytes32 proposalId) external view returns (
        address proposer,
        string memory parameterName,
        uint256 newValue,
        uint256 proposedAt,
        uint256 validUntil,
        uint256 signatures,
        bool executed,
        bool cancelled,
        ProposalType proposalType
    ) {
        Proposal memory proposal = proposals[proposalId];
        return (
            proposal.proposer,
            proposal.parameterName,
            proposal.newValue,
            proposal.proposedAt,
            proposal.validUntil,
            proposal.signatures,
            proposal.executed,
            proposal.cancelled,
            proposal.proposalType
        );
    }

    function getGovernanceStats() external view returns (
        uint256 totalProposalsCount,
        uint256 executedProposalsCount,
        uint256 cancelledProposalsCount,
        uint256 requiredSignaturesCount,
        uint256 proposalValidityPeriodDuration
    ) {
        return (
            totalProposals,
            executedProposals,
            cancelledProposals,
            requiredSignatures,
            proposalValidityPeriod
        );
    }

    function getManagedContract(address contractAddr) external view returns (
        bool isManaged,
        string memory contractType,
        uint256 lastUpdate,
        bool paused
    ) {
        ContractSettings memory settings = managedContracts[contractAddr];
        return (
            settings.isManaged,
            settings.contractType,
            settings.lastUpdate,
            settings.paused
        );
    }

    function getAllParameters() external view returns (
        string[] memory paramNames,
        uint256[] memory paramValues
    ) {
        // Return commonly used parameters
        paramNames = new string[](10);
        paramValues = new uint256[](10);
        
        paramNames[0] = "maxPriceChangeBPS";
        paramNames[1] = "maxMarketCapGrowthBPS";
        paramNames[2] = "minOracleUpdateInterval";
        paramNames[3] = "circuitBreakerCooldown";
        paramNames[4] = "mevMinInterval";
        paramNames[5] = "mevMaxPerBlock";
        paramNames[6] = "mevMaxPerUser";
        paramNames[7] = "maxGasPrice";
        paramNames[8] = "liquidityRatioBPS";
        paramNames[9] = "maxSlippageBPS";
        
        for (uint256 i = 0; i < paramNames.length; i++) {
            paramValues[i] = securityParameters[paramNames[i]];
        }
    }

    function hasValidSignatures(bytes32 proposalId) external view returns (bool) {
        Proposal memory proposal = proposals[proposalId];
        return proposal.signatures >= requiredSignatures;
    }

    function isProposalValid(bytes32 proposalId) external view returns (bool) {
        Proposal memory proposal = proposals[proposalId];
        return proposal.proposer != address(0) && 
               block.timestamp <= proposal.validUntil && 
               !proposal.executed && 
               !proposal.cancelled;
    }

    function getProposalSignatures(bytes32 proposalId) external view returns (
        address[] memory signers,
        uint256 signatureCount
    ) {
        // This would require tracking signers in an array
        // Simplified implementation returning count only
        Proposal memory proposal = proposals[proposalId];
        
        signers = new address[](0); // Placeholder
        signatureCount = proposal.signatures;
    }

    // --- BATCH OPERATIONS ---
    function batchUpdateParameters(
        string[] calldata paramNames,
        uint256[] calldata values
    ) external onlyRole(PARAM_MANAGER_ROLE) returns (bytes32[] memory proposalIds) {
        require(paramNames.length == values.length, "Array length mismatch");
        
        proposalIds = new bytes32[](paramNames.length);
        
        for (uint256 i = 0; i < paramNames.length; i++) {
            proposalIds[i] = this.proposeParameterChange(paramNames[i], values[i]);
        }
    }

    function batchExecuteProposals(bytes32[] calldata proposalIds) external onlyRole(GOVERNANCE_ROLE) {
        for (uint256 i = 0; i < proposalIds.length; i++) {
            try this.executeParameterChange(proposalIds[i]) {
                // Continue on success
            } catch {
                // Continue even if some executions fail
            }
        }
    }

    function batchPauseContracts(address[] calldata contractAddresses) external onlyRole(EMERGENCY_ROLE) {
        for (uint256 i = 0; i < contractAddresses.length; i++) {
            try this.pauseManagedContract(contractAddresses[i]) {
                // Continue on success
            } catch {
                // Continue even if some pause calls fail
            }
        }
    }

    // --- INTERNAL HELPERS ---
    function _initializeRoleTracking(bytes32 role, address account) internal {
        if (roleMembers[role].length == 0 || roleMemberIndex[role][account] == 0) {
            roleMembers[role].push(account);
            roleMemberIndex[role][account] = roleMembers[role].length - 1;
        }
    }

    function _getManagedContractAddresses() internal pure returns (address[] memory) {
        // This would require tracking managed contract addresses in an array
        // Simplified implementation - in practice, you'd maintain a separate array
        address[] memory addresses = new address[](0);
        return addresses;
    }

    function _getImplementation() internal view returns (address) {
        bytes32 slot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address implementation;
        assembly {
            implementation := sload(slot)
        }
        return implementation;
    }

    // --- EMERGENCY RECOVERY ---
    function emergencyRecoverERC20(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(token != address(0), "Invalid token");
        require(to != address(0), "Invalid recipient");
        
        IERC20(token).transfer(to, amount);
    }

    function emergencyRecoverETH(
        address payable to,
        uint256 amount
    ) external onlyRole(GOVERNANCE_ROLE) {
        require(to != address(0), "Invalid recipient");
        require(address(this).balance >= amount, "Insufficient balance");
        
        to.transfer(amount);
    }

    // --- UUPS UPGRADE HOOK ---
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADE_ROLE) {}

    // --- RECEIVE FUNCTION ---
    receive() external payable {}
}