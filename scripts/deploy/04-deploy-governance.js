// scripts/deploy/04-deploy-governance.js
const { ethers, network, upgrades } = require("hardhat");
const { saveDeployment, loadDeployment } = require("../utils/deployment-helpers");

async function main() {
  console.log("🚀 Deploying Governance Contracts to", network.name);
  
  // Load library addresses
  const libraries = await loadDeployment(network.name, "libraries");
  if (!libraries) {
    throw new Error("Libraries not deployed. Run 01-deploy-libraries.js first");
  }

  const [deployer, governance, treasury] = await ethers.getSigners();
  console.log("📝 Deploying with account:", deployer.address);

  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("💰 Account balance:", ethers.formatEther(balance), "ETH");

  // Deploy SecurityGovernance
  console.log("\n🏛️ Deploying SecurityGovernance...");
  const SecurityGovernance = await ethers.getContractFactory("SecurityGovernance", {
    libraries: {
      EmergencyLib: libraries.SecurityLibraries.address,
      ValidationLib: libraries.SecurityLibraries.address,
    },
  });
  
  const securityGovernance = await upgrades.deployProxy(SecurityGovernance, [
    treasury.address,
    24 * 60 * 60, // 24 hours emergency transaction delay
    2 // require 2 signatures for governance actions
  ], {
    initializer: 'initialize',
    kind: 'uups',
    unsafeAllow: ['external-library-linking']
  });
  
  await securityGovernance.waitForDeployment();
  const securityGovernanceAddress = await securityGovernance.getAddress();
  console.log("✅ SecurityGovernance deployed to:", securityGovernanceAddress);

  // Grant additional roles
  console.log("⚙️ Setting up governance roles...");
  try {
    const PARAM_MANAGER_ROLE = await securityGovernance.PARAM_MANAGER_ROLE();
    const EMERGENCY_ROLE = await securityGovernance.EMERGENCY_ROLE();
    const UPGRADE_ROLE = await securityGovernance.UPGRADE_ROLE();
    
    // Grant roles to governance address (if different from deployer)
    if (governance.address !== deployer.address) {
      await securityGovernance.grantRole(PARAM_MANAGER_ROLE, governance.address);
      await securityGovernance.grantRole(EMERGENCY_ROLE, governance.address);
      await securityGovernance.grantRole(UPGRADE_ROLE, governance.address);
      console.log("✅ Roles granted to governance address:", governance.address);
    }

    // Also grant roles to deployer for initial setup
    await securityGovernance.grantRole(PARAM_MANAGER_ROLE, deployer.address);
    await securityGovernance.grantRole(EMERGENCY_ROLE, deployer.address);
    console.log("✅ Setup roles granted to deployer");

  } catch (error) {
    console.log("⚠️ Role setup failed:", error.message);
  }

  // Set up managed contracts (if they exist)
  console.log("⚙️ Setting up managed contracts...");
  try {
    const core = await loadDeployment(network.name, "core");
    const advanced = await loadDeployment(network.name, "advanced");

    if (core?.CoreSecurityManager) {
      await securityGovernance.addManagedContract(
        core.CoreSecurityManager.address,
        "CoreSecurityManager"
      );
      console.log("✅ Added CoreSecurityManager to managed contracts");
    }

    if (core?.EnhancedOracle) {
      await securityGovernance.addManagedContract(
        core.EnhancedOracle.address,
        "EnhancedOracle"
      );
      console.log("✅ Added EnhancedOracle to managed contracts");
    }

    if (advanced?.AdvancedSecurityManager) {
      await securityGovernance.addManagedContract(
        advanced.AdvancedSecurityManager.address,
        "AdvancedSecurityManager"
      );
      console.log("✅ Added AdvancedSecurityManager to managed contracts");
    }

  } catch (error) {
    console.log("⚠️ Managed contracts setup failed:", error.message);
  }

  // Initialize default parameters
  console.log("⚙️ Setting up default security parameters...");
  try {
    // Example: Set up a parameter change proposal
    const proposalId = await securityGovernance.proposeParameterChange(
      "maxPriceChangeBPS",
      2000 // 20%
    );
    console.log("✅ Default parameter proposal created");
  } catch (error) {
    console.log("⚠️ Parameter setup failed:", error.message);
  }

  // Save deployment info
  const deployments = {
    SecurityGovernance: {
      address: securityGovernanceAddress,
      implementation: await upgrades.erc1967.getImplementationAddress(securityGovernanceAddress),
      deploymentBlock: await ethers.provider.getBlockNumber(),
      deployer: deployer.address,
    },
  };

  await saveDeployment(network.name, "governance", deployments);
  
  console.log("\n🎉 Governance contracts deployed successfully!");
  console.log("📄 Deployment info saved to deployments/" + network.name + "/governance.json");
  
  // Display governance setup summary
  console.log("\n📋 Governance Deployment Summary:");
  console.log("=" * 50);
  console.log("SecurityGovernance:", securityGovernanceAddress);
  console.log("Implementation:", deployments.SecurityGovernance.implementation);
  console.log("Treasury Wallet:", treasury.address);
  console.log("Required Signatures: 2");
  console.log("Emergency Delay: 24 hours");
  console.log("Block Number:", deployments.SecurityGovernance.deploymentBlock);
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