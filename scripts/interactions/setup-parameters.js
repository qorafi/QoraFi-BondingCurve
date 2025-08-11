// scripts/interactions/setup-parameters.js
const { ethers, network } = require("hardhat");
const ContractAddresses = require("../utils/contract-addresses");
const { getNetworkConfig } = require("../utils/network-config");

async function main() {
  console.log("⚙️ Setting up parameters on", network.name);
  
  const [deployer, governance] = await ethers.getSigners();
  const addresses = new ContractAddresses(network.name);
  const networkConfig = getNetworkConfig(network.name);
  
  // Get contracts
  const coreSecurityManager = await ethers.getContractAt(
    "CoreSecurityManager", 
    addresses.get("CoreSecurityManager")
  );
  
  const enhancedOracle = await ethers.getContractAt(
    "EnhancedOracle", 
    addresses.get("EnhancedOracle")
  );

  console.log("\n🛡️ Setting up CoreSecurityManager parameters...");
  
  // Set new token mode parameters
  await coreSecurityManager.setNewTokenMode(true);
  console.log("✅ New token mode enabled");
  
  // Set MEV protection parameters
  await coreSecurityManager.setAntiMEVConfig(
    5, // 5 blocks minimum interval
    ethers.parseUnits("50000", 6), // 50k USDT max per block
    ethers.parseUnits("25000", 6)  // 25k USDT max per user per day
  );
  console.log("✅ MEV protection configured");
  
  // Set circuit breaker parameters
  await coreSecurityManager.setCircuitBreakerConfig(
    ethers.parseUnits("100000", 6), // 100k USDT threshold
    2 * 60 * 60, // 2 hours cooldown
    1 * 60 * 60  // 1 hour window
  );
  console.log("✅ Circuit breaker configured");
  
  // Set max gas price for new token protection
  await coreSecurityManager.setMaxGasPrice(ethers.parseUnits("20", "gwei"));
  console.log("✅ Max gas price set to 20 gwei");

  console.log("\n🔮 Setting up EnhancedOracle parameters...");
  
  // Set market cap limits
  await enhancedOracle.setMarketCapLimits(
    ethers.parseEther("100000"),   // 100k USD minimum
    ethers.parseEther("10000000")  // 10M USD maximum
  );
  console.log("✅ Market cap limits set");
  
  // Set liquidity requirements
  await enhancedOracle.setLiquidityRequirements(
    ethers.parseUnits("10000", 6), // 10k USDT minimum liquidity
    ethers.parseEther("1000")      // 1k Qorafi minimum in LP
  );
  console.log("✅ Liquidity requirements set");
  
  // Set update parameters
  await enhancedOracle.setUpdateParameters(
    2000, // 20% max price change
    3000, // 30% max market cap growth
    5 * 60 // 5 minutes minimum update interval
  );
  console.log("✅ Update parameters set");
  
  // Set flash loan protection
  await enhancedOracle.setFlashLoanProtection(
    1, // 1 update per block max
    3  // 3 block detection window
  );
  console.log("✅ Flash loan protection configured");

  console.log("\n🎉 All parameters configured successfully!");
  
  // Display current settings
  console.log("\n📊 Current Settings Summary:");
  const newTokenSettings = await coreSecurityManager.getNewTokenSettings();
  console.log("New Token Mode:", newTokenSettings.newTokenModeActive);
  console.log("Max Gas Price:", ethers.formatUnits(newTokenSettings.maxGasPriceSetting, "gwei"), "gwei");
  
  const circuitBreakerStatus = await coreSecurityManager.getCircuitBreakerStatus();
  console.log("Circuit Breaker Threshold:", ethers.formatUnits(circuitBreakerStatus.volumeThreshold, 6), "USDT");
  
  const liquidityStatus = await enhancedOracle.getLiquidityStatus();
  console.log("Min USDT Liquidity:", ethers.formatUnits(liquidityStatus.minimumRequired, 6), "USDT");
}

if (require.main === module) {
  main()
    .then(() => process.exit(0))
    .catch((error) => {
      console.error("❌ Setup failed:", error);
      process.exit(1);
    });
}

module.exports = main;