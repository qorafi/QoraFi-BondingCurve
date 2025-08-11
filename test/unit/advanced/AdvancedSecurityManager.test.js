// test/unit/advanced/AdvancedSecurityManager.test.js
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

describe("AdvancedSecurityManager", function () {
  async function deployAdvancedSecurityManagerFixture() {
    const [owner, governance, emergency, monitor, user1, user2, treasury] = await ethers.getSigners();
    
    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const usdt = await MockERC20.deploy("Mock USDT", "USDT", 6, ethers.parseUnits("1000000", 6));
    const qorafi = await MockERC20.deploy("Qorafi Token", "QORAFI", 18, ethers.parseEther("1000000"));
    
    // Deploy libraries
    const SecurityLibraries = await ethers.getContractFactory("SecurityLibraries");
    const securityLibraries = await SecurityLibraries.deploy();
    
    // Deploy AdvancedSecurityManager with libraries
    const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager", {
      libraries: {
        MEVLib: await securityLibraries.getAddress(),
        CircuitBreakerLib: await securityLibraries.getAddress(),
        EmergencyLib: await securityLibraries.getAddress(),
        ValidationLib: await securityLibraries.getAddress(),
      },
    });
    
    const advancedSecurityManager = await upgrades.deployProxy(AdvancedSecurityManager, [
      await usdt.getAddress(),
      await qorafi.getAddress(),
      treasury.address
    ], {
      initializer: 'initialize',
      kind: 'uups',
      unsafeAllow: ['external-library-linking']
    });
    
    // Initialize advanced features
    await advancedSecurityManager.initializeAdvanced(
      24 * 60 * 60, // 24 hours emergency delay
      1, // max 1 update per block
      3  // 3 block detection window
    );
    
    // Grant roles
    const GOVERNANCE_ROLE = await advancedSecurityManager.GOVERNANCE_ROLE();
    const EMERGENCY_ROLE = await advancedSecurityManager.EMERGENCY_ROLE();
    const MONITOR_ROLE = await advancedSecurityManager.MONITOR_ROLE();
    
    await advancedSecurityManager.grantRole(GOVERNANCE_ROLE, governance.address);
    await advancedSecurityManager.grantRole(EMERGENCY_ROLE, emergency.address);
    await advancedSecurityManager.grantRole(MONITOR_ROLE, monitor.address);
    
    return { 
      advancedSecurityManager, 
      usdt, 
      qorafi, 
      owner, 
      governance, 
      emergency, 
      monitor, 
      user1, 
      user2, 
      treasury 
    };
  }

  describe("Initialization", function () {
    it("Should initialize advanced features correctly", async function () {
      const { advancedSecurityManager } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      const settings = await advancedSecurityManager.getAdvancedSettings();
      expect(settings.emergencyDelaySettings).to.equal(24 * 60 * 60);
      expect(settings.emergencyModeActiveSetting).to.be.false;
      
      const flashLoanStatus = await advancedSecurityManager.getFlashLoanProtectionStatus();
      expect(flashLoanStatus.maxAllowedUpdates).to.equal(1);
      expect(flashLoanStatus.detectionWindow).to.equal(3);
    });

    it("Should inherit from CoreSecurityManager", async function () {
      const { advancedSecurityManager, usdt, qorafi, treasury } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      expect(await advancedSecurityManager.usdtToken()).to.equal(await usdt.getAddress());
      expect(await advancedSecurityManager.qorafiToken()).to.equal(await qorafi.getAddress());
      expect(await advancedSecurityManager.treasuryWallet()).to.equal(treasury.address);
    });

    it("Should set up initial risk parameters", async function () {
      const { advancedSecurityManager } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      const settings = await advancedSecurityManager.getAdvancedSettings();
      expect(settings.highRiskThresholdSetting).to.equal(8000); // 80%
      expect(settings.maxTransactionsPerWindowSetting).to.equal(10);
    });
  });

  describe("Advanced Security Checks", function () {
    it("Should perform enhanced pre-deposit checks", async function () {
      const { advancedSecurityManager, user1 } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      const depositAmount = ethers.parseUnits("1000", 6);
      
      // Should pass for first-time user
      await expect(
        advancedSecurityManager.advancedPreDepositCheck(user1.address, depositAmount)
      ).to.not.be.reverted;
    });

    it("Should block high-risk users", async function () {
      const { advancedSecurityManager, monitor, user1 } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      // Set user as high risk
      await advancedSecurityManager.connect(monitor).updateUserRiskScore(user1.address, 9000); // 90%
      
      const depositAmount = ethers.parseUnits("1000", 6);
      
      // Should fail for high-risk user
      await expect(
        advancedSecurityManager.advancedPreDepositCheck(user1.address, depositAmount)
      ).to.be.revertedWith("HighRiskUser");
    });

    it("Should block flagged users", async function () {
      const { advancedSecurityManager, monitor, user1 } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      // Flag user for suspicious activity
      await advancedSecurityManager.connect(monitor).flagUser(user1.address, true, "Suspicious pattern detected");
      
      const depositAmount = ethers.parseUnits("1000", 6);
      
      // Should fail for flagged user
      await expect(
        advancedSecurityManager.advancedPreDepositCheck(user1.address, depositAmount)
      ).to.be.revertedWith("SuspiciousActivity");
    });

    it("Should detect flash loan activity", async function () {
      const { advancedSecurityManager, user1 } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      const depositAmount = ethers.parseUnits("1000", 6);
      
      // First check should pass
      await advancedSecurityManager.advancedPreDepositCheck(user1.address, depositAmount);
      
      // Second check in same block should fail due to flash loan protection
      await expect(
        advancedSecurityManager.advancedPreDepositCheck(user1.address, depositAmount)
      ).to.be.revertedWith("TooManyUpdatesPerBlock");
    });

    it("Should track user behavior analytics", async function () {
      const { advancedSecurityManager, user1 } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      const depositAmount = ethers.parseUnits("1000", 6);
      
      // Simulate deposit behavior tracking
      await advancedSecurityManager.advancedPreDepositCheck(user1.address, depositAmount);
      
      // Check that behavior is being tracked
      const riskAssessment = await advancedSecurityManager.getUserRiskAssessment(user1.address);
      expect(riskAssessment.canTransact).to.be.true;
      expect(riskAssessment.flagged).to.be.false;
    });
  });

  describe("Emergency System", function () {
    it("Should activate emergency mode", async function () {
      const { advancedSecurityManager, emergency } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      await expect(
        advancedSecurityManager.connect(emergency).activateEmergencyMode()
      ).to.emit(advancedSecurityManager, "EmergencyModeToggled").withArgs(true);
      
      expect(await advancedSecurityManager.emergencyModeActive()).to.be.true;
      expect(await advancedSecurityManager.isPaused()).to.be.true;
    });

    it("Should deactivate emergency mode", async function () {
      const { advancedSecurityManager, emergency, governance } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      // Activate first
      await advancedSecurityManager.connect(emergency).activateEmergencyMode();
      
      // Deactivate
      await expect(
        advancedSecurityManager.connect(governance).deactivateEmergencyMode()
      ).to.emit(advancedSecurityManager, "EmergencyModeToggled").withArgs(false);
      
      expect(await advancedSecurityManager.emergencyModeActive()).to.be.false;
      expect(await advancedSecurityManager.isPaused()).to.be.false;
    });

    it("Should propose emergency transactions", async function () {
      const { advancedSecurityManager, emergency, usdt } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      const target = await usdt.getAddress();
      const value = 0;
      const data = usdt.interface.encodeFunctionData("transfer", [emergency.address, ethers.parseUnits("1000", 6)]);
      
      await expect(
        advancedSecurityManager.connect(emergency).proposeEmergencyTransaction(target, value, data)
      ).to.emit(advancedSecurityManager, "EmergencyTransactionProposed");
    });

    it("Should enforce timelock on emergency transactions", async function () {
      const { advancedSecurityManager, emergency, governance, usdt } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      const target = await usdt.getAddress();
      const value = 0;
      const data = usdt.interface.encodeFunctionData("transfer", [emergency.address, ethers.parseUnits("1000", 6)]);
      
      const txHash = await advancedSecurityManager.connect(emergency).proposeEmergencyTransaction(target, value, data);
      const receipt = await txHash.wait();
      
      // Extract emergency transaction hash from events
      const event = receipt.logs.find(log => {
        try {
          const parsed = advancedSecurityManager.interface.parseLog(log);
          return parsed.name === "EmergencyTransactionProposed";
        } catch {
          return false;
        }
      });
      
      expect(event).to.not.be.undefined;
      
      if (event) {
        const parsed = advancedSecurityManager.interface.parseLog(event);
        const emergencyTxHash = parsed.args.txHash;
        
        // Try to execute immediately (should fail due to timelock)
        await expect(
          advancedSecurityManager.connect(governance).executeEmergencyTransaction(emergencyTxHash)
        ).to.be.reverted; // Will fail due to timelock
      }
    });

    it("Should execute emergency transactions after timelock", async function () {
      const { advancedSecurityManager, emergency, governance, usdt } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      const target = await usdt.getAddress();
      const value = 0;
      const data = usdt.interface.encodeFunctionData("transfer", [emergency.address, ethers.parseUnits("1000", 6)]);
      
      const txHash = await advancedSecurityManager.connect(emergency).proposeEmergencyTransaction(target, value, data);
      const receipt = await txHash.wait();
      
      // Fast forward time past emergency delay
      await time.increase(24 * 60 * 60 + 1); // 24 hours + 1 second
      
      // Extract and execute emergency transaction
      const event = receipt.logs.find(log => {
        try {
          const parsed = advancedSecurityManager.interface.parseLog(log);
          return parsed.name === "EmergencyTransactionProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = advancedSecurityManager.interface.parseLog(event);
        const emergencyTxHash = parsed.args.txHash;
        
        await expect(
          advancedSecurityManager.connect(governance).executeEmergencyTransaction(emergencyTxHash)
        ).to.emit(advancedSecurityManager, "EmergencyTransactionExecuted");
      }
    });
  });

  describe("Risk Management", function () {
    it("Should update user risk scores", async function () {
      const { advancedSecurityManager, monitor, user1 } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      await expect(
        advancedSecurityManager.connect(monitor).updateUserRiskScore(user1.address, 7500) // 75%
      ).to.emit(advancedSecurityManager, "UserRiskScoreUpdated")
        .withArgs(user1.address, 0, 7500);
      
      const riskAssessment = await advancedSecurityManager.getUserRiskAssessment(user1.address);
      expect(riskAssessment.riskScore).to.equal(7500);
    });

    it("Should batch update risk scores", async function () {
      const { advancedSecurityManager, monitor, user1, user2 } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      const users = [user1.address, user2.address];
      const scores = [6000, 7000];
      
      await advancedSecurityManager.connect(monitor).batchUpdateRiskScores(users, scores);
      
      const risk1 = await advancedSecurityManager.getUserRiskAssessment(user1.address);
      const risk2 = await advancedSecurityManager.getUserRiskAssessment(user2.address);
      
      expect(risk1.riskScore).to.equal(6000);
      expect(risk2.riskScore).to.equal(7000);
    });

    it("Should flag and unflag users", async function () {
      const { advancedSecurityManager, monitor, user1 } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      // Flag user
      await expect(
        advancedSecurityManager.connect(monitor).flagUser(user1.address, true, "Suspicious pattern")
      ).to.emit(advancedSecurityManager, "SuspiciousActivityDetected")
        .withArgs(user1.address, "Suspicious pattern");
      
      let riskAssessment = await advancedSecurityManager.getUserRiskAssessment(user1.address);
      expect(riskAssessment.flagged).to.be.true;
      expect(riskAssessment.suspiciousActivityCount).to.equal(1);
      
      // Unflag user
      await advancedSecurityManager.connect(monitor).flagUser(user1.address, false, "");
      
      riskAssessment = await advancedSecurityManager.getUserRiskAssessment(user1.address);
      expect(riskAssessment.flagged).to.be.false;
    });

    it("Should validate risk score limits", async function () {
      const { advancedSecurityManager, monitor, user1 } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      // Should fail for invalid risk score
      await expect(
        advancedSecurityManager.connect(monitor).updateUserRiskScore(user1.address, 15000) // 150% invalid
      ).to.be.revertedWith("Invalid risk score");
    });
  });

  describe("Advanced Governance", function () {
    it("Should set advanced parameters", async function () {
      const { advancedSecurityManager, governance } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      await advancedSecurityManager.connect(governance).setAdvancedParameters(
        7000, // 70% high risk threshold
        2 * 60 * 60, // 2 hours suspicious activity window
        15 // max 15 transactions per window
      );
      
      const settings = await advancedSecurityManager.getAdvancedSettings();
      expect(settings.highRiskThresholdSetting).to.equal(7000);
      expect(settings.suspiciousActivityWindowSetting).to.equal(2 * 60 * 60);
      expect(settings.maxTransactionsPerWindowSetting).to.equal(15);
    });

    it("Should set flash loan protection parameters", async function () {
      const { advancedSecurityManager, governance } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      await advancedSecurityManager.connect(governance).setFlashLoanProtection(
        2, // max 2 updates per block
        5  // 5 block detection window
      );
      
      const protection = await advancedSecurityManager.getFlashLoanProtectionStatus();
      expect(protection.maxAllowedUpdates).to.equal(2);
      expect(protection.detectionWindow).to.equal(5);
    });

    it("Should set emergency transaction delay", async function () {
      const { advancedSecurityManager, governance } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      const newDelay = 12 * 60 * 60; // 12 hours
      
      await expect(
        advancedSecurityManager.connect(governance).setEmergencyTransactionDelay(newDelay)
      ).to.emit(advancedSecurityManager, "SecurityParametersUpdated")
        .withArgs("emergencyTransactionDelay", 24 * 60 * 60, newDelay);
      
      const settings = await advancedSecurityManager.getAdvancedSettings();
      expect(settings.emergencyDelaySettings).to.equal(newDelay);
    });

    it("Should validate parameter ranges", async function () {
      const { advancedSecurityManager, governance } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      // Should fail for invalid threshold
      await expect(
        advancedSecurityManager.connect(governance).setAdvancedParameters(
          15000, // Invalid threshold > 10000
          1 * 60 * 60,
          10
        )
      ).to.be.revertedWith("Invalid threshold");
      
      // Should fail for invalid window
      await expect(
        advancedSecurityManager.connect(governance).setAdvancedParameters(
          8000,
          25 * 60 * 60, // Invalid window > 24 hours
          10
        )
      ).to.be.revertedWith("Invalid window");
    });
  });

  describe("Advanced View Functions", function () {
    it("Should provide comprehensive user risk assessment", async function () {
      const { advancedSecurityManager, monitor, user1 } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      // Set up user data
      await advancedSecurityManager.connect(monitor).updateUserRiskScore(user1.address, 6000);
      
      const assessment = await advancedSecurityManager.getUserRiskAssessment(user1.address);
      expect(assessment.riskScore).to.equal(6000);
      expect(assessment.flagged).to.be.false;
      expect(assessment.canTransact).to.be.true;
      expect(assessment.avgTransactionSize).to.equal(0); // No transactions yet
      expect(assessment.suspiciousActivityCount).to.equal(0);
    });

    it("Should provide daily metrics", async function () {
      const { advancedSecurityManager } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      const currentDay = Math.floor(Date.now() / (1000 * 60 * 60 * 24));
      const metrics = await advancedSecurityManager.getDailyMetrics(currentDay);
      
      expect(metrics.totalVolume).to.equal(0);
      expect(metrics.uniqueUsers).to.equal(0);
      expect(metrics.largeTransactionCount).to.equal(0);
      expect(metrics.emergencyTriggeredCount).to.equal(0);
    });

    it("Should provide emergency transaction details", async function () {
      const { advancedSecurityManager, emergency, usdt } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      const target = await usdt.getAddress();
      const value = 0;
      const data = usdt.interface.encodeFunctionData("transfer", [emergency.address, ethers.parseUnits("1000", 6)]);
      
      const txHash = await advancedSecurityManager.connect(emergency).proposeEmergencyTransaction(target, value, data);
      const receipt = await txHash.wait();
      
      const event = receipt.logs.find(log => {
        try {
          const parsed = advancedSecurityManager.interface.parseLog(log);
          return parsed.name === "EmergencyTransactionProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = advancedSecurityManager.interface.parseLog(event);
        const emergencyTxHash = parsed.args.txHash;
        
        const txDetails = await advancedSecurityManager.getEmergencyTransaction(emergencyTxHash);
        expect(txDetails.target).to.equal(target);
        expect(txDetails.value).to.equal(value);
        expect(txDetails.executed).to.be.false;
        expect(txDetails.proposer).to.equal(emergency.address);
      }
    });

    it("Should provide flash loan protection status", async function () {
      const { advancedSecurityManager } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      const status = await advancedSecurityManager.getFlashLoanProtectionStatus();
      expect(status.currentBlockUpdates).to.equal(0);
      expect(status.maxAllowedUpdates).to.equal(1);
      expect(status.detectionWindow).to.equal(3);
      expect(status.protectionActive).to.be.true; // newTokenMode is true
    });
  });

  describe("Enhanced Deposit Checks", function () {
    it("Should perform comprehensive deposit eligibility check", async function () {
      const { advancedSecurityManager, user1 } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      const depositAmount = ethers.parseUnits("1000", 6);
      const [canDeposit, reason] = await advancedSecurityManager.canUserDeposit(user1.address, depositAmount);
      
      expect(canDeposit).to.be.true;
      expect(reason).to.equal("OK");
    });

    it("Should block deposits in emergency mode", async function () {
      const { advancedSecurityManager, emergency, user1 } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      await advancedSecurityManager.connect(emergency).activateEmergencyMode();
      
      const depositAmount = ethers.parseUnits("1000", 6);
      const [canDeposit, reason] = await advancedSecurityManager.canUserDeposit(user1.address, depositAmount);
      
      expect(canDeposit).to.be.false;
      expect(reason).to.equal("Emergency mode active");
    });

    it("Should block deposits for high-risk users", async function () {
      const { advancedSecurityManager, monitor, user1 } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      await advancedSecurityManager.connect(monitor).updateUserRiskScore(user1.address, 9000);
      
      const depositAmount = ethers.parseUnits("1000", 6);
      const [canDeposit, reason] = await advancedSecurityManager.canUserDeposit(user1.address, depositAmount);
      
      expect(canDeposit).to.be.false;
      expect(reason).to.equal("High risk user");
    });

    it("Should block deposits for flagged users", async function () {
      const { advancedSecurityManager, monitor, user1 } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      await advancedSecurityManager.connect(monitor).flagUser(user1.address, true, "Suspicious activity");
      
      const depositAmount = ethers.parseUnits("1000", 6);
      const [canDeposit, reason] = await advancedSecurityManager.canUserDeposit(user1.address, depositAmount);
      
      expect(canDeposit).to.be.false;
      expect(reason).to.equal("User flagged for suspicious activity");
    });
  });

  describe("Access Control", function () {
    it("Should enforce role-based access control", async function () {
      const { advancedSecurityManager, user1 } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      // Non-monitor should not be able to update risk scores
      await expect(
        advancedSecurityManager.connect(user1).updateUserRiskScore(user1.address, 5000)
      ).to.be.revertedWith("AccessControl");
      
      // Non-emergency should not be able to activate emergency mode
      await expect(
        advancedSecurityManager.connect(user1).activateEmergencyMode()
      ).to.be.revertedWith("AccessControl");
      
      // Non-governance should not be able to set parameters
      await expect(
        advancedSecurityManager.connect(user1).setAdvancedParameters(8000, 3600, 10)
      ).to.be.revertedWith("AccessControl");
    });

    it("Should allow role administration", async function () {
      const { advancedSecurityManager, governance, user1 } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      const MONITOR_ROLE = await advancedSecurityManager.MONITOR_ROLE();
      
      // Grant monitor role to user1
      await advancedSecurityManager.connect(governance).grantRole(MONITOR_ROLE, user1.address);
      
      // Verify user1 can now perform monitor functions
      expect(await advancedSecurityManager.hasRole(MONITOR_ROLE, user1.address)).to.be.true;
      
      // User1 should now be able to update risk scores
      await expect(
        advancedSecurityManager.connect(user1).updateUserRiskScore(user1.address, 5000)
      ).to.not.be.reverted;
    });
  });

  describe("Integration with Core Security", function () {
    it("Should maintain core security functionality", async function () {
      const { advancedSecurityManager, user1 } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      // Test that core MEV protection still works
      const mevStatus = await advancedSecurityManager.getUserMEVStatus(user1.address);
      expect(mevStatus.canDeposit).to.be.true;
      expect(mevStatus.dailyUsed).to.equal(0);
      
      // Test circuit breaker status
      const cbStatus = await advancedSecurityManager.getCircuitBreakerStatus();
      expect(cbStatus.triggered).to.be.false;
      expect(cbStatus.volumeThreshold).to.be.gt(0);
    });

    it("Should extend core functionality with advanced features", async function () {
      const { advancedSecurityManager, user1 } = await loadFixture(deployAdvancedSecurityManagerFixture);
      
      // Advanced features should be available
      const riskAssessment = await advancedSecurityManager.getUserRiskAssessment(user1.address);
      expect(riskAssessment).to.not.be.undefined;
      
      const advancedSettings = await advancedSecurityManager.getAdvancedSettings();
      expect(advancedSettings.emergencyModeActiveSetting).to.be.false;
      
      // Emergency mode function should be available
      expect(await advancedSecurityManager.isEmergencyMode()).to.be.false;
    });
  });
});