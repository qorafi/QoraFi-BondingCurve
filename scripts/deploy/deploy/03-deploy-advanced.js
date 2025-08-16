// scripts/deploy/03-deploy-advanced.js
const { ethers } = require("hardhat");
const hre = require("hardhat");
const fs = require("fs");

async function main() {
  console.log("🚀 PHASE 3: Deploying Enhanced Oracle...");
  
  const network = hre.network.name;
  console.log(`🌐 Network: ${network}`);
  
  // Load previous deployment data
  const phase2Files = fs.readdirSync('.').filter(f => f.startsWith('deployment-phase2-') && f.includes(network) && !f.includes('failed'));
  if (phase2Files.length === 0) {
    throw new Error("❌ Phase 2 deployment file not found. Run Phase 2 first.");
  }
  
  const phase2File = phase2Files[phase2Files.length - 1]; // Get latest
  const phase2Data = JSON.parse(fs.readFileSync(phase2File, 'utf8'));
  console.log(`📁 Loading Phase 2 data from: ${phase2File}`);
  
  const signers = await ethers.getSigners();
  const deployer = signers[0];
  const treasury = deployer;
  
  console.log(`👤 Deployer: ${deployer.address}`);
  console.log(`💰 Treasury: ${treasury.address}`);
  
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`💵 Deployer Balance: ${ethers.formatEther(balance)} BNB`);
  
  if (balance < ethers.parseEther("0.03")) {
    throw new Error("❌ Insufficient BNB for deployment. Need at least 0.03 BNB");
  }

  const deploymentInfo = {
    phase: "3-enhanced-oracle",
    timestamp: new Date().toISOString(),
    network: network,
    deployer: deployer.address,
    treasury: treasury.address,
    phase1: phase2Data.phase1,
    phase2: phase2Data,
    contracts: {},
    verification: {},
    errors: []
  };

  try {
    // Get previous addresses
    const qorafiToken = phase2Data.phase1.contracts.qorafiToken;
    
    if (!qorafiToken) {
      throw new Error("❌ Missing required QoraFi token address");
    }

    // Determine USDT address
    let usdtAddress;
    if (network === "bscTestnet" || network === "bsc-testnet") {
      try {
        usdtAddress = "0x337610d27c682E347C9cD60BD4b3b107C9d34dDd"; // BSC Testnet USDT
        const code = await ethers.provider.getCode(usdtAddress);
        if (code === "0x") throw new Error("USDT not found");
      } catch (error) {
        usdtAddress = phase2Data.phase1.contracts.mockUsdt;
      }
    } else if (network === "bsc" || network === "bsc-mainnet") {
      usdtAddress = "0x55d398326f99059fF775485246999027B3197955"; // BSC Mainnet USDT
    } else {
      usdtAddress = phase2Data.phase1.contracts.mockUsdt;
    }

    // =========================================================================
    // STEP 1: DEPLOY ENHANCED ORACLE (WITH LIBRARY LINKING)
    // =========================================================================
    console.log("\n🔮 Step 1: Deploying EnhancedOracle...");
    
    // For testnet, create a mock LP pair if needed
    let lpPairAddress = phase2Data.phase1.contracts.mockLpPair;
    if (!lpPairAddress) {
      console.log("🎭 Creating temporary LP pair for oracle...");
      const MockPair = await ethers.getContractFactory("MockUniswapV2Pair");
      const tempPair = await MockPair.deploy(qorafiToken, usdtAddress);
      await tempPair.waitForDeployment();
      lpPairAddress = await tempPair.getAddress();
      console.log("✅ Temporary LP pair:", lpPairAddress);
      deploymentInfo.contracts.mockLpPair = lpPairAddress;
    }
    
    // Verify OracleLibraries exists
    if (!phase2Data.phase1.libraries || !phase2Data.phase1.libraries.OracleLibraries) {
      throw new Error("❌ Missing OracleLibraries from Phase 1");
    }

    console.log("📚 Using OracleLibraries:", phase2Data.phase1.libraries.OracleLibraries);
    
    const EnhancedOracle = await ethers.getContractFactory("EnhancedOracle", {
      libraries: {
        // Link the Oracle libraries that EnhancedOracle uses
        TWAPLib: phase2Data.phase1.libraries.OracleLibraries,
        PriceValidationLib: phase2Data.phase1.libraries.OracleLibraries,
        LiquidityMonitorLib: phase2Data.phase1.libraries.OracleLibraries,
        FlashLoanDetectionLib: phase2Data.phase1.libraries.OracleLibraries,
        CumulativePriceLib: phase2Data.phase1.libraries.OracleLibraries
      }
    });
    
    const enhancedOracle = await EnhancedOracle.deploy();
    await enhancedOracle.waitForDeployment();
    deploymentInfo.contracts.EnhancedOracle = await enhancedOracle.getAddress();
    console.log("✅ EnhancedOracle:", deploymentInfo.contracts.EnhancedOracle);
    
    // Initialize EnhancedOracle
    console.log("🔧 Initializing EnhancedOracle...");
    const initOracleTx = await enhancedOracle.initialize(
      usdtAddress,
      qorafiToken,
      lpPairAddress,
      ethers.parseEther("1000"), // 1K min market cap
      ethers.parseEther("100000000"), // 100M max market cap
      deployer.address, // governance
      deployer.address  // oracle updater
    );
    await initOracleTx.wait();
    console.log("✅ EnhancedOracle initialized");

    // =========================================================================
    // STEP 2: BASIC CONFIGURATION
    // =========================================================================
    console.log("\n🔧 Step 2: Basic Configuration...");
    
    const configOperations = [
      {
        name: "Set EnhancedOracle new token mode",
        operation: async () => {
          await enhancedOracle.setNewTokenMode(true);
        }
      },
      {
        name: "Set EnhancedOracle fallback price",
        operation: async () => {
          await enhancedOracle.setFallbackPrice(ethers.parseEther("0.01")); // $0.01 fallback
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
    // STEP 3: VERIFY CONTRACTS
    // =========================================================================
    console.log("\n🔍 Step 3: Verifying Contracts...");
    
    if (network !== "localhost" && network !== "hardhat") {
      const contractsToVerify = [
        { 
          name: "EnhancedOracle", 
          address: deploymentInfo.contracts.EnhancedOracle, 
          args: [],
          libraries: {
            TWAPLib: phase2Data.phase1.libraries.OracleLibraries,
            PriceValidationLib: phase2Data.phase1.libraries.OracleLibraries,
            LiquidityMonitorLib: phase2Data.phase1.libraries.OracleLibraries,
            FlashLoanDetectionLib: phase2Data.phase1.libraries.OracleLibraries,
            CumulativePriceLib: phase2Data.phase1.libraries.OracleLibraries
          }
        }
      ];

      // Add mock LP pair if created
      if (deploymentInfo.contracts.mockLpPair) {
        contractsToVerify.push({
          name: "MockUniswapV2Pair",
          address: deploymentInfo.contracts.mockLpPair,
          args: [qorafiToken, usdtAddress]
        });
      }

      for (const contract of contractsToVerify) {
        try {
          console.log(`🔍 Verifying ${contract.name}...`);
          const verifyParams = {
            address: contract.address,
            constructorArguments: contract.args,
          };
          
          if (contract.libraries) {
            verifyParams.libraries = contract.libraries;
          }
          
          await hre.run("verify:verify", verifyParams);
          deploymentInfo.verification[contract.name] = "SUCCESS";
          console.log(`✅ ${contract.name} verified`);
        } catch (error) {
          console.log(`⚠️ ${contract.name} verification failed:`, error.message);
          deploymentInfo.verification[contract.name] = error.message;
        }
      }
    }

    // =========================================================================
    // FINALIZE PHASE 3
    // =========================================================================
    deploymentInfo.summary = {
      phase: "3-enhanced-oracle",
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
        OracleLibraries: phase2Data.phase1.libraries.OracleLibraries
      }
    };

    deploymentInfo.timestamp_completed = new Date().toISOString();

    // Save deployment info
    const fileName = `deployment-phase3-${network}-${Date.now()}.json`;
    fs.writeFileSync(fileName, JSON.stringify(deploymentInfo, null, 2));

    console.log("\n🎉 PHASE 3 DEPLOYMENT COMPLETE!");
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
    console.log("   1. Run Phase 4: Protocol Core");
    console.log("   2. Enhanced oracle is configured and ready");
    console.log("   3. Simplified architecture without over-engineered security");

  } catch (error) {
    console.error("\n❌ Phase 3 deployment failed:", error);
    deploymentInfo.errors.push({
      phase: "PHASE_3_DEPLOYMENT",
      error: error.message,
      stack: error.stack
    });
    
    const fileName = `deployment-phase3-failed-${network}-${Date.now()}.json`;
    fs.writeFileSync(fileName, JSON.stringify(deploymentInfo, null, 2));
    throw error;
  }
}

main()
  .then(() => {
    console.log("\n🎊 Phase 3 deployment completed successfully!");
    console.log("🚀 Ready for Phase 4: Protocol Core!");
    process.exit(0);
  })
  .catch((error) => {
    console.error("\n❌ Phase 3 deployment failed:", error.message);
    process.exit(1);
  });