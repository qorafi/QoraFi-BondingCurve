const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");
const { deployFullSystem } = require("../fixtures/mock-deployments");

describe("Emergency Procedures Integration", function () {
  async function deployEmergencySystemFixture() {
    const system = await deployFullSystem();
    const { deployer, governance, emergency, oracleUpdater } = system.signers;
    const { coreSecurityManager, enhancedOracle } = system.contracts;

    // --- FIX: Grant necessary roles for emergency procedures ---
    const EMERGENCY_ROLE = await coreSecurityManager.EMERGENCY_ROLE();
    const GOVERNANCE_ROLE = await coreSecurityManager.GOVERNANCE_ROLE();
    const ORACLE_UPDATER_ROLE = await enhancedOracle.ORACLE_UPDATER_ROLE();

    // Grant EMERGENCY_ROLE to the dedicated emergency signer
    await coreSecurityManager.connect(deployer).grantRole(EMERGENCY_ROLE, emergency.address);
    await enhancedOracle.connect(deployer).grantRole(EMERGENCY_ROLE, emergency.address);

    // Grant GOVERNANCE_ROLE to the governance signer for recovery actions
    await coreSecurityManager.connect(deployer).grantRole(GOVERNANCE_ROLE, governance.address);
    await enhancedOracle.connect(deployer).grantRole(GOVERNANCE_ROLE, governance.address);
    
    // Grant ORACLE_UPDATER_ROLE to the oracleUpdater signer for flash loan tests
    await enhancedOracle.connect(deployer).grantRole(ORACLE_UPDATER_ROLE, oracleUpdater.address);

    return system;
  }

  describe("Emergency Mode Activation", function () {
    it("Should activate emergency mode across all contracts", async function () {
      const { contracts, signers } = await loadFixture(deployEmergencySystemFixture);
      
      // Check initial state
      expect(await contracts.coreSecurityManager.paused()).to.be.false;
      expect(await contracts.enhancedOracle.emergencyMode()).to.be.false;
      
      // Activate emergency mode on security manager using the emergency signer
      await contracts.coreSecurityManager.connect(signers.emergency).pause();
      
      // Activate emergency mode on oracle using the governance signer (as per contract)
      await contracts.enhancedOracle.connect(signers.governance).enableEmergencyMode();
      
      // Verify emergency state
      expect(await contracts.coreSecurityManager.paused()).to.be.true;
      expect(await contracts.enhancedOracle.emergencyMode()).to.be.true;
    });

    it("Should block normal operations during emergency mode", async function () {
      const { contracts, signers } = await loadFixture(deployEmergencySystemFixture);
      
      // Activate emergency mode
      await contracts.coreSecurityManager.connect(signers.emergency).pause();
      
      // Try normal operation (should fail)
      const [canDeposit, reason] = await contracts.coreSecurityManager.canUserDeposit(
        signers.user1.address, 
        ethers.parseUnits("1000", 6)
      );
      
      expect(canDeposit).to.be.false;
      expect(reason).to.equal("Pausable: paused");
    });

    it("Should allow emergency recovery operations", async function () {
      const { contracts, signers } = await loadFixture(deployEmergencySystemFixture);
      
      // Activate emergency mode
      await contracts.coreSecurityManager.connect(signers.emergency).pause();
      await contracts.enhancedOracle.connect(signers.governance).enableEmergencyMode();
      
      // Perform recovery operations with the governance signer
      await contracts.coreSecurityManager.connect(signers.governance).unpause();
      await contracts.enhancedOracle.connect(signers.governance).disableEmergencyMode();
      
      // Verify normal operations restored
      expect(await contracts.coreSecurityManager.paused()).to.be.false;
      expect(await contracts.enhancedOracle.emergencyMode()).to.be.false;
    });
  });

  describe("Circuit Breaker Emergency Response", function () {
    it("Should trigger emergency procedures when circuit breaker activates", async function () {
      const { contracts, signers, tokens } = await loadFixture(deployEmergencySystemFixture);
      
      // Trigger circuit breaker with a large volume deposit through the bonding curve
      const largeVolume = ethers.parseUnits("150000", 6); // Exceeds 100k threshold
      await tokens.usdt.mint(signers.user1.address, largeVolume);
      await tokens.usdt.connect(signers.user1).approve(await contracts.enhancedBondingCurve.getAddress(), largeVolume);
      
      await expect(
        contracts.enhancedBondingCurve.connect(signers.user1).deposit(largeVolume, 0, 0, (await time.latest()) + 60, 100)
      ).to.be.revertedWithCustomError(contracts.coreSecurityManager, "CircuitBreakerTriggered");
      
      // Verify circuit breaker is active
      const cbStatus = await contracts.coreSecurityManager.getCircuitBreakerStatus();
      expect(cbStatus.triggered).to.be.true;
    });

    it("Should automatically recover after circuit breaker cooldown", async function () {
        const { contracts, signers, tokens } = await loadFixture(deployEmergencySystemFixture);
    
        // Trigger circuit breaker
        const largeVolume = ethers.parseUnits("150000", 6);
        await tokens.usdt.mint(signers.user1.address, largeVolume);
        await tokens.usdt.connect(signers.user1).approve(await contracts.enhancedBondingCurve.getAddress(), largeVolume);
        await expect(
            contracts.enhancedBondingCurve.connect(signers.user1).deposit(largeVolume, 0, 0, (await time.latest()) + 60, 100)
        ).to.be.revertedWithCustomError(contracts.coreSecurityManager, "CircuitBreakerTriggered");
    
        // Verify triggered
        let cbStatus = await contracts.coreSecurityManager.getCircuitBreakerStatus();
        expect(cbStatus.triggered).to.be.true;
    
        // Fast forward past cooldown
        const cooldown = await contracts.coreSecurityManager.circuitBreakerCooldown();
        await time.increase(cooldown);
    
        // Check status again (it should now allow the transaction)
        const [canDeposit] = await contracts.coreSecurityManager.canUserDeposit(signers.user1.address, ethers.parseUnits("1", 6));
        expect(canDeposit).to.be.true;
    });
  });

  describe("Oracle Emergency Procedures", function () {
    it("Should handle oracle failures gracefully", async function () {
      const { contracts, signers } = await loadFixture(deployEmergencySystemFixture);
      
      await contracts.enhancedOracle.connect(signers.governance).setFallbackPrice(
        ethers.parseEther("1") // 1 USD per token
      );
      
      await contracts.enhancedOracle.connect(signers.governance).enableEmergencyMode();
      
      const currentPrice = await contracts.enhancedOracle.getCurrentPrice();
      expect(currentPrice).to.equal(ethers.parseEther("1"));
    });

    it("Should reset oracle observations in emergency", async function () {
      const { contracts, signers } = await loadFixture(deployEmergencySystemFixture);
      
      await contracts.enhancedOracle.connect(signers.governance).emergencyResetObservations();
      
      const newCount = await contracts.enhancedOracle.getValidObservationCount();
      expect(newCount).to.equal(1); // Should have exactly one new observation
    });
  });

  describe("Flash Loan Attack Response", function () {
    it("Should detect and respond to flash loan attacks", async function () {
      const { contracts, signers } = await loadFixture(deployEmergencySystemFixture);
      const { oracleUpdater } = signers;
      
      // First update should succeed
      await expect(
        contracts.enhancedOracle.connect(oracleUpdater).updateMarketCap()
      ).to.not.be.reverted;
      
      // Second update in same block should fail due to flash loan protection
      await expect(
        contracts.enhancedOracle.connect(oracleUpdater).updateMarketCap()
      ).to.be.revertedWithCustomError(contracts.enhancedOracle, "UpdateTooFrequent");
    });

    it("Should provide flash loan attack statistics", async function () {
      const { contracts } = await loadFixture(deployEmergencySystemFixture);
      
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
      
      // Use the emergency signer to pause
      await contracts.coreSecurityManager.connect(signers.emergency).pause();
      // Use governance to enable oracle emergency mode
      await contracts.enhancedOracle.connect(signers.governance).enableEmergencyMode();
      
      expect(await contracts.coreSecurityManager.paused()).to.be.true;
      expect(await contracts.enhancedOracle.emergencyMode()).to.be.true;
      
      // Coordinate recovery using the governance signer
      await contracts.enhancedOracle.connect(signers.governance).disableEmergencyMode();
      await contracts.coreSecurityManager.connect(signers.governance).unpause();
      
      expect(await contracts.coreSecurityManager.paused()).to.be.false;
      expect(await contracts.enhancedOracle.emergencyMode()).to.be.false;
    });

    it("Should maintain data integrity during emergency procedures", async function () {
      const { contracts, signers } = await loadFixture(deployEmergencySystemFixture);
      
      const initialProtocolStats = await contracts.coreSecurityManager.getProtocolStatistics();
      
      await contracts.coreSecurityManager.connect(signers.emergency).pause();
      
      const [canDeposit] = await contracts.coreSecurityManager.canUserDeposit(
        signers.user1.address,
        ethers.parseUnits("1000", 6)
      );
      expect(canDeposit).to.be.false;
      
      await contracts.coreSecurityManager.connect(signers.governance).unpause();
      
      const finalProtocolStats = await contracts.coreSecurityManager.getProtocolStatistics();
      expect(finalProtocolStats.totalDeposits).to.equal(initialProtocolStats.totalDeposits);
    });
  });
});
