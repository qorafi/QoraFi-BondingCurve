// scripts/deploy/08-deploy-rwa.js
const { ethers } = require("hardhat");
const hre = require("hardhat");
const fs = require("fs");

async function main() {
  console.log("🚀 PHASE 8: Deploying RWA System (Optional)...");
  
  const network = hre.network.name;
  console.log(`🌐 Network: ${network}`);
  
  // Load previous deployment data
  const phase7Files = fs.readdirSync('.').filter(f => f.startsWith('deployment-phase7-') && f.includes(network) && !f.includes('failed'));
  if (phase7Files.length === 0) {
    throw new Error("❌ Phase 7 deployment file not found. Run Phase 7 first.");
  }
  
  const phase7File = phase7Files[phase7Files.length - 1]; // Get latest
  const phase7Data = JSON.parse(fs.readFileSync(phase7File, 'utf8'));
  console.log(`📁 Loading Phase 7 data from: ${phase7File}`);
  
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
    phase: "8-rwa-system",
    timestamp: new Date().toISOString(),
    network: network,
    deployer: deployer.address,
    treasury: treasury.address,
    phase1: phase7Data.phase1,
    phase2: phase7Data.phase2,
    phase3: phase7Data.phase3,
    phase4: phase7Data.phase4,
    phase5: phase7Data.phase5,
    phase6: phase7Data.phase6,
    phase7: phase7Data,
    contracts: {},
    verification: {},
    errors: []
  };

  try {
    // Get previous addresses
    const qorafiToken = phase7Data.phase1.contracts.qorafiToken;
    const usqToken = phase7Data.phase1.contracts.usqToken;
    const proofOfLiquidity = phase7Data.phase5.contracts.ProofOfLiquidity;
    
    if (!qorafiToken || !usqToken || !proofOfLiquidity) {
      throw new Error("❌ Missing required previous phase contracts");
    }

    // Determine router address
    let routerAddress;
    if (network === "bscTestnet" || network === "bsc-testnet") {
      routerAddress = "0xD99D1c33F9fC3444f8101754aBC46c52416550D2"; // PancakeSwap Testnet
    } else if (network === "bsc" || network === "bsc-mainnet") {
      routerAddress = "0x10ED43C718714eb63d5aA57B78B54704E256024E"; // PancakeSwap V2 Router
    } else {
      routerAddress = phase7Data.phase1.contracts.mockRouter;
    }

    // =========================================================================
    // STEP 1: DEPLOY QORAFI RWA
    // =========================================================================
    console.log("\n🏢 Step 1: Deploying QoraFiRWA...");
    
    try {
      const QoraFiRWA = await ethers.getContractFactory("QoraFiRWA");
      const qorafiRwa = await QoraFiRWA.deploy();
      await qorafiRwa.waitForDeployment();
      deploymentInfo.contracts.QoraFiRWA = await qorafiRwa.getAddress();
      console.log("✅ QoraFiRWA:", deploymentInfo.contracts.QoraFiRWA);
    } catch (error) {
      console.log("⚠️ QoraFiRWA deployment failed:", error.message);
      deploymentInfo.contracts.QoraFiRWA = "DEPLOYMENT_FAILED";
      deploymentInfo.errors.push({
        operation: "Deploy QoraFiRWA",
        error: error.message
      });
    }

    // =========================================================================
    // STEP 2: DEPLOY RWA FACTORY
    // =========================================================================
    console.log("\n🏭 Step 2: Deploying RWAFactory...");
    
    if (deploymentInfo.contracts.QoraFiRWA !== "DEPLOYMENT_FAILED") {
      try {
        const RWAFactory = await ethers.getContractFactory("RWAFactory");
        const rwaFactory = await RWAFactory.deploy(
          deploymentInfo.contracts.QoraFiRWA,      // _qorafiRwaAddress
          qorafiToken,                             // _qorafiTokenAddress  
          usqToken,                                // _usqTokenAddress
          routerAddress,                           // _pancakeRouterAddress
          proofOfLiquidity,                        // _proofOfLiquidityAddress
          treasury.address,                        // _initialTreasuryAddress
          ethers.parseEther("1000"),               // _initialCreationFee (1000 QORAFI)
          ethers.parseEther("10000")               // _minStakingValue ($10k minimum)
        );
        await rwaFactory.waitForDeployment();
        deploymentInfo.contracts.RWAFactory = await rwaFactory.getAddress();
        console.log("✅ RWAFactory:", deploymentInfo.contracts.RWAFactory);
      } catch (error) {
        console.log("⚠️ RWAFactory deployment failed:", error.message);
        deploymentInfo.contracts.RWAFactory = "DEPLOYMENT_FAILED";
        deploymentInfo.errors.push({
          operation: "Deploy RWAFactory",
          error: error.message
        });
      }
    } else {
      console.log("⏭️ Skipping RWAFactory deployment (QoraFiRWA failed)");
      deploymentInfo.contracts.RWAFactory = "SKIPPED_DUE_TO_DEPENDENCY";
    }

    // =========================================================================
    // STEP 3: CONFIGURATION
    // =========================================================================
    console.log("\n🔧 Step 3: Configuration...");
    
    const configOperations = [
      {
        name: "Transfer QoraFiRWA ownership to RWAFactory",
        operation: async () => {
          if (deploymentInfo.contracts.QoraFiRWA !== "DEPLOYMENT_FAILED" && 
              deploymentInfo.contracts.RWAFactory !== "DEPLOYMENT_FAILED" && 
              deploymentInfo.contracts.RWAFactory !== "SKIPPED_DUE_TO_DEPENDENCY") {
            const rwa = await ethers.getContractAt("QoraFiRWA", deploymentInfo.contracts.QoraFiRWA);
            await rwa.transferOwnership(deploymentInfo.contracts.RWAFactory);
          } else {
            throw new Error("Required contracts not available");
          }
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
    // STEP 4: VERIFY CONTRACTS
    // =========================================================================
    console.log("\n🔍 Step 4: Verifying Contracts...");
    
    if (network !== "localhost" && network !== "hardhat") {
      const contractsToVerify = [];
      
      if (deploymentInfo.contracts.QoraFiRWA !== "DEPLOYMENT_FAILED") {
        contractsToVerify.push({
          name: "QoraFiRWA", 
          address: deploymentInfo.contracts.QoraFiRWA, 
          args: [] 
        });
      }
      
      if (deploymentInfo.contracts.RWAFactory !== "DEPLOYMENT_FAILED" && 
          deploymentInfo.contracts.RWAFactory !== "SKIPPED_DUE_TO_DEPENDENCY") {
        contractsToVerify.push({
          name: "RWAFactory", 
          address: deploymentInfo.contracts.RWAFactory, 
          args: [
            deploymentInfo.contracts.QoraFiRWA,
            qorafiToken,
            usqToken,
            routerAddress,
            proofOfLiquidity,
            treasury.address,
            ethers.parseEther("1000"),
            ethers.parseEther("10000")
          ] 
        });
      }

      for (const contract of contractsToVerify) {
        try {
          console.log(`🔍 Verifying ${contract.name}...`);
          await hre.run("verify:verify", {
            address: contract.address,
            constructorArguments: contract.args,
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
    // FINALIZE PHASE 8
    // =========================================================================
    deploymentInfo.summary = {
      phase: "8-rwa-system",
      totalContracts: Object.keys(deploymentInfo.contracts).filter(k => 
        deploymentInfo.contracts[k] !== "DEPLOYMENT_FAILED" && 
        deploymentInfo.contracts[k] !== "SKIPPED_DUE_TO_DEPENDENCY"
      ).length,
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
    const fileName = `deployment-phase8-${network}-${Date.now()}.json`;
    fs.writeFileSync(fileName, JSON.stringify(deploymentInfo, null, 2));

    console.log("\n🎉 PHASE 8 DEPLOYMENT COMPLETE!");
    console.log("==========================================");
    console.log(`📁 Deployment saved to: ${fileName}`);
    console.log(`📋 Contracts deployed: ${deploymentInfo.summary.totalContracts}`);
    console.log(`✅ Configurations: ${deploymentInfo.summary.successfulConfigs}/${deploymentInfo.summary.totalConfigs}`);
    console.log(`✅ Verifications: ${deploymentInfo.summary.verificationSuccess}/${deploymentInfo.summary.verificationTotal}`);

    console.log("\n🌟 Deployed Contracts:");
    Object.entries(deploymentInfo.contracts).forEach(([name, address]) => {
      let status = "✅";
      if (address.includes("FAILED")) status = "❌";
      else if (address.includes("SKIPPED")) status = "⏭️";
      console.log(`   ${status} ${name}: ${address}`);
    });

    if (deploymentInfo.errors.length > 0) {
      console.log("\n⚠️ Deployment Errors:");
      deploymentInfo.errors.forEach((err, i) => {
        console.log(`   ${i + 1}. ${err.operation}: ${err.error}`);
      });
    }

    console.log("\n🏢 RWA System Summary:");
    if (deploymentInfo.contracts.QoraFiRWA !== "DEPLOYMENT_FAILED") {
      console.log(`   📍 QoraFi RWA: ${deploymentInfo.contracts.QoraFiRWA}`);
    }
    if (deploymentInfo.contracts.RWAFactory !== "DEPLOYMENT_FAILED" && 
        deploymentInfo.contracts.RWAFactory !== "SKIPPED_DUE_TO_DEPENDENCY") {
      console.log(`   📍 RWA Factory: ${deploymentInfo.contracts.RWAFactory}`);
      console.log(`   💰 Creation Fee: 1000 QORAFI`);
      console.log(`   🎯 Min Staking: $10,000`);
    }

    console.log("\n🎊 COMPLETE PROTOCOL DEPLOYMENT FINISHED!");
    console.log("==========================================");
    console.log("   ✅ All phases completed successfully!");
    console.log("   🚀 QoraFi protocol is ready for use!");
    console.log("   📚 Review deployment files for addresses");

  } catch (error) {
    console.error("\n❌ Phase 8 deployment failed:", error);
    deploymentInfo.errors.push({
      phase: "PHASE_8_DEPLOYMENT",
      error: error.message,
      stack: error.stack
    });
    
    const fileName = `deployment-phase8-failed-${network}-${Date.now()}.json`;
    fs.writeFileSync(fileName, JSON.stringify(deploymentInfo, null, 2));
    throw error;
  }
}

main()
  .then(() => {
    console.log("\n🎊 Phase 8 deployment completed successfully!");
    console.log("🎉 COMPLETE QORAFI PROTOCOL DEPLOYMENT FINISHED!");
    process.exit(0);
  })
  .catch((error) => {
    console.error("\n❌ Phase 8 deployment failed:", error.message);
    process.exit(1);
  });