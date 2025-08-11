// test/integration/complete-system.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");
const { deployFullSystem } = require("../fixtures/mock-deployments");
const { TEST_CONSTANTS, TEST_DATA, TEST_HELPERS } = require("../fixtures/test-data");

describe("Complete System Integration", function () {
  async function deployCompleteSystemFixture() {
    return await deployFullSystem();
  }

  describe("Full System Deployment", function () {
    it("Should deploy all contracts successfully", async function () {
      const { contracts, tokens, signers } = await loadFixture(deployCompleteSystemFixture);
      
      // Verify all contracts are deployed
      expect(await contracts.coreSecurityManager.getAddress()).to.not.equal(ethers.ZeroAddress);
      expect(await contracts.advancedSecurityManager.getAddress()).to.not.equal(ethers.ZeroAddress);
      expect(await contracts.enhancedOracle.getAddress()).to.not.equal(ethers.ZeroAddress);
      expect(await contracts.securityGovernance.getAddress()).to.not.equal(ethers.ZeroAddress);
      
      // Verify tokens are deployed
      expect(await tokens.usdt.getAddress()).to.not.equal(ethers.ZeroAddress);
      expect(await tokens.qorafi.getAddress()).to.not.equal(ethers.ZeroAddress);
      expect(await tokens.weth.getAddress()).to.not.equal(ethers.ZeroAddress);
      
      // Verify signers have roles
      const GOVERNANCE_ROLE = await contracts.securityGovernance.GOVERNANCE_ROLE();
      expect(await contracts.securityGovernance.hasRole(GOVERNANCE_ROLE, signers.deployer.address)).to.be.true;
    });

    it("Should have correct initial configurations", async function () {
      const { contracts } = await loadFixture(deployCompleteSystemFixture);
      
      // Core Security Manager
      const newTokenSettings = await contracts.coreSecurityManager.getNewTokenSettings();
      expect(newTokenSettings.newTokenModeActive).to.be.true;
      expect(newTokenSettings.maxGasPriceSetting).to.equal(TEST_CONSTANTS.NORMAL_GAS_PRICE);
      
      // Advanced Security Manager
      const advancedSettings = await contracts.advancedSecurityManager.getAdvancedSettings();
      expect(advancedSettings.highRiskThresholdSetting).to.equal(TEST_CONSTANTS.HIGH_RISK_THRESHOLD);
      expect(advancedSettings.emergencyModeActiveSetting).to.be.false;
      
      // Enhanced Oracle
      expect(await contracts.enhancedOracle.newTokenMode()).to.be.true;
      expect(await contracts.enhancedOracle.isHealthy()).to.be.true;
      
      // Security Governance
      const govStats = await contracts.securityGovernance.getGovernanceStats();
      expect(govStats.requiredSignaturesCount).to.equal(2);
    });

    it("Should have proper role assignments", async function () {
      const { contracts, signers } = await loadFixture(deployCompleteSystemFixture);
      
      // Check Security Governance roles
      const EMERGENCY_ROLE = await contracts.securityGovernance.EMERGENCY_ROLE();
      const PARAM_MANAGER_ROLE = await contracts.securityGovernance.PARAM_MANAGER_ROLE();
      
      expect(await contracts.securityGovernance.hasRole(EMERGENCY_ROLE, signers.emergency.address)).to.be.true;
      expect(await contracts.securityGovernance.hasRole(PARAM_MANAGER_ROLE, signers.paramManager.address)).to.be.true;
      
      // Check Oracle roles
      const ORACLE_UPDATER_ROLE = await contracts.enhancedOracle.ORACLE_UPDATER_ROLE();
      expect(await contracts.enhancedOracle.hasRole(ORACLE_UPDATER_ROLE, signers.oracleUpdater.address)).to.be.true;
    });
  });

  describe("End-to-End User Journey", function () {
    it("Should handle complete user deposit flow", async function () {
      const { contracts, tokens, signers } = await loadFixture(deployCompleteSystemFixture);
      
      const depositAmount = TEST_CONSTANTS.MEDIUM_DEPOSIT;
      
      // 1. Check initial user eligibility
      const [canDeposit, reason] = await contracts.advancedSecurityManager.canUserDeposit(
        signers.user1.address, 
        depositAmount
      );
      expect(canDeposit).to.be.true;
      expect(reason).to.equal("OK");
      
      // 2. Perform advanced security checks
      await expect(
        contracts.advancedSecurityManager.advancedPreDepositCheck(signers.user1.address, depositAmount)
      ).to.not.be.reverted;
      
      // 3. Update user behavior tracking
      await contracts.advancedSecurityManager.postDepositUpdate(signers.user1.address, depositAmount);
      
      // 4. Verify user statistics updated
      const userStats = await contracts.advancedSecurityManager.getUserStatistics(signers.user1.address);
      expect(userStats.depositCount).to.equal(1);
      
      // 5. Check risk assessment updated
      const riskAssessment = await contracts.advancedSecurityManager.getUserRiskAssessment(signers.user1.address);
      expect(riskAssessment.canTransact).to.be.true;
    });

    it("Should handle oracle price updates affecting user deposits", async function () {
      const { contracts, signers } = await loadFixture(deployCompleteSystemFixture);
      
      // 1. Initial oracle update
      await TEST_HELPERS.fastForwardTime(TEST_CONSTANTS.MIN_ORACLE_UPDATE_INTERVAL + 1);
      await contracts.enhancedOracle.connect(signers.oracleUpdater).updateMarketCap();
      
      // 2. Check market cap was set
      const marketCap = await contracts.enhancedOracle.getCachedMarketCap();
      expect(marketCap).to.be.gt(0);
      
      // 3. Verify user can still deposit after oracle update
      const [canDeposit] = await contracts.advancedSecurityManager.canUserDeposit(
        signers.user1.address, 
        TEST_CONSTANTS.SMALL_DEPOSIT
      );
      expect(canDeposit).to.be.true;
    });

    it("Should handle governance parameter changes affecting security", async function () {
      const { contracts, signers } = await loadFixture(deployCompleteSystemFixture);
      
      // 1. Propose parameter change to reduce risk threshold
      const proposalTx = await contracts.securityGovernance
        .connect(signers.paramManager)
        .proposeParameterChange("highRiskThreshold", 6000); // Reduce from 8000 to 6000
      
      const receipt = await proposalTx.wait();
      
      // 2. Extract proposal ID and sign it
      const event = receipt.logs.find(log => {
        try {
          const parsed = contracts.securityGovernance.interface.parseLog(log);
          return parsed.name === "ParameterChangeProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = contracts.securityGovernance.interface.parseLog(event);
        const proposalId = parsed.args.proposalId;
        
        // 3. Add second signature to execute
        await contracts.securityGovernance.connect(signers.governance).signProposal(proposalId);
        
        // 4. Verify parameter was updated
        const newThreshold = await contracts.securityGovernance.getSecurityParameter("highRiskThreshold");
        expect(newThreshold).to.equal(6000);
      }
    });
  });

  describe("Security Event Response Chain", function () {
    it("Should handle circuit breaker trigger and recovery", async function () {
      const { contracts, signers } = await loadFixture(deployCompleteSystemFixture);
      
      // 1. Trigger circuit breaker with large volume
      const largeVolume = TEST_CONSTANTS.CIRCUIT_BREAKER_THRESHOLD + ethers.parseUnits("1000", 6);
      
      await expect(
        contracts.coreSecurityManager.checkCircuitBreaker(largeVolume)
      ).to.emit(contracts.coreSecurityManager, "CircuitBreakerTriggered");
      
      // 2. Verify circuit breaker is active
      const cbStatus = await contracts.coreSecurityManager.getCircuitBreakerStatus();
      expect(cbStatus.triggered).to.be.true;
      
      // 3. Verify deposits are blocked
      const [canDeposit, reason] = await contracts.coreSecurityManager.canUserDeposit(
        signers.user1.address,
        TEST_CONSTANTS.SMALL_DEPOSIT
      );
      expect(canDeposit).to.be.false;
      
      // 4. Fast forward past cooldown period
      await TEST_HELPERS.fastForwardTime(TEST_CONSTANTS.CIRCUIT_BREAKER_COOLDOWN + 1);
      
      // 5. Verify circuit breaker reset and deposits allowed
      const cbStatusAfter = await contracts.coreSecurityManager.getCircuitBreakerStatus();
      expect(cbStatusAfter.timeUntilReset).to.equal(0);
      
      const [canDepositAfter] = await contracts.coreSecurityManager.canUserDeposit(
        signers.user1.address,
        TEST_CONSTANTS.SMALL_DEPOSIT
      );
      expect(canDepositAfter).to.be.true;
    });

    it("Should handle flash loan attack detection", async function () {
      const { contracts, signers } = await loadFixture(deployCompleteSystemFixture);
      
      // 1. First oracle update should succeed
      await TEST_HELPERS.fastForwardTime(TEST_CONSTANTS.MIN_ORACLE_UPDATE_INTERVAL + 1);
      await contracts.enhancedOracle.connect(signers.oracleUpdater).updateMarketCap();
      
      // 2. Second update in same block should fail (flash loan protection)
      await expect(
        contracts.enhancedOracle.connect(signers.oracleUpdater).updateMarketCap()
      ).to.be.revertedWith("TooManyUpdatesPerBlock");
      
      // 3. Check flash loan statistics
      const currentBlock = await ethers.provider.getBlockNumber();
      const flashLoanStatus = await contracts.enhancedOracle.getFlashLoanProtectionStatus();
      expect(flashLoanStatus.currentBlockUpdates).to.equal(1);
    });

    it("Should coordinate emergency mode across all contracts", async function () {
      const { contracts, signers } = await loadFixture(deployCompleteSystemFixture);
      
      // 1. Activate emergency mode on security manager
      await contracts.advancedSecurityManager.connect(signers.emergency).activateEmergencyMode();
      
      // 2. Activate emergency mode on oracle
      await contracts.enhancedOracle.connect(signers.governance).enableEmergencyMode();
      
      // 3. Verify all contracts are in emergency state
      expect(await contracts.advancedSecurityManager.emergencyModeActive()).to.be.true;
      expect(await contracts.enhancedOracle.emergencyMode()).to.be.true;
      expect(await contracts.coreSecurityManager.isPaused()).to.be.true;
      
      // 4. Verify normal operations are blocked
      const [canDeposit, reason] = await contracts.advancedSecurityManager.canUserDeposit(
        signers.user1.address,
        TEST_CONSTANTS.SMALL_DEPOSIT
      );
      expect(canDeposit).to.be.false;
      expect(reason).to.equal("Emergency mode active");
      
      // 5. Recovery sequence
      await contracts.enhancedOracle.connect(signers.governance).disableEmergencyMode();
      await contracts.advancedSecurityManager.connect(signers.governance).deactivateEmergencyMode();
      
      // 6. Verify normal operations restored
      expect(await contracts.advancedSecurityManager.emergencyModeActive()).to.be.false;
      expect(await contracts.enhancedOracle.emergencyMode()).to.be.false;
      expect(await contracts.coreSecurityManager.isPaused()).to.be.false;
    });
  });

  describe("Risk Management Integration", function () {
    it("Should escalate user risk and block transactions", async function () {
      const { contracts, signers } = await loadFixture(deployCompleteSystemFixture);
      
      // 1. Set user as high risk
      await contracts.advancedSecurityManager
        .connect(signers.monitor)
        .updateUserRiskScore(signers.user1.address, 9000); // 90% risk
      
      // 2. Verify user is blocked from deposits
      const [canDeposit, reason] = await contracts.advancedSecurityManager.canUserDeposit(
        signers.user1.address,
        TEST_CONSTANTS.SMALL_DEPOSIT
      );
      expect(canDeposit).to.be.false;
      expect(reason).to.equal("High risk user");
      
      // 3. Flag user for suspicious activity
      await contracts.advancedSecurityManager
        .connect(signers.monitor)
        .flagUser(signers.user1.address, true, "Suspicious pattern detected");
      
      // 4. Verify risk assessment reflects changes
      const riskAssessment = await contracts.advancedSecurityManager.getUserRiskAssessment(signers.user1.address);
      expect(riskAssessment.flagged).to.be.true;
      expect(riskAssessment.canTransact).to.be.false;
      expect(riskAssessment.suspiciousActivityCount).to.equal(1);
    });

    it("Should handle batch risk management operations", async function () {
      const { contracts, signers } = await loadFixture(deployCompleteSystemFixture);
      
      const users = [signers.user1.address, signers.user2.address];
      const riskScores = [7500, 6000]; // High and medium risk
      
      // 1. Batch update risk scores
      await contracts.advancedSecurityManager
        .connect(signers.monitor)
        .batchUpdateRiskScores(users, riskScores);
      
      // 2. Verify both users have updated scores
      const user1Risk = await contracts.advancedSecurityManager.getUserRiskAssessment(users[0]);
      const user2Risk = await contracts.advancedSecurityManager.getUserRiskAssessment(users[1]);
      
      expect(user1Risk.riskScore).to.equal(7500);
      expect(user2Risk.riskScore).to.equal(6000);
      expect(user1Risk.canTransact).to.be.true; // Below 8000 threshold
      expect(user2Risk.canTransact).to.be.true;
    });
  });

  describe("Governance Integration", function () {
    it("Should handle complex governance workflow", async function () {
      const { contracts, signers } = await loadFixture(deployCompleteSystemFixture);
      
      // 1. Propose multiple parameter changes
      const proposals = [];
      
      const proposal1Tx = await contracts.securityGovernance
        .connect(signers.paramManager)
        .proposeParameterChange("maxPriceChangeBPS", 1500);
      proposals.push(await proposal1Tx.wait());
      
      const proposal2Tx = await contracts.securityGovernance
        .connect(signers.paramManager)
        .proposeParameterChange("circuitBreakerCooldown", 3600);
      proposals.push(await proposal2Tx.wait());
      
      // 2. Check governance statistics
      const govStats = await contracts.securityGovernance.getGovernanceStats();
      expect(govStats.totalProposalsCount).to.equal(2);
      expect(govStats.executedProposalsCount).to.equal(0);
      
      // 3. Sign and execute proposals
      for (const receipt of proposals) {
        const event = receipt.logs.find(log => {
          try {
            const parsed = contracts.securityGovernance.interface.parseLog(log);
            return parsed.name === "ParameterChangeProposed";
          } catch {
            return false;
          }
        });
        
        if (event) {
          const parsed = contracts.securityGovernance.interface.parseLog(event);
          const proposalId = parsed.args.proposalId;
          
          await contracts.securityGovernance.connect(signers.governance).signProposal(proposalId);
        }
      }
      
      // 4. Verify parameters were updated
      expect(await contracts.securityGovernance.getSecurityParameter("maxPriceChangeBPS")).to.equal(1500);
      expect(await contracts.securityGovernance.getSecurityParameter("circuitBreakerCooldown")).to.equal(3600);
      
      // 5. Check final governance statistics
      const finalStats = await contracts.securityGovernance.getGovernanceStats();
      expect(finalStats.executedProposalsCount).to.equal(2);
    });

    it("Should handle emergency governance procedures", async function () {
      const { contracts, signers, tokens } = await loadFixture(deployCompleteSystemFixture);
      
      // 1. Propose emergency transaction (pause security manager)
      const target = await contracts.coreSecurityManager.getAddress();
      const data = contracts.coreSecurityManager.interface.encodeFunctionData("pause", []);
      
      const emergencyTx = await contracts.securityGovernance
        .connect(signers.emergency)
        .proposeEmergencyTransaction(target, 0, data);
      
      const receipt = await emergencyTx.wait();
      
      // 2. Fast forward past emergency delay
      await TEST_HELPERS.fastForwardTime(TEST_CONSTANTS.ONE_DAY + 1);
      
      // 3. Execute emergency transaction
      const event = receipt.logs.find(log => {
        try {
          const parsed = contracts.securityGovernance.interface.parseLog(log);
          return parsed.name === "EmergencyTransactionProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = contracts.securityGovernance.interface.parseLog(event);
        const emergencyTxHash = parsed.args.txHash;
        
        await expect(
          contracts.securityGovernance.connect(signers.governance).executeEmergencyTransaction(emergencyTxHash)
        ).to.emit(contracts.securityGovernance, "EmergencyTransactionExecuted");
        
        // 4. Verify emergency action was executed (contract paused)
        expect(await contracts.coreSecurityManager.isPaused()).to.be.true;
      }
    });
  });

  describe("Oracle Integration", function () {
    it("Should handle oracle updates affecting entire system", async function () {
      const { contracts, signers } = await loadFixture(deployCompleteSystemFixture);
      
      // 1. Perform multiple oracle updates to build TWAP history
      for (let i = 0; i < 5; i++) {
        await TEST_HELPERS.fastForwardTime(TEST_CONSTANTS.MIN_ORACLE_UPDATE_INTERVAL + 1);
        await contracts.enhancedOracle.connect(signers.oracleUpdater).updateMarketCap();
      }
      
      // 2. Verify oracle health
      expect(await contracts.enhancedOracle.isHealthy()).to.be.true;
      
      // 3. Check observation count
      const observationCount = await contracts.enhancedOracle.getObservationCount();
      expect(observationCount).to.be.gte(5);
      
      // 4. Verify price is available
      const currentPrice = await contracts.enhancedOracle.getCurrentPrice();
      expect(currentPrice).to.be.gt(0);
      
      // 5. Check market cap limits
      await expect(contracts.enhancedOracle.checkMarketCapLimits()).to.not.be.reverted;
    });

    it("Should handle oracle emergency scenarios", async function () {
      const { contracts, signers } = await loadFixture(deployCompleteSystemFixture);
      
      // 1. Set fallback price
      const fallbackPrice = ethers.parseEther("1.5");
      await contracts.enhancedOracle.connect(signers.governance).setFallbackPrice(fallbackPrice);
      
      // 2. Enable emergency mode
      await contracts.enhancedOracle.connect(signers.governance).enableEmergencyMode();
      
      // 3. Verify fallback price is used
      const currentPrice = await contracts.enhancedOracle.getCurrentPrice();
      expect(currentPrice).to.equal(fallbackPrice);
      
      // 4. Verify oracle reports unhealthy
      expect(await contracts.enhancedOracle.isHealthy()).to.be.false;
      
      // 5. Recovery
      await contracts.enhancedOracle.connect(signers.governance).disableEmergencyMode();
      expect(await contracts.enhancedOracle.emergencyMode()).to.be.false;
    });
  });

  describe("Performance and Gas Optimization", function () {
    it("Should handle high-volume operations efficiently", async function () {
      const { contracts, signers } = await loadFixture(deployCompleteSystemFixture);
      
      // 1. Batch user deposit checks
      const users = [signers.user1, signers.user2, signers.user3];
      const depositAmount = TEST_CONSTANTS.SMALL_DEPOSIT;
      
      const results = [];
      for (const user of users) {
        const [canDeposit, reason] = await contracts.advancedSecurityManager.canUserDeposit(
          user.address,
          depositAmount
        );
        results.push({ user: user.address, canDeposit, reason });
      }
      
      // 2. Verify all users can deposit
      expect(results.every(r => r.canDeposit)).to.be.true;
      
      // 3. Batch risk score updates
      const userAddresses = users.map(u => u.address);
      const riskScores = [3000, 4000, 5000];
      
      const tx = await contracts.advancedSecurityManager
        .connect(signers.monitor)
        .batchUpdateRiskScores(userAddresses, riskScores);
      
      const receipt = await tx.wait();
      
      // 4. Verify gas usage is reasonable
      expect(receipt.gasUsed).to.be.lt(500000); // 500k gas limit for batch operation
      
      // 5. Verify all scores were updated
      for (let i = 0; i < users.length; i++) {
        const assessment = await contracts.advancedSecurityManager.getUserRiskAssessment(userAddresses[i]);
        expect(assessment.riskScore).to.equal(riskScores[i]);
      }
    });

    it("Should optimize repeated parameter reads", async function () {
      const { contracts } = await loadFixture(deployCompleteSystemFixture);
      
      // 1. Batch parameter read
      const [paramNames, paramValues] = await contracts.securityGovernance.getAllParameters();
      
      expect(paramNames.length).to.equal(10);
      expect(paramValues.length).to.equal(10);
      
      // 2. Verify specific parameters
      const maxPriceChangeIndex = paramNames.indexOf("maxPriceChangeBPS");
      expect(maxPriceChangeIndex).to.be.gte(0);
      expect(paramValues[maxPriceChangeIndex]).to.equal(TEST_CONSTANTS.MAX_PRICE_CHANGE_BPS);
      
      // 3. Individual reads should match batch reads
      for (let i = 0; i < 3; i++) {
        const individualValue = await contracts.securityGovernance.getSecurityParameter(paramNames[i]);
        expect(individualValue).to.equal(paramValues[i]);
      }
    });
  });

  describe("System State Validation", function () {
    it("Should maintain consistent state across all contracts", async function () {
      const { contracts, signers } = await loadFixture(deployCompleteSystemFixture);
      
      // 1. Capture initial system state
      const initialState = await TEST_HELPERS.validateSystemState(contracts);
      
      // 2. Perform various operations
      await contracts.advancedSecurityManager.advancedPreDepositCheck(
        signers.user1.address,
        TEST_CONSTANTS.SMALL_DEPOSIT
      );
      
      await TEST_HELPERS.fastForwardTime(TEST_CONSTANTS.MIN_ORACLE_UPDATE_INTERVAL + 1);
      await contracts.enhancedOracle.connect(signers.oracleUpdater).updateMarketCap();
      
      await contracts.securityGovernance
        .connect(signers.paramManager)
        .proposeParameterChange("testParam", 12345);
      
      // 3. Capture final system state
      const finalState = await TEST_HELPERS.validateSystemState(contracts);
      
      // 4. Verify state consistency
      expect(finalState.contracts.coreSecurityManager.isPaused).to.equal(
        initialState.contracts.coreSecurityManager.isPaused
      );
      
      expect(finalState.contracts.enhancedOracle.isHealthy).to.be.true;
      expect(finalState.contracts.enhancedOracle.observationCount).to.be.gt(
        initialState.contracts.enhancedOracle.observationCount
      );
      
      expect(finalState.contracts.securityGovernance.totalProposals).to.be.gt(
        initialState.contracts.securityGovernance.totalProposals
      );
    });

    it("Should handle system recovery after failures", async function () {
      const { contracts, signers } = await loadFixture(deployCompleteSystemFixture);
      
      // 1. Trigger multiple failures
      
      // Circuit breaker trigger
      await contracts.coreSecurityManager.checkCircuitBreaker(
        TEST_CONSTANTS.CIRCUIT_BREAKER_THRESHOLD + ethers.parseUnits("1000", 6)
      );
      
      // Emergency mode activation
      await contracts.advancedSecurityManager.connect(signers.emergency).activateEmergencyMode();
      await contracts.enhancedOracle.connect(signers.governance).enableEmergencyMode();
      
      // 2. Verify system is in failed state
      expect(await contracts.coreSecurityManager.getCircuitBreakerStatus()).to.have.property('triggered', true);
      expect(await contracts.advancedSecurityManager.emergencyModeActive()).to.be.true;
      expect(await contracts.enhancedOracle.emergencyMode()).to.be.true;
      
      // 3. Recovery sequence
      
      // Wait for circuit breaker cooldown
      await TEST_HELPERS.fastForwardTime(TEST_CONSTANTS.CIRCUIT_BREAKER_COOLDOWN + 1);
      
      // Disable emergency modes
      await contracts.enhancedOracle.connect(signers.governance).disableEmergencyMode();
      await contracts.advancedSecurityManager.connect(signers.governance).deactivateEmergencyMode();
      
      // 4. Verify full recovery
      const cbStatus = await contracts.coreSecurityManager.getCircuitBreakerStatus();
      expect(cbStatus.timeUntilReset).to.equal(0);
      
      expect(await contracts.advancedSecurityManager.emergencyModeActive()).to.be.false;
      expect(await contracts.enhancedOracle.emergencyMode()).to.be.false;
      expect(await contracts.coreSecurityManager.isPaused()).to.be.false;
      
      // 5. Verify normal operations restored
      const [canDeposit] = await contracts.advancedSecurityManager.canUserDeposit(
        signers.user1.address,
        TEST_CONSTANTS.SMALL_DEPOSIT
      );
      expect(canDeposit).to.be.true;
    });
  });

  describe("Stress Testing", function () {
    it("Should handle rapid successive operations", async function () {
      const { contracts, signers } = await loadFixture(deployCompleteSystemFixture);
      
      // 1. Rapid deposit eligibility checks
      const promises = [];
      for (let i = 0; i < 10; i++) {
        promises.push(
          contracts.advancedSecurityManager.canUserDeposit(
            signers.user1.address,
            TEST_CONSTANTS.SMALL_DEPOSIT
          )
        );
      }
      
      const results = await Promise.all(promises);
      
      // 2. All should succeed
      expect(results.every(([canDeposit]) => canDeposit)).to.be.true;
      
      // 3. Rapid parameter proposals (should all succeed individually)
      const proposalPromises = [];
      for (let i = 0; i < 5; i++) {
        proposalPromises.push(
          contracts.securityGovernance
            .connect(signers.paramManager)
            .proposeParameterChange(`param${i}`, 1000 + i)
        );
      }
      
      const proposalResults = await Promise.all(proposalPromises);
      expect(proposalResults.length).to.equal(5);
      
      // 4. Verify governance statistics
      const govStats = await contracts.securityGovernance.getGovernanceStats();
      expect(govStats.totalProposalsCount).to.be.gte(5);
    });

    it("Should handle edge case scenarios", async function () {
      const { contracts, signers } = await loadFixture(deployCompleteSystemFixture);
      
      // 1. Maximum deposit amount
      const maxDeposit = TEST_CONSTANTS.MEV_MAX_PER_USER;
      const [canDepositMax, reasonMax] = await contracts.advancedSecurityManager.canUserDeposit(
        signers.user1.address,
        maxDeposit
      );
      expect(canDepositMax).to.be.true;
      
      // 2. Just over maximum (should fail)
      const overMax = maxDeposit + ethers.parseUnits("1", 6);
      const [canDepositOver, reasonOver] = await contracts.advancedSecurityManager.canUserDeposit(
        signers.user1.address,
        overMax
      );
      expect(canDepositOver).to.be.false;
      
      // 3. Zero amount (should fail)
      const [canDepositZero, reasonZero] = await contracts.advancedSecurityManager.canUserDeposit(
        signers.user1.address,
        0
      );
      expect(canDepositZero).to.be.false;
      
      // 4. Maximum risk score
      await contracts.advancedSecurityManager
        .connect(signers.monitor)
        .updateUserRiskScore(signers.user2.address, 10000); // 100%
      
      const [canDepositMaxRisk] = await contracts.advancedSecurityManager.canUserDeposit(
        signers.user2.address,
        TEST_CONSTANTS.SMALL_DEPOSIT
      );
      expect(canDepositMaxRisk).to.be.false;
    });
  });

  describe("Documentation and Reporting", function () {
    it("Should provide comprehensive system status", async function () {
      const { contracts, signers } = await loadFixture(deployCompleteSystemFixture);
      
      // 1. Core Security Manager status
      const coreStats = await contracts.coreSecurityManager.getProtocolStatistics();
      const cbStatus = await contracts.coreSecurityManager.getCircuitBreakerStatus();
      const newTokenSettings = await contracts.coreSecurityManager.getNewTokenSettings();
      
      expect(coreStats.oracleHealthy).to.be.true;
      expect(cbStatus.triggered).to.be.false;
      expect(newTokenSettings.newTokenModeActive).to.be.true;
      
      // 2. Advanced Security Manager status
      const advancedSettings = await contracts.advancedSecurityManager.getAdvancedSettings();
      const dailyMetrics = await contracts.advancedSecurityManager.getDailyMetrics(
        Math.floor(Date.now() / (1000 * 60 * 60 * 24))
      );
      
      expect(advancedSettings.emergencyModeActiveSetting).to.be.false;
      expect(dailyMetrics.totalVolume).to.equal(0); // No deposits yet
      
      // 3. Oracle status
      const liquidityStatus = await contracts.enhancedOracle.getLiquidityStatus();
      const priceValidationData = await contracts.enhancedOracle.getPriceValidationData();
      
      expect(liquidityStatus.isHealthy).to.be.true;
      expect(priceValidationData.priceImpactThreshold).to.be.gt(0);
      
      // 4. Governance status
      const govStats = await contracts.securityGovernance.getGovernanceStats();
      
      expect(govStats.requiredSignaturesCount).to.equal(2);
      expect(govStats.totalProposalsCount).to.be.gte(0);
    });

    it("Should generate system health report", async function () {
      const { contracts } = await loadFixture(deployCompleteSystemFixture);
      
      // Generate comprehensive system state
      const systemState = await TEST_HELPERS.validateSystemState(contracts);
      
      // Create mock test results
      const testResults = [
        { name: "Deposit Check", passed: true, gasUsed: 50000 },
        { name: "Oracle Update", passed: true, gasUsed: 80000 },
        { name: "Governance Proposal", passed: true, gasUsed: 120000 },
        { name: "Emergency Response", passed: true, gasUsed: 150000 }
      ];
      
      // Generate report
      const report = TEST_HELPERS.generateTestReport(testResults, systemState);
      
      expect(report.summary.totalTests).to.equal(4);
      expect(report.summary.passed).to.equal(4);
      expect(report.summary.failed).to.equal(0);
      expect(report.systemState).to.not.be.undefined;
      expect(report.recommendations).to.be.an('array');
    });
  });
});