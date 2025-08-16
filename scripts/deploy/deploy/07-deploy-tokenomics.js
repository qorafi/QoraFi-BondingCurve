// scripts/deploy/07-deploy-tokenomics.js
const { ethers } = require("hardhat");
const hre = require("hardhat");
const fs = require("fs");

async function main() {
  console.log("🚀 PHASE 7: Deploying Tokenomics...");
  
  const network = hre.network.name;
  console.log(`🌐 Network: ${network}`);
  
  // Load previous deployment data
  const phase6Files = fs.readdirSync('.').filter(f => f.startsWith('deployment-phase6-') && f.includes(network) && !f.includes('failed'));
  if (phase6Files.length === 0) {
    throw new Error("❌ Phase 6 deployment file not found. Run Phase 6 first.");
  }
  
  const phase6File = phase6Files[phase6Files.length - 1]; // Get latest
  const phase6Data = JSON.parse(fs.readFileSync(phase6File, 'utf8'));
  console.log(`📁 Loading Phase 6 data from: ${phase6File}`);
  
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
    phase: "7-tokenomics",
    timestamp: new Date().toISOString(),
    network: network,
    deployer: deployer.address,
    treasury: treasury.address,
    phase1: phase6Data.phase1,
    phase2: phase6Data.phase2,
    phase3: phase6Data.phase3,
    phase4: phase6Data.phase4,
    phase5: phase6Data.phase5,
    phase6: phase6Data,
    contracts: {},
    verification: {},
    errors: []
  };

  try {
    // Get previous addresses
    const qorafiToken = phase6Data.phase1.contracts.qorafiToken;
    
    if (!qorafiToken) {
      throw new Error("❌ Missing required QoraFi token address");
    }

    // =========================================================================
    // STEP 1: DEPLOY VESTING CONTRACT
    // =========================================================================
    console.log("\n📅 Step 1: Deploying QoraFiVesting...");
    
    const vestingStartTime = Math.floor(Date.now() / 1000) + (7 * 24 * 60 * 60); // Start in 1 week
    const totalVestingAmount = ethers.parseEther("100000000"); // 100M tokens for vesting
    
    const QoraFiVesting = await ethers.getContractFactory("QoraFiVesting");
    const qorafiVesting = await QoraFiVesting.deploy(
      qorafiToken,
      vestingStartTime,
      totalVestingAmount,
      treasury.address
    );
    await qorafiVesting.waitForDeployment();
    deploymentInfo.contracts.QoraFiVesting = await qorafiVesting.getAddress();
    console.log("✅ QoraFiVesting:", deploymentInfo.contracts.QoraFiVesting);

    // =========================================================================
    // STEP 2: DEPLOY AIRDROP CONTRACT
    // =========================================================================
    console.log("\n🪂 Step 2: Deploying QoraFiAirdrop...");
    
    const QoraFiAirdrop = await ethers.getContractFactory("QoraFiAirdrop");
    const qorafiAirdrop = await QoraFiAirdrop.deploy(qorafiToken);
    await qorafiAirdrop.waitForDeployment();
    deploymentInfo.contracts.QoraFiAirdrop = await qorafiAirdrop.getAddress();
    console.log("✅ QoraFiAirdrop:", deploymentInfo.contracts.QoraFiAirdrop);

    // =========================================================================
    // STEP 3: EXECUTE INITIAL MINTING
    // =========================================================================
    console.log("\n🪙 Step 3: Executing Initial Minting...");
    
    const configOperations = [
      {
        name: "Execute initial minting to vesting contract",
        operation: async () => {
          const qorafi = await ethers.getContractAt("QoraFi", qorafiToken);
          await qorafi.executeInitialMinting(deploymentInfo.contracts.QoraFiVesting);
        }
      },
      {
        name: "Update QoraFi fee destinations with airdrop contract",
        operation: async () => {
          const qorafi = await ethers.getContractAt("QoraFi", qorafiToken);
          await qorafi.setFeeDestinations(
            phase6Data.phase4.contracts.USQEngine,
            deployer.address, // Development wallet
            deploymentInfo.contracts.QoraFiAirdrop
          );
        }
      },
      {
        name: "Grant minter role to QoraFiAirdrop",
        operation: async () => {
          const qorafi = await ethers.getContractAt("QoraFi", qorafiToken);
          const minterRole = await qorafi.MINTER_ROLE();
          await qorafi.grantRole(minterRole, deploymentInfo.contracts.QoraFiAirdrop);
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
      const contractsToVerify = [
        { 
          name: "QoraFiVesting", 
          address: deploymentInfo.contracts.QoraFiVesting, 
          args: [
            qorafiToken,
            vestingStartTime,
            totalVestingAmount,
            treasury.address
          ] 
        },
        { 
          name: "QoraFiAirdrop", 
          address: deploymentInfo.contracts.QoraFiAirdrop, 
          args: [qorafiToken] 
        }
      ];

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
    // FINALIZE PHASE 7
    // =========================================================================
    deploymentInfo.summary = {
      phase: "7-tokenomics",
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
      vestingStartTime: vestingStartTime,
      totalVestingAmount: totalVestingAmount.toString()
    };

    deploymentInfo.timestamp_completed = new Date().toISOString();

    // Save deployment info
    const fileName = `deployment-phase7-${network}-${Date.now()}.json`;
    fs.writeFileSync(fileName, JSON.stringify(deploymentInfo, null, 2));

    console.log("\n🎉 PHASE 7 DEPLOYMENT COMPLETE!");
    console.log("==========================================");
    console.log(`📁 Deployment saved to: ${fileName}`);
    console.log(`📋 Contracts deployed: ${deploymentInfo.summary.totalContracts}`);
    console.log(`✅ Configurations: ${deploymentInfo.summary.successfulConfigs}/${deploymentInfo.summary.totalConfigs}`);
    console.log(`✅ Verifications: ${deploymentInfo.summary.verificationSuccess}/${deploymentInfo.summary.verificationTotal}`);

    console.log("\n🌟 Deployed Contracts:");
    Object.entries(deploymentInfo.contracts).forEach(([name, address]) => {
      console.log(`   ✅ ${name}: ${address}`);
    });

    console.log("\n📊 Tokenomics Summary:");
    console.log(`   📅 Vesting Start: ${new Date(vestingStartTime * 1000).toLocaleString()}`);
    console.log(`   💰 Total Vesting: ${ethers.formatEther(totalVestingAmount)} QORAFI`);
    console.log(`   🪂 Airdrop Contract: ${deploymentInfo.contracts.QoraFiAirdrop}`);

    console.log("\n📝 Next Steps:");
    console.log("   1. Optional: Run Phase 8: RWA System");
    console.log("   2. Core protocol deployment is complete!");
    console.log("   3. Initial minting has been executed");
    console.log("   4. Vesting and airdrop systems are ready");

  } catch (error) {
    console.error("\n❌ Phase 7 deployment failed:", error);
    deploymentInfo.errors.push({
      phase: "PHASE_7_DEPLOYMENT",
      error: error.message,
      stack: error.stack
    });
    
    const fileName = `deployment-phase7-failed-${network}-${Date.now()}.json`;
    fs.writeFileSync(fileName, JSON.stringify(deploymentInfo, null, 2));
    throw error;
  }
}

main()
  .then(() => {
    console.log("\n🎊 Phase 7 deployment completed successfully!");
    console.log("🚀 Core protocol deployment complete! Optionally run Phase 8 for RWA system.");
    process.exit(0);
  })
  .catch((error) => {
    console.error("\n❌ Phase 7 deployment failed:", error.message);
    process.exit(1);
  });