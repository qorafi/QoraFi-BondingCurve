// scripts/deploy/05-deploy-staking.js
const { ethers } = require("hardhat");
const hre = require("hardhat");
const fs = require("fs");

async function main() {
  console.log("🚀 PHASE 5: Deploying Staking & Rewards...");
  
  const network = hre.network.name;
  console.log(`🌐 Network: ${network}`);
  
  // Load previous deployment data
  const phase4Files = fs.readdirSync('.').filter(f => f.startsWith('deployment-phase4-') && f.includes(network) && !f.includes('failed'));
  if (phase4Files.length === 0) {
    throw new Error("❌ Phase 4 deployment file not found. Run Phase 4 first.");
  }
  
  const phase4File = phase4Files[phase4Files.length - 1]; // Get latest
  const phase4Data = JSON.parse(fs.readFileSync(phase4File, 'utf8'));
  console.log(`📁 Loading Phase 4 data from: ${phase4File}`);
  
  const signers = await ethers.getSigners();
  const deployer = signers[0];
  const treasury = deployer;
  
  console.log(`👤 Deployer: ${deployer.address}`);
  console.log(`💰 Treasury: ${treasury.address}`);
  
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`💵 Deployer Balance: ${ethers.formatEther(balance)} BNB`);
  
  if (balance < ethers.parseEther("0.08")) {
    throw new Error("❌ Insufficient BNB for deployment. Need at least 0.08 BNB");
  }

  const deploymentInfo = {
    phase: "5-staking-rewards",
    timestamp: new Date().toISOString(),
    network: network,
    deployer: deployer.address,
    treasury: treasury.address,
    phase1: phase4Data.phase1,
    phase2: phase4Data.phase2,
    phase3: phase4Data.phase3,
    phase4: phase4Data,
    contracts: {},
    verification: {},
    errors: []
  };

  try {
    // Get previous addresses
    const qorafiToken = phase4Data.phase1.contracts.qorafiToken;
    const advancedSecurityManager = phase4Data.phase3.contracts.AdvancedSecurityManager;
    const lpPair = phase4Data.contracts.lpPair;
    
    if (!qorafiToken || !advancedSecurityManager || !lpPair) {
      throw new Error("❌ Missing required previous phase contracts");
    }

    // =========================================================================
    // STEP 1: DEPLOY PROOF OF LIQUIDITY
    // =========================================================================
    console.log("\n🎯 Step 1: Deploying ProofOfLiquidity...");
    
    const ProofOfLiquidity = await ethers.getContractFactory("ProofOfLiquidity");
    const proofOfLiquidity = await ProofOfLiquidity.deploy(lpPair);
    await proofOfLiquidity.waitForDeployment();
    deploymentInfo.contracts.ProofOfLiquidity = await proofOfLiquidity.getAddress();
    console.log("✅ ProofOfLiquidity:", deploymentInfo.contracts.ProofOfLiquidity);

    // =========================================================================
    // STEP 2: DEPLOY REWARD ENGINE
    // =========================================================================
    console.log("\n🎁 Step 2: Deploying RewardEngine...");
    
    const RewardEngine = await ethers.getContractFactory("RewardEngine");
    const rewardEngine = await RewardEngine.deploy(
      qorafiToken,                                        // _qorafiTokenAddress
      lpPair,                                             // _stakingTokenAddress
      phase4Data.phase3.contracts.EnhancedOracle,        // _oracleAddress
      deploymentInfo.contracts.ProofOfLiquidity,         // _polVaultAddress
      treasury.address                                    // _treasuryAddress
    );
    await rewardEngine.waitForDeployment();
    deploymentInfo.contracts.RewardEngine = await rewardEngine.getAddress();
    console.log("✅ RewardEngine:", deploymentInfo.contracts.RewardEngine);

    // =========================================================================
    // STEP 3: DEPLOY DELEGATOR DISTRIBUTOR
    // =========================================================================
    console.log("\n🎁 Step 3: Deploying DelegatorDistributor...");
    
    const DelegatorDistributor = await ethers.getContractFactory("DelegatorDistributor");
    const delegatorDistributor = await DelegatorDistributor.deploy(
      qorafiToken,
      treasury.address
    );
    await delegatorDistributor.waitForDeployment();
    deploymentInfo.contracts.DelegatorDistributor = await delegatorDistributor.getAddress();
    console.log("✅ DelegatorDistributor:", deploymentInfo.contracts.DelegatorDistributor);

    // =========================================================================
    // STEP 4: DEPLOY POOL REWARD DISTRIBUTOR
    // =========================================================================
    console.log("\n🏊 Step 4: Deploying PoolRewardDistributor...");
    
    const PoolRewardDistributor = await ethers.getContractFactory("PoolRewardDistributor");
    const poolRewardDistributor = await PoolRewardDistributor.deploy(
      qorafiToken,                                        // _qorafiTokenAddress
      deploymentInfo.contracts.ProofOfLiquidity,         // _proofOfLiquidityAddress
      phase4Data.contracts.USQEngine,                     // _usqEngineAddress
      treasury.address                                    // _initialTreasuryAddress
    );
    await poolRewardDistributor.waitForDeployment();
    deploymentInfo.contracts.PoolRewardDistributor = await poolRewardDistributor.getAddress();
    console.log("✅ PoolRewardDistributor:", deploymentInfo.contracts.PoolRewardDistributor);

    // =========================================================================
    // STEP 5: CONFIGURATION
    // =========================================================================
    console.log("\n🔧 Step 5: Configuration...");
    
    const configOperations = [
      {
        name: "Link RewardEngine to ProofOfLiquidity",
        operation: async () => {
          await proofOfLiquidity.setRewardEngine(deploymentInfo.contracts.RewardEngine);
        }
      },
      {
        name: "Update PoolRewardDistributor in DelegatorNodeRewardsLedger",
        operation: async () => {
          const ledger = await ethers.getContractAt("DelegatorNodeRewardsLedger", phase4Data.contracts.DelegatorNodeRewardsLedger);
          await ledger.setPoolRewardDistributor(deploymentInfo.contracts.PoolRewardDistributor);
        }
      },
      {
        name: "Set authorized funder in PoolRewardDistributor",
        operation: async () => {
          await poolRewardDistributor.setAuthorizedFunder(phase4Data.contracts.DelegatorNodeRewardsLedger);
        }
      },
      {
        name: "Grant minter role to DelegatorDistributor",
        operation: async () => {
          const qorafi = await ethers.getContractAt("QoraFi", qorafiToken);
          const minterRole = await qorafi.MINTER_ROLE();
          await qorafi.grantRole(minterRole, deploymentInfo.contracts.DelegatorDistributor);
        }
      },
      {
        name: "Grant minter role to PoolRewardDistributor",
        operation: async () => {
          const qorafi = await ethers.getContractAt("QoraFi", qorafiToken);
          const minterRole = await qorafi.MINTER_ROLE();
          await qorafi.grantRole(minterRole, deploymentInfo.contracts.PoolRewardDistributor);
        }
      },
      {
        name: "Grant minter role to RewardEngine",
        operation: async () => {
          const qorafi = await ethers.getContractAt("QoraFi", qorafiToken);
          const minterRole = await qorafi.MINTER_ROLE();
          await qorafi.grantRole(minterRole, deploymentInfo.contracts.RewardEngine);
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
    // STEP 6: VERIFY CONTRACTS
    // =========================================================================
    console.log("\n🔍 Step 6: Verifying Contracts...");
    
    if (network !== "localhost" && network !== "hardhat") {
      const contractsToVerify = [
        { 
          name: "ProofOfLiquidity", 
          address: deploymentInfo.contracts.ProofOfLiquidity, 
          args: [lpPair] 
        },
        { 
          name: "RewardEngine", 
          address: deploymentInfo.contracts.RewardEngine, 
          args: [
            qorafiToken,
            lpPair,
            phase4Data.phase3.contracts.EnhancedOracle,
            deploymentInfo.contracts.ProofOfLiquidity,
            treasury.address
          ] 
        },
        { 
          name: "DelegatorDistributor", 
          address: deploymentInfo.contracts.DelegatorDistributor, 
          args: [qorafiToken, treasury.address] 
        },
        { 
          name: "PoolRewardDistributor", 
          address: deploymentInfo.contracts.PoolRewardDistributor, 
          args: [
            qorafiToken,
            deploymentInfo.contracts.ProofOfLiquidity,
            phase4Data.contracts.USQEngine,
            treasury.address
          ] 
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
    // FINALIZE PHASE 5
    // =========================================================================
    deploymentInfo.summary = {
      phase: "5-staking-rewards",
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
    const fileName = `deployment-phase5-${network}-${Date.now()}.json`;
    fs.writeFileSync(fileName, JSON.stringify(deploymentInfo, null, 2));

    console.log("\n🎉 PHASE 5 DEPLOYMENT COMPLETE!");
    console.log("==========================================");
    console.log(`📁 Deployment saved to: ${fileName}`);
    console.log(`📋 Contracts deployed: ${deploymentInfo.summary.totalContracts}`);
    console.log(`✅ Configurations: ${deploymentInfo.summary.successfulConfigs}/${deploymentInfo.summary.totalConfigs}`);
    console.log(`✅ Verifications: ${deploymentInfo.summary.verificationSuccess}/${deploymentInfo.summary.verificationTotal}`);

    console.log("\n🌟 Deployed Contracts:");
    Object.entries(deploymentInfo.contracts).forEach(([name, address]) => {
      console.log(`   ✅ ${name}: ${address}`);
    });

    console.log("\n🔗 Key Contract Addresses:");
    console.log(`   📍 Proof of Liquidity: ${deploymentInfo.contracts.ProofOfLiquidity}`);
    console.log(`   📍 Reward Engine: ${deploymentInfo.contracts.RewardEngine}`);
    console.log(`   📍 Pool Reward Distributor: ${deploymentInfo.contracts.PoolRewardDistributor}`);

    console.log("\n📝 Next Steps:");
    console.log("   1. Run Phase 6: Governance");
    console.log("   2. Staking system is ready for use");
    console.log("   3. Reward distribution is configured");

  } catch (error) {
    console.error("\n❌ Phase 5 deployment failed:", error);
    deploymentInfo.errors.push({
      phase: "PHASE_5_DEPLOYMENT",
      error: error.message,
      stack: error.stack
    });
    
    const fileName = `deployment-phase5-failed-${network}-${Date.now()}.json`;
    fs.writeFileSync(fileName, JSON.stringify(deploymentInfo, null, 2));
    throw error;
  }
}

main()
  .then(() => {
    console.log("\n🎊 Phase 5 deployment completed successfully!");
    console.log("🚀 Ready for Phase 6: Governance!");
    process.exit(0);
  })
  .catch((error) => {
    console.error("\n❌ Phase 5 deployment failed:", error.message);
    process.exit(1);
  });