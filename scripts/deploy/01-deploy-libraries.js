const { ethers, network } = require("hardhat");
const { saveDeployment, loadDeployment } = require("../utils/deployment-helpers");

async function main() {
  console.log("🚀 Deploying Libraries to", network.name);
  
  // Get deployer
  const [deployer] = await ethers.getSigners();
  console.log("📝 Deploying with account:", deployer.address);
  
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log("💰 Account balance:", ethers.formatEther(balance), "ETH");

  // Deploy SecurityLibraries
  console.log("\n📚 Deploying SecurityLibraries...");
  const SecurityLibraries = await ethers.getContractFactory("SecurityLibraries");
  const securityLibraries = await SecurityLibraries.deploy();
  await securityLibraries.waitForDeployment();
  
  const securityLibrariesAddress = await securityLibraries.getAddress();
  console.log("✅ SecurityLibraries deployed to:", securityLibrariesAddress);
  
  // Deploy OracleLibraries
  console.log("\n🔮 Deploying OracleLibraries...");
  const OracleLibraries = await ethers.getContractFactory("OracleLibraries");
  const oracleLibraries = await OracleLibraries.deploy();
  await oracleLibraries.waitForDeployment();
  
  const oracleLibrariesAddress = await oracleLibraries.getAddress();
  console.log("✅ OracleLibraries deployed to:", oracleLibrariesAddress);
  
  // Deploy UtilityLibraries
  console.log("\n🛠️ Deploying UtilityLibraries...");
  const UtilityLibraries = await ethers.getContractFactory("UtilityLibraries");
  const utilityLibraries = await UtilityLibraries.deploy();
  await utilityLibraries.waitForDeployment();
  
  const utilityLibrariesAddress = await utilityLibraries.getAddress();
  console.log("✅ UtilityLibraries deployed to:", utilityLibrariesAddress);

  // Save deployment info
  const deployments = {
    SecurityLibraries: {
      address: securityLibrariesAddress,
      deploymentBlock: await ethers.provider.getBlockNumber(),
    },
    OracleLibraries: {
      address: oracleLibrariesAddress,
      deploymentBlock: await ethers.provider.getBlockNumber(),
    },
    UtilityLibraries: {
      address: utilityLibrariesAddress,
      deploymentBlock: await ethers.provider.getBlockNumber(),
    },
  };

  await saveDeployment(network.name, "libraries", deployments);
  
  console.log("\n🎉 All libraries deployed successfully!");
  console.log("📄 Deployment info saved to deployments/" + network.name + "/libraries.json");
  
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