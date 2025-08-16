// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title MEVProtection
 * @notice MEV protection and validation libraries
 */

// --- MEV PROTECTION LIBRARY ---
library MEVLib {
    struct MEVConfig {
        uint256 minDepositInterval;
        uint256 maxDepositPerBlock;
        uint256 maxDepositPerUser;
        mapping(address => uint256) lastDepositBlock;
        mapping(address => uint256) userDailyVolume;
        mapping(address => uint256) userDayStart;
        mapping(uint256 => uint256) blockDepositTotal;
        mapping(address => uint256) lastInteractionBlock;
    }

    error DepositTooFrequent();
    error BlockDepositLimitExceeded();
    error DailyLimitExceeded();
    error FlashLoanProtection();

    function checkPreDeposit(MEVConfig storage mev, address user, uint256 amount) internal view {
        if (mev.lastInteractionBlock[user] == block.number) {
            revert FlashLoanProtection();
        }
        
        if (mev.minDepositInterval > 0 && block.number - mev.lastDepositBlock[user] < mev.minDepositInterval) {
            revert DepositTooFrequent();
        }
        
        if (mev.maxDepositPerBlock > 0 && mev.blockDepositTotal[block.number] + amount > mev.maxDepositPerBlock) {
            revert BlockDepositLimitExceeded();
        }
        
        uint256 currentDay = _getCurrentDay();
        if (mev.maxDepositPerUser > 0 && mev.userDayStart[user] == currentDay) {
            if (mev.userDailyVolume[user] + amount > mev.maxDepositPerUser) {
                revert DailyLimitExceeded();
            }
        }
    }

    function updatePostDeposit(MEVConfig storage mev, address user, uint256 amount) internal {
        mev.lastDepositBlock[user] = block.number;
        mev.lastInteractionBlock[user] = block.number;
        mev.blockDepositTotal[block.number] += amount;
        
        uint256 currentDay = _getCurrentDay();
        
        if (mev.userDayStart[user] != currentDay) {
            mev.userDayStart[user] = currentDay;
            mev.userDailyVolume[user] = amount;
        } else {
            mev.userDailyVolume[user] += amount;
        }
    }

    function _getCurrentDay() internal view returns (uint256) {
        return block.timestamp / 86400;
    }

    function getUserStatus(MEVConfig storage mev, address user) internal view returns (
        uint256 lastBlock,
        uint256 blocksSince,
        bool canDeposit,
        uint256 dailyUsed,
        uint256 dailyRemaining
    ) {
        lastBlock = mev.lastDepositBlock[user];
        blocksSince = block.number > lastBlock ? block.number - lastBlock : 0;
        
        bool flashLoanSafe = mev.lastInteractionBlock[user] != block.number;
        bool intervalSafe = blocksSince >= mev.minDepositInterval;
        canDeposit = flashLoanSafe && intervalSafe;
        
        uint256 currentDay = _getCurrentDay();
        if (mev.userDayStart[user] == currentDay) {
            dailyUsed = mev.userDailyVolume[user];
        } else {
            dailyUsed = 0;
        }
        
        dailyRemaining = mev.maxDepositPerUser > dailyUsed ? mev.maxDepositPerUser - dailyUsed : 0;
    }

    function validateDeposit(MEVConfig storage mev, address user, uint256 amount) internal view returns (bool isValid, string memory reason) {
        if (mev.lastInteractionBlock[user] == block.number) {
            return (false, "Flash loan protection: wait next block");
        }
        
        if (mev.minDepositInterval > 0 && block.number - mev.lastDepositBlock[user] < mev.minDepositInterval) {
            return (false, "Deposit too frequent");
        }
        
        if (mev.maxDepositPerBlock > 0 && mev.blockDepositTotal[block.number] + amount > mev.maxDepositPerBlock) {
            return (false, "Block deposit limit exceeded");
        }
        
        uint256 currentDay = _getCurrentDay();
        if (mev.maxDepositPerUser > 0 && mev.userDayStart[user] == currentDay) {
            if (mev.userDailyVolume[user] + amount > mev.maxDepositPerUser) {
                return (false, "Daily limit exceeded");
            }
        }
        
        return (true, "OK");
    }

    function getWaitTimes(MEVConfig storage mev, address user) internal view returns (
        uint256 blocksToWait,
        uint256 timeToNextDay
    ) {
        uint256 blocksSince = block.number > mev.lastDepositBlock[user] ? 
            block.number - mev.lastDepositBlock[user] : 0;
        
        if (blocksSince < mev.minDepositInterval) {
            blocksToWait = mev.minDepositInterval - blocksSince;
        } else {
            blocksToWait = 0;
        }
        
        uint256 currentDay = _getCurrentDay();
        uint256 nextDay = currentDay + 1;
        uint256 nextDayStart = nextDay * 86400;
        timeToNextDay = nextDayStart > block.timestamp ? nextDayStart - block.timestamp : 0;
    }
}

// --- VALIDATION LIBRARY ---
library ValidationLib {
    error InvalidAmount();
    error InvalidAddress();
    error InvalidConfiguration();
    error InvalidDelay();
    error GasPriceTooHigh();
    error NewTokenLimitExceeded();
    error InvalidSlippage();
    error InvalidRatio();

    uint256 public constant MAX_BPS = 10000;
    uint256 public constant MIN_DEPOSIT_INTERVAL_BLOCKS = 5;
    uint256 public constant MAX_SINGLE_DEPOSIT_NEW_TOKEN = 5000 * 10**18;
    uint256 public constant MAX_SLIPPAGE_BPS = 1000; // 10%
    uint256 public constant MIN_SLIPPAGE_BPS = 1; // 0.01%

    function validateAmount(uint256 amount, uint256 minAmount, uint256 maxAmount) internal pure {
        if (amount < minAmount || amount > maxAmount) revert InvalidAmount();
    }

    function validateAddress(address addr) internal pure {
        if (addr == address(0)) revert InvalidAddress();
    }

    function validateNewTokenLimits(
        uint256 amount,
        uint256 gasPrice,
        uint256 maxGasPrice,
        bool newTokenMode
    ) internal pure {
        if (newTokenMode) {
            if (amount > MAX_SINGLE_DEPOSIT_NEW_TOKEN) revert NewTokenLimitExceeded();
            if (gasPrice > maxGasPrice) revert GasPriceTooHigh();
            if (amount == 0) revert InvalidAmount();
            if (maxGasPrice == 0) revert InvalidConfiguration();
        }
    }

    function validateDelay(uint256 delay, uint256 minDelay, uint256 maxDelay) internal pure {
        if (delay < minDelay || delay > maxDelay) revert InvalidDelay();
    }

    function validateBPS(uint256 bps) internal pure {
        if (bps > MAX_BPS) revert InvalidConfiguration();
    }

    function validateSlippage(uint256 slippageBps) internal pure {
        if (slippageBps < MIN_SLIPPAGE_BPS || slippageBps > MAX_SLIPPAGE_BPS) {
            revert InvalidSlippage();
        }
    }

    function validateRatio(uint256 ratioBps, uint256 minRatio, uint256 maxRatio) internal pure {
        if (ratioBps < minRatio || ratioBps > maxRatio) {
            revert InvalidRatio();
        }
    }

    function validateMEVConfig(
        uint256 minInterval,
        uint256 maxPerBlock,
        uint256 maxPerUser
    ) internal pure {
        if (minInterval < 1) revert InvalidConfiguration();
        if (maxPerBlock == 0) revert InvalidConfiguration();
        if (maxPerUser == 0) revert InvalidConfiguration();
        if (minInterval > 100) revert InvalidConfiguration();
        if (maxPerBlock > maxPerUser) revert InvalidConfiguration();
    }

    function validateCircuitBreakerConfig(uint256 cooldown, uint256 window) internal pure {
        if (cooldown < 10 minutes || cooldown > 24 hours) revert InvalidConfiguration();
        if (window == 0 || window > 24 hours) revert InvalidConfiguration();
        if (cooldown > window) revert InvalidConfiguration();
    }

    function validateArrayLengths(uint256 array1Length, uint256 array2Length) internal pure {
        if (array1Length != array2Length) revert InvalidConfiguration();
    }

    function validatePercentageBounds(
        uint256 value,
        uint256 baseValue,
        uint256 maxPercentageBps
    ) internal pure {
        if (baseValue == 0) return;
        
        uint256 percentageBps = (value * MAX_BPS) / baseValue;
        if (percentageBps > maxPercentageBps) {
            revert InvalidConfiguration();
        }
    }
}

