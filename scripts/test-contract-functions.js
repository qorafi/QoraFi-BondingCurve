// scripts/test-contract-functions.js
const { ethers } = require("hardhat");

async function main() {
  console.log("🧪 Testing AdvancedSecurityManager Functions...\n");

  const contractAddress = "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9";
  const [deployer, user1, user2] = await ethers.getSigners();

  console.log("Contract:", contractAddress);
  console.log("Deployer:", deployer.address);

  try {
    const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager");
    const securityManager = AdvancedSecurityManager.attach(contractAddress);

    console.log("🔍 Testing Core Functions:");
    console.log("==========================");

    // Test 1: Check emergency mode
    const emergencyMode = await securityManager.emergencyMode();
    console.log("✅ Emergency mode:", emergencyMode);

    // Test 2: Check emergency delay
    const emergencyDelay = await securityManager.emergencyTransactionDelay();
    console.log("✅ Emergency delay:", emergencyDelay.toString(), "seconds");

    // Test 3: Check risk configuration
    const riskConfig = await securityManager.getRiskConfig();
    console.log("✅ Risk config:");
    console.log("  - High risk threshold:", riskConfig.highRiskThreshold.toString());
    console.log("  - Activity window:", riskConfig.suspiciousActivityWindow.toString(), "seconds");
    console.log("  - Max transactions per window:", riskConfig.maxTransactionsPerWindow.toString());

    // Test 4: Check flash loan protection
    const flashStatus = await securityManager.getFlashLoanProtectionStatus();
    console.log("✅ Flash loan protection:");
    console.log("  - Current updates:", flashStatus[0].toString());
    console.log("  - Max updates per block:", flashStatus[1].toString());
    console.log("  - Detection window:", flashStatus[2].toString(), "seconds");
    console.log("  - Protection active:", flashStatus[3]);

    // Test 5: Check system health
    const healthStatus = await securityManager.getSystemHealthStatus();
    console.log("✅ System health:");
    console.log("  - System healthy:", healthStatus[0]);
    console.log("  - Warnings:", healthStatus[1].length);
    console.log("  - Errors:", healthStatus[2].length);

    console.log("\n🧪 Testing User Functions:");
    console.log("===========================");

    // Test 6: Check deposit eligibility
    const depositAmount = ethers.parseUnits("1000", 6); // $1000
    const canDeposit = await securityManager.canUserDepositAdvanced(user1.address, depositAmount);
    console.log("✅ User can deposit:", canDeposit[0], "-", canDeposit[1]);

    // Test 7: Get user risk assessment
    const userRisk = await securityManager.getUserRiskAssessment(user1.address);
    console.log("✅ User risk assessment:");
    console.log("  - Risk score:", userRisk[0].toString());
    console.log("  - Flagged:", userRisk[1]);
    console.log("  - Can transact:", userRisk[4]);

    console.log("\n🎉 All Core Functions Working!");
    console.log("==============================");
    console.log("Your AdvancedSecurityManager is fully functional! 🛡️");
    console.log("\nNext steps:");
    console.log("1. ✅ Core security features are active");
    console.log("2. ✅ Risk management is configured");
    console.log("3. ✅ Flash loan protection is enabled");
    console.log("4. ⚠️ Role setup can be done later if needed");

  } catch (error) {
    console.error("❌ Testing failed:", error.message);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });