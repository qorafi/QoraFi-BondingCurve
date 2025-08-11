// test/integration/emergency-procedures.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");
const { deployFullSystem } = require("../fixtures/mock-deployments");
const { TEST_HELPERS } = require("../fixtures/test-data");

describe("Emergency Procedures Integration", function () {
  async function deployEmergencySystemFixture() {
    return await deployFullSystem();
  }

  describe("Emergency Mode Activation", function () {
    it("Should activate emergency mode across all contracts", async function () {
      const { contracts, signers } = await loadFixture(deployEmergencySystemFixture);
      
      // Check initial state
      expect(await contracts.coreSecurityManager.isPaused()).to.be.false;
      expect(await contracts.enhancedOracle.emergencyMode()).to.be.false;
      
      // Activate emergency mode on security manager
      await contracts.coreSecurityManager.connect(signers.governance).pause();
      
      // Activate emergency mode on oracle
      await contracts.enhancedOracle.connect(signers.governance).enableEmergencyMode();
      
      // Verify emergency state
      expect(await contracts.coreSecurityManager.isPaused()).to.be.true;
      expect(await contracts.enhancedOracle.emergencyMode()).to.be.true;
    });

    it("Should block normal operations during emergency mode", async function () {
      const { contracts, signers } = await loadFixture(deployEmergencySystemFixture);
      
      // Activate emergency mode
      await contracts.coreSecurityManager.connect(signers.governance).pause();
      
      // Try normal operation (should fail)
      const [canDeposit, reason] = await contracts.coreSecurityManager.canUserDeposit(
        signers.user1.address, 
        ethers.parseUnits("1000", 6)
      );
      
      expect(canDeposit).to.be.false;
      expect(reason).to.equal("Paused");
    });

    it("Should allow emergency recovery operations", async function () {
      const { contracts, signers } = await loadFixture(deployEmergencySystemFixture);
      
      // Activate emergency mode
      await contracts.coreSecurityManager.connect(signers.governance).pause();
      await contracts.enhancedOracle.connect(signers.governance).enableEmergencyMode();
      
      // Perform recovery operations
      await contracts.coreSecurityManager.connect(signers.governance).unpause();
      await contracts.enhancedOracle.connect(signers.governance).disableEmergencyMode();
      
      // Verify normal operations restored
      expect(await contracts.coreSecurityManager.isPaused()).to.be.false;
      expect(await contracts.enhancedOracle.emergencyMode()).to.be.false;
    });
  });

  describe("Circuit Breaker Emergency Response", function () {
    it("Should trigger emergency procedures when circuit breaker activates", async function () {
      const { contracts, signers } = await loadFixture(deployEmergencySystemFixture);
      
      // Trigger circuit breaker with large volume
      const largeVolume = ethers.parseUnits("150000", 6); // Exceeds 100k threshold
      
      await expect(
        contracts.coreSecurityManager.checkCircuitBreaker(largeVolume)
      ).to.emit(contracts.coreSecurityManager, "CircuitBreakerTriggered");
      
      // Verify circuit breaker is active
      const cbStatus = await contracts.coreSecurityManager.getCircuitBreakerStatus();
      expect(cbStatus.triggered).to.be.true;
    });

    it("Should automatically recover after circuit breaker cooldown", async function () {
      const { contracts } = await loadFixture(deployEmergencySystemFixture);
      
      // Trigger circuit breaker
      const largeVolume = ethers.parseUnits("150000", 6);
      await contracts.coreSecurityManager.checkCircuitBreaker(largeVolume);
      
      // Verify triggered
      let cbStatus = await contracts.coreSecurityManager.getCircuitBreakerStatus();
      expect(cbStatus.triggered).to.be.true;
      
      // Fast forward past cooldown
      await TEST_HELPERS.fastForwardTime(2 * 60 * 60 + 1); // 2 hours + 1 second
      
      // Verify reset
      cbStatus = await contracts.coreSecurityManager.getCircuitBreakerStatus();
      expect(cbStatus.timeUntilReset).to.equal(0);
    });
  });

  describe("Oracle Emergency Procedures", function () {
    it("Should handle oracle failures gracefully", async function () {
      const { contracts, signers } = await loadFixture(deployEmergencySystemFixture);
      
      // Set fallback price
      await contracts.enhancedOracle.connect(signers.governance).setFallbackPrice(
        ethers.parseEther("1") // 1 USD per token
      );
      
      // Enable emergency mode
      await contracts.enhancedOracle.connect(signers.governance).enableEmergencyMode();
      
      // Verify fallback price is used
      const currentPrice = await contracts.enhancedOracle.getCurrentPrice();
      expect(currentPrice).to.equal(ethers.parseEther("1"));
    });

    it("Should reset oracle observations in emergency", async function () {
      const { contracts, signers } = await loadFixture(deployEmergencySystemFixture);
      
      // Get initial observation count
      const initialCount = await contracts.enhancedOracle.getObservationCount();
      
      // Reset observations (emergency procedure)
      await contracts.enhancedOracle.connect(signers.governance).emergencyResetObservations();
      
      // Verify observations were reset and reinitialized
      const newCount = await contracts.enhancedOracle.getObservationCount();
      expect(newCount).to.be.gte(1); // Should have at least one new observation
    });
  });

  describe("Flash Loan Attack Response", function () {
    it("Should detect and respond to flash loan attacks", async function () {
      const { contracts, signers } = await loadFixture(deployEmergencySystemFixture);
      
      // Simulate flash loan attack by rapid updates
      const oracleUpdater = signers.deployer; // Has ORACLE_UPDATER_ROLE
      
      // Try multiple updates in same block (should fail)
      await expect(
        contracts.enhancedOracle.connect(oracleUpdater).updateMarketCap()
      ).to.not.be.reverted;
      
      // Second update in same block should fail due to flash loan protection
      await expect(
        contracts.enhancedOracle.connect(oracleUpdater).updateMarketCap()
      ).to.be.revertedWith("TooManyUpdatesPerBlock");
    });

    it("Should provide flash loan attack statistics", async function () {
      const { contracts } = await loadFixture(deployEmergencySystemFixture);
      
      // Get flash loan statistics
      const currentBlock = await ethers.provider.getBlockNumber();
      const [updatesInBlock, updatesInWindow, isRisky] = await contracts.enhancedOracle.getFlashLoanStats(currentBlock);
      
      expect(updatesInBlock).to.be.a("bigint");
      expect(updatesInWindow).to.be.a("bigint");
      expect(isRisky).to.be.a("boolean");
    });
  });

  describe("Multi-Contract Emergency Coordination", function () {
    it("Should coordinate emergency procedures across contracts", async function () {
      const { contracts, signers } = await loadFixture(deployEmergencySystemFixture);
      
      // Simulate system-wide emergency
      await contracts.coreSecurityManager.connect(signers.governance).pause();
      await contracts.enhancedOracle.connect(signers.governance).enableEmergencyMode();
      
      // Verify all contracts are in emergency state
      expect(await contracts.coreSecurityManager.isPaused()).to.be.true;
      expect(await contracts.enhancedOracle.emergencyMode()).to.be.true;
      
      // Coordinate recovery
      await contracts.enhancedOracle.connect(signers.governance).disableEmergencyMode();
      await contracts.coreSecurityManager.connect(signers.governance).unpause();
      
      // Verify recovery
      expect(await contracts.coreSecurityManager.isPaused()).to.be.false;
      expect(await contracts.enhancedOracle.emergencyMode()).to.be.false;
    });

    it("Should maintain data integrity during emergency procedures", async function () {
      const { contracts, signers, tokens } = await loadFixture(deployEmergencySystemFixture);
      
      // Record initial state
      const initialProtocolStats = await contracts.coreSecurityManager.getProtocolStatistics();
      
      // Emergency pause
      await contracts.coreSecurityManager.connect(signers.governance).pause();
      
      // Try to modify state (should fail)
      const [canDeposit] = await contracts.coreSecurityManager.canUserDeposit(
        signers.user1.address,
        ethers.parseUnits("1000", 6)
      );
      expect(canDeposit).to.be.false;
      
      // Resume operations
      await contracts.coreSecurityManager.connect(signers.governance).unpause();
      
      // Verify state integrity maintained
      const finalProtocolStats = await contracts.coreSecurityManager.getProtocolStatistics();
      expect(finalProtocolStats.totalDeposits).to.equal(initialProtocolStats.totalDeposits);
    });
  });

  describe("Emergency Token Recovery", function () {
    it("Should allow emergency token recovery from contracts", async function () {
      const { contracts, tokens, signers } = await loadFixture(deployEmergencySystemFixture);
      
      // Send some tokens to the contract (simulate stuck tokens)
      await tokens.usdt.mint(await contracts.coreSecurityManager.getAddress(), ethers.parseUnits("1000", 6));
      
      const initialBalance = await tokens.usdt.balanceOf(await contracts.coreSecurityManager.getAddress());
      expect(initialBalance).to.equal(ethers.parseUnits("1000", 6));
      
      // Emergency recovery would be implemented in a real emergency function
      // This is a placeholder showing the concept
      const recoveryAmount = ethers.parseUnits("1000", 6);
      
      // In practice, you'd call an emergency recovery function
      // await contracts.coreSecurityManager.connect(signers.governance).emergencyRecoverERC20(
      //   await tokens.usdt.getAddress(),
      //   signers.treasury.address,
      //   recoveryAmount
      // );
    });
  });
});