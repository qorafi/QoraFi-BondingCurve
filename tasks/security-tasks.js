// tasks/security-tasks.js
const { task } = require("hardhat/config");

// Task to initialize advanced security features
task("init-advanced", "Initialize advanced security features")
  .addParam("contract", "AdvancedSecurityManager contract address")
  .addOptionalParam("delay", "Emergency transaction delay in seconds", "3600")
  .addOptionalParam("maxupdates", "Max updates per block", "10")
  .addOptionalParam("window", "Flash loan detection window in seconds", "300")
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    
    console.log("🔧 Initializing Advanced Security Features...");
    console.log("Contract:", taskArgs.contract);
    
    const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager");
    const securityManager = AdvancedSecurityManager.attach(taskArgs.contract);
    
    try {
      const tx = await securityManager.initializeAdvanced(
        parseInt(taskArgs.delay),
        parseInt(taskArgs.maxupdates),
        parseInt(taskArgs.window)
      );
      await tx.wait();
      
      console.log("✅ Advanced features initialized successfully!");
      console.log("  - Emergency delay:", taskArgs.delay, "seconds");
      console.log("  - Max updates per block:", taskArgs.maxupdates);
      console.log("  - Detection window:", taskArgs.window, "seconds");
      console.log("  - Transaction hash:", tx.hash);
      
    } catch (error) {
      console.error("❌ Initialization failed:", error.message);
      if (error.message.includes("revert")) {
        console.log("💡 Tip: Contract may already be initialized or you may not have the correct role");
      }
    }
  });

// Task to configure risk parameters
task("config-risk", "Configure risk management parameters")
  .addParam("contract", "AdvancedSecurityManager contract address")
  .addOptionalParam("threshold", "High risk threshold (0-10000)", "8000")
  .addOptionalParam("window", "Suspicious activity window in seconds", "3600")
  .addOptionalParam("maxtx", "Max transactions per window", "10")
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    
    console.log("🛡️ Configuring Risk Parameters...");
    console.log("Contract:", taskArgs.contract);
    
    const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager");
    const securityManager = AdvancedSecurityManager.attach(taskArgs.contract);
    
    try {
      const tx = await securityManager.setAdvancedParameters(
        parseInt(taskArgs.threshold),
        parseInt(taskArgs.window),
        parseInt(taskArgs.maxtx)
      );
      await tx.wait();
      
      console.log("✅ Risk parameters configured successfully!");
      console.log("  - High risk threshold:", taskArgs.threshold, "(80% = 8000)");
      console.log("  - Activity window:", taskArgs.window, "seconds");
      console.log("  - Max transactions per window:", taskArgs.maxtx);
      console.log("  - Transaction hash:", tx.hash);
      
    } catch (error) {
      console.error("❌ Risk configuration failed:", error.message);
    }
  });

// Task to set up roles
task("setup-roles", "Set up security roles")
  .addParam("contract", "AdvancedSecurityManager contract address")
  .addOptionalParam("governance", "Governance address")
  .addOptionalParam("emergency", "Emergency address")
  .addOptionalParam("monitor", "Monitor address")
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    
    console.log("👥 Setting up Security Roles...");
    console.log("Contract:", taskArgs.contract);
    
    const [deployer, defaultGovernance, defaultEmergency, defaultMonitor] = await ethers.getSigners();
    
    // Use provided addresses or default to signers
    const governanceAddr = taskArgs.governance || defaultGovernance.address;
    const emergencyAddr = taskArgs.emergency || defaultEmergency.address;
    const monitorAddr = taskArgs.monitor || defaultMonitor.address;
    
    console.log("Governance address:", governanceAddr);
    console.log("Emergency address:", emergencyAddr);
    console.log("Monitor address:", monitorAddr);
    
    const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager");
    const securityManager = AdvancedSecurityManager.attach(taskArgs.contract);
    
    try {
      const GOVERNANCE_ROLE = await securityManager.GOVERNANCE_ROLE();
      const EMERGENCY_ROLE = await securityManager.EMERGENCY_ROLE();
      const MONITOR_ROLE = await securityManager.MONITOR_ROLE();

      // Grant governance role
      let tx = await securityManager.grantRole(GOVERNANCE_ROLE, governanceAddr);
      await tx.wait();
      console.log("✅ Governance role granted to:", governanceAddr);

      // Grant emergency role
      tx = await securityManager.grantRole(EMERGENCY_ROLE, emergencyAddr);
      await tx.wait();
      console.log("✅ Emergency role granted to:", emergencyAddr);

      // Grant monitor role
      tx = await securityManager.grantRole(MONITOR_ROLE, monitorAddr);
      await tx.wait();
      console.log("✅ Monitor role granted to:", monitorAddr);

      console.log("\n🎉 All roles configured successfully!");
      
    } catch (error) {
      console.error("❌ Role setup failed:", error.message);
    }
  });

