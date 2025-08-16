// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title EmergencySystem
 * @notice Emergency transaction management system
 */

// --- EMERGENCY SYSTEM LIBRARY ---
library EmergencyLib {
    struct EmergencyTransaction {
        address target;
        uint256 value;
        bytes data;
        uint256 executeAfter;
        bool executed;
        address proposer;
        uint256 proposedAt;
        uint256 deadline;
        bool cancelled;
    }

    error TransactionNotFound();
    error TransactionAlreadyExecuted();
    error TransactionCancelled();
    error TimelockNotExpired();
    error TransactionExpired();
    error InvalidTarget();
    error InvalidDelay();

    function proposeTransaction(
        mapping(bytes32 => EmergencyTransaction) storage emergencyTxs,
        address target,
        uint256 value,
        bytes calldata data,
        uint256 delay,
        address proposer
    ) internal returns (bytes32 txHash) {
        if (target == address(0)) revert InvalidTarget();
        if (delay < 1 hours || delay > 7 days) revert InvalidDelay();
        
        txHash = keccak256(abi.encode(target, value, data, block.timestamp, proposer));
        
        uint256 executeAfter = block.timestamp + delay;
        uint256 deadline = executeAfter + 7 days;
        
        emergencyTxs[txHash] = EmergencyTransaction({
            target: target,
            value: value,
            data: data,
            executeAfter: executeAfter,
            executed: false,
            proposer: proposer,
            proposedAt: block.timestamp,
            deadline: deadline,
            cancelled: false
        });
        
        return txHash;
    }

    function executeTransaction(
        mapping(bytes32 => EmergencyTransaction) storage emergencyTxs,
        bytes32 txHash
    ) internal returns (bool success) {
        EmergencyTransaction storage txInfo = emergencyTxs[txHash];
        if (txInfo.target == address(0)) revert TransactionNotFound();
        if (txInfo.cancelled) revert TransactionCancelled();
        if (block.timestamp < txInfo.executeAfter) revert TimelockNotExpired();
        if (block.timestamp > txInfo.deadline) revert TransactionExpired();
        if (txInfo.executed) revert TransactionAlreadyExecuted();

        txInfo.executed = true;
        (success, ) = txInfo.target.call{value: txInfo.value}(txInfo.data);
        
        return success;
    }

    function cancelTransaction(
        mapping(bytes32 => EmergencyTransaction) storage emergencyTxs,
        bytes32 txHash
    ) internal {
        EmergencyTransaction storage txInfo = emergencyTxs[txHash];
        if (txInfo.target == address(0)) revert TransactionNotFound();
        if (txInfo.executed) revert TransactionAlreadyExecuted();
        
        txInfo.cancelled = true;
    }

    function getTransaction(
        mapping(bytes32 => EmergencyTransaction) storage emergencyTxs,
        bytes32 txHash
    ) internal view returns (
        address target,
        uint256 value,
        bytes memory data,
        uint256 executeAfter,
        bool executed,
        address proposer,
        uint256 proposedAt,
        uint256 deadline,
        bool cancelled
    ) {
        EmergencyTransaction memory txInfo = emergencyTxs[txHash];
        return (
            txInfo.target,
            txInfo.value,
            txInfo.data,
            txInfo.executeAfter,
            txInfo.executed,
            txInfo.proposer,
            txInfo.proposedAt,
            txInfo.deadline,
            txInfo.cancelled
        );
    }

    function isTransactionValid(
        mapping(bytes32 => EmergencyTransaction) storage emergencyTxs,
        bytes32 txHash
    ) internal view returns (bool isValid, string memory reason) {
        EmergencyTransaction storage txInfo = emergencyTxs[txHash];
        
        if (txInfo.target == address(0)) {
            return (false, "Transaction not found");
        }
        if (txInfo.cancelled) {
            return (false, "Transaction cancelled");
        }
        if (txInfo.executed) {
            return (false, "Transaction already executed");
        }
        if (block.timestamp < txInfo.executeAfter) {
            return (false, "Timelock not expired");
        }
        if (block.timestamp > txInfo.deadline) {
            return (false, "Transaction expired");
        }
        
        return (true, "Valid");
    }
}

/**
 * @title EmergencySystem Contract
 */
