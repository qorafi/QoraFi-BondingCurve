// scripts/deploy/01-deploy-foundation.js
const { ethers } = require("hardhat");
const hre = require("hardhat");
const fs = require("fs");

async function main() {
  console.log("🚀 PHASE 1: Deploying Foundation Contracts...");
  
  const network = hre.network.name;
  console.log(`🌐 Network: ${network}`);
  
  const signers = await ethers.getSigners();
  const deployer = signers[0];
  const treasury = deployer; // Use deployer as treasury initially
  
  console.log(`👤 Deployer: ${deployer.address}`);
  console.log(`💰 Treasury: ${treasury.address}`);
  
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`💵 Deployer Balance: ${ethers.formatEther(balance)} BNB`);
  
  if (balance < ethers.parseEther("0.05")) {
    throw new Error("❌ Insufficient BNB for deployment. Need at least 0.05 BNB");
  }

  const deploymentInfo = {
    phase: "1-foundation",
    timestamp: new Date().toISOString(),
    network: network,
    deployer: deployer.address,
    treasury: treasury.address,
    contracts: {},
    libraries: {},
    verification: {},
    errors: [],
    externalContracts: {}
  };

  try {
    // =========================================================================
    // STEP 1: DEPLOY ALL INDIVIDUAL MODULAR LIBRARIES
    // =========================================================================
    console.log("\n📚 Step 1: Deploying All Individual Modular Libraries...");
    
    // SECURITY LIBRARIES (3 individual libraries)
    console.log("\n🔒 Security Libraries:");
    
    console.log("📚 Deploying MEVProtection Library...");
    const MEVProtection = await ethers.getContractFactory("MEVProtection");
    const mevProtection = await MEVProtection.deploy();
    await mevProtection.waitForDeployment();
    deploymentInfo.libraries.MEVProtection = await mevProtection.getAddress();
    console.log("✅ MEVProtection:", deploymentInfo.libraries.MEVProtection);
    
    console.log("📚 Deploying CircuitBreaker Library...");
    const CircuitBreaker = await ethers.getContractFactory("CircuitBreaker");
    const circuitBreaker = await CircuitBreaker.deploy();
    await circuitBreaker.waitForDeployment();
    deploymentInfo.libraries.CircuitBreaker = await circuitBreaker.getAddress();
    console.log("✅ CircuitBreaker:", deploymentInfo.libraries.CircuitBreaker);
    
    console.log("📚 Deploying EmergencySystem Library...");
    const EmergencySystem = await ethers.getContractFactory("EmergencySystem");
    const emergencySystem = await EmergencySystem.deploy();
    await emergencySystem.waitForDeployment();
    deploymentInfo.libraries.EmergencySystem = await emergencySystem.getAddress();
    console.log("✅ EmergencySystem:", deploymentInfo.libraries.EmergencySystem);
    
    // UTILITY LIBRARIES (5 individual libraries)
    console.log("\n🛠️ Utility Libraries:");
    
    console.log("📚 Deploying SwapUtilities Library...");
    const SwapUtilities = await ethers.getContractFactory("SwapUtilities");
    const swapUtilities = await SwapUtilities.deploy();
    await swapUtilities.waitForDeployment();
    deploymentInfo.libraries.SwapUtilities = await swapUtilities.getAddress();
    console.log("✅ SwapUtilities:", deploymentInfo.libraries.SwapUtilities);
    
    console.log("📚 Deploying TokenUtilities Library...");
    const TokenUtilities = await ethers.getContractFactory("TokenUtilities");
    const tokenUtilities = await TokenUtilities.deploy();
    await tokenUtilities.waitForDeployment();
    deploymentInfo.libraries.TokenUtilities = await tokenUtilities.getAddress();
    console.log("✅ TokenUtilities:", deploymentInfo.libraries.TokenUtilities);
    
    console.log("📚 Deploying MathUtilities Library...");
    const MathUtilities = await ethers.getContractFactory("MathUtilities");
    const mathUtilities = await MathUtilities.deploy();
    await mathUtilities.waitForDeployment();
    deploymentInfo.libraries.MathUtilities = await mathUtilities.getAddress();
    console.log("✅ MathUtilities:", deploymentInfo.libraries.MathUtilities);
    
    console.log("📚 Deploying StatisticsCore Library...");
    const StatisticsCore = await ethers.getContractFactory("StatisticsCore");
    const statisticsCore = await StatisticsCore.deploy();
    await statisticsCore.waitForDeployment();
    deploymentInfo.libraries.StatisticsCore = await statisticsCore.getAddress();
    console.log("✅ StatisticsCore:", deploymentInfo.libraries.StatisticsCore);
    
    console.log("📚 Deploying AnalyticsEngine Library...");
    const AnalyticsEngine = await ethers.getContractFactory("AnalyticsEngine");
    const analyticsEngine = await AnalyticsEngine.deploy();
    await analyticsEngine.waitForDeployment();
    deploymentInfo.libraries.AnalyticsEngine = await analyticsEngine.getAddress();
    console.log("✅ AnalyticsEngine:", deploymentInfo.libraries.AnalyticsEngine);
    
    // ORACLE LIBRARIES (1 consolidated library)
    console.log("\n🔮 Oracle Libraries:");
    
    console.log("📚 Deploying OracleLibraries...");
    const OracleLibraries = await ethers.getContractFactory("OracleLibraries");
    const oracleLibraries = await OracleLibraries.deploy();
    await oracleLibraries.waitForDeployment();
    deploymentInfo.libraries.OracleLibraries = await oracleLibraries.getAddress();
    console.log("✅ OracleLibraries:", deploymentInfo.libraries.OracleLibraries);

    // =========================================================================
    // STEP 1.5: VERIFY ALL LIBRARY VERSIONS
    // =========================================================================
    console.log("\n🔍 Step 1.5: Verifying All Library Versions...");
    try {
      console.log("📚 Library Versions (Total: 9 libraries):");
      console.log("🔒 Security Libraries:");
      console.log(`   MEV Protection: ${await mevProtection.getLibraryVersion()}`);
      console.log(`   Circuit Breaker: ${await circuitBreaker.getLibraryVersion()}`);
      console.log(`   Emergency System: ${await emergencySystem.getLibraryVersion()}`);
      console.log("🛠️ Utility Libraries:");
      console.log(`   Swap Utilities: ${await swapUtilities.getLibraryVersion()}`);
      console.log(`   Token Utilities: ${await tokenUtilities.getLibraryVersion()}`);
      console.log(`   Math Utilities: ${await mathUtilities.getLibraryVersion()}`);
      console.log(`   Statistics Core: ${await statisticsCore.getLibraryVersion()}`);
      console.log(`   Analytics Engine: ${await analyticsEngine.getLibraryVersion()}`);
      console.log("🔮 Oracle Libraries:");
      console.log(`   Oracle Libraries: ${await oracleLibraries.getLibraryVersion()}`);
    } catch (error) {
      console.log("⚠️ Could not fetch library versions:", error.message);
      deploymentInfo.errors.push({
        phase: "LIBRARY_VERSION_CHECK",
        error: error.message
      });
    }

    // =========================================================================
    // STEP 2: REFERENCE EXISTING CONTRACTS
    // =========================================================================
    console.log("\n🔗 Step 2: Referencing External Contracts...");
    
    // Store external contract addresses from .env for reference
    deploymentInfo.externalContracts = {
      usdt: process.env.USDT_ADDRESS,
      pancakeRouter: process.env.PANCAKE_ROUTER_ADDRESS,
      pancakeFactory: process.env.PANCAKE_FACTORY_ADDRESS,
      wbnb: process.env.WBNB_ADDRESS
    };
    
    console.log("🔗 External contracts from .env:");
    console.log(`   USDT: ${deploymentInfo.externalContracts.usdt}`);
    console.log(`   PancakeRouter: ${deploymentInfo.externalContracts.pancakeRouter}`);
    console.log(`   PancakeFactory: ${deploymentInfo.externalContracts.pancakeFactory}`);
    console.log(`   WBNB: ${deploymentInfo.externalContracts.wbnb}`);

    // =========================================================================
    // STEP 3: DEPLOY BASIC TOKENS
    // =========================================================================
    console.log("\n🪙 Step 3: Deploying Basic Tokens...");
    
    // QoraFi Token
    console.log("🪙 Deploying QoraFi Token...");
    const QoraFi = await ethers.getContractFactory("QoraFi");
    const qorafiToken = await QoraFi.deploy(
      "QoraFi",
      "QORAFI",
      treasury.address
    );
    await qorafiToken.waitForDeployment();
    deploymentInfo.contracts.qorafiToken = await qorafiToken.getAddress();
    console.log("✅ QoraFi Token:", deploymentInfo.contracts.qorafiToken);
    
    // USQ Token (will be owned by USQEngine later)
    console.log("🪙 Deploying USQ Token...");
    const USQ = await ethers.getContractFactory("contracts/usq/USQ.sol:USQ");
    const usqToken = await USQ.deploy();
    await usqToken.waitForDeployment();
    deploymentInfo.contracts.usqToken = await usqToken.getAddress();
    console.log("✅ USQ Token:", deploymentInfo.contracts.usqToken);

    // =========================================================================
    // STEP 4: VERIFY ALL CONTRACTS AND LIBRARIES
    // =========================================================================
    console.log("\n🔍 Step 4: Verifying All Contracts and Libraries...");
    
    // Skip verification for local development networks only
    if (network === "localhost" || network === "hardhat") {
      console.log("⚠️ Skipping verification - local development network");
    } else {
      console.log(`🔍 Starting verification on ${network}...`);
      
      const contractsToVerify = [
        // ALL INDIVIDUAL LIBRARIES (9 total)
        // Security Libraries (3)
        { name: "MEVProtection", address: deploymentInfo.libraries.MEVProtection, args: [] },
        { name: "CircuitBreaker", address: deploymentInfo.libraries.CircuitBreaker, args: [] },
        { name: "EmergencySystem", address: deploymentInfo.libraries.EmergencySystem, args: [] },
        // Utility Libraries (5)
        { name: "SwapUtilities", address: deploymentInfo.libraries.SwapUtilities, args: [] },
        { name: "TokenUtilities", address: deploymentInfo.libraries.TokenUtilities, args: [] },
        { name: "MathUtilities", address: deploymentInfo.libraries.MathUtilities, args: [] },
        { name: "StatisticsCore", address: deploymentInfo.libraries.StatisticsCore, args: [] },
        { name: "AnalyticsEngine", address: deploymentInfo.libraries.AnalyticsEngine, args: [] },
        // Oracle Libraries (1)
        { name: "OracleLibraries", address: deploymentInfo.libraries.OracleLibraries, args: [] },
        // Tokens (2)
        { name: "QoraFi", address: deploymentInfo.contracts.qorafiToken, args: ["QoraFi", "QORAFI", treasury.address] },
        { name: "contracts/usq/USQ.sol:USQ", address: deploymentInfo.contracts.usqToken, args: [] },
      ];

      console.log(`📋 Total contracts/libraries to verify: ${contractsToVerify.length}`);

      for (const contract of contractsToVerify) {
        try {
          console.log(`🔍 Verifying ${contract.name} on ${network}...`);
          await hre.run("verify:verify", {
            address: contract.address,
            constructorArguments: contract.args,
          });
          deploymentInfo.verification[contract.name] = "SUCCESS";
          console.log(`✅ ${contract.name} verified on BSCScan`);
        } catch (error) {
          console.log(`⚠️ ${contract.name} verification failed:`, error.message);
          deploymentInfo.verification[contract.name] = error.message;
        }
      }
    }

    // =========================================================================
    // FINALIZE PHASE 1 - COMPLETE SUMMARY
    // =========================================================================
    deploymentInfo.summary = {
      phase: "1-foundation",
      totalLibraries: Object.keys(deploymentInfo.libraries).length,
      totalContracts: Object.keys(deploymentInfo.contracts).length,
      externalContracts: Object.keys(deploymentInfo.externalContracts).length,
      verificationSuccess: Object.values(deploymentInfo.verification).filter(v => v === "SUCCESS").length,
      verificationTotal: Object.keys(deploymentInfo.verification).length,
      errors: deploymentInfo.errors.length,
      complete: true,
      network: network,
      deployer: deployer.address,
      deploymentTime: new Date().toISOString(),
      libraryArchitecture: "modular-individual",
      libraryBreakdown: {
        securityLibraries: 3, // MEVProtection, CircuitBreaker, EmergencySystem
        utilityLibraries: 5,  // SwapUtilities, TokenUtilities, MathUtilities, StatisticsCore, AnalyticsEngine  
        oracleLibraries: 1,   // OracleLibraries
        totalIndividual: 9
      }
    };

    deploymentInfo.timestamp_completed = new Date().toISOString();

    // Save deployment info
    const fileName = `deployment-phase1-${network}-${Date.now()}.json`;
    fs.writeFileSync(fileName, JSON.stringify(deploymentInfo, null, 2));

    console.log("\n🎉 PHASE 1 DEPLOYMENT COMPLETE!");
    console.log("==========================================");
    console.log(`📁 Deployment saved to: ${fileName}`);
    console.log(`📚 Libraries deployed: ${deploymentInfo.summary.totalLibraries} (9 total)`);
    console.log(`📋 Contracts deployed: ${deploymentInfo.summary.totalContracts}`);
    console.log(`🔗 External contracts referenced: ${deploymentInfo.summary.externalContracts}`);
    console.log(`✅ Verifications: ${deploymentInfo.summary.verificationSuccess}/${deploymentInfo.summary.verificationTotal}`);

    console.log("\n🌟 ALL DEPLOYED LIBRARIES (9 total):");
    console.log("🔒 Security Libraries (3):");
    console.log(`   ✅ MEVProtection: ${deploymentInfo.libraries.MEVProtection}`);
    console.log(`   ✅ CircuitBreaker: ${deploymentInfo.libraries.CircuitBreaker}`);
    console.log(`   ✅ EmergencySystem: ${deploymentInfo.libraries.EmergencySystem}`);
    console.log("🛠️ Utility Libraries (5):");
    console.log(`   ✅ SwapUtilities: ${deploymentInfo.libraries.SwapUtilities}`);
    console.log(`   ✅ TokenUtilities: ${deploymentInfo.libraries.TokenUtilities}`);
    console.log(`   ✅ MathUtilities: ${deploymentInfo.libraries.MathUtilities}`);
    console.log(`   ✅ StatisticsCore: ${deploymentInfo.libraries.StatisticsCore}`);
    console.log(`   ✅ AnalyticsEngine: ${deploymentInfo.libraries.AnalyticsEngine}`);
    console.log("🔮 Oracle Libraries (1):");
    console.log(`   ✅ OracleLibraries: ${deploymentInfo.libraries.OracleLibraries}`);

    console.log("\n🌟 Deployed Contracts:");
    Object.entries(deploymentInfo.contracts).forEach(([name, address]) => {
      console.log(`   ✅ ${name}: ${address}`);
    });

    console.log("\n🔗 External Contracts (from .env):");
    Object.entries(deploymentInfo.externalContracts).forEach(([name, address]) => {
      console.log(`   🔗 ${name}: ${address}`);
    });

    console.log("\n📊 Library Architecture Summary:");
    console.log(`   🔒 Security Libraries: ${deploymentInfo.summary.libraryBreakdown.securityLibraries}`);
    console.log(`   🛠️ Utility Libraries: ${deploymentInfo.summary.libraryBreakdown.utilityLibraries}`);
    console.log(`   🔮 Oracle Libraries: ${deploymentInfo.summary.libraryBreakdown.oracleLibraries}`);
    console.log(`   📚 Total Individual Libraries: ${deploymentInfo.summary.libraryBreakdown.totalIndividual}`);

    console.log("\n📝 Next Steps:");
    console.log("   1. Run Phase 2: Core Infrastructure");
    console.log("   2. Update hardhat.config.js with library addresses if needed");
    console.log("   3. Save these addresses for next deployment phase");
    console.log("   4. All 9 libraries are now modular and individually deployable");

  } catch (error) {
    console.error("\n❌ Phase 1 deployment failed:", error);
    deploymentInfo.errors.push({
      phase: "PHASE_1_DEPLOYMENT",
      error: error.message,
      stack: error.stack
    });
    
    const fileName = `deployment-phase1-failed-${network}-${Date.now()}.json`;
    fs.writeFileSync(fileName, JSON.stringify(deploymentInfo, null, 2));
    throw error;
  }
}

main()
  .then(() => {
    console.log("\n🎊 Phase 1 deployment completed successfully!");
    console.log("🚀 Ready for Phase 2: Core Infrastructure!");
    console.log("📚 All 9 libraries deployed in modular architecture!");
    console.log("   🔒 3 Security Libraries");
    console.log("   🛠️ 5 Utility Libraries"); 
    console.log("   🔮 1 Oracle Library");
    process.exit(0);
  })
  .catch((error) => {
    console.error("\n❌ Phase 1 deployment failed:", error.message);
    process.exit(1);
  });
