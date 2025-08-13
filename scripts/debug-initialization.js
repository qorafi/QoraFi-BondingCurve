// scripts/debug-initialization.js
const { ethers } = require("hardhat");

async function main() {
  console.log("🔍 Debugging Initialization Issues...\n");

  const [deployer] = await ethers.getSigners();
  
  try {
    // Test CoreSecurityManager initialization
    console.log("📋 Testing CoreSecurityManager Initialization:");
    const CoreSecurityManager = await ethers.getContractFactory("CoreSecurityManager");
    const coreManager = await CoreSecurityManager.deploy();
    await coreManager.waitForDeployment();
    const coreAddress = await coreManager.getAddress();
    console.log("✅ CoreSecurityManager deployed at:", coreAddress);

    // Check if it's already initialized
    try {
      const paused = await coreManager.paused();
      console.log("Contract paused status:", paused);
      
      // Try to check if already initialized by calling a function that should exist
      const treasuryWallet = await coreManager.treasuryWallet();
      console.log("Treasury wallet:", treasuryWallet);
      
      if (treasuryWallet !== ethers.ZeroAddress) {
        console.log("⚠️ Contract appears to already be initialized");
        return;
      }
    } catch (checkError) {
      console.log("Contract state check:", checkError.message);
    }

    // Test different initialization approaches
    console.log("\n🧪 Testing Initialization Approaches:");
    
    // Approach 1: Try with real addresses
    try {
      console.log("1. Trying with valid addresses...");
      
      // Create dummy tokens for testing
      const QoraFi = await ethers.getContractFactory("QoraFi");
      const testToken = await QoraFi.deploy("Test Token", "TEST", deployer.address);
      await testToken.waitForDeployment();
      const tokenAddress = await testToken.getAddress();
      
      await coreManager.initialize(
        tokenAddress,    // USDT token
        tokenAddress,    // QoraFi token (same for testing)
        deployer.address // Treasury wallet
      );
      console.log("✅ Initialization successful with approach 1");
      
    } catch (initError) {
      console.log("❌ Approach 1 failed:", initError.message);
      
      // Approach 2: Check the contract's expected interface
      try {
        console.log("2. Checking contract interface...");
        const interface = coreManager.interface;
        const initFunction = interface.getFunction("initialize");
        
        if (initFunction) {
          console.log("Initialize function signature:");
          console.log("  Name:", initFunction.name);
          console.log("  Inputs:", initFunction.inputs.map(i => `${i.type} ${i.name}`));
        }
        
      } catch (interfaceError) {
        console.log("Interface check failed:", interfaceError.message);
      }
      
      // Approach 3: Try with different parameters
      try {
        console.log("3. Trying with different parameter patterns...");
        
        // Maybe it expects different parameters?
        const CoreSecurityManager2 = await ethers.getContractFactory("CoreSecurityManager");
        const coreManager2 = await CoreSecurityManager2.deploy();
        await coreManager2.waitForDeployment();
        
        // Try with zero addresses first
        await coreManager2.initialize(
          ethers.ZeroAddress,
          ethers.ZeroAddress, 
          deployer.address
        );
        console.log("✅ Initialization with zero addresses worked");
        
      } catch (zeroAddressError) {
        console.log("❌ Zero address approach failed:", zeroAddressError.message);
      }
    }

    // Test AdvancedSecurityManager
    console.log("\n📋 Testing AdvancedSecurityManager Initialization:");
    try {
      const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager");
      const advancedManager = await AdvancedSecurityManager.deploy();
      await advancedManager.waitForDeployment();
      console.log("✅ AdvancedSecurityManager deployed successfully");
      
    } catch (advError) {
      console.log("❌ AdvancedSecurityManager deployment failed:", advError.message);
    }

    // Test SecurityGovernance
    console.log("\n📋 Testing SecurityGovernance Initialization:");
    try {
      const SecurityGovernance = await ethers.getContractFactory("SecurityGovernance");
      const securityGovernance = await SecurityGovernance.deploy();
      await securityGovernance.waitForDeployment();
      console.log("✅ SecurityGovernance deployed successfully");
      
    } catch (govError) {
      console.log("❌ SecurityGovernance deployment failed:", govError.message);
    }

    console.log("\n💡 Debug complete. Check the patterns that worked above.");

  } catch (error) {
    console.error("❌ Debug failed:", error.message);
    console.error("Stack:", error.stack);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });