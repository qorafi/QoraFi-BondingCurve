// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title CircuitBreaker
 * @notice Circuit breaker protection library and contract
 */

// --- CIRCUIT BREAKER LIBRARY ---
library CircuitBreakerLib {
    struct CircuitBreakerData {
        bool isTriggered;
        uint256 triggerTime;
        uint256 cooldownPeriod;
        uint256 volumeThreshold;
        uint256 currentVolume;
        uint256 windowStart;
        uint256 windowDuration;
        uint256 triggerCount;
        bool isUpdating;
        uint256 pendingVolume;
        uint256 consecutiveTriggers;
        uint256 lastTriggerTime;
    }

    error CircuitBreakerActive();
    error CircuitBreakerIsUpdating();
    error TooManyConsecutiveTriggers();

    function check(CircuitBreakerData storage cb) internal view {
        if (cb.isUpdating) revert CircuitBreakerIsUpdating();
        if (cb.isTriggered && block.timestamp < cb.triggerTime + cb.cooldownPeriod) {
            revert CircuitBreakerActive();
        }
        
        if (cb.consecutiveTriggers >= 5 && 
            block.timestamp < cb.lastTriggerTime + (cb.cooldownPeriod * 2)) {
            revert TooManyConsecutiveTriggers();
        }
    }

    function atomicCheckAndUpdate(CircuitBreakerData storage cb, uint256 amount) internal returns (bool wasTriggered) {
        if (cb.isUpdating) revert CircuitBreakerIsUpdating();
        cb.isUpdating = true;
        
        if (cb.isTriggered && block.timestamp >= cb.triggerTime + cb.cooldownPeriod) {
            cb.isTriggered = false;
            if (block.timestamp >= cb.lastTriggerTime + (cb.cooldownPeriod * 3)) {
                cb.consecutiveTriggers = 0;
            }
        }
        
        if (cb.isTriggered) {
            cb.isUpdating = false;
            revert CircuitBreakerActive();
        }
        
        if (cb.consecutiveTriggers >= 5 && 
            block.timestamp < cb.lastTriggerTime + (cb.cooldownPeriod * 2)) {
            cb.isUpdating = false;
            revert TooManyConsecutiveTriggers();
        }
        
        if (block.timestamp > cb.windowStart + cb.windowDuration) {
            cb.currentVolume = 0;
            cb.windowStart = block.timestamp;
        }

        uint256 newVolume = cb.currentVolume + amount;
        if (cb.volumeThreshold > 0 && newVolume > cb.volumeThreshold) {
            cb.isTriggered = true;
            cb.triggerTime = block.timestamp;
            cb.triggerCount++;
            
            if (block.timestamp < cb.lastTriggerTime + cb.cooldownPeriod) {
                cb.consecutiveTriggers++;
            } else {
                cb.consecutiveTriggers = 1;
            }
            cb.lastTriggerTime = block.timestamp;
            
            cb.isUpdating = false;
            return true;
        }
        
        cb.currentVolume = newVolume;
        cb.isUpdating = false;
        return false;
    }

    function update(CircuitBreakerData storage cb, uint256 amount) internal returns (bool wasTriggered) {
        if (cb.consecutiveTriggers >= 5 && 
            block.timestamp < cb.lastTriggerTime + (cb.cooldownPeriod * 2)) {
            return false;
        }
        
        if (block.timestamp > cb.windowStart + cb.windowDuration) {
            cb.currentVolume = 0;
            cb.windowStart = block.timestamp;
        }

        if (cb.isTriggered && block.timestamp >= cb.triggerTime + cb.cooldownPeriod) {
            cb.isTriggered = false;
            if (block.timestamp >= cb.lastTriggerTime + (cb.cooldownPeriod * 3)) {
                cb.consecutiveTriggers = 0;
            }
        }

        uint256 newVolume = cb.currentVolume + amount;
        if (cb.volumeThreshold > 0 && newVolume > cb.volumeThreshold) {
            cb.isTriggered = true;
            cb.triggerTime = block.timestamp;
            cb.triggerCount++;
            
            if (block.timestamp < cb.lastTriggerTime + cb.cooldownPeriod) {
                cb.consecutiveTriggers++;
            } else {
                cb.consecutiveTriggers = 1;
            }
            cb.lastTriggerTime = block.timestamp;
            
            return true;
        }
        
        cb.currentVolume = newVolume;
        return false;
    }

    function reset(CircuitBreakerData storage cb) internal {
        cb.isTriggered = false;
        cb.currentVolume = 0;
        cb.windowStart = block.timestamp;
        cb.isUpdating = false;
        cb.consecutiveTriggers = 0;
    }

    function getStatus(CircuitBreakerData storage cb) internal view returns (
        bool circuitTriggered,
        uint256 currentVolume,
        uint256 volumeThreshold,
        uint256 triggerCount,
        uint256 timeUntilReset,
        bool currentlyUpdating,
        uint256 consecutiveTriggers,
        bool inSpamProtection
    ) {
        uint256 timeLeft = 0;
        if (cb.isTriggered && block.timestamp < cb.triggerTime + cb.cooldownPeriod) {
            timeLeft = cb.triggerTime + cb.cooldownPeriod - block.timestamp;
        }
        
        bool spamProtection = cb.consecutiveTriggers >= 5 && 
            block.timestamp < cb.lastTriggerTime + (cb.cooldownPeriod * 2);
        
        return (
            cb.isTriggered,
            cb.currentVolume,
            cb.volumeThreshold,
            cb.triggerCount,
            timeLeft,
            cb.isUpdating,
            cb.consecutiveTriggers,
            spamProtection
        );
    }
}

