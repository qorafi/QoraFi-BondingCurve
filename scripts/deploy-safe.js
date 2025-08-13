// scripts/deploy-safe.js
const { ethers } = require("hardhat");

async function main() {
  console.log("🚀 Safe Deployment with Error Handling...\n");

  const [deployer, governance, emergency, monitor, paramManager] = await ethers.getSigners();
  
  console.log("Account Setup:");
  console.log("  - Deployer:", deployer.address);
  console.log("  - Governance:", governance.address); 
  console.log("  - Emergency:", emergency.address);
  console.log("  - Monitor:", monitor.address);
  console.log("  - ParamManager:", paramManager.address);

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
    contracts: {},
    errors: []
  };

  try {
    // 1. Deploy QoraFi Token
    console.log("\n📝 Step 1: Deploying QoraFi Token...");
    try {
      const QoraFi = await ethers.getContractFactory("QoraFi");
      const qorafiToken = await QoraFi.deploy(
        "QoraFi Test", 
        "QORAFI", 
        deployer.address
      );
      await qorafiToken.waitForDeployment();
      const tokenAddress = await qorafiToken.getAddress();
      deploymentInfo.contracts.qorafiToken = tokenAddress;
      console.log("✅ QoraFi Token:", tokenAddress);
    } catch (tokenError) {
      console.log("❌ QoraFi deployment failed:", tokenError.message);
      deploymentInfo.errors.push(`QoraFi: ${tokenError.message}`);
      throw tokenError; // Can't continue without tokens
    }

    // 2. Deploy USDT Token
    console.log("\n📝 Step 2: Deploying USDT Test Token...");
    try {
      const QoraFi = await ethers.getContractFactory("QoraFi");
      const usdtToken = await QoraFi.deploy(
        "Test USDT", 
        "USDT", 
        deployer.address
      );
      await usdtToken.waitForDeployment();
      const usdtAddress = await usdtToken.getAddress();
      deploymentInfo.contracts.usdtToken = usdtAddress;
      console.log("✅ USDT Token:", usdtAddress);
    } catch (usdtError) {
      console.log("❌ USDT deployment failed:", usdtError.message);
      deploymentInfo.errors.push(`USDT: ${usdtError.message}`);
      throw usdtError;
    }

    // 3. Deploy CoreSecurityManager
    console.log("\n📝 Step 3: Deploying CoreSecurityManager...");
    try {
      const CoreSecurityManager = await ethers.getContractFactory("CoreSecurityManager");
      const coreManager = await CoreSecurityManager.deploy();
      await coreManager.waitForDeployment();
      const coreAddress = await coreManager.getAddress();
      deploymentInfo.contracts.coreSecurityManager = coreAddress;
      console.log("✅ CoreSecurityManager:", coreAddress);
    } catch (coreError) {
      console.log("❌ CoreSecurityManager deployment failed:", coreError.message);
      deploymentInfo.errors.push(`CoreSecurityManager: ${coreError.message}`);
      throw coreError;
    }

    // 4. Deploy AdvancedSecurityManager
    console.log("\n📝 Step 4: Deploying AdvancedSecurityManager...");
    try {
      const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager");
      const advancedManager = await AdvancedSecurityManager.deploy();
      await advancedManager.waitForDeployment();
      const advancedAddress = await advancedManager.getAddress();
      deploymentInfo.contracts.advancedSecurityManager = advancedAddress;
      console.log("✅ AdvancedSecurityManager:", advancedAddress);
    } catch (advancedError) {
      console.log("❌ AdvancedSecurityManager deployment failed:", advancedError.message);
      deploymentInfo.errors.push(`AdvancedSecurityManager: ${advancedError.message}`);
      // Continue without advanced features
    }

    // 5. Deploy SecurityGovernance
    console.log("\n📝 Step 5: Deploying SecurityGovernance...");
    try {
      const SecurityGovernance = await ethers.getContractFactory("SecurityGovernance");
      const securityGovernance = await SecurityGovernance.deploy();
      await securityGovernance.waitForDeployment();
      const governanceAddress = await securityGovernance.getAddress();
      deploymentInfo.contracts.securityGovernance = governanceAddress;
      console.log("✅ SecurityGovernance:", governanceAddress);
    } catch (govError) {
      console.log("❌ SecurityGovernance deployment failed:", govError.message);
      deploymentInfo.errors.push(`SecurityGovernance: ${govError.message}`);
      // Continue without governance
    }

    // 6. Deploy EnhancedOracle
    console.log("\n📝 Step 6: Deploying EnhancedOracle...");
    try {
      const EnhancedOracle = await ethers.getContractFactory("EnhancedOracle");
      const oracle = await EnhancedOracle.deploy();
      await oracle.waitForDeployment();
      const oracleAddress = await oracle.getAddress();
      deploymentInfo.contracts.enhancedOracle = oracleAddress;
      console.log("✅ EnhancedOracle:", oracleAddress);
    } catch (oracleError) {
      console.log("❌ EnhancedOracle deployment failed:", oracleError.message);
      deploymentInfo.errors.push(`EnhancedOracle: ${oracleError.message}`);
      // Continue without oracle
    }

    // 7. Initialize CoreSecurityManager SAFELY
    console.log("\n⚙️ Step 7: Initializing CoreSecurityManager...");
    if (deploymentInfo.contracts.coreSecurityManager) {
      try {
        const CoreSecurityManager = await ethers.getContractFactory("CoreSecurityManager");
        const coreManager = CoreSecurityManager.attach(deploymentInfo.contracts.coreSecurityManager);
        
        // Check if already initialized
        try {
          const currentTreasury = await coreManager.treasuryWallet();
          if (currentTreasury !== ethers.ZeroAddress) {
            console.log("ℹ️ CoreSecurityManager already initialized, treasury:", currentTreasury);
          } else {
            throw new Error("Not initialized");
          }
        } catch {
          // Not initialized, proceed with initialization
          await coreManager.initialize(
            deploymentInfo.contracts.usdtToken,
            deploymentInfo.contracts.qorafiToken,
            deployer.address
          );
          console.log("✅ CoreSecurityManager initialized");
        }
      } catch (coreInitError) {
        console.log("❌ CoreSecurityManager initialization failed:", coreInitError.message);
        deploymentInfo.errors.push(`CoreSecurityManager init: ${coreInitError.message}`);
        
        // Try to diagnose the issue
        console.log("🔍 Diagnosing initialization issue...");
        try {
          const CoreSecurityManager = await ethers.getContractFactory("CoreSecurityManager");
          const coreManager = CoreSecurityManager.attach(deploymentInfo.contracts.coreSecurityManager);
          
          // Check contract state
          const bytecode = await ethers.provider.getCode(deploymentInfo.contracts.coreSecurityManager);
          console.log("Contract bytecode length:", bytecode.length);
          
          // Try to call a simple view function
          const paused = await coreManager.paused();
          console.log("Contract paused status:", paused);
          
        } catch (diagError) {
          console.log("Diagnosis failed:", diagError.message);
        }
      }
    }

    // 8. Initialize AdvancedSecurityManager SAFELY
    console.log("\n⚙️ Step 8: Initializing AdvancedSecurityManager...");
    if (deploymentInfo.contracts.advancedSecurityManager) {
      try {
        const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager");
        const advancedManager = AdvancedSecurityManager.attach(deploymentInfo.contracts.advancedSecurityManager);
        
        // Check if already initialized
        try {
          const currentTreasury = await advancedManager.treasuryWallet();
          if (currentTreasury !== ethers.ZeroAddress) {
            console.log("ℹ️ AdvancedSecurityManager already initialized");
          } else {
            throw new Error("Not initialized");
          }
        } catch {
          await advancedManager.initialize(
            deploymentInfo.contracts.usdtToken,
            deploymentInfo.contracts.qorafiToken,
            deployer.address
          );
          console.log("✅ AdvancedSecurityManager initialized");
        }
      } catch (advInitError) {
        console.log("❌ AdvancedSecurityManager initialization failed:", advInitError.message);
        deploymentInfo.errors.push(`AdvancedSecurityManager init: ${advInitError.message}`);
      }
    }

    // 9. Initialize SecurityGovernance SAFELY
    console.log("\n⚙️ Step 9: Initializing SecurityGovernance...");
    if (deploymentInfo.contracts.securityGovernance) {
      try {
        const SecurityGovernance = await ethers.getContractFactory("SecurityGovernance");
        const securityGovernance = SecurityGovernance.attach(deploymentInfo.contracts.securityGovernance);
        
        await securityGovernance.initialize(
          governance.address,
          emergency.address,
          deployer.address
        );
        console.log("✅ SecurityGovernance initialized");
      } catch (govInitError) {
        console.log("❌ SecurityGovernance initialization failed:", govInitError.message);
        deploymentInfo.errors.push(`SecurityGovernance init: ${govInitError.message}`);
      }
    }

    // 10. Initialize EnhancedOracle SAFELY
    console.log("\n⚙️ Step 10: Initializing EnhancedOracle...");
    if (deploymentInfo.contracts.enhancedOracle) {
      try {
        const EnhancedOracle = await ethers.getContractFactory("EnhancedOracle");
        const oracle = EnhancedOracle.attach(deploymentInfo.contracts.enhancedOracle);
        
        await oracle.initialize(
          governance.address,
          emergency.address
        );
        console.log("✅ EnhancedOracle initialized");
      } catch (oracleInitError) {
        console.log("❌ EnhancedOracle initialization failed:", oracleInitError.message);
        deploymentInfo.errors.push(`EnhancedOracle init: ${oracleInitError.message}`);
      }
    }

    // 11. Configure Advanced Features (if available)
    console.log("\n🔧 Step 11: Configuring Advanced Features...");
    if (deploymentInfo.contracts.advancedSecurityManager) {
      try {
        const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager");
        const advancedManager = AdvancedSecurityManager.attach(deploymentInfo.contracts.advancedSecurityManager);
        
        // Try to initialize advanced features
        try {
          await advancedManager.initializeAdvanced(3600, 10, 300);
          console.log("✅ Advanced features initialized");
        } catch (advFeatError) {
          console.log("⚠️ Advanced features initialization failed:", advFeatError.message);
        }
        
        // Try to set advanced parameters
        try {
          await advancedManager.setAdvancedParameters(8000, 3600, 10);
          console.log("✅ Advanced parameters set");
        } catch (advParamError) {
          console.log("⚠️ Advanced parameters setting failed:", advParamError.message);
        }
        
      } catch (advConfigError) {
        console.log("❌ Advanced configuration failed:", advConfigError.message);
        deploymentInfo.errors.push(`Advanced config: ${advConfigError.message}`);
      }
    }

    // 12. Summary
    console.log("\n📊 DEPLOYMENT SUMMARY:");
    console.log("======================");
    
    Object.entries(deploymentInfo.contracts).forEach(([name, address]) => {
      console.log(`✅ ${name}: ${address}`);
    });
    
    if (deploymentInfo.errors.length > 0) {
      console.log("\n⚠️ Issues encountered:");
      deploymentInfo.errors.forEach(error => {
        console.log(`  - ${error}`);
      });
    }
    
    console.log(`\n🎯 Successfully deployed ${Object.keys(deploymentInfo.contracts).length} contracts!`);
    
    return deploymentInfo;

  } catch (error) {
    console.error("❌ Deployment failed:", error.message);
    return deploymentInfo;
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