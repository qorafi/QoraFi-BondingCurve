// scripts/interactions/manage-governance.js
const { ethers, network } = require("hardhat");
const ContractAddresses = require("../utils/contract-addresses");

async function main() {
  console.log("🏛️ Managing governance on", network.name);
  
  const [deployer, governance, emergency] = await ethers.getSigners();
  const addresses = new ContractAddresses(network.name);
  
  if (!addresses.exists("SecurityGovernance")) {
    console.log("❌ SecurityGovernance not deployed yet");
    return;
  }
  
  const securityGovernance = await ethers.getContractAt(
    "SecurityGovernance", 
    addresses.get("SecurityGovernance")
  );

  console.log("\n📊 Current Governance Status:");
  
  try {
    const governanceStats = await securityGovernance.getGovernanceStats();
    console.log("Governance Statistics:");
    console.log("  Total Proposals:", governanceStats.totalProposalsCount.toString());
    console.log("  Executed Proposals:", governanceStats.executedProposalsCount.toString());
    console.log("  Cancelled Proposals:", governanceStats.cancelledProposalsCount.toString());
    console.log("  Required Signatures:", governanceStats.requiredSignaturesCount.toString());
    console.log("  Proposal Validity Period:", governanceStats.proposalValidityPeriodDuration.toString(), "seconds");
  } catch (error) {
    console.log("❌ Could not fetch governance stats:", error.message);
  }

  console.log("\n📋 Current Security Parameters:");
  
  try {
    const [paramNames, paramValues] = await securityGovernance.getAllParameters();
    
    for (let i = 0; i < paramNames.length; i++) {
      console.log(`  ${paramNames[i]}: ${paramValues[i].toString()}`);
    }
  } catch (error) {
    console.log("❌ Could not fetch parameters:", error.message);
  }

  console.log("\n🔧 Example: Proposing Parameter Change...");
  
  try {
    // Example: Propose to change max price change to 15% (1500 BPS)
    const txHash = await securityGovernance.connect(governance).proposeParameterChange(
      "maxPriceChangeBPS",
      1500
    );
    
    console.log("✅ Parameter change proposed");
    console.log("Transaction hash:", txHash.hash);
    
    // Wait for transaction to be mined
    const receipt = await txHash.wait();
    console.log("Block number:", receipt.blockNumber);
    
  } catch (error) {
    console.log("❌ Could not propose parameter change:", error.message);
  }

  console.log("\n🚨 Example: Emergency Transaction...");
  
  try {
    // Example: Propose emergency pause
    const pauseData = securityGovernance.interface.encodeFunctionData("emergencyPause", []);
    
    const emergencyTxHash = await securityGovernance.connect(emergency).proposeEmergencyTransaction(
      addresses.get("CoreSecurityManager"),
      0,
      pauseData
    );
    
    console.log("✅ Emergency transaction proposed");
    console.log("Emergency transaction hash:", emergencyTxHash.hash);
    
  } catch (error) {
    console.log("❌ Could not propose emergency transaction:", error.message);
  }

  console.log("\n👥 Role Management:");
  
  try {
    const GOVERNANCE_ROLE = await securityGovernance.GOVERNANCE_ROLE();
    const EMERGENCY_ROLE = await securityGovernance.EMERGENCY_ROLE();
    const PARAM_MANAGER_ROLE = await securityGovernance.PARAM_MANAGER_ROLE();
    
    console.log("Role Assignments:");
    console.log("  Deployer has GOVERNANCE_ROLE:", await securityGovernance.hasRole(GOVERNANCE_ROLE, deployer.address));
    console.log("  Governance has PARAM_MANAGER_ROLE:", await securityGovernance.hasRole(PARAM_MANAGER_ROLE, governance.address));
    console.log("  Emergency has EMERGENCY_ROLE:", await securityGovernance.hasRole(EMERGENCY_ROLE, emergency.address));
    
  } catch (error) {
    console.log("❌ Could not check roles:", error.message);
  }

  console.log("\n💰 Treasury Management:");
  
  try {
    const treasuryWallet = await securityGovernance.getTreasuryWallet();
    console.log("Current treasury wallet:", treasuryWallet);
    
  } catch (error) {
    console.log("❌ Could not fetch treasury wallet:", error.message);
  }

  console.log("\n✅ Governance management completed!");
}

if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error("❌ Governance management failed:", error);
      process.exit(1);
    });
}

module.exports = main;