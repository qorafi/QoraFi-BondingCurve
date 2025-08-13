// scripts/diagnose-contracts.js
const { ethers, upgrades } = require("hardhat");

async function main() {
  console.log("🔍 Diagnosing contract deployment issues...\n");
  
  const [deployer] = await ethers.getSigners();
  console.log("Deploying contracts with account:", deployer.address);
  
  try {
    // Test MockERC20 deployment
    console.log("📝 Testing MockERC20 deployment...");
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const usdt = await MockERC20.deploy("Mock USDT", "USDT", 6, ethers.parseUnits("1000000", 6));
    console.log("✅ MockERC20 deployed successfully");
    
    // Test CoreSecurityManager deployment
    console.log("📝 Testing CoreSecurityManager deployment...");
    const CoreSecurityManager = await ethers.getContractFactory("CoreSecurityManager");
    
    const coreSecurityManager = await upgrades.deployProxy(CoreSecurityManager, [
      await usdt.getAddress(),
      await usdt.getAddress(), // Use same for qorafi
      deployer.address // treasury
    ], {
      initializer: 'initialize',
      kind: 'uups'
    });
    
    console.log("✅ CoreSecurityManager deployed successfully");
    console.log("📋 Contract address:", await coreSecurityManager.getAddress());
    
    // Test role constants
    console.log("\n📝 Testing role constants...");
    try {
      const DEFAULT_ADMIN_ROLE = await coreSecurityManager.DEFAULT_ADMIN_ROLE();
      console.log("✅ DEFAULT_ADMIN_ROLE:", DEFAULT_ADMIN_ROLE);
      
      const GOVERNANCE_ROLE = await coreSecurityManager.GOVERNANCE_ROLE();
      console.log("✅ GOVERNANCE_ROLE:", GOVERNANCE_ROLE);
      
      const EMERGENCY_ROLE = await coreSecurityManager.EMERGENCY_ROLE();
      console.log("✅ EMERGENCY_ROLE:", EMERGENCY_ROLE);
      
      const MONITOR_ROLE = await coreSecurityManager.MONITOR_ROLE();
      console.log("✅ MONITOR_ROLE:", MONITOR_ROLE);
    } catch (error) {
      console.log("❌ Role constants not available:", error.message);
    }
    
    // Test core functions
    console.log("\n📝 Testing core functions...");
    
    // Test getter functions
    const functions = [
      'usdtToken',
      'qorafiToken', 
      'treasuryWallet',
      'newTokenMode',
      'getCircuitBreakerStatus',
      'getNewTokenSettings',
      'getMEVConfig',
      'isPaused',
      'paused'
    ];
    
    for (const funcName of functions) {
      try {
        const result = await coreSecurityManager[funcName]();
        console.log(`✅ ${funcName}():`, result.toString ? result.toString() : result);
      } catch (error) {
        console.log(`❌ ${funcName}() not available:`, error.message.split('\n')[0]);
      }
    }
    
    // Test AdvancedSecurityManager if it exists
    console.log("\n📝 Testing AdvancedSecurityManager deployment...");
    try {
      const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager");
      
      const advancedSecurityManager = await upgrades.deployProxy(AdvancedSecurityManager, [
        await usdt.getAddress(),
        await usdt.getAddress(),
        deployer.address
      ], {
        initializer: 'initialize',
        kind: 'uups'
      });
      
      console.log("✅ AdvancedSecurityManager deployed successfully");
      console.log("📋 Contract address:", await advancedSecurityManager.getAddress());
      
      // Test advanced functions
      const advancedFunctions = [
        'emergencyMode',
        'emergencyTransactionDelay',
        'getRiskConfig',
        'getFlashLoanProtectionStatus'
      ];
      
      for (const funcName of advancedFunctions) {
        try {
          const result = await advancedSecurityManager[funcName]();
          console.log(`✅ ${funcName}():`, result.toString ? result.toString() : result);
        } catch (error) {
          console.log(`❌ ${funcName}() not available:`, error.message.split('\n')[0]);
        }
      }
      
    } catch (error) {
      console.log("❌ AdvancedSecurityManager deployment failed:", error.message.split('\n')[0]);
    }
    
    // Test EnhancedOracle if it exists
    console.log("\n📝 Testing EnhancedOracle deployment...");
    try {
      // Get different signers for different roles
      const [deployer, governance, oracleUpdater] = await ethers.getSigners();
      
      // Deploy mock pair for EnhancedOracle
      const MockUniswapV2Pair = await ethers.getContractFactory("MockUniswapV2Pair");
      const pair = await MockUniswapV2Pair.deploy(
        await usdt.getAddress(),
        await usdt.getAddress()
      );
      
      // Set initial reserves
      await pair.setReserves(
        ethers.parseEther("100000"), // 100k tokens
        ethers.parseUnits("100000", 6) // 100k USDT
      );
      
      const EnhancedOracle = await ethers.getContractFactory("EnhancedOracle");
      
      const enhancedOracle = await upgrades.deployProxy(EnhancedOracle, [
        await usdt.getAddress(),         // USDT token
        await usdt.getAddress(),         // Qorafi token (using USDT as mock)
        await pair.getAddress(),         // LP pair
        ethers.parseEther("100000"),     // Min market cap
        ethers.parseEther("10000000"),   // Max market cap
        governance.address,              // Governance (different from deployer)
        oracleUpdater.address            // Oracle updater (different from governance)
      ], {
        initializer: 'initialize',
        kind: 'uups'
      });
      
      console.log("✅ EnhancedOracle deployed successfully");
      console.log("📋 Contract address:", await enhancedOracle.getAddress());
      console.log("📋 Governance address:", governance.address);
      console.log("📋 Oracle updater address:", oracleUpdater.address);
      
      // Test a few key functions
      try {
        const newTokenMode = await enhancedOracle.newTokenMode();
        console.log("✅ newTokenMode():", newTokenMode);
        
        const mcLowerLimit = await enhancedOracle.mcLowerLimit();
        console.log("✅ mcLowerLimit():", ethers.formatEther(mcLowerLimit), "ETH");
        
        const mcUpperLimit = await enhancedOracle.mcUpperLimit();
        console.log("✅ mcUpperLimit():", ethers.formatEther(mcUpperLimit), "ETH");
      } catch (funcError) {
        console.log("Some oracle functions not available:", funcError.message);
      }
      
    } catch (error) {
      console.log("❌ EnhancedOracle deployment failed:", error.message.split('\n')[0]);
      
      // Try with different approach - maybe the contract expects different parameters
      try {
        console.log("📝 Trying alternative EnhancedOracle deployment...");
        const [deployer, alt1, alt2, alt3] = await ethers.getSigners();
        
        const EnhancedOracle = await ethers.getContractFactory("EnhancedOracle");
        
        // Try with more distinct addresses
        const enhancedOracle = await upgrades.deployProxy(EnhancedOracle, [
          await usdt.getAddress(),         // USDT token
          await usdt.getAddress(),         // Qorafi token  
          alt1.address,                    // LP pair (use address)
          ethers.parseEther("100000"),     // Min market cap
          ethers.parseEther("10000000"),   // Max market cap
          alt2.address,                    // Governance
          alt3.address                     // Oracle updater
        ], {
          initializer: 'initialize',
          kind: 'uups'
        });
        
        console.log("✅ EnhancedOracle deployed successfully (alternative method)");
        console.log("📋 Contract address:", await enhancedOracle.getAddress());
        
      } catch (altError) {
        console.log("❌ Alternative EnhancedOracle deployment also failed:", altError.message.split('\n')[0]);
      }
    }
    
    // Test SecurityGovernance if it exists
    console.log("\n📝 Testing SecurityGovernance deployment...");
    try {
      const SecurityGovernance = await ethers.getContractFactory("SecurityGovernance");
      
      const securityGovernance = await upgrades.deployProxy(SecurityGovernance, [
        deployer.address,    // Treasury wallet
        24 * 60 * 60,       // Emergency transaction delay (24 hours)
        1                   // Required signatures
      ], {
        initializer: 'initialize',
        kind: 'uups'
      });
      
      console.log("✅ SecurityGovernance deployed successfully");
      console.log("📋 Contract address:", await securityGovernance.getAddress());
      
    } catch (error) {
      console.log("❌ SecurityGovernance deployment failed:", error.message.split('\n')[0]);
    }
    
    console.log("\n🎉 Diagnosis complete!");
    
  } catch (error) {
    console.error("❌ Major deployment error:", error.message);
    console.error("Stack trace:", error.stack);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });