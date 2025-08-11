// test/fixtures/test-data.js
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

/**
 * @title Test Data and Helpers
 * @notice Centralized test data and utility functions for consistent testing
 * @dev Provides reusable test constants, mock data, and helper functions
 */

// Test Constants
const TEST_CONSTANTS = {
  // Token amounts
  USDT_DECIMALS: 6,
  QORAFI_DECIMALS: 18,
  WETH_DECIMALS: 18,
  
  // Common amounts
  SMALL_DEPOSIT: ethers.parseUnits("100", 6),      // 100 USDT
  MEDIUM_DEPOSIT: ethers.parseUnits("1000", 6),    // 1,000 USDT
  LARGE_DEPOSIT: ethers.parseUnits("10000", 6),    // 10,000 USDT
  HUGE_DEPOSIT: ethers.parseUnits("100000", 6),    // 100,000 USDT
  
  // Security thresholds
  MEV_MIN_INTERVAL: 5,                             // 5 blocks
  MEV_MAX_PER_BLOCK: ethers.parseUnits("50000", 6), // 50k USDT
  MEV_MAX_PER_USER: ethers.parseUnits("25000", 6),  // 25k USDT
  
  CIRCUIT_BREAKER_THRESHOLD: ethers.parseUnits("100000", 6), // 100k USDT
  CIRCUIT_BREAKER_COOLDOWN: 2 * 60 * 60,          // 2 hours
  CIRCUIT_BREAKER_WINDOW: 1 * 60 * 60,            // 1 hour
  
  // Oracle settings
  MAX_PRICE_CHANGE_BPS: 2000,                     // 20%
  MAX_MARKET_CAP_GROWTH_BPS: 3000,                // 30%
  MIN_ORACLE_UPDATE_INTERVAL: 5 * 60,             // 5 minutes
  
  // Risk management
  HIGH_RISK_THRESHOLD: 8000,                      // 80%
  SUSPICIOUS_ACTIVITY_WINDOW: 1 * 60 * 60,        // 1 hour
  MAX_TRANSACTIONS_PER_WINDOW: 10,
  
  // Time constants
  ONE_HOUR: 60 * 60,
  ONE_DAY: 24 * 60 * 60,
  ONE_WEEK: 7 * 24 * 60 * 60,
  
  // Gas prices
  LOW_GAS_PRICE: ethers.parseUnits("5", "gwei"),
  NORMAL_GAS_PRICE: ethers.parseUnits("20", "gwei"),
  HIGH_GAS_PRICE: ethers.parseUnits("100", "gwei"),
  
  // Market cap limits
  MIN_MARKET_CAP: ethers.parseEther("100000"),    // 100k USD
  MAX_MARKET_CAP: ethers.parseEther("10000000"),  // 10M USD
};

// Test Data Sets
const TEST_DATA = {
  // Valid deposit scenarios
  validDeposits: [
    {
      name: "Small deposit",
      amount: TEST_CONSTANTS.SMALL_DEPOSIT,
      user: "user1",
      shouldPass: true
    },
    {
      name: "Medium deposit",
      amount: TEST_CONSTANTS.MEDIUM_DEPOSIT,
      user: "user1",
      shouldPass: true
    },
    {
      name: "Large deposit",
      amount: TEST_CONSTANTS.LARGE_DEPOSIT,
      user: "user2",
      shouldPass: true
    }
  ],
  
  // Invalid deposit scenarios
  invalidDeposits: [
    {
      name: "Exceeds daily limit",
      amount: ethers.parseUnits("30000", 6), // Exceeds 25k limit
      user: "user1",
      expectedError: "DailyLimitExceeded"
    },
    {
      name: "Exceeds block limit",
      amount: ethers.parseUnits("60000", 6), // Exceeds 50k block limit
      user: "user1",
      expectedError: "BlockDepositLimitExceeded"
    },
    {
      name: "Zero amount",
      amount: 0,
      user: "user1",
      expectedError: "InvalidAmount"
    }
  ],
  
  // Risk score test cases
  riskScores: [
    { score: 1000, description: "Low risk", shouldAllowDeposit: true },
    { score: 5000, description: "Medium risk", shouldAllowDeposit: true },
    { score: 7500, description: "High risk", shouldAllowDeposit: true },
    { score: 8500, description: "Very high risk", shouldAllowDeposit: false },
    { score: 9500, description: "Extreme risk", shouldAllowDeposit: false }
  ],
  
  // Price change scenarios for oracle testing
  priceChanges: [
    { change: 0.05, description: "5% increase", shouldPass: true },
    { change: 0.15, description: "15% increase", shouldPass: true },
    { change: 0.25, description: "25% increase", shouldPass: false },
    { change: -0.10, description: "10% decrease", shouldPass: true },
    { change: -0.30, description: "30% decrease", shouldPass: false }
  ],
  
  // Governance proposal scenarios
  governanceProposals: [
    {
      paramName: "maxPriceChangeBPS",
      oldValue: 2000,
      newValue: 1500,
      description: "Reduce max price change"
    },
    {
      paramName: "circuitBreakerCooldown",
      oldValue: 7200, // 2 hours
      newValue: 3600, // 1 hour
      description: "Reduce circuit breaker cooldown"
    },
    {
      paramName: "highRiskThreshold",
      oldValue: 8000,
      newValue: 7000,
      description: "Lower high risk threshold"
    }
  ],
  
  // Emergency transaction scenarios
  emergencyTransactions: [
    {
      description: "Pause security manager",
      target: "coreSecurityManager",
      functionName: "pause",
      args: [],
      value: 0
    },
    {
      description: "Update oracle fallback price",
      target: "enhancedOracle",
      functionName: "setFallbackPrice",
      args: [ethers.parseEther("1.5")],
      value: 0
    },
    {
      description: "Emergency token transfer",
      target: "usdt",
      functionName: "transfer",
      args: ["treasury", ethers.parseUnits("10000", 6)],
      value: 0
    }
  ]
};