contract EmergencySystem {
    mapping(bytes32 => EmergencyLib.EmergencyTransaction) private emergencyTxs;
    
    event EmergencyTransactionProposed(
        bytes32 indexed txHash, 
        address indexed proposer,
        address indexed target,
        uint256 value,
        uint256 executeAfter,
        uint256 deadline
    );
    
    event EmergencyTransactionExecuted(
        bytes32 indexed txHash,
        address indexed executor,
        bool success
    );
    
    event EmergencyTransactionCancelled(
        bytes32 indexed txHash,
        address indexed canceller
    );
    
    function getLibraryVersion() external pure returns (string memory) {
        return "EM-2.0.0";
    }
    
    function proposeEmergencyTransaction(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 delay
    ) external returns (bytes32) {
        bytes32 txHash = EmergencyLib.proposeTransaction(
            emergencyTxs, 
            target, 
            value, 
            data, 
            delay, 
            msg.sender
        );
        
        EmergencyLib.EmergencyTransaction memory txInfo = emergencyTxs[txHash];
        
        emit EmergencyTransactionProposed(
            txHash,
            msg.sender,
            target,
            value,
            txInfo.executeAfter,
            txInfo.deadline
        );
        
        return txHash;
    }
    
    function executeEmergencyTransaction(bytes32 txHash) external returns (bool success) {
        success = EmergencyLib.executeTransaction(emergencyTxs, txHash);
        emit EmergencyTransactionExecuted(txHash, msg.sender, success);
        return success;
    }
    
    function cancelEmergencyTransaction(bytes32 txHash) external {
        EmergencyLib.cancelTransaction(emergencyTxs, txHash);
        emit EmergencyTransactionCancelled(txHash, msg.sender);
    }
    
    function isEmergencyTransactionValid(bytes32 txHash) external view returns (bool isValid, string memory reason) {
        return EmergencyLib.isTransactionValid(emergencyTxs, txHash);
    }
    
    function getEmergencyTransaction(bytes32 txHash) external view returns (
        address target,
        uint256 value,
        bytes memory data,
        uint256 executeAfter,
        bool executed,
        address proposer,
        uint256 proposedAt,
        uint256 deadline,
        bool cancelled
    ) {
        return EmergencyLib.getTransaction(emergencyTxs, txHash);
    }
    
    function getTransactionStatus(bytes32 txHash) external view returns (
        bool exists,
        bool canExecute,
        bool isExpired,
        uint256 timeUntilExecution,
        uint256 timeUntilExpiry,
        string memory status
    ) {
        EmergencyLib.EmergencyTransaction memory txInfo = emergencyTxs[txHash];
        
        exists = txInfo.target != address(0);
        if (!exists) {
            return (false, false, false, 0, 0, "Not found");
        }
        
        if (txInfo.cancelled) {
            return (true, false, false, 0, 0, "Cancelled");
        }
        
        if (txInfo.executed) {
            return (true, false, false, 0, 0, "Executed");
        }
        
        isExpired = block.timestamp > txInfo.deadline;
        if (isExpired) {
            return (true, false, true, 0, 0, "Expired");
        }
        
        canExecute = block.timestamp >= txInfo.executeAfter;
        
        if (canExecute) {
            timeUntilExpiry = txInfo.deadline > block.timestamp ? 
                txInfo.deadline - block.timestamp : 0;
            return (true, true, false, 0, timeUntilExpiry, "Ready to execute");
        } else {
            timeUntilExecution = txInfo.executeAfter - block.timestamp;
            timeUntilExpiry = txInfo.deadline - block.timestamp;
            return (true, false, false, timeUntilExecution, timeUntilExpiry, "Timelock active");
        }
    }
    
    function getAllTransactionHashes() external pure returns (bytes32[] memory) {
        // Note: This is a simplified implementation
        // In a real system, you'd want to track hashes in an array
        // For now, return empty array as this requires additional storage
        bytes32[] memory empty = new bytes32[](0);
        return empty;
    }
    
    function getTransactionsByProposer(address) external pure returns (bytes32[] memory) {
        // Note: This is a simplified implementation
        // In a real system, you'd want to index by proposer
        // For now, return empty array as this requires additional storage
        bytes32[] memory empty = new bytes32[](0);
        return empty;
    }
    
    function calculateTransactionHash(
        address target,
        uint256 value,
        bytes calldata data,
        uint256 timestamp,
        address proposer
    ) external pure returns (bytes32) {
        return keccak256(abi.encode(target, value, data, timestamp, proposer));
    }
    
    function getMinDelay() external pure returns (uint256) {
        return 1 hours;
    }
    
    function getMaxDelay() external pure returns (uint256) {
        return 7 days;
    }
    
    function getExecutionWindow() external pure returns (uint256) {
        return 7 days;
    }
    
    // Emergency function to check contract balance
    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }
    
    // Allow contract to receive ETH for emergency transactions
    receive() external payable {}
    
    fallback() external payable {}
}