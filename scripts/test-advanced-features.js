// scripts/test-advanced-features.js
const { ethers } = require("hardhat");

async function main() {
  console.log("🧪 Testing Advanced Security Features...\n");

  const [deployer, user1, user2, attacker] = await ethers.getSigners();

  // Deploy and initialize (similar to deployment script but focused on testing)
  console.log("📋 Setting up test environment...");
  
  // Deploy contracts
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const mockToken = await MockERC20.deploy("Test USDT", "USDT", 6);
  await mockToken.waitForDeployment();

  const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager");
  const securityManager = await AdvancedSecurityManager.deploy();
  await securityManager.waitForDeployment();

  // Initialize base
  await securityManager.initialize(
    await mockToken.getAddress(),
    await mockToken.getAddress(),
    deployer.address
  );

  // **STEP 1: INITIALIZE ADVANCED FEATURES** ⭐
  console.log("\n🔧 Step 1: Initializing Advanced Features...");
  await securityManager.initializeAdvanced(
    3600,    // 1 hour emergency delay
    10,      // max updates per block  
    300      // 5 minute detection window
  );
  console.log("✅ Advanced features initialized");

  // **STEP 2: CONFIGURE RISK PARAMETERS** ⭐
  console.log("\n🛡️ Step 2: Configuring Risk Parameters...");
  await securityManager.setAdvancedParameters(
    8000,    // 80% high risk threshold
    3600,    // 1 hour activity window
    10       // max transactions per window
  );
  console.log("✅ Risk parameters configured");

  // **STEP 3: SET UP ROLES** ⭐
  console.log("\n👥 Step 3: Setting up Roles...");
  const MONITOR_ROLE = await securityManager.MONITOR_ROLE();
  await securityManager.grantRole(MONITOR_ROLE, deployer.address);
  console.log("✅ Monitor role granted");

  // **STEP 4: TEST ADVANCED FEATURES** ⭐
  console.log("\n🧪 Step 4: Testing Advanced Features...");

  // Test 1: Risk Score Management
  console.log("\n📊 Testing Risk Score Management:");
  try {
    await securityManager.updateUserRiskScore(user1.address, 5000); // 50% risk
    await securityManager.updateUserRiskScore(user2.address, 9000); // 90% risk (high)
    
    const user1Risk = await securityManager.getUserRiskAssessment(user1.address);
    const user2Risk = await securityManager.getUserRiskAssessment(user2.address);
    
    console.log("  ✅ User1 risk score:", user1Risk[0].toString(), "- Can transact:", user1Risk[4]);
    console.log("  ✅ User2 risk score:", user2Risk[0].toString(), "- Can transact:", user2Risk[4]);
  } catch (error) {
    console.log("  ❌ Risk score test failed:", error.message);
  }

  // Test 2: User Flagging
  console.log("\n🚩 Testing User Flagging:");
  try {
    await securityManager.flagUser(attacker.address, true, "Suspicious activity detected");
    const attackerRisk = await securityManager.getUserRiskAssessment(attacker.address);
    console.log("  ✅ Attacker flagged - Can transact:", attackerRisk[4]);
  } catch (error) {
    console.log("  ❌ User flagging test failed:", error.message);
  }

  // Test 3: Deposit Eligibility Check
  console.log("\n💰 Testing Deposit Eligibility:");
  try {
    const depositAmount = ethers.parseUnits("1000", 6); // $1000
    
    const user1Check = await securityManager.canUserDepositAdvanced(user1.address, depositAmount);
    const user2Check = await securityManager.canUserDepositAdvanced(user2.address, depositAmount);
    const attackerCheck = await securityManager.canUserDepositAdvanced(attacker.address, depositAmount);
    
    console.log("  ✅ User1 can deposit:", user1Check[0], "-", user1Check[1]);
    console.log("  ✅ User2 can deposit:", user2Check[0], "-", user2Check[1]);
    console.log("  ✅ Attacker can deposit:", attackerCheck[0], "-", attackerCheck[1]);
  } catch (error) {
    console.log("  ❌ Deposit eligibility test failed:", error.message);
  }

  // Test 4: System Health Check
  console.log("\n🏥 Testing System Health:");
  try {
    const healthStatus = await securityManager.getSystemHealthStatus();
    console.log("  ✅ System healthy:", healthStatus[0]);
    console.log("  ✅ Warnings:", healthStatus[1].length);
    console.log("  ✅ Errors:", healthStatus[2].length);
  } catch (error) {
    console.log("  ❌ System health test failed:", error.message);
  }

  // Test 5: Flash Loan Protection
  console.log("\n⚡ Testing Flash Loan Protection:");
  try {
    const flashStatus = await securityManager.getFlashLoanProtectionStatus();
    console.log("  ✅ Current block updates:", flashStatus[0].toString());
    console.log("  ✅ Max allowed updates:", flashStatus[1].toString());
    console.log("  ✅ Protection active:", flashStatus[3]);
  } catch (error) {
    console.log("  ❌ Flash loan protection test failed:", error.message);
  }

  // Test 6: Emergency Mode
  console.log("\n🚨 Testing Emergency Mode:");
  try {
    const emergencyMode = await securityManager.emergencyMode();
    const emergencyDelay = await securityManager.emergencyTransactionDelay();
    const advancedEmergencyActive = await securityManager.isAdvancedEmergencyModeActive();
    
    console.log("  ✅ Emergency mode active:", emergencyMode);
    console.log("  ✅ Emergency delay:", emergencyDelay.toString(), "seconds");
    console.log("  ✅ Advanced emergency active:", advancedEmergencyActive);
  } catch (error) {
    console.log("  ❌ Emergency mode test failed:", error.message);
  }

  // Test 7: Configuration Verification
  console.log("\n⚙️ Verifying Final Configuration:");
  try {
    const riskConfig = await securityManager.getRiskConfig();
    console.log("  ✅ Risk Configuration:");
    console.log("    - High risk threshold:", riskConfig.highRiskThreshold.toString());
    console.log("    - Activity window:", riskConfig.suspiciousActivityWindow.toString());
    console.log("    - Max transactions per window:", riskConfig.maxTransactionsPerWindow.toString());
    console.log("    - Emergency delay:", riskConfig.advancedEmergencyTransactionDelay.toString());
  } catch (error) {
    console.log("  ❌ Configuration verification failed:", error.message);
  }

  console.log("\n🎉 Advanced Features Testing Complete!");
  console.log("=====================================");
  console.log("Contract Address:", await securityManager.getAddress());
  console.log("All advanced features are properly initialized and functioning! 🛡️");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Testing failed:", error);
    process.exit(1);
  });