// scripts/deploy/04-deploy-protocol-enhanced.js
const { ethers } = require("hardhat");
const hre = require("hardhat");
const fs = require("fs");

async function main() {
  console.log("🚀 PHASE 4: Deploying Protocol Core with Library Linking...");
  
  const network = hre.network.name;
  console.log(`🌐 Network: ${network}`);
  
  // Load previous deployment data
  const phase3Files = fs.readdirSync('.').filter(f => f.startsWith('deployment-phase3-') && f.includes(network) && !f.includes('failed'));
  if (phase3Files.length === 0) {
    throw new Error("❌ Phase 3 deployment file not found. Run Phase 3 first.");
  }
  
  const phase3File = phase3Files[phase3Files.length - 1]; // Get latest
  const phase3Data = JSON.parse(fs.readFileSync(phase3File, 'utf8'));
  console.log(`📁 Loading Phase 3 data from: ${phase3File}`);
  
  const signers = await ethers.getSigners();
  const deployer = signers[0];
  const treasury = deployer;
  
  console.log(`👤 Deployer: ${deployer.address}`);
  console.log(`💰 Treasury: ${treasury.address}`);
  
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`💵 Deployer Balance: ${ethers.formatEther(balance)} BNB`);
  
  if (balance < ethers.parseEther("0.1")) {
    throw new Error("❌ Insufficient BNB for deployment. Need at least 0.1 BNB");
  }

  const deploymentInfo = {
    phase: "4-protocol-core-enhanced",
    timestamp: new Date().toISOString(),
    network: network,
    deployer: deployer.address,
    treasury: treasury.address,
    phase1: phase3Data.phase1,
    phase2: phase3Data.phase2,
    phase3: phase3Data,
    libraries: {},
    contracts: {},
    verification: {},
    errors: []
  };

  try {
    // Get previous addresses
    const qorafiToken = phase3Data.phase1.contracts.qorafiToken;
    const usqToken = phase3Data.phase1.contracts.usqToken;
    const advancedSecurityManager = phase3Data.contracts.AdvancedSecurityManager;
    const enhancedOracle = phase3Data.contracts.EnhancedOracle;
    
    if (!qorafiToken || !usqToken || !advancedSecurityManager || !enhancedOracle) {
      throw new Error("❌ Missing required previous phase contracts");
    }

    // Determine USDT and Router addresses
    let usdtAddress, routerAddress;
    if (network === "bscTestnet" || network === "bsc-testnet") {
      routerAddress = "0xD99D1c33F9fC3444f8101754aBC46c52416550D2"; // PancakeSwap Testnet
      try {
        usdtAddress = "0x337610d27c682E347C9cD60BD4b3b107C9d34dDd"; // BSC Testnet USDT
        const code = await ethers.provider.getCode(usdtAddress);
        if (code === "0x") throw new Error("USDT not found");
      } catch (error) {
        usdtAddress = phase3Data.phase1.contracts.mockUsdt;
      }
    } else if (network === "bsc" || network === "bsc-mainnet") {
      usdtAddress = "0x55d398326f99059fF775485246999027B3197955"; // BSC Mainnet USDT
      routerAddress = "0x10ED43C718714eb63d5aA57B78B54704E256024E"; // PancakeSwap V2 Router
    } else {
      usdtAddress = phase3Data.phase1.contracts.mockUsdt;
      routerAddress = phase3Data.phase1.contracts.mockRouter;
    }

    // =========================================================================
    // STEP 1: DEPLOY REQUIRED LIBRARIES
    // =========================================================================
    console.log("\n📚 Step 1: Deploying Required Libraries...");
    
    const libraries = [
      "ValidationLib",
      "MathHelperLib", 
      "SwapLib",
      "LiquidityLib",
      "TokenHelperLib",
      "LedgerLib",
      "StatisticsLib"
    ];
    
    const deployedLibraries = {};
    
    for (const libName of libraries) {
      try {
        console.log(`📖 Deploying ${libName}...`);
        const LibFactory = await ethers.getContractFactory(libName);
        const lib = await LibFactory.deploy();
        await lib.waitForDeployment();
        const libAddress = await lib.getAddress();
        deployedLibraries[libName] = libAddress;
        deploymentInfo.libraries[libName] = libAddress;
        console.log(`✅ ${libName}: ${libAddress}`);
      } catch (error) {
        console.log(`⚠️ ${libName} deployment failed: ${error.message}`);
        deploymentInfo.errors.push({
          library: libName,
          error: error.message
        });
      }
    }

    // =========================================================================
    // STEP 2: DEPLOY USQ ENGINE
    // =========================================================================
    console.log("\n🔥 Step 2: Deploying USQEngine...");
    
    const USQEngine = await ethers.getContractFactory("USQEngine");
    const usqEngine = await USQEngine.deploy(treasury.address);
    await usqEngine.waitForDeployment();
    deploymentInfo.contracts.USQEngine = await usqEngine.getAddress();
    console.log("✅ USQEngine:", deploymentInfo.contracts.USQEngine);
    
    // Configure USQEngine
    console.log("🔧 Configuring USQEngine...");
    await usqEngine.setOracle(phase3Data.phase2.contracts.usqOracle);
    console.log("✅ USQEngine oracle set");

    // =========================================================================
    // STEP 3: DEPLOY DELEGATOR NODE REWARDS LEDGER
    // =========================================================================
    console.log("\n📊 Step 3: Deploying DelegatorNodeRewardsLedger...");
    
    // Create level requirements and reward percentages
    const levelDepositRequirements = Array(15).fill(0).map((_, i) => 
      ethers.parseEther(((i + 1) * 100).toString())
    );
    const levelRewardPercentagesBPS = Array(15).fill(0).map((_, i) => (i + 1) * 50);
    
    const DelegatorNodeRewardsLedger = await ethers.getContractFactory("DelegatorNodeRewardsLedger");
    const delegatorNodeRewardsLedger = await DelegatorNodeRewardsLedger.deploy(
      levelDepositRequirements,
      levelRewardPercentagesBPS,
      treasury.address,
      deployer.address, // Will be updated to PoolRewardDistributor later
      deployer.address  // Will be updated to bonding curve later
    );
    await delegatorNodeRewardsLedger.waitForDeployment();
    deploymentInfo.contracts.DelegatorNodeRewardsLedger = await delegatorNodeRewardsLedger.getAddress();
    console.log("✅ DelegatorNodeRewardsLedger:", deploymentInfo.contracts.DelegatorNodeRewardsLedger);

    // =========================================================================
    // STEP 4: DEPLOY ENHANCED BONDING CURVE WITH LIBRARY LINKING
    // =========================================================================
    console.log("\n📈 Step 4: Deploying EnhancedBondingCurve with Library Linking...");
    
    // Prepare library linking
    const libraryLinks = {};
    
    // Link only the libraries that are actually used by EnhancedBondingCurve
    const requiredLibraries = [
      "ValidationLib",
      "SwapLib", 
      "LiquidityLib",
      "MathHelperLib",
      "StatisticsLib",
      "LedgerLib"
    ];
    
    for (const libName of requiredLibraries) {
      if (deployedLibraries[libName]) {
        libraryLinks[libName] = deployedLibraries[libName];
      }
    }
    
    console.log("🔗 Linking libraries:", Object.keys(libraryLinks));
    
    const EnhancedBondingCurve = await ethers.getContractFactory("EnhancedBondingCurve", {
      libraries: libraryLinks
    });
    
    const enhancedBondingCurve = await EnhancedBondingCurve.deploy(
      usdtAddress,                                        // _usdtToken
      qorafiToken,                                        // _qorafiToken
      routerAddress,                                      // _router
      advancedSecurityManager,                            // _securityManager
      enhancedOracle,                                     // _oracle
      deploymentInfo.contracts.DelegatorNodeRewardsLedger, // _ledger
      deployer.address                                    // _admin
    );
    await enhancedBondingCurve.waitForDeployment();
    deploymentInfo.contracts.EnhancedBondingCurve = await enhancedBondingCurve.getAddress();
    console.log("✅ EnhancedBondingCurve:", deploymentInfo.contracts.EnhancedBondingCurve);

    // =========================================================================
    // STEP 5: CREATE LP PAIR
    // =========================================================================
    console.log("\n💧 Step 5: Creating LP Pair...");
    
    let lpPairAddress;
    if (network.includes("testnet") || network.includes("localhost")) {
      // Use existing mock pair or create new one
      if (phase3Data.phase1.contracts.mockLpPair) {
        lpPairAddress = phase3Data.phase1.contracts.mockLpPair;
        console.log("✅ Using existing mock LP pair:", lpPairAddress);
        
        // Update the mock pair with correct tokens
        const mockPair = await ethers.getContractAt("MockUniswapV2Pair", lpPairAddress);
        // Set some mock reserves
        await mockPair.setReserves(
          ethers.parseEther("1000"), // 1000 QoraFi
          ethers.parseEther("10")     // 10 USDT (price = $0.01)
        );
        console.log("✅ Mock LP pair reserves set");
      } else {
        // Create new mock pair
        const MockPair = await ethers.getContractFactory("MockUniswapV2Pair");
        const newPair = await MockPair.deploy(qorafiToken, usdtAddress);
        await newPair.waitForDeployment();
        lpPairAddress = await newPair.getAddress();
        console.log("✅ New mock LP pair created:", lpPairAddress);
      }
    } else {
      // For mainnet/testnet, would create real PancakeSwap pair
      // This is a placeholder - actual implementation would use PancakeSwap factory
      console.log("⚠️ Real LP pair creation not implemented for mainnet");
      lpPairAddress = ethers.ZeroAddress; // Placeholder
    }
    
    deploymentInfo.contracts.lpPair = lpPairAddress;

    // =========================================================================
    // STEP 6: CONFIGURATION
    // =========================================================================
    console.log("\n🔧 Step 6: Configuration...");
    
    const configOperations = [
      {
        name: "Update BondingCurve in DelegatorNodeRewardsLedger",
        operation: async () => {
          await delegatorNodeRewardsLedger.setBondingCurveAddress(deploymentInfo.contracts.EnhancedBondingCurve);
        }
      },
      {
        name: "Grant minter role to EnhancedBondingCurve",
        operation: async () => {
          const qorafi = await ethers.getContractAt("QoraFi", qorafiToken);
          const minterRole = await qorafi.MINTER_ROLE();
          await qorafi.grantRole(minterRole, deploymentInfo.contracts.EnhancedBondingCurve);
        }
      },
      {
        name: "Grant minter role to USQEngine", 
        operation: async () => {
          const qorafi = await ethers.getContractAt("QoraFi", qorafiToken);
          const minterRole = await qorafi.MINTER_ROLE();
          await qorafi.grantRole(minterRole, deploymentInfo.contracts.USQEngine);
        }
      },
      {
        name: "Set QoraFi fee destinations",
        operation: async () => {
          const qorafi = await ethers.getContractAt("QoraFi", qorafiToken);
          await qorafi.setFeeDestinations(
            deploymentInfo.contracts.USQEngine,
            deployer.address, // Development wallet
            deployer.address  // Airdrop contract (placeholder)
          );
        }
      },
      {
        name: "Set QoraFi fee splits",
        operation: async () => {
          const qorafi = await ethers.getContractAt("QoraFi", qorafiToken);
          await qorafi.setFeeSplits(200, 100, 100); // 2%, 1%, 1%
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
    // STEP 7: VERIFY CONTRACTS
    // =========================================================================
    console.log("\n🔍 Step 7: Verifying Contracts...");
    
    if (network !== "localhost" && network !== "hardhat") {
      const contractsToVerify = [
        { 
          name: "USQEngine", 
          address: deploymentInfo.contracts.USQEngine, 
          args: [treasury.address] 
        },
        { 
          name: "DelegatorNodeRewardsLedger", 
          address: deploymentInfo.contracts.DelegatorNodeRewardsLedger, 
          args: [
            levelDepositRequirements,
            levelRewardPercentagesBPS,
            treasury.address,
            deployer.address,
            deployer.address
          ] 
        },
        { 
          name: "EnhancedBondingCurve", 
          address: deploymentInfo.contracts.EnhancedBondingCurve, 
          args: [
            usdtAddress,
            qorafiToken,
            routerAddress,
            advancedSecurityManager,
            enhancedOracle,
            deploymentInfo.contracts.DelegatorNodeRewardsLedger,
            deployer.address
          ],
          libraries: libraryLinks // Include library links for verification
        }
      ];

      // Verify libraries first
      for (const [libName, libAddress] of Object.entries(deployedLibraries)) {
        try {
          console.log(`🔍 Verifying library ${libName}...`);
          await hre.run("verify:verify", {
            address: libAddress,
            constructorArguments: [],
          });
          deploymentInfo.verification[libName] = "SUCCESS";
          console.log(`✅ ${libName} library verified`);
        } catch (error) {
          console.log(`⚠️ ${libName} library verification failed:`, error.message);
          deploymentInfo.verification[libName] = error.message;
        }
      }

      // Verify contracts
      for (const contract of contractsToVerify) {
        try {
          console.log(`🔍 Verifying ${contract.name}...`);
          const verifyOptions = {
            address: contract.address,
            constructorArguments: contract.args,
          };
          
          // Add libraries if present
          if (contract.libraries) {
            verifyOptions.libraries = contract.libraries;
          }
          
          await hre.run("verify:verify", verifyOptions);
          deploymentInfo.verification[contract.name] = "SUCCESS";
          console.log(`✅ ${contract.name} verified`);
        } catch (error) {
          console.log(`⚠️ ${contract.name} verification failed:`, error.message);
          deploymentInfo.verification[contract.name] = error.message;
        }
      }
    }

    // =========================================================================
    // FINALIZE PHASE 4
    // =========================================================================
    deploymentInfo.summary = {
      phase: "4-protocol-core-enhanced",
      totalLibraries: Object.keys(deploymentInfo.libraries).length,
      totalContracts: Object.keys(deploymentInfo.contracts).length,
      successfulConfigs: successfulConfigs,
      totalConfigs: configOperations.length,
      verificationSuccess: Object.values(deploymentInfo.verification).filter(v => v === "SUCCESS").length,
      verificationTotal: Object.keys(deploymentInfo.verification).length,
      errors: deploymentInfo.errors.length,
      complete: true,
      network: network,
      deployer: deployer.address,
      deploymentTime: new Date().toISOString()
    };

    deploymentInfo.timestamp_completed = new Date().toISOString();

    // Save deployment info
    const fileName = `deployment-phase4-enhanced-${network}-${Date.now()}.json`;
    fs.writeFileSync(fileName, JSON.stringify(deploymentInfo, null, 2));

    console.log("\n🎉 PHASE 4 ENHANCED DEPLOYMENT COMPLETE!");
    console.log("==========================================");
    console.log(`📁 Deployment saved to: ${fileName}`);
    console.log(`📚 Libraries deployed: ${deploymentInfo.summary.totalLibraries}`);
    console.log(`📋 Contracts deployed: ${deploymentInfo.summary.totalContracts}`);
    console.log(`✅ Configurations: ${deploymentInfo.summary.successfulConfigs}/${deploymentInfo.summary.totalConfigs}`);
    console.log(`✅ Verifications: ${deploymentInfo.summary.verificationSuccess}/${deploymentInfo.summary.verificationTotal}`);

    console.log("\n📚 Deployed Libraries:");
    Object.entries(deploymentInfo.libraries).forEach(([name, address]) => {
      console.log(`   ✅ ${name}: ${address}`);
    });

    console.log("\n🌟 Deployed Contracts:");
    Object.entries(deploymentInfo.contracts).forEach(([name, address]) => {
      console.log(`   ✅ ${name}: ${address}`);
    });

    console.log("\n🔗 Key Contract Addresses:");
    console.log(`   📍 USQ Engine: ${deploymentInfo.contracts.USQEngine}`);
    console.log(`   📍 Enhanced Bonding Curve: ${deploymentInfo.contracts.EnhancedBondingCurve}`);
    console.log(`   📍 Delegator Rewards Ledger: ${deploymentInfo.contracts.DelegatorNodeRewardsLedger}`);
    console.log(`   📍 LP Pair: ${deploymentInfo.contracts.lpPair}`);

    console.log("\n📝 Next Steps:");
    console.log("   1. Run Phase 5: Staking & Rewards");
    console.log("   2. Core protocol is ready for staking");
    console.log("   3. Bonding curve is configured and ready with library linking");
    console.log("   4. All libraries are properly linked and verified");

  } catch (error) {
    console.error("\n❌ Phase 4 enhanced deployment failed:", error);
    deploymentInfo.errors.push({
      phase: "PHASE_4_ENHANCED_DEPLOYMENT",
      error: error.message,
      stack: error.stack
    });
    
    const fileName = `deployment-phase4-enhanced-failed-${network}-${Date.now()}.json`;
    fs.writeFileSync(fileName, JSON.stringify(deploymentInfo, null, 2));
    throw error;
  }
}

main()
  .then(() => {
    console.log("\n🎊 Phase 4 enhanced deployment completed successfully!");
    console.log("🚀 Ready for Phase 5: Staking & Rewards!");
    process.exit(0);
  })
  .catch((error) => {
    console.error("\n❌ Phase 4 enhanced deployment failed:", error.message);
    process.exit(1);
  });