// Task to check contract status
task("check-status", "Check contract configuration status")
  .addParam("contract", "AdvancedSecurityManager contract address")
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    
    console.log("🔍 Checking Contract Status...");
    console.log("Contract:", taskArgs.contract);
    
    const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager");
    const securityManager = AdvancedSecurityManager.attach(taskArgs.contract);
    
    try {
      // Check if contract is initialized
      console.log("\n📋 Basic Contract Info:");
      const emergencyDelay = await securityManager.emergencyTransactionDelay();
      const emergencyMode = await securityManager.emergencyMode();
      const newTokenMode = await securityManager.newTokenMode();
      
      console.log("  - Emergency delay:", emergencyDelay.toString(), "seconds");
      console.log("  - Emergency mode active:", emergencyMode);
      console.log("  - New token mode:", newTokenMode);
      
      // Check risk configuration
      const riskConfig = await securityManager.getRiskConfig();
      console.log("\n📊 Risk Configuration:");
      console.log("  - High risk threshold:", riskConfig.highRiskThreshold.toString());
      console.log("  - Activity window:", riskConfig.suspiciousActivityWindow.toString(), "seconds");
      console.log("  - Max transactions per window:", riskConfig.maxTransactionsPerWindow.toString());

      // Check flash loan protection
      const flashStatus = await securityManager.getFlashLoanProtectionStatus();
      console.log("\n⚡ Flash Loan Protection:");
      console.log("  - Current block updates:", flashStatus[0].toString());
      console.log("  - Max updates per block:", flashStatus[1].toString());
      console.log("  - Detection window:", flashStatus[2].toString(), "seconds");
      console.log("  - Protection active:", flashStatus[3]);

      // Check system health
      const healthStatus = await securityManager.getSystemHealthStatus();
      console.log("\n🏥 System Health:");
      console.log("  - System healthy:", healthStatus[0]);
      console.log("  - Warnings count:", healthStatus[1].length);
      console.log("  - Errors count:", healthStatus[2].length);
      
      if (healthStatus[1].length > 0) {
        console.log("  - Warnings:", healthStatus[1]);
      }
      if (healthStatus[2].length > 0) {
        console.log("  - Errors:", healthStatus[2]);
      }

      // Determine initialization status
      console.log("\n🔧 Initialization Status:");
      const isAdvancedInit = emergencyDelay.toString() !== "0";
      const isRiskConfigured = riskConfig.highRiskThreshold.toString() !== "0";
      
      console.log("  - Advanced features initialized:", isAdvancedInit);
      console.log("  - Risk parameters configured:", isRiskConfigured);
      
      if (!isAdvancedInit) {
        console.log("\n💡 To initialize: npx hardhat init-advanced --contract", taskArgs.contract);
      }
      if (!isRiskConfigured) {
        console.log("💡 To configure risk: npx hardhat config-risk --contract", taskArgs.contract);
      }

      console.log("\n✅ Status check complete!");
      
    } catch (error) {
      console.error("❌ Status check failed:", error.message);
      console.log("💡 Make sure the contract address is correct and the contract is deployed");
    }
  });

// Comprehensive initialization task
task("full-init", "Complete initialization of AdvancedSecurityManager")
  .addParam("contract", "AdvancedSecurityManager contract address")
  .setAction(async (taskArgs, hre) => {
    const { ethers } = hre;
    
    console.log("🚀 Complete AdvancedSecurityManager Initialization...\n");
    console.log("Contract:", taskArgs.contract);
    
    const [deployer, governance, emergency, monitor] = await ethers.getSigners();
    
    console.log("Using accounts:");
    console.log("  - Deployer:", deployer.address);
    console.log("  - Governance:", governance.address);
    console.log("  - Emergency:", emergency.address);
    console.log("  - Monitor:", monitor.address);
    
    const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager");
    const securityManager = AdvancedSecurityManager.attach(taskArgs.contract);
    
    try {
      // Step 1: Initialize advanced features
      console.log("\n🔧 Step 1: Initializing advanced features...");
      let tx = await securityManager.initializeAdvanced(3600, 10, 300);
      await tx.wait();
      console.log("✅ Advanced features initialized");

      // Step 2: Configure risk parameters
      console.log("\n🛡️ Step 2: Configuring risk parameters...");
      tx = await securityManager.setAdvancedParameters(8000, 3600, 10);
      await tx.wait();
      console.log("✅ Risk parameters configured");

      // Step 3: Set up roles
      console.log("\n👥 Step 3: Setting up roles...");
      const GOVERNANCE_ROLE = await securityManager.GOVERNANCE_ROLE();
      const EMERGENCY_ROLE = await securityManager.EMERGENCY_ROLE();
      const MONITOR_ROLE = await securityManager.MONITOR_ROLE();

      tx = await securityManager.grantRole(GOVERNANCE_ROLE, governance.address);
      await tx.wait();
      
      tx = await securityManager.grantRole(EMERGENCY_ROLE, emergency.address);
      await tx.wait();
      
      tx = await securityManager.grantRole(MONITOR_ROLE, monitor.address);
      await tx.wait();
      console.log("✅ All roles granted");

      // Step 4: Configure flash loan protection
      console.log("\n⚡ Step 4: Configuring flash loan protection...");
      tx = await securityManager.setFlashLoanProtection(5, 600);
      await tx.wait();
      console.log("✅ Flash loan protection configured");

      console.log("\n🎉 Complete initialization successful!");
      console.log("Contract is now fully configured and ready for production use! 🛡️");
      
      // Show final status
      console.log("\n📊 Final Configuration Summary:");
      const riskConfig = await securityManager.getRiskConfig();
      console.log("  - Emergency delay:", riskConfig.advancedEmergencyTransactionDelay.toString(), "seconds");
      console.log("  - High risk threshold:", riskConfig.highRiskThreshold.toString());
      console.log("  - Max transactions per window:", riskConfig.maxTransactionsPerWindow.toString());
      
    } catch (error) {
      console.error("❌ Full initialization failed:", error.message);
      console.log("\n🔍 Use 'npx hardhat check-status --contract", taskArgs.contract, "' to diagnose issues");
    }
  });

// Task to update your deployed contract with your specific address
task("quick-setup", "Quick setup for your deployed contract")
  .setAction(async (taskArgs, hre) => {
    const contractAddress = "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9"; // Your deployed address
    
    console.log("🚀 Quick Setup for Your Deployed Contract");
    console.log("==========================================");
    console.log("Contract Address:", contractAddress);
    
    // Run full initialization
    await hre.run("full-init", { contract: contractAddress });
  });

module.exports = {};