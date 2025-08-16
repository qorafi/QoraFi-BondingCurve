// scripts/deploy/02-deploy-core.js
const { ethers } = require("hardhat");
const hre = require("hardhat");
const fs = require("fs");

async function main() {
  console.log("🚀 PHASE 2: Deploying Core Infrastructure...");
  
  const network = hre.network.name;
  console.log(`🌐 Network: ${network}`);
  
  // Load Phase 1 deployment data
  const phase1Files = fs.readdirSync('.').filter(f => f.startsWith('deployment-phase1-') && f.includes(network) && !f.includes('failed'));
  if (phase1Files.length === 0) {
    throw new Error("❌ Phase 1 deployment file not found. Run Phase 1 first.");
  }
  
  const phase1File = phase1Files[phase1Files.length - 1]; // Get latest
  const phase1Data = JSON.parse(fs.readFileSync(phase1File, 'utf8'));
  console.log(`📁 Loading Phase 1 data from: ${phase1File}`);
  
  const signers = await ethers.getSigners();
  const deployer = signers[0];
  const treasury = deployer;
  
  console.log(`👤 Deployer: ${deployer.address}`);
  console.log(`💰 Treasury: ${treasury.address}`);
  
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`💵 Deployer Balance: ${ethers.formatEther(balance)} BNB`);
  
  if (balance < ethers.parseEther("0.05")) {
    throw new Error("❌ Insufficient BNB for deployment. Need at least 0.05 BNB");
  }

  const deploymentInfo = {
    phase: "2-core-infrastructure",
    timestamp: new Date().toISOString(),
    network: network,
    deployer: deployer.address,
    treasury: treasury.address,
    phase1: phase1Data,
    contracts: {},
    verification: {},
    errors: []
  };

  try {
    // Get Phase 1 addresses
    const qorafiToken = phase1Data.contracts.qorafiToken;
    const usqToken = phase1Data.contracts.usqToken;
    const mockUsdt = phase1Data.contracts.mockUsdt;
    
    if (!qorafiToken || !usqToken) {
      throw new Error("❌ Missing required Phase 1 contracts");
    }

    // Verify library addresses exist
    if (!phase1Data.libraries || !phase1Data.libraries.MEVProtection || !phase1Data.libraries.CircuitBreaker) {
      throw new Error("❌ Missing required Phase 1 libraries for CoreSecurityManager");
    }

    // Use real USDT or mock based on network
    let usdtAddress;
    if (network === "bscTestnet" || network === "bsc-testnet") {
      // Try BSC Testnet USDT first
      try {
        usdtAddress = "0x337610d27c682E347C9cD60BD4b3b107C9d34dDd"; // BSC Testnet USDT
        const code = await ethers.provider.getCode(usdtAddress);
        if (code === "0x") {
          throw new Error("USDT not found");
        }
        console.log("✅ Using BSC Testnet USDT:", usdtAddress);
      } catch (error) {
        usdtAddress = mockUsdt;
        console.log("⚠️ Using Mock USDT:", usdtAddress);
      }
    } else if (network === "bsc" || network === "bsc-mainnet") {
      usdtAddress = "0x55d398326f99059fF775485246999027B3197955"; // BSC Mainnet USDT
    } else {
      usdtAddress = mockUsdt;
    }

    // =========================================================================
    // STEP 1: DEPLOY CORE SECURITY MANAGER (WITH LIBRARY LINKING)
    // =========================================================================
    console.log("\n🛡️ Step 1: Deploying CoreSecurityManager with Library Linking...");
    
    console.log("📚 Using libraries:");
    console.log(`   MEVProtection: ${phase1Data.libraries.MEVProtection}`);
    console.log(`   CircuitBreaker: ${phase1Data.libraries.CircuitBreaker}`);
    
    const CoreSecurityManager = await ethers.getContractFactory("CoreSecurityManager", {
      libraries: {
        // Link the individual libraries that CoreSecurityManager uses
        MEVLib: phase1Data.libraries.MEVProtection,
        CircuitBreakerLib: phase1Data.libraries.CircuitBreaker,
        ValidationLib: phase1Data.libraries.MEVProtection // ValidationLib is in MEVProtection.sol
      }
    });
    
    const coreSecurityManager = await CoreSecurityManager.deploy();
    await coreSecurityManager.waitForDeployment();
    deploymentInfo.contracts.CoreSecurityManager = await coreSecurityManager.getAddress();
    console.log("✅ CoreSecurityManager:", deploymentInfo.contracts.CoreSecurityManager);
    
    // Initialize CoreSecurityManager
    console.log("🔧 Initializing CoreSecurityManager...");
    const initTx = await coreSecurityManager.initialize(
      usdtAddress,
      qorafiToken,
      treasury.address
    );
    await initTx.wait();
    console.log("✅ CoreSecurityManager initialized");

    // =========================================================================
    // STEP 2: DEPLOY USQ ORACLE
    // =========================================================================
    console.log("\n🔮 Step 2: Deploying USQ Oracle...");
    
    const Oracle = await ethers.getContractFactory("Oracle");
    const usqOracle = await Oracle.deploy();
    await usqOracle.waitForDeployment();
    deploymentInfo.contracts.usqOracle = await usqOracle.getAddress();
    console.log("✅ USQ Oracle:", deploymentInfo.contracts.usqOracle);

    // =========================================================================
    // STEP 3: DEPLOY TIMELOCK
    // =========================================================================
    console.log("\n⏰ Step 3: Deploying QoraFiTimelock...");
    
    const QoraFiTimelock = await ethers.getContractFactory("QoraFiTimelock");
    const minDelay = 2 * 24 * 60 * 60; // 2 days
    const initialProposers = [deployer.address];
    const initialExecutors = [ethers.ZeroAddress]; // Anyone can execute
    
    const timelock = await QoraFiTimelock.deploy(
      minDelay,
      initialProposers,
      initialExecutors
    );
    await timelock.waitForDeployment();
    deploymentInfo.contracts.QoraFiTimelock = await timelock.getAddress();
    console.log("✅ QoraFiTimelock:", deploymentInfo.contracts.QoraFiTimelock);

    // =========================================================================
    // STEP 4: BASIC CONFIGURATION
    // =========================================================================
    console.log("\n🔧 Step 4: Basic Configuration...");
    
    const configOperations = [
      {
        name: "Set CoreSecurityManager new token mode",
        operation: async () => {
          await coreSecurityManager.setNewTokenMode(true);
        }
      }
    ];

    let successfulConfigs = 0;
    for (const config of configOperations) {
      try {
        await config.operation();
        console.log(`✅ ${config.name}`);
        successfulConfigs++;
      } catch (error) {
        console.log(`⚠️ ${config.name} failed: ${error.message}`);
        deploymentInfo.errors.push({
          operation: config.name,
          error: error.message
        });
      }
    }

    // =========================================================================
    // STEP 5: VERIFY CONTRACTS
    // =========================================================================
    console.log("\n🔍 Step 5: Verifying Contracts...");
    
    if (network !== "localhost" && network !== "hardhat") {
      const contractsToVerify = [
        { 
          name: "CoreSecurityManager", 
          address: deploymentInfo.contracts.CoreSecurityManager, 
          args: [] 
        },
        { 
          name: "Oracle", 
          address: deploymentInfo.contracts.usqOracle, 
          args: [] 
        },
        { 
          name: "QoraFiTimelock", 
          address: deploymentInfo.contracts.QoraFiTimelock, 
          args: [minDelay, initialProposers, initialExecutors] 
        }
      ];

      for (const contract of contractsToVerify) {
        try {
          console.log(`🔍 Verifying ${contract.name}...`);
          await hre.run("verify:verify", {
            address: contract.address,
            constructorArguments: contract.args,
            libraries: contract.name === "CoreSecurityManager" ? {
              MEVLib: phase1Data.libraries.MEVProtection,
              CircuitBreakerLib: phase1Data.libraries.CircuitBreaker,
              ValidationLib: phase1Data.libraries.MEVProtection
            } : {}
          });
          deploymentInfo.verification[contract.name] = "SUCCESS";
          console.log(`✅ ${contract.name} verified`);
        } catch (error) {
          console.log(`⚠️ ${contract.name} verification failed:`, error.message);
          deploymentInfo.verification[contract.name] = error.message;
        }
      }
    }

    // =========================================================================
    // FINALIZE PHASE 2
    // =========================================================================
    deploymentInfo.summary = {
      phase: "2-core-infrastructure",
      totalContracts: Object.keys(deploymentInfo.contracts).length,
      successfulConfigs: successfulConfigs,
      totalConfigs: configOperations.length,
      verificationSuccess: Object.values(deploymentInfo.verification).filter(v => v === "SUCCESS").length,
      verificationTotal: Object.keys(deploymentInfo.verification).length,
      errors: deploymentInfo.errors.length,
      complete: true,
      network: network,
      deployer: deployer.address,
      deploymentTime: new Date().toISOString(),
      librariesUsed: {
        MEVLib: phase1Data.libraries.MEVProtection,
        CircuitBreakerLib: phase1Data.libraries.CircuitBreaker,
        ValidationLib: phase1Data.libraries.MEVProtection
      }
    };

    deploymentInfo.timestamp_completed = new Date().toISOString();

    // Save deployment info
    const fileName = `deployment-phase2-${network}-${Date.now()}.json`;
    fs.writeFileSync(fileName, JSON.stringify(deploymentInfo, null, 2));

    console.log("\n🎉 PHASE 2 DEPLOYMENT COMPLETE!");
    console.log("==========================================");
    console.log(`📁 Deployment saved to: ${fileName}`);
    console.log(`📋 Contracts deployed: ${deploymentInfo.summary.totalContracts}`);
    console.log(`✅ Configurations: ${deploymentInfo.summary.successfulConfigs}/${deploymentInfo.summary.totalConfigs}`);
    console.log(`✅ Verifications: ${deploymentInfo.summary.verificationSuccess}/${deploymentInfo.summary.verificationTotal}`);

    console.log("\n🌟 Deployed Contracts:");
    Object.entries(deploymentInfo.contracts).forEach(([name, address]) => {
      console.log(`   ✅ ${name}: ${address}`);
    });

    console.log("\n📚 Libraries Used:");
    Object.entries(deploymentInfo.summary.librariesUsed).forEach(([name, address]) => {
      console.log(`   🔗 ${name}: ${address}`);
    });

    console.log("\n📝 Next Steps:");
    console.log("   1. Run Phase 3: Enhanced Oracle (simplified)");
    console.log("   2. CoreSecurityManager is ready with proper library linking");
    console.log("   3. Timelock is ready for governance");

  } catch (error) {
    console.error("\n❌ Phase 2 deployment failed:", error);
    deploymentInfo.errors.push({
      phase: "PHASE_2_DEPLOYMENT",
      error: error.message,
      stack: error.stack
    });
    
    const fileName = `deployment-phase2-failed-${network}-${Date.now()}.json`;
    fs.writeFileSync(fileName, JSON.stringify(deploymentInfo, null, 2));
    throw error;
  }
}

main()
  .then(() => {
    console.log("\n🎊 Phase 2 deployment completed successfully!");
    console.log("🚀 Ready for Phase 3: Enhanced Oracle!");
    process.exit(0);
  })
  .catch((error) => {
    console.error("\n❌ Phase 2 deployment failed:", error.message);
    process.exit(1);
  });