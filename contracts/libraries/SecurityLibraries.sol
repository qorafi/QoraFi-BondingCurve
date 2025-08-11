// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title SecurityLibraries
 * @notice Collection of security-focused libraries for MEV protection, circuit breaking, and validation
 * @dev Extracted from monolithic contracts to improve modularity and reduce contract sizes
 */

// --- MEV PROTECTION LIBRARY ---
library MEVLib {
    struct MEVProtection {
        uint256 minDepositInterval;
        uint256 maxDepositPerBlock;
        uint256 maxDepositPerUser;
        mapping(address => uint256) lastDepositBlock;
        mapping(address => uint256) userDailyVolume;
        mapping(address => uint256) userDayStart;
        mapping(uint256 => uint256) blockDepositTotal;
    }

    // Define errors within the library
    error DepositTooFrequent();
    error BlockDepositLimitExceeded();
    error DailyLimitExceeded();

    /**
     * @notice Validates deposit before execution
     * @param mev MEV protection storage
     * @param user Address of the user
     * @param amount Deposit amount to validate
     */
    function checkPreDeposit(MEVProtection storage mev, address user, uint256 amount) internal view {
        // Enhanced check for new token - more blocks required
        if (mev.minDepositInterval > 0 && block.number - mev.lastDepositBlock[user] < mev.minDepositInterval) {
            revert DepositTooFrequent();
        }
        
        // Atomic block deposit check to prevent race conditions
        if (mev.maxDepositPerBlock > 0 && mev.blockDepositTotal[block.number] + amount > mev.maxDepositPerBlock) {
            revert BlockDepositLimitExceeded();
        }
        
        // Enhanced daily limit tracking
        uint256 userDayStart = mev.userDayStart[user];
        if (mev.maxDepositPerUser > 0 && userDayStart != 0 && block.timestamp < userDayStart + 1 days) {
            if (mev.userDailyVolume[user] + amount > mev.maxDepositPerUser) {
                revert DailyLimitExceeded();
            }
        }
    }

    /**
     * @notice Updates MEV protection state after successful deposit
     * @param mev MEV protection storage
     * @param user Address of the user
     * @param amount Deposit amount
     */
    function updatePostDeposit(MEVProtection storage mev, address user, uint256 amount) internal {
        mev.lastDepositBlock[user] = block.number;
        mev.blockDepositTotal[block.number] += amount;
        
        // Fixed: Proper daily volume initialization and tracking
        if (mev.userDayStart[user] == 0 || block.timestamp >= mev.userDayStart[user] + 1 days) {
            mev.userDayStart[user] = block.timestamp;
            mev.userDailyVolume[user] = amount;
        } else {
            mev.userDailyVolume[user] += amount;
        }
    }

    /**
     * @notice Gets user's MEV protection status
     * @param mev MEV protection storage
     * @param user Address of the user
     * @return lastBlock Last deposit block
     * @return blocksSince Blocks since last deposit
     * @return canDeposit Whether user can deposit now
     * @return dailyUsed Daily volume used
     * @return dailyRemaining Daily volume remaining
     */
    function getUserStatus(MEVProtection storage mev, address user) internal view returns (
        uint256 lastBlock,
        uint256 blocksSince,
        bool canDeposit,
        uint256 dailyUsed,
        uint256 dailyRemaining
    ) {
        lastBlock = mev.lastDepositBlock[user];
        blocksSince = block.number > lastBlock ? block.number - lastBlock : 0;
        canDeposit = blocksSince >= mev.minDepositInterval;
        dailyUsed = mev.userDailyVolume[user];
        dailyRemaining = mev.maxDepositPerUser > dailyUsed ? mev.maxDepositPerUser - dailyUsed : 0;
    }

    /**
     * @notice Validates user deposit eligibility
     * @param mev MEV protection storage
     * @param user Address of the user
     * @param amount Deposit amount
     * @return isValid Whether deposit is valid
     * @return reason Reason if not valid
     */
    function validateDeposit(MEVProtection storage mev, address user, uint256 amount) internal view returns (bool isValid, string memory reason) {
        if (mev.minDepositInterval > 0 && block.number - mev.lastDepositBlock[user] < mev.minDepositInterval) {
            return (false, "Deposit too frequent");
        }
        if (mev.maxDepositPerBlock > 0 && mev.blockDepositTotal[block.number] + amount > mev.maxDepositPerBlock) {
            return (false, "Block deposit limit exceeded");
        }
        uint256 userDayStart = mev.userDayStart[user];
        if (mev.maxDepositPerUser > 0 && userDayStart != 0 && block.timestamp < userDayStart + 1 days) {
            if (mev.userDailyVolume[user] + amount > mev.maxDepositPerUser) {
                return (false, "Daily limit exceeded");
            }
        }
        return (true, "OK");
    }
}

