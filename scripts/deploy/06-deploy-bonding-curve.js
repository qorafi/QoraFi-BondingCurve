// scripts/deploy/06-deploy-bonding-curve.js
const { ethers, network, upgrades } = require("hardhat");
const { saveDeployment, loadDeployment } = require("../utils/deployment-helpers");

async function main() {
  console.log("🚀 Deploying EnhancedBondingCurve to", network.name);

  // Load prerequisite deployments
  const libraries = await loadDeployment(network.name, "libraries");
  const core = await loadDeployment(network.name, "core");
  const advanced = await loadDeployment(network.name, "advanced");

  if (!libraries || !core || !advanced) {
    throw new Error("Prerequisites not deployed. Run previous deployment scripts first.");
  }

  const [deployer] = await ethers.getSigners();
  console.log("📝 Deploying with account:", deployer.address);

  // Get required contract addresses from previous deployments
  const usdtAddress = core.CoreSecurityManager.usdtAddress;
  const qorafiAddress = core.CoreSecurityManager.qorafiAddress;
  const securityManagerAddress = advanced.AdvancedSecurityManager.address;
  const oracleAddress = core.EnhancedOracle.address;
  const ledgerAddress = process.env.LEDGER_ADDRESS || ethers.ZeroAddress; // Use AddressZero for clarity

  // --- FIX: Add a safety check for the router address ---
  const routerAddress = process.env.ROUTER_ADDRESS;
  if (!routerAddress) {
    throw new Error("ROUTER_ADDRESS environment variable not set. This is required for deployment.");
  }
  console.log("✅ Using PancakeSwap Router at:", routerAddress);

  // Deploy EnhancedBondingCurve
  console.log("\n📈 Deploying EnhancedBondingCurve...");

  // --- FIX: Remove the `libraries` object. The compiler has already included them. ---
  // The Hardhat Upgrades plugin handles this automatically from the compiled artifact.
  const EnhancedBondingCurve = await ethers.getContractFactory("EnhancedBondingCurve");

  const enhancedBondingCurve = await upgrades.deployProxy(EnhancedBondingCurve, [
    usdtAddress,
    qorafiAddress,
    routerAddress,
    securityManagerAddress,
    oracleAddress,
    ledgerAddress
  ], {
    initializer: 'initialize',
    kind: 'uups',
    // --- FIX: The `unsafeAllow` flag is no longer needed ---
  });

  await enhancedBondingCurve.waitForDeployment();
  const enhancedBondingCurveAddress = await enhancedBondingCurve.getAddress();
  console.log("✅ EnhancedBondingCurve proxy deployed to:", enhancedBondingCurveAddress);

  // Save deployment info
  const implementationAddress = await upgrades.erc1967.getImplementationAddress(enhancedBondingCurveAddress);
  console.log("✅ Implementation contract deployed to:", implementationAddress);

  const deployments = {
    EnhancedBondingCurve: {
      address: enhancedBondingCurveAddress,
      implementation: implementationAddress,
      deploymentBlock: await ethers.provider.getBlockNumber(),
    },
  };

  await saveDeployment(network.name, "bondingcurve", deployments);

  console.log("\n🎉 EnhancedBondingCurve deployed successfully!");
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
