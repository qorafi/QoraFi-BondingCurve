// scripts/setup-roles-manual.js
const { ethers } = require("hardhat");

async function main() {
  console.log("👥 Manual Role Setup for AdvancedSecurityManager...\n");

  const contractAddress = "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9";
  const [deployer, governance, emergency, monitor] = await ethers.getSigners();

  console.log("Contract Address:", contractAddress);
  console.log("Deployer:", deployer.address);
  console.log("Governance:", governance.address);
  console.log("Emergency:", emergency.address);
  console.log("Monitor:", monitor.address);

  try {
    // Connect to the contract
    const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager");
    const securityManager = AdvancedSecurityManager.attach(contractAddress);

    console.log("\n🔍 Checking role constants...");

    // Method 1: Try to get role constants directly
    try {
      const DEFAULT_ADMIN_ROLE = await securityManager.DEFAULT_ADMIN_ROLE();
      console.log("✅ DEFAULT_ADMIN_ROLE:", DEFAULT_ADMIN_ROLE);

      // Try different role access methods
      let GOVERNANCE_ROLE;
      try {
        GOVERNANCE_ROLE = await securityManager.GOVERNANCE_ROLE();
        console.log("✅ GOVERNANCE_ROLE:", GOVERNANCE_ROLE);
      } catch (govError) {
        // If GOVERNANCE_ROLE doesn't exist, use DEFAULT_ADMIN_ROLE
        console.log("⚠️ GOVERNANCE_ROLE not found, using DEFAULT_ADMIN_ROLE");
        GOVERNANCE_ROLE = DEFAULT_ADMIN_ROLE;
      }

      let EMERGENCY_ROLE;
      try {
        EMERGENCY_ROLE = await securityManager.EMERGENCY_ROLE();
        console.log("✅ EMERGENCY_ROLE:", EMERGENCY_ROLE);
      } catch (emergError) {
        // Calculate standard role hash
        EMERGENCY_ROLE = ethers.keccak256(ethers.toUtf8Bytes("EMERGENCY_ROLE"));
        console.log("⚠️ EMERGENCY_ROLE not found, using calculated hash:", EMERGENCY_ROLE);
      }

      let MONITOR_ROLE;
      try {
        MONITOR_ROLE = await securityManager.MONITOR_ROLE();
        console.log("✅ MONITOR_ROLE:", MONITOR_ROLE);
      } catch (monError) {
        // Calculate standard role hash
        MONITOR_ROLE = ethers.keccak256(ethers.toUtf8Bytes("MONITOR_ROLE"));
        console.log("⚠️ MONITOR_ROLE not found, using calculated hash:", MONITOR_ROLE);
      }

      console.log("\n👥 Granting roles...");

      // Grant roles
      try {
        if (GOVERNANCE_ROLE !== DEFAULT_ADMIN_ROLE) {
          let tx = await securityManager.grantRole(GOVERNANCE_ROLE, governance.address);
          await tx.wait();
          console.log("✅ Governance role granted to:", governance.address);
        } else {
          console.log("ℹ️ Governance uses admin role, already has access");
        }

        let tx = await securityManager.grantRole(EMERGENCY_ROLE, emergency.address);
        await tx.wait();
        console.log("✅ Emergency role granted to:", emergency.address);

        tx = await securityManager.grantRole(MONITOR_ROLE, monitor.address);
        await tx.wait();
        console.log("✅ Monitor role granted to:", monitor.address);

        console.log("\n🎉 Role setup completed successfully!");

      } catch (grantError) {
        console.log("❌ Role granting failed:", grantError.message);
        
        // Try alternative approach - grant admin role to other accounts
        console.log("\n🔄 Trying alternative approach...");
        try {
          let tx = await securityManager.grantRole(DEFAULT_ADMIN_ROLE, governance.address);
          await tx.wait();
          console.log("✅ Admin role granted to governance account");

          tx = await securityManager.grantRole(DEFAULT_ADMIN_ROLE, emergency.address);
          await tx.wait();
          console.log("✅ Admin role granted to emergency account");

          tx = await securityManager.grantRole(DEFAULT_ADMIN_ROLE, monitor.address);
          await tx.wait();
          console.log("✅ Admin role granted to monitor account");

          console.log("🎉 Alternative role setup completed!");

        } catch (altError) {
          console.log("❌ Alternative approach failed:", altError.message);
        }
      }

    } catch (roleError) {
      console.log("❌ Could not access role constants:", roleError.message);
      console.log("💡 This might indicate the contract doesn't inherit from AccessControl properly");
    }

    // Verify current contract state
    console.log("\n🔍 Verifying contract configuration...");
    
    try {
      // Check if we can call basic functions
      const emergencyMode = await securityManager.emergencyMode();
      const emergencyDelay = await securityManager.emergencyTransactionDelay();
      
      console.log("✅ Emergency mode:", emergencyMode);
      console.log("✅ Emergency delay:", emergencyDelay.toString(), "seconds");

      // Check risk config
      const riskConfig = await securityManager.getRiskConfig();
      console.log("✅ High risk threshold:", riskConfig.highRiskThreshold.toString());
      console.log("✅ Suspicious activity window:", riskConfig.suspiciousActivityWindow.toString());

      console.log("\n🎉 Contract is properly configured and accessible!");

    } catch (verifyError) {
      console.log("❌ Contract verification failed:", verifyError.message);
    }

  } catch (error) {
    console.error("❌ Setup failed:", error.message);
    console.log("\n🔍 Troubleshooting tips:");
    console.log("1. Make sure the contract address is correct");
    console.log("2. Ensure the contract is deployed on the current network");
    console.log("3. Check if the contract has the expected functions");
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });