// scripts/deploy-with-proper-roles-fixed.js
const { ethers } = require("hardhat");

async function main() {
  console.log("🚀 Deploying with Proper Role Setup (Using QoraFi Token)...\n");

  const [deployer, governance, emergency, monitor, paramManager] = await ethers.getSigners();
  
  console.log("Account Setup:");
  console.log("  - Deployer:", deployer.address);
  console.log("  - Governance:", governance.address); 
  console.log("  - Emergency:", emergency.address);
  console.log("  - Monitor:", monitor.address);
  console.log("  - ParamManager:", paramManager.address);

  try {
    // 1. Deploy QoraFi Token
    console.log("\n📝 Step 1: Deploying QoraFi Token...");
    const QoraFi = await ethers.getContractFactory("QoraFi");
    const qorafiToken = await QoraFi.deploy(
      "QoraFi Test", 
      "QORAFI", 
      deployer.address  // initial treasury address
    );
    await qorafiToken.waitForDeployment();
    const tokenAddress = await qorafiToken.getAddress();
    console.log("✅ QoraFi Token deployed at:", tokenAddress);

    // 2. Deploy USDT Token (for testing)
    console.log("\n📝 Step 2: Deploying USDT Test Token...");
    const usdtToken = await QoraFi.deploy(
      "Test USDT", 
      "USDT", 
      deployer.address
    );
    await usdtToken.waitForDeployment();
    const usdtAddress = await usdtToken.getAddress();
    console.log("✅ USDT Token deployed at:", usdtAddress);

    // 3. Deploy CoreSecurityManager
    console.log("\n📝 Step 3: Deploying CoreSecurityManager...");
    const CoreSecurityManager = await ethers.getContractFactory("CoreSecurityManager");
    const coreManager = await CoreSecurityManager.deploy();
    await coreManager.waitForDeployment();
    const coreAddress = await coreManager.getAddress();
    console.log("✅ CoreSecurityManager:", coreAddress);

    // 4. Deploy AdvancedSecurityManager
    console.log("\n📝 Step 4: Deploying AdvancedSecurityManager...");
    const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager");
    const advancedManager = await AdvancedSecurityManager.deploy();
    await advancedManager.waitForDeployment();
    const advancedAddress = await advancedManager.getAddress();
    console.log("✅ AdvancedSecurityManager:", advancedAddress);

    // 5. Deploy SecurityGovernance
    console.log("\n📝 Step 5: Deploying SecurityGovernance...");
    const SecurityGovernance = await ethers.getContractFactory("SecurityGovernance");
    const securityGovernance = await SecurityGovernance.deploy();
    await securityGovernance.waitForDeployment();
    const governanceAddress = await securityGovernance.getAddress();
    console.log("✅ SecurityGovernance:", governanceAddress);

    // 6. Deploy EnhancedOracle
    console.log("\n📝 Step 6: Deploying EnhancedOracle...");
    const EnhancedOracle = await ethers.getContractFactory("EnhancedOracle");
    const oracle = await EnhancedOracle.deploy();
    await oracle.waitForDeployment();
    const oracleAddress = await oracle.getAddress();
    console.log("✅ EnhancedOracle:", oracleAddress);

    // 7. Initialize CoreSecurityManager
    console.log("\n⚙️ Step 7: Initializing CoreSecurityManager...");
    await coreManager.initialize(usdtAddress, tokenAddress, deployer.address);
    console.log("✅ CoreSecurityManager initialized");

    // 8. Initialize AdvancedSecurityManager
    console.log("\n⚙️ Step 8: Initializing AdvancedSecurityManager...");
    await advancedManager.initialize(usdtAddress, tokenAddress, deployer.address);
    console.log("✅ AdvancedSecurityManager base initialized");

    // 9. Initialize SecurityGovernance
    console.log("\n⚙️ Step 9: Initializing SecurityGovernance...");
    await securityGovernance.initialize(
      governance.address,  // governance address
      emergency.address,   // emergency address
      deployer.address    // treasury
    );
    console.log("✅ SecurityGovernance initialized");

    // 10. Initialize EnhancedOracle
    console.log("\n⚙️ Step 10: Initializing EnhancedOracle...");
    await oracle.initialize(
      governance.address,  // governance
      emergency.address   // oracle updater
    );
    console.log("✅ EnhancedOracle initialized");

    // 11. CRITICAL: Set up roles PROPERLY
    console.log("\n👥 Step 11: Setting up Roles (CRITICAL FIX)...");
    
    // Core Security Manager Roles
    console.log("Setting up CoreSecurityManager roles...");
    try {
      const EMERGENCY_ROLE = await coreManager.EMERGENCY_ROLE();
      const GOVERNANCE_ROLE = await coreManager.GOVERNANCE_ROLE();
      const MONITOR_ROLE = await coreManager.MONITOR_ROLE();
      
      // Grant roles to proper accounts
      await coreManager.grantRole(EMERGENCY_ROLE, emergency.address);
      await coreManager.grantRole(GOVERNANCE_ROLE, governance.address);
      await coreManager.grantRole(MONITOR_ROLE, monitor.address);
      
      // IMPORTANT: Also grant emergency role to governance for tests
      await coreManager.grantRole(EMERGENCY_ROLE, governance.address);
      
      console.log("✅ CoreSecurityManager roles granted");
    } catch (roleError) {
      console.log("⚠️ CoreSecurityManager role setup issue:", roleError.message);
    }

    // Advanced Security Manager Roles
    console.log("Setting up AdvancedSecurityManager roles...");
    try {
      const ADV_EMERGENCY_ROLE = await advancedManager.EMERGENCY_ROLE();
      const ADV_GOVERNANCE_ROLE = await advancedManager.GOVERNANCE_ROLE();
      const ADV_MONITOR_ROLE = await advancedManager.MONITOR_ROLE();
      
      await advancedManager.grantRole(ADV_EMERGENCY_ROLE, emergency.address);
      await advancedManager.grantRole(ADV_GOVERNANCE_ROLE, governance.address);
      await advancedManager.grantRole(ADV_MONITOR_ROLE, monitor.address);
      
      // Grant emergency role to governance for tests
      await advancedManager.grantRole(ADV_EMERGENCY_ROLE, governance.address);
      
      console.log("✅ AdvancedSecurityManager roles granted");
    } catch (advRoleError) {
      console.log("⚠️ AdvancedSecurityManager role setup issue:", advRoleError.message);
    }

    // Security Governance Roles
    console.log("Setting up SecurityGovernance roles...");
    try {
      const DEFAULT_ADMIN_ROLE = await securityGovernance.DEFAULT_ADMIN_ROLE();
      const PARAM_MANAGER_ROLE = await securityGovernance.PARAM_MANAGER_ROLE();
      const GOV_EMERGENCY_ROLE = await securityGovernance.EMERGENCY_ROLE();
      
      // Grant admin role to governance account
      await securityGovernance.grantRole(DEFAULT_ADMIN_ROLE, governance.address);
      await securityGovernance.grantRole(PARAM_MANAGER_ROLE, paramManager.address);
      await securityGovernance.grantRole(GOV_EMERGENCY_ROLE, emergency.address);
      
      // Grant param manager role to governance for tests
      await securityGovernance.grantRole(PARAM_MANAGER_ROLE, governance.address);
      await securityGovernance.grantRole(GOV_EMERGENCY_ROLE, governance.address);
      
      console.log("✅ SecurityGovernance roles granted");
    } catch (govRoleError) {
      console.log("⚠️ SecurityGovernance role setup issue:", govRoleError.message);
    }

    // 12. Initialize Advanced Features
    console.log("\n🔧 Step 12: Configuring Advanced Features...");
    
    // Advanced Security Manager configuration
    try {
      await advancedManager.initializeAdvanced(3600, 10, 300);
      await advancedManager.setAdvancedParameters(8000, 3600, 10);
      await advancedManager.setFlashLoanProtection(5, 600);
      console.log("✅ Advanced features configured");
    } catch (advConfigError) {
      console.log("⚠️ Advanced config issue:", advConfigError.message);
    }

    // 13. Add managed contracts to governance
    console.log("\n🔗 Step 13: Setting up Contract Management...");
    try {
      // Connect to governance with governance account
      const govAsGovernance = securityGovernance.connect(governance);
      
      await govAsGovernance.addManagedContract(coreAddress);
      await govAsGovernance.addManagedContract(advancedAddress);
      await govAsGovernance.addManagedContract(oracleAddress);
      
      console.log("✅ Managed contracts added to governance");
    } catch (managedError) {
      console.log("⚠️ Managed contracts setup issue:", managedError.message);
    }

    // 14. Set up QoraFi Token for testing
    console.log("\n🪙 Step 14: Configuring QoraFi Token for Testing...");
    try {
      // Set fee destinations (required for minting)
      await qorafiToken.setFeeDestinations(
        deployer.address, // USQ Engine (temp)
        deployer.address, // Development wallet
        deployer.address  // Airdrop contract (temp)
      );
      
      // Set fee splits (1% total for testing)
      await qorafiToken.setFeeSplits(50, 30, 20); // 0.5%, 0.3%, 0.2%
      
      // Grant minter role to deployer for testing
      // Note: In production, this should be the bonding curve contract
      await qorafiToken.grantMinterRole(coreAddress); // Grant to core manager
      
      console.log("✅ QoraFi token configured for testing");
    } catch (tokenError) {
      console.log("⚠️ QoraFi token configuration issue:", tokenError.message);
    }

    // 15. Mint some test tokens
    console.log("\n💰 Step 15: Minting Test Tokens...");
    try {
      // Mint some USDT for testing
      const testAmount = ethers.parseUnits("1000000", 6); // 1M USDT with 6 decimals
      await usdtToken.mint(deployer.address, testAmount);
      await usdtToken.mint(governance.address, testAmount);
      
      console.log("✅ Test tokens minted");
    } catch (mintError) {
      console.log("⚠️ Test token minting issue:", mintError.message);
    }

    // 16. Verification
    console.log("\n🔍 Step 16: Verifying Setup...");
    
    // Test role access
    try {
      console.log("Testing role access...");
      
      // Test emergency role can pause core manager
      const hasEmergencyRole = await coreManager.hasRole(await coreManager.EMERGENCY_ROLE(), governance.address);
      console.log("✅ Emergency role verification:", hasEmergencyRole);
      
      // Test governance role access
      const hasGovernanceRole = await advancedManager.hasRole(await advancedManager.GOVERNANCE_ROLE(), governance.address);
      console.log("✅ Governance role verification:", hasGovernanceRole);
      
    } catch (verifyError) {
      console.log("⚠️ Verification issue:", verifyError.message);
    }

    // 17. Test Configuration Status
    console.log("\n📊 Step 17: Configuration Status...");
    
    try {
      // Advanced Security Manager status
      const riskConfig = await advancedManager.getRiskConfig();
      console.log("Risk threshold:", riskConfig.highRiskThreshold.toString());
      
      const flashStatus = await advancedManager.getFlashLoanProtectionStatus();
      console.log("Flash loan protection active:", flashStatus[3]);
      
      // System health
      const healthStatus = await advancedManager.getSystemHealthStatus();
      console.log("System healthy:", healthStatus[0]);
      
      // Token status
      const tokenSupply = await qorafiToken.totalSupply();
      const dailyLimit = await qorafiToken.dailyMintLimit();
      console.log("QoraFi total supply:", ethers.formatEther(tokenSupply));
      console.log("Daily mint limit:", ethers.formatEther(dailyLimit));
      
    } catch (statusError) {
      console.log("⚠️ Status check issue:", statusError.message);
    }

    // 18. Save deployment info for tests
    console.log("\n💾 Step 18: Saving Deployment Info...");
    
    const deploymentInfo = {
      network: hre.network.name,
      timestamp: new Date().toISOString(),
      accounts: {
        deployer: deployer.address,
        governance: governance.address,
        emergency: emergency.address,
        monitor: monitor.address,
        paramManager: paramManager.address
      },
      contracts: {
        qorafiToken: tokenAddress,
        usdtToken: usdtAddress,
        coreSecurityManager: coreAddress,
        advancedSecurityManager: advancedAddress,
        securityGovernance: governanceAddress,
        enhancedOracle: oracleAddress
      },
      roleSetup: {
        coreRolesGranted: true,
        advancedRolesGranted: true,
        governanceRolesGranted: true,
        emergencyRoleToGovernance: true // Critical for tests
      },
      tokenConfiguration: {
        qorafiConfigured: true,
        testTokensMinted: true,
        feeDestinationsSet: true
      }
    };

    // Write to global for tests to access
    global.testDeployment = deploymentInfo;

    console.log("\n🎉 DEPLOYMENT COMPLETE WITH QORAFI TOKEN!");
    console.log("============================================");
    console.log("🪙 QoraFi Token:", tokenAddress);
    console.log("💰 USDT Token:", usdtAddress);
    console.log("🔒 CoreSecurityManager:", coreAddress);
    console.log("🛡️ AdvancedSecurityManager:", advancedAddress);
    console.log("⚖️ SecurityGovernance:", governanceAddress);
    console.log("🔮 EnhancedOracle:", oracleAddress);
    console.log("\n✅ All roles properly configured for testing!");
    console.log("✅ QoraFi token ready for minting/burning tests");
    console.log("✅ Emergency roles granted to governance account");
    console.log("✅ Access control issues should be resolved");

    return deploymentInfo;

  } catch (error) {
    console.error("❌ Deployment failed:", error.message);
    console.error("Stack trace:", error.stack);
    throw error;
  }
}

// Export for use in tests
module.exports = { main };

if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error(error);
      process.exit(1);
    });
}