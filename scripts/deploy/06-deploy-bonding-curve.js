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
  const routerAddress = process.env.ROUTER_ADDRESS || "0x0000000000000000000000000000000000000003"; // Add your router address
  const securityManagerAddress = advanced.AdvancedSecurityManager.address;
  const oracleAddress = core.EnhancedOracle.address;
  const ledgerAddress = process.env.LEDGER_ADDRESS || ethers.constants.AddressZero; // Optional: Add a ledger address if you have one

  // Deploy EnhancedBondingCurve
  console.log("\n📈 Deploying EnhancedBondingCurve...");
  const EnhancedBondingCurve = await ethers.getContractFactory("EnhancedBondingCurve", {
    libraries: {
      SwapLib: libraries.UtilityLibraries.address,
      LiquidityLib: libraries.UtilityLibraries.address,
      TokenHelperLib: libraries.UtilityLibraries.address,
      ValidationLib: libraries.SecurityLibraries.address,
      StatisticsLib: libraries.UtilityLibraries.address
    },
  });

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
    unsafeAllow: ['external-library-linking']
  });

  await enhancedBondingCurve.waitForDeployment();
  const enhancedBondingCurveAddress = await enhancedBondingCurve.getAddress();
  console.log("✅ EnhancedBondingCurve deployed to:", enhancedBondingCurveAddress);

  // Save deployment info
  const deployments = {
    EnhancedBondingCurve: {
      address: enhancedBondingCurveAddress,
      implementation: await upgrades.erc1967.getImplementationAddress(enhancedBondingCurveAddress),
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