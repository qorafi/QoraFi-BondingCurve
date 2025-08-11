// scripts/deploy/05-verify-contracts.js
const { network } = require("hardhat");
const { loadDeployment } = require("../utils/deployment-helpers");

async function main() {
  console.log("🔍 Verifying Contracts on", network.name);
  
  if (network.name === "localhost" || network.name === "hardhat") {
    console.log("⚠️ Skipping verification on local network");
    return;
  }

  if (!process.env.BSC_API_KEY && !process.env.ETHEREUM_API_KEY) {
    console.log("⚠️ No API keys found. Skipping verification.");
    console.log("💡 Set BSC_API_KEY or ETHEREUM_API_KEY in .env file to enable verification");
    return;
  }

  // Load all deployments
  const libraries = await loadDeployment(network.name, "libraries");
  const core = await loadDeployment(network.name, "core");
  const advanced = await loadDeployment(network.name, "advanced");
  const governance = await loadDeployment(network.name, "governance");

  let verificationCount = 0;
  let successCount = 0;

  async function verifyContract(address, constructorArguments = [], contractName = "") {
    if (!address || address === "0x0000000000000000000000000000000000000000") {
      console.log(`⚠️ Skipping verification for ${contractName} - invalid address`);
      return false;
    }

    try {
      verificationCount++;
      console.log(`\n🔍 Verifying ${contractName} at ${address}...`);
      
      await hre.run("verify:verify", {
        address: address,
        constructorArguments: constructorArguments,
      });
      
      console.log(`✅ ${contractName} verified successfully`);
      successCount++;
      return true;
      
    } catch (error) {
      if (error.message.includes("already verified")) {
        console.log(`✅ ${contractName} already verified`);
        successCount++;
        return true;
      } else {
        console.log(`❌ ${contractName} verification failed:`, error.message);
        return false;
      }
    }
  }

  try {
    // Verify libraries first
    if (libraries) {
      console.log("\n📚 Verifying Libraries...");
      
      await verifyContract(
        libraries.SecurityLibraries?.address,
        [],
        "SecurityLibraries"
      );
      
      await verifyContract(
        libraries.OracleLibraries?.address,
        [],
        "OracleLibraries"
      );
      
      await verifyContract(
        libraries.UtilityLibraries?.address,
        [],
        "UtilityLibraries"
      );
    }

    // Verify core contracts (implementation contracts for proxies)
    if (core) {
      console.log("\n🛡️ Verifying Core Contracts...");
      
      if (core.CoreSecurityManager?.implementation) {
        await verifyContract(
          core.CoreSecurityManager.implementation,
          [],
          "CoreSecurityManager (Implementation)"
        );
      }
      
      if (core.EnhancedOracle?.implementation) {
        await verifyContract(
          core.EnhancedOracle.implementation,
          [],
          "EnhancedOracle (Implementation)"
        );
      }

      // Also verify proxy contracts if possible
      if (core.CoreSecurityManager?.address) {
        await verifyContract(
          core.CoreSecurityManager.address,
          [],
          "CoreSecurityManager (Proxy)"
        );
      }

      if (core.EnhancedOracle?.address) {
        await verifyContract(
          core.EnhancedOracle.address,
          [],
          "EnhancedOracle (Proxy)"
        );
      }
    }

    // Verify advanced contracts
    if (advanced) {
      console.log("\n🔬 Verifying Advanced Contracts...");
      
      if (advanced.AdvancedSecurityManager?.implementation) {
        await verifyContract(
          advanced.AdvancedSecurityManager.implementation,
          [],
          "AdvancedSecurityManager (Implementation)"
        );
      }

      if (advanced.AdvancedSecurityManager?.address) {
        await verifyContract(
          advanced.AdvancedSecurityManager.address,
          [],
          "AdvancedSecurityManager (Proxy)"
        );
      }
    }

    // Verify governance contracts
    if (governance) {
      console.log("\n🏛️ Verifying Governance Contracts...");
      
      if (governance.SecurityGovernance?.implementation) {
        await verifyContract(
          governance.SecurityGovernance.implementation,
          [],
          "SecurityGovernance (Implementation)"
        );
      }

      if (governance.SecurityGovernance?.address) {
        await verifyContract(
          governance.SecurityGovernance.address,
          [],
          "SecurityGovernance (Proxy)"
        );
      }
    }

    // Verification summary
    console.log("\n📊 Verification Summary:");
    console.log("=" * 50);
    console.log(`Total contracts to verify: ${verificationCount}`);
    console.log(`Successfully verified: ${successCount}`);
    console.log(`Failed verifications: ${verificationCount - successCount}`);
    console.log("=" * 50);

    if (successCount === verificationCount) {
      console.log("\n🎉 All contracts verified successfully!");
    } else if (successCount > 0) {
      console.log("\n⚠️ Some contracts verified, but some failed");
      console.log("💡 Failed verifications might be due to:");
      console.log("   - Network delays");
      console.log("   - Constructor argument mismatches");
      console.log("   - Complex library linking");
      console.log("   - API rate limits");
    } else {
      console.log("\n❌ No contracts were verified");
    }

    // Provide block explorer links
    console.log("\n🔗 Block Explorer Links:");
    const getBlockExplorerUrl = (address) => {
      const baseUrls = {
        'bscMainnet': 'https://bscscan.com',
        'bscTestnet': 'https://testnet.bscscan.com',
        'sepolia': 'https://sepolia.etherscan.io',
        'mainnet': 'https://etherscan.io'
      };
      const baseUrl = baseUrls[network.name] || 'https://etherscan.io';
      return `${baseUrl}/address/${address}`;
    };

    if (libraries?.SecurityLibraries?.address) {
      console.log(`SecurityLibraries: ${getBlockExplorerUrl(libraries.SecurityLibraries.address)}`);
    }
    if (core?.CoreSecurityManager?.address) {
      console.log(`CoreSecurityManager: ${getBlockExplorerUrl(core.CoreSecurityManager.address)}`);
    }
    if (core?.EnhancedOracle?.address) {
      console.log(`EnhancedOracle: ${getBlockExplorerUrl(core.EnhancedOracle.address)}`);
    }
    if (governance?.SecurityGovernance?.address) {
      console.log(`SecurityGovernance: ${getBlockExplorerUrl(governance.SecurityGovernance.address)}`);
    }
    
  } catch (error) {
    console.error("❌ Verification process failed:", error);
    console.log("\n💡 Troubleshooting tips:");
    console.log("1. Check your API key is correct and has quota remaining");
    console.log("2. Wait a few minutes and try again (network delays)");
    console.log("3. Verify contracts individually if batch verification fails");
    console.log("4. Check that all contracts are deployed and confirmed");
  }

  return {
    total: verificationCount,
    successful: successCount,
    failed: verificationCount - successCount
  };
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