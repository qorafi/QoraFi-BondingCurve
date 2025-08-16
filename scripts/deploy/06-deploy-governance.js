// scripts/deploy/06-deploy-governance.js
const { ethers } = require("hardhat");
const hre = require("hardhat");
const fs = require("fs");

async function main() {
  console.log("🚀 PHASE 6: Deploying Governance...");
  
  const network = hre.network.name;
  console.log(`🌐 Network: ${network}`);
  
  // Load previous deployment data
  const phase5Files = fs.readdirSync('.').filter(f => f.startsWith('deployment-phase5-') && f.includes(network) && !f.includes('failed'));
  if (phase5Files.length === 0) {
    throw new Error("❌ Phase 5 deployment file not found. Run Phase 5 first.");
  }
  
  const phase5File = phase5Files[phase5Files.length - 1]; // Get latest
  const phase5Data = JSON.parse(fs.readFileSync(phase5File, 'utf8'));
  console.log(`📁 Loading Phase 5 data from: ${phase5File}`);
  
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
    phase: "6-governance",
    timestamp: new Date().toISOString(),
    network: network,
    deployer: deployer.address,
    treasury: treasury.address,
    phase1: phase5Data.phase1,
    phase2: phase5Data.phase2,
    phase3: phase5Data.phase3,
    phase4: phase5Data.phase4,
    phase5: phase5Data,
    contracts: {},
    verification: {},
    errors: []
  };

  try {
    // Get previous addresses
    const qorafiToken = phase5Data.phase1.contracts.qorafiToken;
    const timelock = phase5Data.phase2.contracts.QoraFiTimelock;
    const proofOfLiquidity = phase5Data.contracts.ProofOfLiquidity;
    const lpPair = phase5Data.phase4.contracts.lpPair;
    
    if (!qorafiToken || !timelock || !proofOfLiquidity || !lpPair) {
      throw new Error("❌ Missing required previous phase contracts");
    }

    // =========================================================================
    // STEP 1: DEPLOY QORAFI GOVERNOR
    // =========================================================================
    console.log("\n⚖️ Step 1: Deploying QoraFiGovernor...");
    
    try {
      const QoraFiGovernor = await ethers.getContractFactory("QoraFiGovernor");
      const governor = await QoraFiGovernor.deploy(
        qorafiToken,                                        // token
        timelock,                                           // timelock
        proofOfLiquidity,                                   // stakingContract
        lpPair,                                             // lpPair
        1,                                                  // votingDelay (1 block)
        45818,                                              // votingPeriod (~1 week in blocks)
        ethers.parseEther("1000"),                          // proposalThreshold (1K tokens)
        ethers.parseEther("50000")                          // quorumValue (50K tokens)
      );
      await governor.waitForDeployment();
      deploymentInfo.contracts.QoraFiGovernor = await governor.getAddress();
      console.log("✅ QoraFiGovernor:", deploymentInfo.contracts.QoraFiGovernor);
    } catch (error) {
      console.log("⚠️ QoraFiGovernor deployment failed:", error.message);
      deploymentInfo.contracts.QoraFiGovernor = "DEPLOYMENT_FAILED";
      deploymentInfo.errors.push({
        operation: "Deploy QoraFiGovernor",
        error: error.message
      });
    }

    // =========================================================================
    // STEP 2: CONFIGURATION
    // =========================================================================
    console.log("\n🔧 Step 2: Configuration...");
    
    const configOperations = [
      {
        name: "Setup governance roles in Timelock",
        operation: async () => {
          if (deploymentInfo.contracts.QoraFiGovernor !== "DEPLOYMENT_FAILED") {
            const timelockContract = await ethers.getContractAt("QoraFiTimelock", timelock);
            const proposerRole = await timelockContract.PROPOSER_ROLE();
            
            // Grant proposer role to governor
            await timelockContract.grantRole(proposerRole, deploymentInfo.contracts.QoraFiGovernor);
            console.log("   ✅ Governor granted proposer role");
            
            // Renounce proposer role from deployer
            await timelockContract.renounceRole(proposerRole, deployer.address);
            console.log("   ✅ Deployer renounced proposer role");
          } else {
            throw new Error("QoraFiGovernor not available");
          }
        }
      },
      {
        name: "Create initial governance snapshot",
        operation: async () => {
          if (deploymentInfo.contracts.QoraFiGovernor !== "DEPLOYMENT_FAILED") {
            const governorContract = await ethers.getContractAt("QoraFiGovernor", deploymentInfo.contracts.QoraFiGovernor);
            await governorContract.createLpSnapshot();
            console.log("   ✅ Initial governance snapshot created");
          } else {
            throw new Error("QoraFiGovernor not available");
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
    // STEP 3: VERIFY CONTRACTS
    // =========================================================================
    console.log("\n🔍 Step 3: Verifying Contracts...");
    
    if (network !== "localhost" && network !== "hardhat") {
      const contractsToVerify = [];
      
      if (deploymentInfo.contracts.QoraFiGovernor !== "DEPLOYMENT_FAILED") {
        contractsToVerify.push({
          name: "QoraFiGovernor", 
          address: deploymentInfo.contracts.QoraFiGovernor, 
          args: [
            qorafiToken,
            timelock,
            proofOfLiquidity,
            lpPair,
            1,
            45818,
            ethers.parseEther("1000"),
            ethers.parseEther("50000")
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
    // FINALIZE PHASE 6
    // =========================================================================
    deploymentInfo.summary = {
      phase: "6-governance",
      totalContracts: Object.keys(deploymentInfo.contracts).filter(k => deploymentInfo.contracts[k] !== "DEPLOYMENT_FAILED").length,
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
    const fileName = `deployment-phase6-${network}-${Date.now()}.json`;
    fs.writeFileSync(fileName, JSON.stringify(deploymentInfo, null, 2));

    console.log("\n🎉 PHASE 6 DEPLOYMENT COMPLETE!");
    console.log("==========================================");
    console.log(`📁 Deployment saved to: ${fileName}`);
    console.log(`📋 Contracts deployed: ${deploymentInfo.summary.totalContracts}`);
    console.log(`✅ Configurations: ${deploymentInfo.summary.successfulConfigs}/${deploymentInfo.summary.totalConfigs}`);
    console.log(`✅ Verifications: ${deploymentInfo.summary.verificationSuccess}/${deploymentInfo.summary.verificationTotal}`);

    console.log("\n🌟 Deployed Contracts:");
    Object.entries(deploymentInfo.contracts).forEach(([name, address]) => {
      const status = address.includes("FAILED") ? "❌" : "✅";
      console.log(`   ${status} ${name}: ${address}`);
    });

    if (deploymentInfo.errors.length > 0) {
      console.log("\n⚠️ Deployment Errors:");
      deploymentInfo.errors.forEach((err, i) => {
        console.log(`   ${i + 1}. ${err.operation}: ${err.error}`);
      });
    }

    console.log("\n📝 Next Steps:");
    console.log("   1. Run Phase 7: Tokenomics");
    console.log("   2. Governance system is ready (if deployed successfully)");
    console.log("   3. Timelock controls are in place");

  } catch (error) {
    console.error("\n❌ Phase 6 deployment failed:", error);
    deploymentInfo.errors.push({
      phase: "PHASE_6_DEPLOYMENT",
      error: error.message,
      stack: error.stack
    });
    
    const fileName = `deployment-phase6-failed-${network}-${Date.now()}.json`;
    fs.writeFileSync(fileName, JSON.stringify(deploymentInfo, null, 2));
    throw error;
  }
}

main()
  .then(() => {
    console.log("\n🎊 Phase 6 deployment completed successfully!");
    console.log("🚀 Ready for Phase 7: Tokenomics!");
    process.exit(0);
  })
  .catch((error) => {
    console.error("\n❌ Phase 6 deployment failed:", error.message);
    process.exit(1);
  });