// Test Helpers
const TEST_HELPERS = {
  /**
   * @notice Fast forward blockchain time
   * @param seconds Number of seconds to advance
   */
  async fastForwardTime(seconds) {
    await time.increase(seconds);
  },
  
  /**
   * @notice Fast forward to specific timestamp
   * @param timestamp Target timestamp
   */
  async fastForwardToTime(timestamp) {
    await time.increaseTo(timestamp);
  },
  
  /**
   * @notice Mine specific number of blocks
   * @param blocks Number of blocks to mine
   */
  async mineBlocks(blocks) {
    for (let i = 0; i < blocks; i++) {
      await ethers.provider.send("evm_mine");
    }
  },
  
  /**
   * @notice Get current block timestamp
   */
  async getCurrentTime() {
    const block = await ethers.provider.getBlock("latest");
    return block.timestamp;
  },
  
  /**
   * @notice Calculate percentage change
   * @param oldValue Original value
   * @param newValue New value
   * @return Percentage change in basis points
   */
  calculatePercentageChange(oldValue, newValue) {
    if (oldValue === 0n) return 0n;
    const diff = newValue > oldValue ? newValue - oldValue : oldValue - newValue;
    return (diff * 10000n) / oldValue;
  },
  
  /**
   * @notice Apply percentage change to value
   * @param value Original value
   * @param percentageBPS Percentage in basis points
   * @param increase Whether to increase or decrease
   */
  applyPercentageChange(value, percentageBPS, increase = true) {
    const change = (value * percentageBPS) / 10000n;
    return increase ? value + change : value - change;
  },
  
  /**
   * @notice Generate random address
   */
  randomAddress() {
    return ethers.Wallet.createRandom().address;
  },
  
  /**
   * @notice Generate random amount within range
   * @param min Minimum value
   * @param max Maximum value
   * @param decimals Token decimals
   */
  randomAmount(min, max, decimals = 6) {
    const range = max - min;
    const random = Math.floor(Math.random() * Number(range)) + Number(min);
    return ethers.parseUnits(random.toString(), decimals);
  },
  
  /**
   * @notice Create mock proposal ID
   */
  createMockProposalId(paramName, value, timestamp) {
    return ethers.id(`${paramName}-${value}-${timestamp}`);
  },
  
  /**
   * @notice Simulate user behavior for testing
   * @param contracts Contract instances
   * @param user User signer
   * @param depositCount Number of deposits to simulate
   */
  async simulateUserBehavior(contracts, user, depositCount = 5) {
    const deposits = [];
    
    for (let i = 0; i < depositCount; i++) {
      const amount = this.randomAmount(100, 5000, 6); // 100-5000 USDT
      
      try {
        // Check if deposit is allowed
        const [canDeposit, reason] = await contracts.coreSecurityManager.canUserDeposit(
          user.address, 
          amount
        );
        
        deposits.push({
          amount,
          canDeposit,
          reason,
          timestamp: await this.getCurrentTime()
        });
        
        // Wait between deposits to avoid MEV protection
        if (i < depositCount - 1) {
          await this.fastForwardTime(301); // 5+ minutes
        }
        
      } catch (error) {
        deposits.push({
          amount,
          canDeposit: false,
          reason: error.message,
          timestamp: await this.getCurrentTime()
        });
      }
    }
    
    return deposits;
  },
  
  /**
   * @notice Simulate oracle price updates
   * @param oracle Oracle contract
   * @param priceChanges Array of price change percentages
   * @param oracleUpdater Signer with oracle updater role
   */
  async simulateOraclePriceUpdates(oracle, priceChanges, oracleUpdater) {
    const updates = [];
    
    for (const change of priceChanges) {
      try {
        // Wait for minimum update interval
        await this.fastForwardTime(TEST_CONSTANTS.MIN_ORACLE_UPDATE_INTERVAL + 1);
        
        // Update market cap (this would trigger price calculation)
        const tx = await oracle.connect(oracleUpdater).updateMarketCap();
        const receipt = await tx.wait();
        
        updates.push({
          change,
          success: true,
          gasUsed: receipt.gasUsed,
          timestamp: await this.getCurrentTime()
        });
        
      } catch (error) {
        updates.push({
          change,
          success: false,
          error: error.message,
          timestamp: await this.getCurrentTime()
        });
      }
    }
    
    return updates;
  },
  
  /**
   * @notice Create test emergency transaction data
   * @param targetContract Target contract address
   * @param functionName Function to call
   * @param args Function arguments
   * @param value ETH value to send
   */
  createEmergencyTransactionData(targetContract, functionName, args = [], value = 0) {
    const iface = new ethers.Interface([
      `function ${functionName}(${args.map((_, i) => `uint256`).join(',')})`
    ]);
    const data = iface.encodeFunctionData(functionName, args);
    
    return {
      target: targetContract,
      value,
      data
    };
  },
  
  /**
   * @notice Simulate governance proposal flow
   * @param governance Governance contract
   * @param proposers Array of proposer signers
   * @param paramName Parameter name
   * @param newValue New parameter value
   */
  async simulateGovernanceProposal(governance, proposers, paramName, newValue) {
    // Propose parameter change
    const proposalTx = await governance.connect(proposers[0]).proposeParameterChange(paramName, newValue);
    const receipt = await proposalTx.wait();
    
    // Extract proposal ID from events
    const event = receipt.logs.find(log => {
      try {
        const parsed = governance.interface.parseLog(log);
        return parsed.name === "ParameterChangeProposed";
      } catch {
        return false;
      }
    });
    
    if (!event) throw new Error("Proposal event not found");
    
    const parsed = governance.interface.parseLog(event);
    const proposalId = parsed.args.proposalId;
    
    // Collect signatures from other proposers
    const signatures = [];
    for (let i = 1; i < proposers.length; i++) {
      try {
        const signTx = await governance.connect(proposers[i]).signProposal(proposalId);
        const signReceipt = await signTx.wait();
        signatures.push({
          signer: proposers[i].address,
          gasUsed: signReceipt.gasUsed,
          success: true
        });
      } catch (error) {
        signatures.push({
          signer: proposers[i].address,
          success: false,
          error: error.message
        });
      }
    }
    
    // Check final proposal state
    const finalProposal = await governance.getProposal(proposalId);
    
    return {
      proposalId,
      proposalTx: receipt,
      signatures,
      finalState: {
        executed: finalProposal.executed,
        cancelled: finalProposal.cancelled,
        signatures: finalProposal.signatures,
        validUntil: finalProposal.validUntil
      }
    };
  },
  
  /**
   * @notice Batch create test users with different risk profiles
   * @param count Number of users to create
   */
  async createTestUsers(count = 5) {
    const users = [];
    
    for (let i = 0; i < count; i++) {
      const wallet = ethers.Wallet.createRandom();
      const riskScore = Math.floor(Math.random() * 10000); // 0-100%
      const depositHistory = Math.floor(Math.random() * 50); // 0-49 previous deposits
      
      users.push({
        wallet,
        address: wallet.address,
        riskScore,
        depositHistory,
        profile: this.getRiskProfile(riskScore)
      });
    }
    
    return users;
  },
  
  /**
   * @notice Get risk profile description
   * @param riskScore Risk score (0-10000)
   */
  getRiskProfile(riskScore) {
    if (riskScore < 2000) return "Low Risk";
    if (riskScore < 5000) return "Medium Risk";
    if (riskScore < 8000) return "High Risk";
    return "Very High Risk";
  },
  
  /**
   * @notice Create stress test scenarios
   */
  createStressTestScenarios() {
    return {
      // High volume scenario
      highVolume: {
        name: "High Volume Stress Test",
        userCount: 100,
        depositsPerUser: 10,
        timeWindow: TEST_CONSTANTS.ONE_HOUR,
        expectedBehavior: "Circuit breaker should trigger"
      },
      
      // Flash loan attack simulation
      flashLoanAttack: {
        name: "Flash Loan Attack Simulation",
        updateCount: 10,
        timeWindow: 3, // 3 blocks
        priceChanges: [0.5, -0.3, 0.4, -0.6], // Volatile changes
        expectedBehavior: "Flash loan protection should trigger"
      },
      
      // MEV attack simulation
      mevAttack: {
        name: "MEV Attack Simulation",
        userCount: 5,
        depositsPerBlock: 20,
        blockCount: 10,
        expectedBehavior: "MEV protection should trigger"
      },
      
      // Governance attack simulation
      governanceAttack: {
        name: "Governance Attack Simulation",
        proposalCount: 50,
        timeWindow: TEST_CONSTANTS.ONE_HOUR,
        maliciousParams: [
          { name: "maxPriceChangeBPS", value: 10000 }, // 100% - dangerous
          { name: "circuitBreakerCooldown", value: 0 }, // No cooldown - dangerous
        ],
        expectedBehavior: "Proposal validation should prevent execution"
      }
    };
  },
  
  /**
   * @notice Validate contract state consistency
   * @param contracts Object containing all contract instances
   */
  async validateSystemState(contracts) {
    const state = {
      timestamp: await this.getCurrentTime(),
      blockNumber: await ethers.provider.getBlockNumber(),
      contracts: {}
    };
    
    // Core Security Manager state
    if (contracts.coreSecurityManager) {
      const cbStatus = await contracts.coreSecurityManager.getCircuitBreakerStatus();
      const protocolStats = await contracts.coreSecurityManager.getProtocolStatistics();
      
      state.contracts.coreSecurityManager = {
        isPaused: await contracts.coreSecurityManager.isPaused(),
        circuitBreakerTriggered: cbStatus.triggered,
        totalDeposits: protocolStats.totalDeposits,
        newTokenMode: (await contracts.coreSecurityManager.getNewTokenSettings()).newTokenModeActive
      };
    }
    
    // Advanced Security Manager state
    if (contracts.advancedSecurityManager) {
      const advancedSettings = await contracts.advancedSecurityManager.getAdvancedSettings();
      
      state.contracts.advancedSecurityManager = {
        emergencyModeActive: advancedSettings.emergencyModeActiveSetting,
        highRiskThreshold: advancedSettings.highRiskThresholdSetting
      };
    }
    
    // Enhanced Oracle state
    if (contracts.enhancedOracle) {
      state.contracts.enhancedOracle = {
        isHealthy: await contracts.enhancedOracle.isHealthy(),
        emergencyMode: await contracts.enhancedOracle.emergencyMode(),
        observationCount: await contracts.enhancedOracle.getObservationCount(),
        currentPrice: await contracts.enhancedOracle.getCurrentPrice()
      };
    }
    
    // Security Governance state
    if (contracts.securityGovernance) {
      const govStats = await contracts.securityGovernance.getGovernanceStats();
      
      state.contracts.securityGovernance = {
        totalProposals: govStats.totalProposalsCount,
        executedProposals: govStats.executedProposalsCount,
        requiredSignatures: govStats.requiredSignaturesCount
      };
    }
    
    return state;
  },
  
  /**
   * @notice Create comprehensive test report
   * @param testResults Array of test results
   * @param systemState System state snapshot
   */
  generateTestReport(testResults, systemState) {
    const report = {
      timestamp: new Date().toISOString(),
      summary: {
        totalTests: testResults.length,
        passed: testResults.filter(r => r.passed).length,
        failed: testResults.filter(r => r.failed).length,
        skipped: testResults.filter(r => r.skipped).length
      },
      systemState,
      detailedResults: testResults,
      recommendations: []
    };
    
    // Add recommendations based on results
    if (report.summary.failed > 0) {
      report.recommendations.push("Review failed tests and update implementation");
    }
    
    if (systemState.contracts.coreSecurityManager?.circuitBreakerTriggered) {
      report.recommendations.push("Circuit breaker was triggered - review volume thresholds");
    }
    
    if (!systemState.contracts.enhancedOracle?.isHealthy) {
      report.recommendations.push("Oracle is unhealthy - check price feeds and liquidity");
    }
    
    return report;
  }
};

