// test/integration/complete-system.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");
const { deployFullSystem } = require("../fixtures/mock-deployments");
const { TEST_CONSTANTS } = require("../fixtures/test-data");

describe("Complete System Integration", function () {
  async function deployAndSetupSystemFixture() {
    return await deployFullSystem();
  }

  describe("Full System Deployment", function () {
    it("Should deploy all contracts successfully", async function () {
      const { contracts, tokens } = await loadFixture(deployAndSetupSystemFixture);
      
      for (const contract of Object.values(contracts)) {
        expect(await contract.getAddress()).to.not.equal(ethers.ZeroAddress);
      }
      for (const token of Object.values(tokens)) {
        expect(await token.getAddress()).to.not.equal(ethers.ZeroAddress);
      }
    });

    it("Should have correct initial configurations", async function () {
      const { contracts } = await loadFixture(deployAndSetupSystemFixture);
      
      const newTokenSettings = await contracts.coreSecurityManager.getNewTokenSettings();
      expect(newTokenSettings.newTokenModeActive).to.be.true;
      
      const advancedSettings = await contracts.advancedSecurityManager.getAdvancedSettings();
      expect(advancedSettings.highRiskThresholdSetting).to.equal(8000);
      expect(advancedSettings.emergencyModeActiveSetting).to.be.false;
      
      expect(await contracts.enhancedOracle.isHealthy()).to.be.true;
      
      const govStats = await contracts.securityGovernance.getGovernanceStats();
      expect(govStats.requiredSignaturesCount).to.equal(2);
    });

    it("Should have proper role assignments", async function () {
      const { contracts, signers } = await loadFixture(deployAndSetupSystemFixture);
      
      const EMERGENCY_ROLE_SG = await contracts.securityGovernance.EMERGENCY_ROLE();
      const PARAM_MANAGER_ROLE_SG = await contracts.securityGovernance.PARAM_MANAGER_ROLE();
      const ORACLE_UPDATER_ROLE_EO = await contracts.enhancedOracle.ORACLE_UPDATER_ROLE();
      
      expect(await contracts.securityGovernance.hasRole(EMERGENCY_ROLE_SG, signers.emergency.address)).to.be.true;
      expect(await contracts.securityGovernance.hasRole(PARAM_MANAGER_ROLE_SG, signers.paramManager.address)).to.be.true;
      expect(await contracts.enhancedOracle.hasRole(ORACLE_UPDATER_ROLE_EO, signers.oracleUpdater.address)).to.be.true;
    });
  });

  describe("End-to-End User Journey", function () {
    it("Should handle complete user deposit flow", async function () {
        const { contracts, tokens, signers } = await loadFixture(deployAndSetupSystemFixture);
        const { enhancedBondingCurve, advancedSecurityManager } = contracts;
        const { user1 } = signers;
        
        const depositAmount = TEST_CONSTANTS.MEDIUM_DEPOSIT;
        await tokens.usdt.mint(user1.address, depositAmount);
        await tokens.usdt.connect(user1).approve(await enhancedBondingCurve.getAddress(), depositAmount);
  
        await expect(
          enhancedBondingCurve.connect(user1).deposit(depositAmount, 0, 0, (await time.latest()) + 60, 100)
        ).to.emit(enhancedBondingCurve, "DepositProcessed");
        
        const userStats = await advancedSecurityManager.getUserStatistics(user1.address);
        expect(userStats.depositCount).to.equal(1);
    });

    it("Should handle oracle price updates affecting user deposits", async function () {
      const { contracts, signers } = await loadFixture(deployAndSetupSystemFixture);
      
      const marketCap = await contracts.enhancedOracle.getCachedMarketCap();
      expect(marketCap).to.be.gt(0);
      
      const [canDeposit] = await contracts.advancedSecurityManager.canUserDeposit(
        signers.user1.address, 
        TEST_CONSTANTS.SMALL_DEPOSIT
      );
      expect(canDeposit).to.be.true;
    });
  });

  describe("Security Event Response Chain", function () {
    it("Should handle circuit breaker trigger and recovery", async function () {
        const { contracts, signers, tokens } = await loadFixture(deployAndSetupSystemFixture);
        const { enhancedBondingCurve, coreSecurityManager } = contracts;
    
        const largeVolume = TEST_CONSTANTS.CIRCUIT_BREAKER_THRESHOLD + ethers.parseUnits("1", 6);
        await tokens.usdt.mint(signers.user1.address, largeVolume);
        await tokens.usdt.connect(signers.user1).approve(await enhancedBondingCurve.getAddress(), largeVolume);
    
        await expect(
            enhancedBondingCurve.connect(signers.user1).deposit(largeVolume, 0, 0, (await time.latest()) + 60, 100)
        ).to.be.revertedWithCustomError(coreSecurityManager, "CircuitBreakerTriggered");
    
        const [canDeposit] = await coreSecurityManager.canUserDeposit(signers.user1.address, TEST_CONSTANTS.SMALL_DEPOSIT);
        expect(canDeposit).to.be.false;
    
        await time.increase(TEST_CONSTANTS.CIRCUIT_BREAKER_COOLDOWN + 1);
    
        const [canDepositAfter] = await coreSecurityManager.canUserDeposit(signers.user1.address, TEST_CONSTANTS.SMALL_DEPOSIT);
        expect(canDepositAfter).to.be.true;
    });

    it("Should handle flash loan attack detection", async function () {
        const { contracts, signers } = await loadFixture(deployAndSetupSystemFixture);
        
        await time.increase(TEST_CONSTANTS.MIN_ORACLE_UPDATE_INTERVAL + 1);
        await contracts.enhancedOracle.connect(signers.oracleUpdater).updateMarketCap();
    
        await expect(
            contracts.enhancedOracle.connect(signers.oracleUpdater).updateMarketCap()
        ).to.be.revertedWithCustomError(contracts.enhancedOracle, "UpdateTooFrequent");
    });

    it("Should coordinate emergency mode across all contracts", async function () {
        const { contracts, signers } = await loadFixture(deployAndSetupSystemFixture);
    
        await contracts.advancedSecurityManager.connect(signers.emergency).activateEmergencyMode();
        await contracts.enhancedOracle.connect(signers.governance).enableEmergencyMode();
    
        expect(await contracts.advancedSecurityManager.advancedEmergencyModeActive()).to.be.true;
        expect(await contracts.enhancedOracle.emergencyMode()).to.be.true;
        expect(await contracts.coreSecurityManager.paused()).to.be.true;
    
        const [, reason] = await contracts.advancedSecurityManager.canUserDeposit(
            signers.user1.address,
            TEST_CONSTANTS.SMALL_DEPOSIT
        );
        expect(reason).to.equal("Advanced emergency mode active");
    
        await contracts.enhancedOracle.connect(signers.governance).disableEmergencyMode();
        await contracts.advancedSecurityManager.connect(signers.governance).deactivateEmergencyMode();
    
        expect(await contracts.advancedSecurityManager.advancedEmergencyModeActive()).to.be.false;
        expect(await contracts.coreSecurityManager.paused()).to.be.false;
    });
  });

  describe("Risk Management Integration", function () {
    it("Should escalate user risk and block transactions", async function () {
      const { contracts, signers } = await loadFixture(deployAndSetupSystemFixture);
      
      await contracts.advancedSecurityManager
        .connect(signers.monitor)
        .updateUserRiskScore(signers.user1.address, 9000);
      
      const [, reason] = await contracts.advancedSecurityManager.canUserDeposit(
        signers.user1.address,
        TEST_CONSTANTS.SMALL_DEPOSIT
      );
      expect(reason).to.equal("High risk user");
    });
  });

  describe("Governance Integration", function () {
    it("Should handle emergency governance procedures", async function () {
        const { contracts, signers } = await loadFixture(deployAndSetupSystemFixture);
        const { securityGovernance, coreSecurityManager } = contracts;
        const { emergency, governance } = signers;
    
        const target = await coreSecurityManager.getAddress();
        const data = coreSecurityManager.interface.encodeFunctionData("pause", []);
    
        const proposalTx = await securityGovernance.connect(emergency).proposeEmergencyTransaction(target, 0, data);
        const receipt = await proposalTx.wait();
        const event = receipt.logs.find(e => e.eventName === 'EmergencyTransactionProposed');
        const txHash = event.args.txHash;
    
        await time.increase(TEST_CONSTANTS.ONE_DAY + 1);
    
        await expect(
            securityGovernance.connect(governance).executeEmergencyTransaction(txHash)
        ).to.emit(securityGovernance, "EmergencyTransactionExecuted");
    
        expect(await coreSecurityManager.paused()).to.be.true;
    });
  });
});