// test/unit/core/CoreSecurityManager.test.js
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

describe("CoreSecurityManager", function () {
  async function deployCoreSecurityManagerFixture() {
    const [owner, user1, user2, treasury, governance, emergency, monitor] = await ethers.getSigners();
    
    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const usdt = await MockERC20.deploy("Mock USDT", "USDT", 6, ethers.parseUnits("1000000", 6));
    const qorafi = await MockERC20.deploy("Qorafi Token", "QORAFI", 18, ethers.parseEther("1000000"));
    
    // Deploy libraries first
    const SecurityLibraries = await ethers.getContractFactory("SecurityLibraries");
    const securityLibraries = await SecurityLibraries.deploy();
    
    // Deploy CoreSecurityManager with libraries
    const CoreSecurityManager = await ethers.getContractFactory("CoreSecurityManager", {
      libraries: {
        MEVLib: await securityLibraries.getAddress(),
        CircuitBreakerLib: await securityLibraries.getAddress(),
        ValidationLib: await securityLibraries.getAddress(),
      },
    });
    
    const coreSecurityManager = await upgrades.deployProxy(CoreSecurityManager, [
      await usdt.getAddress(),
      await qorafi.getAddress(),
      treasury.address
    ], {
      initializer: 'initialize',
      kind: 'uups',
      unsafeAllow: ['external-library-linking']
    });
    
    // Grant roles
    const GOVERNANCE_ROLE = await coreSecurityManager.GOVERNANCE_ROLE();
    const EMERGENCY_ROLE = await coreSecurityManager.EMERGENCY_ROLE();
    const MONITOR_ROLE = await coreSecurityManager.MONITOR_ROLE();
    
    await coreSecurityManager.grantRole(GOVERNANCE_ROLE, governance.address);
    await coreSecurityManager.grantRole(EMERGENCY_ROLE, emergency.address);
    await coreSecurityManager.grantRole(MONITOR_ROLE, monitor.address);
    
    return { 
      coreSecurityManager, 
      usdt, 
      qorafi, 
      owner, 
      user1, 
      user2, 
      treasury,
      governance,
      emergency,
      monitor
    };
  }

  describe("Initialization", function () {
    it("Should initialize with correct parameters", async function () {
      const { coreSecurityManager, usdt, qorafi, treasury } = await loadFixture(deployCoreSecurityManagerFixture);
      
      expect(await coreSecurityManager.usdtToken()).to.equal(await usdt.getAddress());
      expect(await coreSecurityManager.qorafiToken()).to.equal(await qorafi.getAddress());
      expect(await coreSecurityManager.treasuryWallet()).to.equal(treasury.address);
      expect(await coreSecurityManager.newTokenMode()).to.be.true;
    });

    it("Should set up initial security parameters", async function () {
      const { coreSecurityManager } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const cbStatus = await coreSecurityManager.getCircuitBreakerStatus();
      expect(cbStatus.volumeThreshold).to.equal(ethers.parseUnits("100000", 6));
      
      const newTokenSettings = await coreSecurityManager.getNewTokenSettings();
      expect(newTokenSettings.newTokenModeActive).to.be.true;
      expect(newTokenSettings.maxGasPriceSetting).to.equal(ethers.parseUnits("20", "gwei"));
    });

    it("Should set up initial MEV protection parameters", async function () {
      const { coreSecurityManager } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const mevSettings = await coreSecurityManager.getMEVProtectionSettings();
      expect(mevSettings.mevMinInterval).to.equal(5); // 5 blocks
      expect(mevSettings.maxDepositPerBlock).to.equal(ethers.parseUnits("50000", 6)); // 50k USDT
      expect(mevSettings.maxDepositPerUser).to.equal(ethers.parseUnits("25000", 6)); // 25k USDT
    });

    it("Should grant correct roles during initialization", async function () {
      const { coreSecurityManager, owner, governance, emergency, monitor } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const DEFAULT_ADMIN_ROLE = await coreSecurityManager.DEFAULT_ADMIN_ROLE();
      const GOVERNANCE_ROLE = await coreSecurityManager.GOVERNANCE_ROLE();
      const EMERGENCY_ROLE = await coreSecurityManager.EMERGENCY_ROLE();
      const MONITOR_ROLE = await coreSecurityManager.MONITOR_ROLE();
      
      expect(await coreSecurityManager.hasRole(DEFAULT_ADMIN_ROLE, owner.address)).to.be.true;
      expect(await coreSecurityManager.hasRole(GOVERNANCE_ROLE, governance.address)).to.be.true;
      expect(await coreSecurityManager.hasRole(EMERGENCY_ROLE, emergency.address)).to.be.true;
      expect(await coreSecurityManager.hasRole(MONITOR_ROLE, monitor.address)).to.be.true;
    });
  });

  describe("MEV Protection", function () {
    it("Should allow first deposit", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const depositAmount = ethers.parseUnits("1000", 6);
      const [canDeposit, reason] = await coreSecurityManager.canUserDeposit(user1.address, depositAmount);
      
      expect(canDeposit).to.be.true;
      expect(reason).to.equal("OK");
    });

    it("Should prevent deposits that exceed daily limits", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const largeAmount = ethers.parseUnits("30000", 6); // Exceeds 25k daily limit
      const [canDeposit, reason] = await coreSecurityManager.canUserDeposit(user1.address, largeAmount);
      
      expect(canDeposit).to.be.false;
      expect(reason).to.include("limit");
    });

    it("Should prevent deposits that exceed block limits", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const blockLimitAmount = ethers.parseUnits("60000", 6); // Exceeds 50k block limit
      const [canDeposit, reason] = await coreSecurityManager.canUserDeposit(user1.address, blockLimitAmount);
      
      expect(canDeposit).to.be.false;
      expect(reason).to.include("Block deposit limit exceeded");
    });

    it("Should track user MEV status correctly", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const mevStatus = await coreSecurityManager.getUserMEVStatus(user1.address);
      expect(mevStatus.lastBlock).to.equal(0);
      expect(mevStatus.canDeposit).to.be.true;
      expect(mevStatus.dailyUsed).to.equal(0);
    });

    it("Should enforce minimum interval between deposits", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const depositAmount = ethers.parseUnits("1000", 6);
      
      // First deposit should work
      await coreSecurityManager.preDepositCheck(user1.address, depositAmount);
      
      // Second deposit in same block should fail
      await expect(
        coreSecurityManager.preDepositCheck(user1.address, depositAmount)
      ).to.be.revertedWith("MEV protection: interval too short");
    });

    it("Should reset daily limits after 24 hours", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const maxDailyAmount = ethers.parseUnits("25000", 6);
      
      // Use up daily limit
      await coreSecurityManager.preDepositCheck(user1.address, maxDailyAmount);
      
      // Should be at limit
      const [canDepositAtLimit] = await coreSecurityManager.canUserDeposit(user1.address, ethers.parseUnits("1", 6));
      expect(canDepositAtLimit).to.be.false;
      
      // Fast forward 24 hours
      await time.increase(24 * 60 * 60 + 1);
      
      // Should be able to deposit again
      const [canDepositAfter] = await coreSecurityManager.canUserDeposit(user1.address, ethers.parseUnits("1000", 6));
      expect(canDepositAfter).to.be.true;
    });

    it("Should track multiple users independently", async function () {
      const { coreSecurityManager, user1, user2 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const depositAmount = ethers.parseUnits("1000", 6);
      
      // Both users should be able to deposit
      const [canDeposit1] = await coreSecurityManager.canUserDeposit(user1.address, depositAmount);
      const [canDeposit2] = await coreSecurityManager.canUserDeposit(user2.address, depositAmount);
      
      expect(canDeposit1).to.be.true;
      expect(canDeposit2).to.be.true;
      
      // User1 deposits
      await coreSecurityManager.preDepositCheck(user1.address, depositAmount);
      
      // User2 should still be able to deposit
      const [canDepositUser2After] = await coreSecurityManager.canUserDeposit(user2.address, depositAmount);
      expect(canDepositUser2After).to.be.true;
    });
  });

  describe("Circuit Breaker", function () {
    it("Should trigger when volume threshold is exceeded", async function () {
      const { coreSecurityManager } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // This would require simulating large volume
      const largeVolume = ethers.parseUnits("150000", 6); // Exceeds 100k threshold
      
      await expect(
        coreSecurityManager.checkCircuitBreaker(largeVolume)
      ).to.emit(coreSecurityManager, "CircuitBreakerTriggered");
    });

    it("Should block deposits when circuit breaker is triggered", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Trigger circuit breaker
      const largeVolume = ethers.parseUnits("150000", 6);
      await coreSecurityManager.checkCircuitBreaker(largeVolume);
      
      // Deposits should be blocked
      const [canDeposit, reason] = await coreSecurityManager.canUserDeposit(user1.address, ethers.parseUnits("1000", 6));
      expect(canDeposit).to.be.false;
      expect(reason).to.include("Circuit breaker triggered");
    });

    it("Should reset after cooldown period", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Trigger circuit breaker
      const largeVolume = ethers.parseUnits("150000", 6);
      await coreSecurityManager.checkCircuitBreaker(largeVolume);
      
      // Fast forward time
      await time.increase(2 * 60 * 60 + 1); // 2 hours + 1 second
      
      // Circuit breaker should be reset
      const cbStatus = await coreSecurityManager.getCircuitBreakerStatus();
      expect(cbStatus.triggered).to.be.false;
      
      // Deposits should work again
      const [canDeposit] = await coreSecurityManager.canUserDeposit(user1.address, ethers.parseUnits("1000", 6));
      expect(canDeposit).to.be.true;
    });

    it("Should provide correct time until reset", async function () {
      const { coreSecurityManager } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Trigger circuit breaker
      const largeVolume = ethers.parseUnits("150000", 6);
      await coreSecurityManager.checkCircuitBreaker(largeVolume);
      
      const cbStatus = await coreSecurityManager.getCircuitBreakerStatus();
      expect(cbStatus.timeUntilReset).to.be.gt(0);
      expect(cbStatus.timeUntilReset).to.be.lte(2 * 60 * 60); // Should be <= 2 hours
    });

    it("Should accumulate volume correctly", async function () {
      const { coreSecurityManager } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Add some volume
      const volume1 = ethers.parseUnits("30000", 6);
      const volume2 = ethers.parseUnits("40000", 6);
      
      await coreSecurityManager.checkCircuitBreaker(volume1);
      await coreSecurityManager.checkCircuitBreaker(volume2);
      
      const cbStatus = await coreSecurityManager.getCircuitBreakerStatus();
      expect(cbStatus.currentVolume).to.equal(volume1 + volume2);
    });

    it("Should reset volume after window period", async function () {
      const { coreSecurityManager } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Add some volume
      const volume = ethers.parseUnits("50000", 6);
      await coreSecurityManager.checkCircuitBreaker(volume);
      
      // Fast forward past window period
      await time.increase(60 * 60 + 1); // 1 hour + 1 second
      
      // Add more volume (should reset the window)
      await coreSecurityManager.checkCircuitBreaker(ethers.parseUnits("10000", 6));
      
      const cbStatus = await coreSecurityManager.getCircuitBreakerStatus();
      expect(cbStatus.currentVolume).to.be.lt(volume); // Should not include old volume
    });
  });

  describe("New Token Mode", function () {
    it("Should enforce gas price limits in new token mode", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Set very high gas price
      const highGasPrice = ethers.parseUnits("100", "gwei");
      
      // Mock high gas price transaction
      await expect(
        coreSecurityManager.connect(user1).preDepositCheck(user1.address, ethers.parseUnits("1000", 6), {
          gasPrice: highGasPrice
        })
      ).to.be.revertedWith("Gas price too high for new token");
    });

    it("Should allow normal gas prices in new token mode", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const normalGasPrice = ethers.parseUnits("10", "gwei");
      
      // Should not revert with normal gas price
      await expect(
        coreSecurityManager.connect(user1).preDepositCheck(user1.address, ethers.parseUnits("1000", 6), {
          gasPrice: normalGasPrice
        })
      ).to.not.be.reverted;
    });

    it("Should disable new token mode when governance decides", async function () {
      const { coreSecurityManager, governance } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Disable new token mode
      await coreSecurityManager.connect(governance).setNewTokenMode(false);
      
      expect(await coreSecurityManager.newTokenMode()).to.be.false;
      
      const settings = await coreSecurityManager.getNewTokenSettings();
      expect(settings.newTokenModeActive).to.be.false;
    });

    it("Should relax restrictions when new token mode is disabled", async function () {
      const { coreSecurityManager, governance, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Disable new token mode
      await coreSecurityManager.connect(governance).setNewTokenMode(false);
      
      // High gas price should now be allowed
      const highGasPrice = ethers.parseUnits("100", "gwei");
      
      await expect(
        coreSecurityManager.connect(user1).preDepositCheck(user1.address, ethers.parseUnits("1000", 6), {
          gasPrice: highGasPrice
        })
      ).to.not.be.reverted;
    });
  });

  describe("Governance", function () {
    it("Should allow governance to update parameters", async function () {
      const { coreSecurityManager, governance } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const newGasPrice = ethers.parseUnits("30", "gwei");
      await coreSecurityManager.connect(governance).setMaxGasPrice(newGasPrice);
      
      const settings = await coreSecurityManager.getNewTokenSettings();
      expect(settings.maxGasPriceSetting).to.equal(newGasPrice);
    });

    it("Should prevent non-governance from updating parameters", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      await expect(
        coreSecurityManager.connect(user1).setMaxGasPrice(ethers.parseUnits("30", "gwei"))
      ).to.be.revertedWith("AccessControl");
    });

    it("Should allow governance to update circuit breaker settings", async function () {
      const { coreSecurityManager, governance } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const newThreshold = ethers.parseUnits("200000", 6); // 200k USDT
      const newCooldown = 4 * 60 * 60; // 4 hours
      
      await coreSecurityManager.connect(governance).setCircuitBreakerSettings(newThreshold, newCooldown);
      
      const cbSettings = await coreSecurityManager.getCircuitBreakerSettings();
      expect(cbSettings.volumeThreshold).to.equal(newThreshold);
      expect(cbSettings.cooldownPeriod).to.equal(newCooldown);
    });

    it("Should allow governance to update MEV protection settings", async function () {
      const { coreSecurityManager, governance } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const newInterval = 10; // 10 blocks
      const newBlockLimit = ethers.parseUnits("75000", 6); // 75k USDT
      const newUserLimit = ethers.parseUnits("35000", 6); // 35k USDT
      
      await coreSecurityManager.connect(governance).setMEVProtectionSettings(
        newInterval,
        newBlockLimit,
        newUserLimit
      );
      
      const mevSettings = await coreSecurityManager.getMEVProtectionSettings();
      expect(mevSettings.mevMinInterval).to.equal(newInterval);
      expect(mevSettings.maxDepositPerBlock).to.equal(newBlockLimit);
      expect(mevSettings.maxDepositPerUser).to.equal(newUserLimit);
    });

    it("Should validate parameter ranges", async function () {
      const { coreSecurityManager, governance } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Should fail for invalid gas price (too low)
      await expect(
        coreSecurityManager.connect(governance).setMaxGasPrice(ethers.parseUnits("1", "gwei"))
      ).to.be.revertedWith("Invalid gas price");
      
      // Should fail for invalid circuit breaker threshold (too low)
      await expect(
        coreSecurityManager.connect(governance).setCircuitBreakerSettings(
          ethers.parseUnits("1000", 6), // Too low
          2 * 60 * 60
        )
      ).to.be.revertedWith("Invalid threshold");
    });

    it("Should allow treasury wallet updates", async function () {
      const { coreSecurityManager, governance, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      await expect(
        coreSecurityManager.connect(governance).setTreasuryWallet(user1.address)
      ).to.emit(coreSecurityManager, "TreasuryWalletUpdated")
        .withArgs(coreSecurityManager.treasuryWallet(), user1.address);
      
      expect(await coreSecurityManager.treasuryWallet()).to.equal(user1.address);
    });
  });

  describe("Emergency Functions", function () {
    it("Should allow emergency role to pause contract", async function () {
      const { coreSecurityManager, emergency } = await loadFixture(deployCoreSecurityManagerFixture);
      
      await expect(
        coreSecurityManager.connect(emergency).pause()
      ).to.emit(coreSecurityManager, "Paused")
        .withArgs(emergency.address);
      
      expect(await coreSecurityManager.isPaused()).to.be.true;
    });

    it("Should allow governance to unpause contract", async function () {
      const { coreSecurityManager, emergency, governance } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Pause first
      await coreSecurityManager.connect(emergency).pause();
      
      // Unpause
      await expect(
        coreSecurityManager.connect(governance).unpause()
      ).to.emit(coreSecurityManager, "Unpaused")
        .withArgs(governance.address);
      
      expect(await coreSecurityManager.isPaused()).to.be.false;
    });

    it("Should prevent operations when paused", async function () {
      const { coreSecurityManager, emergency, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Pause contract
      await coreSecurityManager.connect(emergency).pause();
      
      // Should prevent deposits
      const [canDeposit, reason] = await coreSecurityManager.canUserDeposit(
        user1.address,
        ethers.parseUnits("1000", 6)
      );
      
      expect(canDeposit).to.be.false;
      expect(reason).to.equal("Paused");
    });

    it("Should prevent non-emergency from pausing", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      await expect(
        coreSecurityManager.connect(user1).pause()
      ).to.be.revertedWith("AccessControl");
    });

    it("Should allow emergency circuit breaker reset", async function () {
      const { coreSecurityManager, emergency } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Trigger circuit breaker
      const largeVolume = ethers.parseUnits("150000", 6);
      await coreSecurityManager.checkCircuitBreaker(largeVolume);
      
      // Emergency reset
      await expect(
        coreSecurityManager.connect(emergency).emergencyResetCircuitBreaker()
      ).to.emit(coreSecurityManager, "CircuitBreakerReset");
      
      const cbStatus = await coreSecurityManager.getCircuitBreakerStatus();
      expect(cbStatus.triggered).to.be.false;
    });
  });

  describe("View Functions", function () {
    it("Should provide protocol statistics", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Perform some operations to generate stats
      await coreSecurityManager.preDepositCheck(user1.address, ethers.parseUnits("1000", 6));
      
      const stats = await coreSecurityManager.getProtocolStatistics();
      expect(stats.totalUsers).to.equal(1);
      expect(stats.totalDeposits).to.equal(1);
      expect(stats.oracleHealthy).to.be.true;
    });

    it("Should provide user deposit history", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Perform multiple deposits
      await coreSecurityManager.preDepositCheck(user1.address, ethers.parseUnits("1000", 6));
      
      // Mine some blocks
      await time.increase(10);
      
      await coreSecurityManager.preDepositCheck(user1.address, ethers.parseUnits("2000", 6));
      
      const history = await coreSecurityManager.getUserDepositHistory(user1.address, 0, 10);
      expect(history.length).to.equal(2);
      expect(history[0].amount).to.equal(ethers.parseUnits("1000", 6));
      expect(history[1].amount).to.equal(ethers.parseUnits("2000", 6));
    });

    it("Should provide daily metrics", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Perform deposit
      await coreSecurityManager.preDepositCheck(user1.address, ethers.parseUnits("1000", 6));
      
      const currentDay = Math.floor(Date.now() / (1000 * 60 * 60 * 24));
      const metrics = await coreSecurityManager.getDailyMetrics(currentDay);
      
      expect(metrics.totalVolume).to.equal(ethers.parseUnits("1000", 6));
      expect(metrics.uniqueUsers).to.equal(1);
    });

    it("Should check oracle health status", async function () {
      const { coreSecurityManager } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const oracleHealth = await coreSecurityManager.getOracleHealthStatus();
      expect(oracleHealth.isHealthy).to.be.true;
      expect(oracleHealth.lastUpdate).to.be.gt(0);
    });

    it("Should provide comprehensive user status", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Perform deposit to generate data
      await coreSecurityManager.preDepositCheck(user1.address, ethers.parseUnits("1000", 6));
      
      const userStatus = await coreSecurityManager.getUserStatus(user1.address);
      expect(userStatus.canDeposit).to.be.true;
      expect(userStatus.dailyUsed).to.equal(ethers.parseUnits("1000", 6));
      expect(userStatus.depositCount).to.equal(1);
    });
  });

  describe("Post-Deposit Updates", function () {
    it("Should update user statistics after deposit", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const depositAmount = ethers.parseUnits("1000", 6);
      
      // Pre-deposit check
      await coreSecurityManager.preDepositCheck(user1.address, depositAmount);
      
      // Post-deposit update
      await coreSecurityManager.postDepositUpdate(user1.address, depositAmount);
      
      const userStats = await coreSecurityManager.getUserStatistics(user1.address);
      expect(userStats.totalDeposited).to.equal(depositAmount);
      expect(userStats.depositCount).to.equal(1);
    });

    it("Should update protocol statistics after deposit", async function () {
      const { coreSecurityManager, user1, user2 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const amount1 = ethers.parseUnits("1000", 6);
      const amount2 = ethers.parseUnits("2000", 6);
      
      // Two users deposit
      await coreSecurityManager.preDepositCheck(user1.address, amount1);
      await coreSecurityManager.postDepositUpdate(user1.address, amount1);
      
      await coreSecurityManager.preDepositCheck(user2.address, amount2);
      await coreSecurityManager.postDepositUpdate(user2.address, amount2);
      
      const stats = await coreSecurityManager.getProtocolStatistics();
      expect(stats.totalUsers).to.equal(2);
      expect(stats.totalVolume).to.equal(amount1 + amount2);
    });

    it("Should trigger circuit breaker on large post-deposit updates", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const largeAmount = ethers.parseUnits("150000", 6); // Exceeds threshold
      
      // Pre-deposit check should pass (doesn't check circuit breaker)
      await coreSecurityManager.preDepositCheck(user1.address, largeAmount);
      
      // Post-deposit update should trigger circuit breaker
      await expect(
        coreSecurityManager.postDepositUpdate(user1.address, largeAmount)
      ).to.emit(coreSecurityManager, "CircuitBreakerTriggered");
    });
  });

  describe("Monitoring Functions", function () {
    it("Should allow monitors to update user risk flags", async function () {
      const { coreSecurityManager, monitor, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      await expect(
        coreSecurityManager.connect(monitor).flagUserForReview(user1.address, "Suspicious activity detected")
      ).to.emit(coreSecurityManager, "UserFlaggedForReview")
        .withArgs(user1.address, "Suspicious activity detected");
      
      const userStatus = await coreSecurityManager.getUserStatus(user1.address);
      expect(userStatus.flaggedForReview).to.be.true;
    });

    it("Should block deposits for flagged users", async function () {
      const { coreSecurityManager, monitor, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Flag user
      await coreSecurityManager.connect(monitor).flagUserForReview(user1.address, "Suspicious activity");
      
      // Deposit should be blocked
      const [canDeposit, reason] = await coreSecurityManager.canUserDeposit(
        user1.address,
        ethers.parseUnits("1000", 6)
      );
      
      expect(canDeposit).to.be.false;
      expect(reason).to.include("flagged");
    });

    it("Should allow monitors to clear user flags", async function () {
      const { coreSecurityManager, monitor, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Flag user
      await coreSecurityManager.connect(monitor).flagUserForReview(user1.address, "Suspicious activity");
      
      // Clear flag
      await expect(
        coreSecurityManager.connect(monitor).clearUserFlag(user1.address)
      ).to.emit(coreSecurityManager, "UserFlagCleared")
        .withArgs(user1.address);
      
      // User should be able to deposit again
      const [canDeposit] = await coreSecurityManager.canUserDeposit(
        user1.address,
        ethers.parseUnits("1000", 6)
      );
      expect(canDeposit).to.be.true;
    });

    it("Should prevent non-monitors from flagging users", async function () {
      const { coreSecurityManager, user1, user2 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      await expect(
        coreSecurityManager.connect(user1).flagUserForReview(user2.address, "Suspicious activity")
      ).to.be.revertedWith("AccessControl");
    });
  });

  describe("Integration with External Systems", function () {
    it("Should interact with oracle for health checks", async function () {
      const { coreSecurityManager } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Test oracle health check
      const oracleHealth = await coreSecurityManager.getOracleHealthStatus();
      expect(oracleHealth.isHealthy).to.be.true;
    });

    it("Should validate treasury wallet functionality", async function () {
      const { coreSecurityManager, treasury } = await loadFixture(deployCoreSecurityManagerFixture);
      
      expect(await coreSecurityManager.treasuryWallet()).to.equal(treasury.address);
      
      // Validate treasury is not zero address
      expect(treasury.address).to.not.equal(ethers.ZeroAddress);
    });

    it("Should handle external contract calls safely", async function () {
      const { coreSecurityManager, governance } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Test safe external call functionality
      await expect(
        coreSecurityManager.connect(governance).setTreasuryWallet(ethers.ZeroAddress)
      ).to.be.revertedWith("Invalid treasury wallet");
    });
  });

  describe("Gas Optimization Tests", function () {
    it("Should efficiently handle multiple user checks", async function () {
      const { coreSecurityManager, user1, user2 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const depositAmount = ethers.parseUnits("1000", 6);
      
      // Check multiple users in sequence
      const checks = await Promise.all([
        coreSecurityManager.canUserDeposit(user1.address, depositAmount),
        coreSecurityManager.canUserDeposit(user2.address, depositAmount)
      ]);
      
      expect(checks[0][0]).to.be.true; // user1 can deposit
      expect(checks[1][0]).to.be.true; // user2 can deposit
    });

    it("Should optimize storage reads for frequent operations", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const depositAmount = ethers.parseUnits("1000", 6);
      
      // Multiple checks should be efficient
      for (let i = 0; i < 5; i++) {
        const [canDeposit] = await coreSecurityManager.canUserDeposit(user1.address, depositAmount);
        expect(canDeposit).to.be.true;
      }
    });
  });

  describe("Edge Cases and Error Handling", function () {
    it("Should handle zero deposit amounts", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const [canDeposit, reason] = await coreSecurityManager.canUserDeposit(user1.address, 0);
      expect(canDeposit).to.be.false;
      expect(reason).to.include("Invalid amount");
    });

    it("Should handle maximum uint256 values", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const maxValue = ethers.MaxUint256;
      const [canDeposit, reason] = await coreSecurityManager.canUserDeposit(user1.address, maxValue);
      expect(canDeposit).to.be.false;
      expect(reason).to.include("limit");
    });

    it("Should handle invalid user addresses", async function () {
      const { coreSecurityManager } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const [canDeposit, reason] = await coreSecurityManager.canUserDeposit(
        ethers.ZeroAddress,
        ethers.parseUnits("1000", 6)
      );
      expect(canDeposit).to.be.false;
      expect(reason).to.include("Invalid user");
    });

    it("Should handle contract interactions when paused", async function () {
      const { coreSecurityManager, emergency, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Pause contract
      await coreSecurityManager.connect(emergency).pause();
      
      // All user operations should be blocked
      await expect(
        coreSecurityManager.preDepositCheck(user1.address, ethers.parseUnits("1000", 6))
      ).to.be.revertedWith("Pausable: paused");
    });

    it("Should handle rapid successive calls", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const depositAmount = ethers.parseUnits("1000", 6);
      
      // First call should succeed
      await coreSecurityManager.preDepositCheck(user1.address, depositAmount);
      
      // Rapid second call should fail (MEV protection)
      await expect(
        coreSecurityManager.preDepositCheck(user1.address, depositAmount)
      ).to.be.revertedWith("MEV protection: interval too short");
    });
  });

  describe("Comprehensive Integration Tests", function () {
    it("Should handle complete deposit flow", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const depositAmount = ethers.parseUnits("1000", 6);
      
      // Step 1: Check if user can deposit
      const [canDeposit, reason] = await coreSecurityManager.canUserDeposit(user1.address, depositAmount);
      expect(canDeposit).to.be.true;
      expect(reason).to.equal("OK");
      
      // Step 2: Pre-deposit check
      await expect(
        coreSecurityManager.preDepositCheck(user1.address, depositAmount)
      ).to.not.be.reverted;
      
      // Step 3: Post-deposit update
      await expect(
        coreSecurityManager.postDepositUpdate(user1.address, depositAmount)
      ).to.not.be.reverted;
      
      // Step 4: Verify user statistics updated
      const userStats = await coreSecurityManager.getUserStatistics(user1.address);
      expect(userStats.totalDeposited).to.equal(depositAmount);
      expect(userStats.depositCount).to.equal(1);
    });

    it("Should handle multiple users with different scenarios", async function () {
      const { coreSecurityManager, user1, user2, monitor } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const amount1 = ethers.parseUnits("5000", 6);
      const amount2 = ethers.parseUnits("15000", 6);
      
      // User1: Normal deposit
      await coreSecurityManager.preDepositCheck(user1.address, amount1);
      await coreSecurityManager.postDepositUpdate(user1.address, amount1);
      
      // User2: Large deposit but within limits
      await coreSecurityManager.preDepositCheck(user2.address, amount2);
      await coreSecurityManager.postDepositUpdate(user2.address, amount2);
      
      // Flag user2 for large deposit
      await coreSecurityManager.connect(monitor).flagUserForReview(user2.address, "Large deposit pattern");
      
      // User1 should still be able to deposit
      const [canDeposit1] = await coreSecurityManager.canUserDeposit(user1.address, amount1);
      expect(canDeposit1).to.be.true;
      
      // User2 should be blocked
      const [canDeposit2] = await coreSecurityManager.canUserDeposit(user2.address, amount1);
      expect(canDeposit2).to.be.false;
    });

    it("Should handle system stress scenarios", async function () {
      const { coreSecurityManager, user1, user2 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Scenario 1: Approach circuit breaker limit
      const largeAmount = ethers.parseUnits("90000", 6); // Close to 100k limit
      
      await coreSecurityManager.preDepositCheck(user1.address, largeAmount);
      await coreSecurityManager.postDepositUpdate(user1.address, largeAmount);
      
      // Scenario 2: Next deposit should trigger circuit breaker
      const triggerAmount = ethers.parseUnits("20000", 6);
      
      await coreSecurityManager.preDepositCheck(user2.address, triggerAmount);
      await expect(
        coreSecurityManager.postDepositUpdate(user2.address, triggerAmount)
      ).to.emit(coreSecurityManager, "CircuitBreakerTriggered");
      
      // Scenario 3: All deposits should now be blocked
      const [canDeposit] = await coreSecurityManager.canUserDeposit(user1.address, ethers.parseUnits("100", 6));
      expect(canDeposit).to.be.false;
    });
  });

  describe("Data Integrity and Validation", function () {
    it("Should maintain consistent user data across operations", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const amounts = [
        ethers.parseUnits("1000", 6),
        ethers.parseUnits("2000", 6),
        ethers.parseUnits("1500", 6)
      ];
      
      let totalExpected = 0n;
      
      for (const amount of amounts) {
        await coreSecurityManager.preDepositCheck(user1.address, amount);
        await coreSecurityManager.postDepositUpdate(user1.address, amount);
        totalExpected += amount;
        
        // Advance time to avoid MEV protection
        await time.increase(10);
      }
      
      const userStats = await coreSecurityManager.getUserStatistics(user1.address);
      expect(userStats.totalDeposited).to.equal(totalExpected);
      expect(userStats.depositCount).to.equal(amounts.length);
    });

    it("Should validate state transitions correctly", async function () {
      const { coreSecurityManager, emergency, governance } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Normal state
      expect(await coreSecurityManager.isPaused()).to.be.false;
      
      // Emergency pause
      await coreSecurityManager.connect(emergency).pause();
      expect(await coreSecurityManager.isPaused()).to.be.true;
      
      // Cannot pause when already paused
      await expect(
        coreSecurityManager.connect(emergency).pause()
      ).to.be.revertedWith("Pausable: paused");
      
      // Governance unpause
      await coreSecurityManager.connect(governance).unpause();
      expect(await coreSecurityManager.isPaused()).to.be.false;
      
      // Cannot unpause when already unpaused
      await expect(
        coreSecurityManager.connect(governance).unpause()
      ).to.be.revertedWith("Pausable: not paused");
    });

    it("Should handle concurrent access safely", async function () {
      const { coreSecurityManager, user1, user2 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const amount = ethers.parseUnits("1000", 6);
      
      // Simulate concurrent deposits (though in testing they're sequential)
      const promises = [
        coreSecurityManager.canUserDeposit(user1.address, amount),
        coreSecurityManager.canUserDeposit(user2.address, amount)
      ];
      
      const results = await Promise.all(promises);
      
      // Both should succeed independently
      expect(results[0][0]).to.be.true;
      expect(results[1][0]).to.be.true;
    });
  });

  describe("Upgrade Functionality", function () {
    it("Should support UUPS upgrades", async function () {
      const { coreSecurityManager, governance } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Check upgrade authorization
      const GOVERNANCE_ROLE = await coreSecurityManager.GOVERNANCE_ROLE();
      expect(await coreSecurityManager.hasRole(GOVERNANCE_ROLE, governance.address)).to.be.true;
      
      // In a real scenario, you would deploy a new implementation
      // and call upgradeTo or upgradeToAndCall
    });

    it("Should prevent unauthorized upgrades", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Should fail for non-governance
      await expect(
        coreSecurityManager.connect(user1).upgradeToAndCall(user1.address, "0x")
      ).to.be.revertedWith("AccessControl");
    });
  });

  describe("Event Emission", function () {
    it("Should emit correct events for deposit operations", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const depositAmount = ethers.parseUnits("1000", 6);
      
      // Pre-deposit check should emit event
      await expect(
        coreSecurityManager.preDepositCheck(user1.address, depositAmount)
      ).to.emit(coreSecurityManager, "DepositChecked")
        .withArgs(user1.address, depositAmount, true);
      
      // Post-deposit update should emit event
      await expect(
        coreSecurityManager.postDepositUpdate(user1.address, depositAmount)
      ).to.emit(coreSecurityManager, "DepositProcessed")
        .withArgs(user1.address, depositAmount);
    });

    it("Should emit events for parameter changes", async function () {
      const { coreSecurityManager, governance } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const newGasPrice = ethers.parseUnits("30", "gwei");
      
      await expect(
        coreSecurityManager.connect(governance).setMaxGasPrice(newGasPrice)
      ).to.emit(coreSecurityManager, "MaxGasPriceUpdated")
        .withArgs(ethers.parseUnits("20", "gwei"), newGasPrice);
    });

    it("Should emit events for security actions", async function () {
      const { coreSecurityManager, monitor, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      await expect(
        coreSecurityManager.connect(monitor).flagUserForReview(user1.address, "Test flag")
      ).to.emit(coreSecurityManager, "UserFlaggedForReview")
        .withArgs(user1.address, "Test flag");
    });
  });

  describe("Documentation and Reporting", function () {
    it("Should provide comprehensive system status", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Generate some activity
      await coreSecurityManager.preDepositCheck(user1.address, ethers.parseUnits("1000", 6));
      await coreSecurityManager.postDepositUpdate(user1.address, ethers.parseUnits("1000", 6));
      
      // Get comprehensive status
      const protocolStats = await coreSecurityManager.getProtocolStatistics();
      const cbStatus = await coreSecurityManager.getCircuitBreakerStatus();
      const newTokenSettings = await coreSecurityManager.getNewTokenSettings();
      const mevSettings = await coreSecurityManager.getMEVProtectionSettings();
      
      // Verify all data is available
      expect(protocolStats.totalUsers).to.be.gte(1);
      expect(protocolStats.totalVolume).to.be.gt(0);
      expect(cbStatus.volumeThreshold).to.be.gt(0);
      expect(newTokenSettings.newTokenModeActive).to.be.true;
      expect(mevSettings.mevMinInterval).to.be.gt(0);
    });

    it("Should provide audit trail through events", async function () {
      const { coreSecurityManager, user1, governance, monitor } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const depositAmount = ethers.parseUnits("1000", 6);
      
      // Series of operations that should be auditable
      const tx1 = await coreSecurityManager.preDepositCheck(user1.address, depositAmount);
      const tx2 = await coreSecurityManager.postDepositUpdate(user1.address, depositAmount);
      const tx3 = await coreSecurityManager.connect(monitor).flagUserForReview(user1.address, "Audit test");
      const tx4 = await coreSecurityManager.connect(governance).setMaxGasPrice(ethers.parseUnits("25", "gwei"));
      
      // All transactions should have events for audit trail
      const receipt1 = await tx1.wait();
      const receipt2 = await tx2.wait();
      const receipt3 = await tx3.wait();
      const receipt4 = await tx4.wait();
      
      expect(receipt1.logs.length).to.be.gt(0);
      expect(receipt2.logs.length).to.be.gt(0);
      expect(receipt3.logs.length).to.be.gt(0);
      expect(receipt4.logs.length).to.be.gt(0);
    });
  });
});