// Mock Data Generators
const MOCK_DATA = {
  /**
   * @notice Generate mock user deposit data
   */
  generateUserDepositData(userCount = 10, depositsPerUser = 5) {
    const users = [];
    
    for (let i = 0; i < userCount; i++) {
      const user = {
        address: TEST_HELPERS.randomAddress(),
        deposits: []
      };
      
      for (let j = 0; j < depositsPerUser; j++) {
        user.deposits.push({
          amount: TEST_HELPERS.randomAmount(100, 10000, 6),
          timestamp: Date.now() - (Math.random() * TEST_CONSTANTS.ONE_WEEK * 1000),
          success: Math.random() > 0.1 // 90% success rate
        });
      }
      
      users.push(user);
    }
    
    return users;
  },
  
  /**
   * @notice Generate mock oracle price data
   */
  generateOraclePriceData(dataPoints = 100) {
    const prices = [];
    let currentPrice = 1.0; // Start at $1
    
    for (let i = 0; i < dataPoints; i++) {
      // Random walk with some volatility
      const change = (Math.random() - 0.5) * 0.1; // ±5% max change
      currentPrice = Math.max(0.1, currentPrice * (1 + change));
      
      prices.push({
        price: ethers.parseEther(currentPrice.toFixed(6)),
        timestamp: Date.now() - ((dataPoints - i) * 5 * 60 * 1000), // 5 min intervals
        blockNumber: 1000000 + i,
        valid: Math.random() > 0.05 // 95% valid observations
      });
    }
    
    return prices;
  },
  
  /**
   * @notice Generate mock governance proposal data
   */
  generateGovernanceProposalData(proposalCount = 20) {
    const proposals = [];
    const paramNames = [
      "maxPriceChangeBPS",
      "maxMarketCapGrowthBPS", 
      "circuitBreakerCooldown",
      "mevMinInterval",
      "highRiskThreshold"
    ];
    
    for (let i = 0; i < proposalCount; i++) {
      proposals.push({
        id: TEST_HELPERS.createMockProposalId(
          paramNames[i % paramNames.length],
          Math.floor(Math.random() * 10000),
          Date.now()
        ),
        paramName: paramNames[i % paramNames.length],
        proposedValue: Math.floor(Math.random() * 10000),
        proposer: TEST_HELPERS.randomAddress(),
        signatures: Math.floor(Math.random() * 5),
        status: ["pending", "executed", "cancelled"][Math.floor(Math.random() * 3)],
        createdAt: Date.now() - (Math.random() * TEST_CONSTANTS.ONE_WEEK * 1000)
      });
    }
    
    return proposals;
  }
};

// Export all test utilities
module.exports = {
  TEST_CONSTANTS,
  TEST_DATA,
  TEST_HELPERS,
  MOCK_DATA
};