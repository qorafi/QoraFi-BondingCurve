// scripts/deploy/02-deploy-core.js
const { ethers, network } = require("hardhat");
const { saveDeployment, loadDeployment } = require("../utils/deployment-helpers");

async function main() {
  console.log("🚀 Deploying Core Contracts to", network.name);
  
  // Load library addresses
  const libraries = await loadDeployment(network.name, "libraries");
  if (!libraries) {
    throw new Error("Libraries not deployed. Run 01-deploy-libraries.js first");
  }

  const [deployer, governance, treasury] = await ethers.getSigners();
  console.log("📝 Deploying with account:", deployer.address);

  // Mock token addresses for testing (replace with real addresses on mainnet)
  const usdtAddress = process.env.USDT_ADDRESS || "0x0000000000000000000000000000000000000001";
  const qorafiAddress = process.env.QORAFI_ADDRESS || "0x0000000000000000000000000000000000000002";
  
  // Deploy CoreSecurityManager
  console.log("\n🛡️ Deploying CoreSecurityManager...");
  const CoreSecurityManager = await ethers.getContractFactory("CoreSecurityManager", {
    libraries: {
      MEVLib: libraries.SecurityLibraries.address,
      CircuitBreakerLib: libraries.SecurityLibraries.address,
      ValidationLib: libraries.SecurityLibraries.address,
    },
  });
  
  // Deploy as upgradeable proxy
  const coreSecurityManager = await upgrades.deployProxy(CoreSecurityManager, [
    usdtAddress,
    qorafiAddress,
    treasury.address
  ], {
    initializer: 'initialize',
    kind: 'uups',
    unsafeAllow: ['external-library-linking']
  });
  
  await coreSecurityManager.waitForDeployment();
  const coreSecurityManagerAddress = await coreSecurityManager.getAddress();
  console.log("✅ CoreSecurityManager deployed to:", coreSecurityManagerAddress);

  // Deploy EnhancedOracle
  console.log("\n🔮 Deploying EnhancedOracle...");
  const mockPairAddress = process.env.LP_PAIR_ADDRESS || "0x0000000000000000000000000000000000000003";
  
  const EnhancedOracle = await ethers.getContractFactory("EnhancedOracle", {
    libraries: {
      TWAPLib: libraries.OracleLibraries.address,
      PriceValidationLib: libraries.OracleLibraries.address,
      LiquidityMonitorLib: libraries.OracleLibraries.address,
      FlashLoanDetectionLib: libraries.OracleLibraries.address,
      CumulativePriceLib: libraries.OracleLibraries.address,
    },
  });
  
  const enhancedOracle = await upgrades.deployProxy(EnhancedOracle, [
    usdtAddress,
    qorafiAddress,
    mockPairAddress,
    ethers.parseEther("100000"), // 100k min market cap
    ethers.parseEther("10000000"), // 10M max market cap
    governance.address,
    deployer.address
  ], {
    initializer: 'initialize',
    kind: 'uups',
    unsafeAllow: ['external-library-linking']
  });
  
  await enhancedOracle.waitForDeployment();
  const enhancedOracleAddress = await enhancedOracle.getAddress();
  console.log("✅ EnhancedOracle deployed to:", enhancedOracleAddress);

  // Save deployment info
  const deployments = {
    CoreSecurityManager: {
      address: coreSecurityManagerAddress,
      implementation: await upgrades.erc1967.getImplementationAddress(coreSecurityManagerAddress),
      deploymentBlock: await ethers.provider.getBlockNumber(),
    },
    EnhancedOracle: {
      address: enhancedOracleAddress,
      implementation: await upgrades.erc1967.getImplementationAddress(enhancedOracleAddress),
      deploymentBlock: await ethers.provider.getBlockNumber(),
    },
  };

  await saveDeployment(network.name, "core", deployments);
  
  console.log("\n🎉 Core contracts deployed successfully!");
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

// scripts/deploy/03-deploy-advanced.js
const { ethers, network } = require("hardhat");
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
  
  const usdtAddress = process.env.USDT_ADDRESS || "0x0000000000000000000000000000000000000001";
  const qorafiAddress = process.env.QORAFI_ADDRESS || "0x0000000000000000000000000000000000000002";
  
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
  await advancedSecurityManager.initializeAdvanced(
    24 * 60 * 60, // 24 hours emergency delay
    1, // max 1 update per block for new token
    3  // 3 block flash loan detection window
  );

  // Save deployment info
  const deployments = {
    AdvancedSecurityManager: {
      address: advancedSecurityManagerAddress,
      implementation: await upgrades.erc1967.getImplementationAddress(advancedSecurityManagerAddress),
      deploymentBlock: await ethers.provider.getBlockNumber(),
    },
  };

  await saveDeployment(network.name, "advanced", deployments);
  
  console.log("\n🎉 Advanced contracts deployed successfully!");
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

// scripts/deploy/04-deploy-governance.js
const { ethers, network } = require("hardhat");
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
  const PARAM_MANAGER_ROLE = await securityGovernance.PARAM_MANAGER_ROLE();
  const EMERGENCY_ROLE = await securityGovernance.EMERGENCY_ROLE();
  
  // Grant roles to governance address
  await securityGovernance.grantRole(PARAM_MANAGER_ROLE, governance.address);
  await securityGovernance.grantRole(EMERGENCY_ROLE, governance.address);

  // Save deployment info
  const deployments = {
    SecurityGovernance: {
      address: securityGovernanceAddress,
      implementation: await upgrades.erc1967.getImplementationAddress(securityGovernanceAddress),
      deploymentBlock: await ethers.provider.getBlockNumber(),
    },
  };

  await saveDeployment(network.name, "governance", deployments);
  
  console.log("\n🎉 Governance contracts deployed successfully!");
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

// scripts/deploy/05-verify-contracts.js
const { ethers, network } = require("hardhat");
const { loadDeployment } = require("../utils/deployment-helpers");

async function main() {
  console.log("🔍 Verifying Contracts on", network.name);
  
  if (network.name === "localhost" || network.name === "hardhat") {
    console.log("⚠️ Skipping verification on local network");
    return;
  }

  // Load all deployments
  const libraries = await loadDeployment(network.name, "libraries");
  const core = await loadDeployment(network.name, "core");
  const advanced = await loadDeployment(network.name, "advanced");
  const governance = await loadDeployment(network.name, "governance");

  try {
    // Verify libraries
    if (libraries) {
      console.log("\n📚 Verifying Libraries...");
      
      await hre.run("verify:verify", {
        address: libraries.SecurityLibraries.address,
        constructorArguments: [],
      });
      
      await hre.run("verify:verify", {
        address: libraries.OracleLibraries.address,
        constructorArguments: [],
      });
      
      await hre.run("verify:verify", {
        address: libraries.UtilityLibraries.address,
        constructorArguments: [],
      });
    }

    // Verify core contracts
    if (core) {
      console.log("\n🛡️ Verifying Core Contracts...");
      
      await hre.run("verify:verify", {
        address: core.CoreSecurityManager.implementation,
        constructorArguments: [],
      });
      
      await hre.run("verify:verify", {
        address: core.EnhancedOracle.implementation,
        constructorArguments: [],
      });
    }

    // Verify advanced contracts
    if (advanced) {
      console.log("\n🔬 Verifying Advanced Contracts...");
      
      await hre.run("verify:verify", {
        address: advanced.AdvancedSecurityManager.implementation,
        constructorArguments: [],
      });
    }

    // Verify governance contracts
    if (governance) {
      console.log("\n🏛️ Verifying Governance Contracts...");
      
      await hre.run("verify:verify", {
        address: governance.SecurityGovernance.implementation,
        constructorArguments: [],
      });
    }

    console.log("\n✅ All contracts verified successfully!");
    
  } catch (error) {
    console.error("❌ Verification failed:", error);
    console.log("💡 This might be because contracts are already verified or network doesn't support verification");
  }
}

if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error("❌ Verification failed:", error);
      process.exit(1);
    });
}

module.exports = main;