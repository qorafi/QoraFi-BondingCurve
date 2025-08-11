// scripts/deploy/03-deploy-advanced.js
const { ethers, network, upgrades } = require("hardhat");
const { saveDeployment, loadDeployment } = require("../utils/deployment-helpers");

async function main() {
  console.log("🚀 Deploying Advanced Contracts to", network.name);
  
  // Load previous deployments
  const libraries = await loadDeployment(network.name, "libraries");
  const core = await loadDeployment(network.name, "core");
  
  if (!libraries || !core) {
    throw new Error("Prerequisites not deployed. Run previous deployment scripts first");
  }

  const [deployer, governance, treasury] = await ethers.getSigners();
  console.log("📝 Deploying with account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("💰 Account balance:", ethers.formatEther(balance), "ETH");

  // Contract addresses
  const usdtAddress = process.env.USDT_ADDRESS || "0x0000000000000000000000000000000000000001";
  const qorafiAddress = process.env.QORAFI_ADDRESS || "0x0000000000000000000000000000000000000002";

  // Deploy AdvancedSecurityManager (inherits from CoreSecurityManager)
  console.log("\n🛡️ Deploying AdvancedSecurityManager...");
  const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager", {
    libraries: {
      MEVLib: libraries.SecurityLibraries.address,
      CircuitBreakerLib: libraries.SecurityLibraries.address,
      EmergencyLib: libraries.SecurityLibraries.address,
      ValidationLib: libraries.SecurityLibraries.address,
    },
  });
  
  const advancedSecurityManager = await upgrades.deployProxy(AdvancedSecurityManager, [
    usdtAddress,
    qorafiAddress,
    treasury.address
  ], {
    initializer: 'initialize',
    kind: 'uups',
    unsafeAllow: ['external-library-linking']
  });
  
  await advancedSecurityManager.waitForDeployment();
  const advancedSecurityManagerAddress = await advancedSecurityManager.getAddress();
  console.log("✅ AdvancedSecurityManager deployed to:", advancedSecurityManagerAddress);

  // Initialize advanced features
  console.log("⚙️ Initializing advanced features...");
  try {
    await advancedSecurityManager.initializeAdvanced(
      24 * 60 * 60, // 24 hours emergency delay
      1, // max 1 update per block for new token
      3  // 3 block flash loan detection window
    );
    console.log("✅ Advanced features initialized");
  } catch (error) {
    console.log("⚠️ Advanced initialization failed (might already be initialized):", error.message);
  }

  // Set up initial risk parameters
  console.log("⚙️ Setting up risk parameters...");
  try {
    await advancedSecurityManager.setAdvancedParameters(
      8000, // 80% high risk threshold
      1 * 60 * 60, // 1 hour suspicious activity window
      10 // max 10 transactions per window
    );
    console.log("✅ Risk parameters configured");
  } catch (error) {
    console.log("⚠️ Risk parameter setup failed:", error.message);
  }

  // Set up flash loan protection
  console.log("⚙️ Setting up flash loan protection...");
  try {
    await advancedSecurityManager.setFlashLoanProtection(
      1, // max 1 update per block
      3  // 3 block detection window
    );
    console.log("✅ Flash loan protection configured");
  } catch (error) {
    console.log("⚠️ Flash loan protection setup failed:", error.message);
  }

  // Save deployment info
  const deployments = {
    AdvancedSecurityManager: {
      address: advancedSecurityManagerAddress,
      implementation: await upgrades.erc1967.getImplementationAddress(advancedSecurityManagerAddress),
      deploymentBlock: await ethers.provider.getBlockNumber(),
      deployer: deployer.address,
    },
  };

  await saveDeployment(network.name, "advanced", deployments);
  
  console.log("\n🎉 Advanced contracts deployed successfully!");
  console.log("📄 Deployment info saved to deployments/" + network.name + "/advanced.json");
  
  // Display deployment summary
  console.log("\n📋 Advanced Deployment Summary:");
  console.log("=" * 50);
  console.log("AdvancedSecurityManager:", advancedSecurityManagerAddress);
  console.log("Implementation:", deployments.AdvancedSecurityManager.implementation);
  console.log("Block Number:", deployments.AdvancedSecurityManager.deploymentBlock);
  console.log("=" * 50);
  
  return deployments;
}

if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error("❌ Deployment failed:", error);
      process.exit(1);
    });
}

module.exports = main;