// --- CIRCUIT BREAKER LIBRARY ---
library CircuitBreakerLib {
    struct CircuitBreaker {
        bool triggered;
        uint256 triggerTime;
        uint256 cooldownPeriod;
        uint256 volumeThreshold;
        uint256 currentVolume;
        uint256 windowStart;
        uint256 windowDuration;
        uint256 triggerCount;
        bool updating;
        uint256 pendingVolume;
    }

    // Define errors within the library
    error CircuitBreakerActive();
    error CircuitBreakerUpdating();

    /**
     * @notice Checks if circuit breaker allows operations
     * @param cb Circuit breaker storage
     */
    function check(CircuitBreaker storage cb) internal view {
        if (cb.updating) revert CircuitBreakerUpdating();
        if (cb.triggered && block.timestamp < cb.triggerTime + cb.cooldownPeriod) {
            revert CircuitBreakerActive();
        }
    }

    /**
     * @notice Atomically checks and updates circuit breaker
     * @param cb Circuit breaker storage
     * @param amount Amount to add to volume
     * @return triggered Whether circuit breaker was triggered
     */
    function atomicCheckAndUpdate(CircuitBreaker storage cb, uint256 amount) internal returns (bool triggered) {
        // Set updating flag to prevent race conditions
        if (cb.updating) revert CircuitBreakerUpdating();
        cb.updating = true;
        
        // Check if cooldown expired
        if (cb.triggered && block.timestamp >= cb.triggerTime + cb.cooldownPeriod) {
            cb.triggered = false;
        }
        
        // If still triggered, revert
        if (cb.triggered) {
            cb.updating = false;
            revert CircuitBreakerActive();
        }
        
        // Reset window if expired
        if (block.timestamp > cb.windowStart + cb.windowDuration) {
            cb.currentVolume = 0;
            cb.windowStart = block.timestamp;
        }

        // Check if new volume would trigger circuit breaker
        uint256 newVolume = cb.currentVolume + amount;
        if (cb.volumeThreshold > 0 && newVolume > cb.volumeThreshold) {
            cb.triggered = true;
            cb.triggerTime = block.timestamp;
            cb.triggerCount++;
            cb.updating = false;
            return true; // Return true to indicate triggering
        }
        
        // Update volume
        cb.currentVolume = newVolume;
        cb.updating = false;
        return false;
    }

    /**
     * @notice Updates circuit breaker without reverting
     * @param cb Circuit breaker storage
     * @param amount Amount to add to volume
     * @return triggered Whether circuit breaker was triggered
     */
    function update(CircuitBreaker storage cb, uint256 amount) internal returns (bool triggered) {
        if (block.timestamp > cb.windowStart + cb.windowDuration) {
            cb.currentVolume = 0;
            cb.windowStart = block.timestamp;
        }

        if (cb.triggered && block.timestamp >= cb.triggerTime + cb.cooldownPeriod) {
            cb.triggered = false;
        }

        uint256 newVolume = cb.currentVolume + amount;
        if (cb.volumeThreshold > 0 && newVolume > cb.volumeThreshold) {
            cb.triggered = true;
            cb.triggerTime = block.timestamp;
            cb.triggerCount++;
            return true; // Return true instead of reverting
        }
        
        cb.currentVolume = newVolume;
        return false;
    }

    /**
     * @notice Resets circuit breaker to initial state
     * @param cb Circuit breaker storage
     */
    function reset(CircuitBreaker storage cb) internal {
        cb.triggered = false;
        cb.currentVolume = 0;
        cb.windowStart = block.timestamp;
        cb.updating = false;
    }

    /**
     * @notice Gets circuit breaker status
     * @param cb Circuit breaker storage
     * @return triggered Whether circuit breaker is triggered
     * @return currentVolume Current volume in window
     * @return volumeThreshold Volume threshold
     * @return triggerCount Number of times triggered
     * @return timeUntilReset Time until reset (if triggered)
     * @return updating Whether currently updating
     */
    function getStatus(CircuitBreaker storage cb) internal view returns (
        bool triggered,
        uint256 currentVolume,
        uint256 volumeThreshold,
        uint256 triggerCount,
        uint256 timeUntilReset,
        bool updating
    ) {
        uint256 timeLeft = 0;
        if (cb.triggered && block.timestamp < cb.triggerTime + cb.cooldownPeriod) {
            timeLeft = cb.triggerTime + cb.cooldownPeriod - block.timestamp;
        }
        
        return (
            cb.triggered,
            cb.currentVolume,
            cb.volumeThreshold,
            cb.triggerCount,
            timeLeft,
            cb.updating
        );
    }
}

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
    }

    // Emergency system errors
    error TransactionNotFound();
    error TransactionAlreadyExecuted();
    error TimelockNotExpired();
    error InvalidTarget();

    /**
     * @notice Creates a new emergency transaction proposal
     * @param emergencyTxs Mapping of emergency transactions
     * @param target Target contract address
     * @param value ETH value to send
     * @param data Transaction data
     * @param delay Timelock delay
     * @param proposer Address of proposer
     * @return txHash Hash of the transaction
     */
    function proposeTransaction(
        mapping(bytes32 => EmergencyTransaction) storage emergencyTxs,
        address target,
        uint256 value,
        bytes calldata data,
        uint256 delay,
        address proposer
    ) internal returns (bytes32 txHash) {
        if (target == address(0)) revert InvalidTarget();
        
        txHash = keccak256(abi.encode(target, value, data, block.timestamp, proposer));
        
        emergencyTxs[txHash] = EmergencyTransaction({
            target: target,
            value: value,
            data: data,
            executeAfter: block.timestamp + delay,
            executed: false,
            proposer: proposer,
            proposedAt: block.timestamp
        });
        
        return txHash;
    }

    /**
     * @notice Executes an emergency transaction
     * @param emergencyTxs Mapping of emergency transactions
     * @param txHash Transaction hash
     * @return success Whether execution was successful
     */
    function executeTransaction(
        mapping(bytes32 => EmergencyTransaction) storage emergencyTxs,
        bytes32 txHash
    ) internal returns (bool success) {
        EmergencyTransaction storage txInfo = emergencyTxs[txHash];
        if (txInfo.target == address(0)) revert TransactionNotFound();
        if (block.timestamp < txInfo.executeAfter) revert TimelockNotExpired();
        if (txInfo.executed) revert TransactionAlreadyExecuted();

        txInfo.executed = true;
        (success, ) = txInfo.target.call{value: txInfo.value}(txInfo.data);
        
        return success;
    }

    /**
     * @notice Cancels an emergency transaction
     * @param emergencyTxs Mapping of emergency transactions
     * @param txHash Transaction hash
     */
    function cancelTransaction(
        mapping(bytes32 => EmergencyTransaction) storage emergencyTxs,
        bytes32 txHash
    ) internal {
        EmergencyTransaction storage txInfo = emergencyTxs[txHash];
        if (txInfo.target == address(0)) revert TransactionNotFound();
        if (txInfo.executed) revert TransactionAlreadyExecuted();
        
        delete emergencyTxs[txHash];
    }

    /**
     * @notice Gets emergency transaction details
     * @param emergencyTxs Mapping of emergency transactions
     * @param txHash Transaction hash
     * @return target Target address
     * @return value ETH value
     * @return data Transaction data
     * @return executeAfter Execution timestamp
     * @return executed Whether executed
     * @return proposer Proposer address
     * @return proposedAt Proposal timestamp
     */
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
        uint256 proposedAt
    ) {
        EmergencyTransaction memory txInfo = emergencyTxs[txHash];
        return (
            txInfo.target,
            txInfo.value,
            txInfo.data,
            txInfo.executeAfter,
            txInfo.executed,
            txInfo.proposer,
            txInfo.proposedAt
        );
    }
}