/**
 * @title CircuitBreaker Contract
 */
contract CircuitBreaker {
    using CircuitBreakerLib for CircuitBreakerLib.CircuitBreakerData;
    
    CircuitBreakerLib.CircuitBreakerData private circuitBreaker;
    
    event CircuitBreakerTriggered(uint256 volume, uint256 threshold);
    event CircuitBreakerReset();
    
    function getLibraryVersion() external pure returns (string memory) {
        return "CB-2.0.0";
    }
    
    function checkCircuitBreaker() external view {
        circuitBreaker.check();
    }
    
    function updateCircuitBreaker(uint256 amount) external returns (bool wasTriggered) {
        bool triggerResult = circuitBreaker.update(amount);
        if (triggerResult) {
            emit CircuitBreakerTriggered(amount, circuitBreaker.volumeThreshold);
        }
        return triggerResult;
    }
    
    function atomicUpdateCircuitBreaker(uint256 amount) external returns (bool wasTriggered) {
        bool triggerResult = circuitBreaker.atomicCheckAndUpdate(amount);
        if (triggerResult) {
            emit CircuitBreakerTriggered(amount, circuitBreaker.volumeThreshold);
        }
        return triggerResult;
    }
    
    function getCircuitBreakerStatus() external view returns (
        bool circuitTriggered,
        uint256 currentVolume,
        uint256 volumeThreshold,
        uint256 triggerCount,
        uint256 timeUntilReset,
        bool currentlyUpdating,
        uint256 consecutiveTriggers,
        bool inSpamProtection
    ) {
        return circuitBreaker.getStatus();
    }
    
    function initializeCircuitBreaker(
        uint256 volumeThreshold,
        uint256 cooldownPeriod,
        uint256 windowDuration
    ) external {
        require(cooldownPeriod >= 10 minutes && cooldownPeriod <= 24 hours, "Invalid cooldown");
        require(windowDuration > 0 && windowDuration <= 24 hours, "Invalid window");
        require(cooldownPeriod <= windowDuration, "Cooldown > window");
        
        circuitBreaker.volumeThreshold = volumeThreshold;
        circuitBreaker.cooldownPeriod = cooldownPeriod;
        circuitBreaker.windowDuration = windowDuration;
        circuitBreaker.windowStart = block.timestamp;
    }
    
    function resetCircuitBreaker() external {
        circuitBreaker.reset();
        emit CircuitBreakerReset();
    }
    
    function isCircuitBreakerActive() external view returns (bool) {
        return circuitBreaker.isTriggered && 
               block.timestamp < circuitBreaker.triggerTime + circuitBreaker.cooldownPeriod;
    }
    
    function getTimeUntilReset() external view returns (uint256) {
        if (!circuitBreaker.isTriggered) return 0;
        
        uint256 resetTime = circuitBreaker.triggerTime + circuitBreaker.cooldownPeriod;
        if (block.timestamp >= resetTime) return 0;
        
        return resetTime - block.timestamp;
    }
    
    function getCurrentVolume() external view returns (uint256) {
        return circuitBreaker.currentVolume;
    }
    
    function getVolumeThreshold() external view returns (uint256) {
        return circuitBreaker.volumeThreshold;
    }
    
    function getTriggerCount() external view returns (uint256) {
        return circuitBreaker.triggerCount;
    }
    
    function getConsecutiveTriggers() external view returns (uint256) {
        return circuitBreaker.consecutiveTriggers;
    }
    
    function isInSpamProtection() external view returns (bool) {
        return circuitBreaker.consecutiveTriggers >= 5 && 
               block.timestamp < circuitBreaker.lastTriggerTime + (circuitBreaker.cooldownPeriod * 2);
    }
    
    function getWindowInfo() external view returns (
        uint256 windowStart,
        uint256 windowDuration,
        uint256 timeLeftInWindow
    ) {
        windowStart = circuitBreaker.windowStart;
        windowDuration = circuitBreaker.windowDuration;
        
        uint256 windowEnd = windowStart + windowDuration;
        if (block.timestamp >= windowEnd) {
            timeLeftInWindow = 0;
        } else {
            timeLeftInWindow = windowEnd - block.timestamp;
        }
    }
}