/**
 * @title MEVProtection Contract
 */
contract MEVProtection {
    using MEVLib for MEVLib.MEVConfig;
    
    MEVLib.MEVConfig private mevProtection;
    
    event MEVProtectionTriggered(address indexed user, string reason);
    
    function getLibraryVersion() external pure returns (string memory) {
        return "MEV-2.0.0";
    }
    
    function validateDeposit(address user, uint256 amount) external view returns (bool isValid, string memory reason) {
        return mevProtection.validateDeposit(user, amount);
    }
    
    function updatePostDeposit(address user, uint256 amount) external {
        mevProtection.updatePostDeposit(user, amount);
    }
    
    function getWaitTimes(address user) external view returns (uint256 blocksToWait, uint256 timeToNextDay) {
        return mevProtection.getWaitTimes(user);
    }
    
    function getMEVProtectionStatus(address user) external view returns (
        uint256 lastBlock,
        uint256 blocksSince,
        bool canDeposit,
        uint256 dailyUsed,
        uint256 dailyRemaining,
        uint256 blocksToWait,
        uint256 timeToNextDay,
        bool flashLoanSafe
    ) {
        (lastBlock, blocksSince, canDeposit, dailyUsed, dailyRemaining) = mevProtection.getUserStatus(user);
        (blocksToWait, timeToNextDay) = mevProtection.getWaitTimes(user);
        flashLoanSafe = mevProtection.lastInteractionBlock[user] != block.number;
    }
    
    function checkDepositEligibility(address user, uint256 amount) external view returns (
        bool canDeposit,
        string memory reason,
        uint256 suggestedWaitTime
    ) {
        (canDeposit, reason) = mevProtection.validateDeposit(user, amount);
        
        if (!canDeposit) {
            (uint256 blocksToWait, uint256 timeToNextDay) = mevProtection.getWaitTimes(user);
            
            if (blocksToWait > 0) {
                suggestedWaitTime = blocksToWait * 3;
            } else if (timeToNextDay > 0) {
                suggestedWaitTime = timeToNextDay;
            }
        }
    }
    
    function getCurrentDay() external view returns (uint256) {
        return block.timestamp / 86400;
    }
    
    function initializeMEVProtection(
        uint256 minInterval,
        uint256 maxPerBlock,
        uint256 maxPerUser
    ) external {
        ValidationLib.validateMEVConfig(minInterval, maxPerBlock, maxPerUser);
        
        mevProtection.minDepositInterval = minInterval;
        mevProtection.maxDepositPerBlock = maxPerBlock;
        mevProtection.maxDepositPerUser = maxPerUser;
    }
    
    function getBlockInfo() external view returns (
        uint256 blockNumber,
        uint256 blockTime,
        uint256 currentDay
    ) {
        return (block.number, block.timestamp, block.timestamp / 86400);
    }
    
    // Validation functions
    function validateAmount(uint256 amount, uint256 minAmount, uint256 maxAmount) external pure {
        ValidationLib.validateAmount(amount, minAmount, maxAmount);
    }
    
    function validateAddress(address addr) external pure {
        ValidationLib.validateAddress(addr);
    }
    
    function validateSlippage(uint256 slippageBps) external pure {
        ValidationLib.validateSlippage(slippageBps);
    }
    
    function validateRatio(uint256 ratioBps, uint256 minRatio, uint256 maxRatio) external pure {
        ValidationLib.validateRatio(ratioBps, minRatio, maxRatio);
    }
}