// --- VALIDATION LIBRARY ---
library ValidationLib {
    // Validation errors
    error InvalidAmount();
    error InvalidAddress();
    error InvalidConfiguration();
    error InvalidDelay();
    error GasPriceTooHigh();
    error NewTokenLimitExceeded();

    uint256 public constant MAX_BPS = 10000;
    uint256 public constant MIN_DEPOSIT_INTERVAL_BLOCKS = 5;
    uint256 public constant MAX_SINGLE_DEPOSIT_NEW_TOKEN = 5000 * 10**6;

    /**
     * @notice Validates deposit amount
     * @param amount Deposit amount
     * @param minAmount Minimum allowed amount
     * @param maxAmount Maximum allowed amount
     */
    function validateAmount(uint256 amount, uint256 minAmount, uint256 maxAmount) internal pure {
        if (amount < minAmount || amount > maxAmount) revert InvalidAmount();
    }

    /**
     * @notice Validates address is not zero
     * @param addr Address to validate
     */
    function validateAddress(address addr) internal pure {
        if (addr == address(0)) revert InvalidAddress();
    }

    /**
     * @notice Validates new token specific limits
     * @param amount Deposit amount
     * @param gasPrice Current gas price
     * @param maxGasPrice Maximum allowed gas price
     * @param newTokenMode Whether new token mode is active
     */
    function validateNewTokenLimits(
        uint256 amount,
        uint256 gasPrice,
        uint256 maxGasPrice,
        bool newTokenMode
    ) internal pure {
        if (newTokenMode) {
            if (amount > MAX_SINGLE_DEPOSIT_NEW_TOKEN) revert NewTokenLimitExceeded();
            if (gasPrice > maxGasPrice) revert GasPriceTooHigh();
        }
    }

    /**
     * @notice Validates timelock delay
     * @param delay Delay in seconds
     * @param minDelay Minimum allowed delay
     * @param maxDelay Maximum allowed delay
     */
    function validateDelay(uint256 delay, uint256 minDelay, uint256 maxDelay) internal pure {
        if (delay < minDelay || delay > maxDelay) revert InvalidDelay();
    }

    /**
     * @notice Validates BPS (basis points) value
     * @param bps Basis points value
     */
    function validateBPS(uint256 bps) internal pure {
        if (bps > MAX_BPS) revert InvalidConfiguration();
    }

    /**
     * @notice Validates configuration parameters
     * @param minInterval Minimum interval
     * @param maxPerBlock Maximum per block
     * @param maxPerUser Maximum per user
     */
    function validateMEVConfig(
        uint256 minInterval,
        uint256 maxPerBlock,
        uint256 maxPerUser
    ) internal pure {
        if (minInterval < 1) revert InvalidConfiguration();
        if (maxPerBlock == 0) revert InvalidConfiguration();
        if (maxPerUser == 0) revert InvalidConfiguration();
    }

    /**
     * @notice Validates circuit breaker configuration
     * @param cooldown Cooldown period
     * @param window Window duration
     */
    function validateCircuitBreakerConfig(uint256 cooldown, uint256 window) internal pure {
        if (cooldown < 10 minutes || cooldown > 24 hours) revert InvalidConfiguration();
        if (window == 0 || window > 24 hours) revert InvalidConfiguration();
    }
}