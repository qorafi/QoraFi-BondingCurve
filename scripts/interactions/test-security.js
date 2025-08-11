// scripts/interactions/test-security.js
const { ethers, network } = require("hardhat");
const ContractAddresses = require("../utils/contract-addresses");

async function main() {
  console.log("🧪 Testing security features on", network.name);
  
  const [deployer, user1, user2] = await ethers.getSigners();
  const addresses = new ContractAddresses(network.name);
  
  const coreSecurityManager = await ethers.getContractAt(
    "CoreSecurityManager", 
    addresses.get("CoreSecurityManager")
  );
  
  const advancedSecurityManager = addresses.exists("AdvancedSecurityManager") 
    ? await ethers.getContractAt("AdvancedSecurityManager", addresses.get("AdvancedSecurityManager"))
    : null;

  console.log("\n🧪 Testing MEV Protection...");
  
  // Test user deposit eligibility
  const depositAmount = ethers.parseUnits("1000", 6); // 1000 USDT
  
  try {
    const [canDeposit, reason] = await coreSecurityManager.canUserDeposit(user1.address, depositAmount);
    console.log(`User1 can deposit: ${canDeposit}, Reason: ${reason}`);
  } catch (error) {
    console.log("❌ Deposit check failed:", error.message);
  }
  
  // Test MEV status
  try {
    const mevStatus = await coreSecurityManager.getUserMEVStatus(user1.address);
    console.log("MEV Status for User1:");
    console.log("  Last Block:", mevStatus.lastBlock.toString());
    console.log("  Blocks Since Last Deposit:", mevStatus.blocksSince.toString());
    console.log("  Can Deposit Now:", mevStatus.canDeposit);
    console.log("  Daily Volume Used:", ethers.formatUnits(mevStatus.dailyUsed, 6), "USDT");
    console.log("  Daily Volume Remaining:", ethers.formatUnits(mevStatus.dailyRemaining, 6), "USDT");
  } catch (error) {
    console.log("❌ MEV status check failed:", error.message);
  }

  console.log("\n🧪 Testing Circuit Breaker...");
  
  try {
    const cbStatus = await coreSecurityManager.getCircuitBreakerStatus();
    console.log("Circuit Breaker Status:");
    console.log("  Triggered:", cbStatus.triggered);
    console.log("  Current Volume:", ethers.formatUnits(cbStatus.currentVolume, 6), "USDT");
    console.log("  Volume Threshold:", ethers.formatUnits(cbStatus.volumeThreshold, 6), "USDT");
    console.log("  Trigger Count:", cbStatus.triggerCount.toString());
    console.log("  Time Until Reset:", cbStatus.timeUntilReset.toString(), "seconds");
    console.log("  Currently Updating:", cbStatus.updating);
  } catch (error) {
    console.log("❌ Circuit breaker status check failed:", error.message);
  }

  if (advancedSecurityManager) {
    console.log("\n🧪 Testing Advanced Security Features...");
    
    try {
      const riskAssessment = await advancedSecurityManager.getUserRiskAssessment(user1.address);
      console.log("Risk Assessment for User1:");
      console.log("  Risk Score:", riskAssessment.riskScore.toString());
      console.log("  Flagged:", riskAssessment.flagged);
      console.log("  Avg Transaction Size:", ethers.formatUnits(riskAssessment.avgTransactionSize, 6), "USDT");
      console.log("  Suspicious Activity Count:", riskAssessment.suspiciousActivityCount.toString());
      console.log("  Can Transact:", riskAssessment.canTransact);
    } catch (error) {
      console.log("❌ Risk assessment failed:", error.message);
    }
    
    try {
      const advancedSettings = await advancedSecurityManager.getAdvancedSettings();
      console.log("Advanced Settings:");
      console.log("  High Risk Threshold:", advancedSettings.highRiskThresholdSetting.toString());
      console.log("  Suspicious Activity Window:", advancedSettings.suspiciousActivityWindowSetting.toString(), "seconds");
      console.log("  Max Transactions Per Window:", advancedSettings.maxTransactionsPerWindowSetting.toString());
      console.log("  Emergency Mode Active:", advancedSettings.emergencyModeActiveSetting);
    } catch (error) {
      console.log("❌ Advanced settings check failed:", error.message);
    }
  }

  console.log("\n🧪 Testing Protocol Statistics...");
  
  try {
    const protocolStats = await coreSecurityManager.getProtocolStatistics();
    console.log("Protocol Statistics:");
    console.log("  Total Deposits:", ethers.formatUnits(protocolStats.totalDeposits, 6), "USDT");
    console.log("  Current Price:", protocolStats.currentPrice.toString());
    console.log("  Market Cap:", protocolStats.marketCap.toString());
    console.log("  Oracle Healthy:", protocolStats.oracleHealthy);
  } catch (error) {
    console.log("❌ Protocol stats check failed:", error.message);
  }

  console.log("\n✅ Security testing completed!");
}

if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error("❌ Testing failed:", error);
      process.exit(1);
    });
}

module.exports = main;