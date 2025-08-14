// test/helpers/deploy-mock-token.js
// Shared helper for deploying mock tokens across all tests

const { ethers } = require("hardhat");

async function deployMockToken(name = "Mock Token", symbol = "MOCK", decimals = 18) {
  const [deployer] = await ethers.getSigners();
  
  // Try different MockERC20 patterns
  let token;
  
  try {
    // Pattern 1: No constructor arguments
    const MockERC20 = await ethers.getContractFactory("MockERC20", deployer);
    token = await MockERC20.deploy();
    await token.waitForDeployment();
    
    // Set properties if functions exist
    if (token.setDecimals) {
      await token.setDecimals(decimals);
    }
  } catch (e) {
    // Pattern 2: OpenZeppelin ERC20Mock pattern
    try {
      const ERC20Mock = await ethers.getContractFactory("ERC20Mock", deployer);
      token = await ERC20Mock.deploy(name, symbol);
      await token.waitForDeployment();
    } catch (e2) {
      // Pattern 3: Full constructor parameters
      try {
        const MockERC20 = await ethers.getContractFactory("MockERC20", deployer);
        const initialSupply = ethers.parseUnits("1000000000", decimals);
        token = await MockERC20.deploy(name, symbol, decimals, initialSupply);
        await token.waitForDeployment();
      } catch (e3) {
        throw new Error(`Failed to deploy mock token: ${e3.message}`);
      }
    }
  }
  
  // Mint initial supply if mint function exists
  try {
    if (token.mint) {
      await token.mint(deployer.address, ethers.parseUnits("1000000", decimals));
    }
  } catch (e) {
    // Minting might not be available or already have supply
  }
  
  return token;
}

// Update for CoreSecurityManager test fixture
async function deployCoreSecurityManagerFixture() {
  const [owner, governance, emergency, user] = await ethers.getSigners();
  
  // Deploy mock USDT
  const usdt = await deployMockToken("USDT", "USDT", 6);
  
  // Deploy Core Security Manager
  const CoreSecurityManager = await ethers.getContractFactory("CoreSecurityManager", owner);
  const coreSecurityManager = await upgrades.deployProxy(
    CoreSecurityManager,
    [
      ethers.parseUnits("100000", 6), // maxDailyDeposit
      ethers.parseUnits("10000", 6),  // maxSingleDeposit
      3600 // circuitBreakerCooldown
    ],
    {
      initializer: "initialize",
      kind: "uups"
    }
  );
  await coreSecurityManager.waitForDeployment();
  
  // Grant roles after deployment
  const GOVERNANCE_ROLE = await coreSecurityManager.GOVERNANCE_ROLE();
  const EMERGENCY_ROLE = await coreSecurityManager.EMERGENCY_ROLE();
  
  // Check if owner has DEFAULT_ADMIN_ROLE
  const DEFAULT_ADMIN_ROLE = await coreSecurityManager.DEFAULT_ADMIN_ROLE();
  const hasAdmin = await coreSecurityManager.hasRole(DEFAULT_ADMIN_ROLE, owner.address);
  
  if (!hasAdmin) {
    console.log("WARNING: Owner doesn't have DEFAULT_ADMIN_ROLE - contract initialization issue");
    // The contract's initialize function needs to grant DEFAULT_ADMIN_ROLE to msg.sender
  } else {
    // Grant other roles
    await coreSecurityManager.grantRole(GOVERNANCE_ROLE, governance.address);
    await coreSecurityManager.grantRole(EMERGENCY_ROLE, emergency.address);
  }
  
  return {
    coreSecurityManager,
    usdt,
    owner,
    governance,
    emergency,
    user,
    GOVERNANCE_ROLE,
    EMERGENCY_ROLE
  };
}

// Update for EnhancedOracle test fixture
async function deployEnhancedOracleFixture() {
  const [owner, governance, oracleUpdater, user] = await ethers.getSigners();
  
  // Deploy mock tokens
  const usdt = await deployMockToken("USDT", "USDT", 6);
  const projectToken = await deployMockToken("Project Token", "PROJ", 18);
  
  // Deploy Enhanced Oracle
  const EnhancedOracle = await ethers.getContractFactory("EnhancedOracle", owner);
  const enhancedOracle = await upgrades.deployProxy(
    EnhancedOracle,
    [
      await projectToken.getAddress(),
      ethers.ZeroAddress, // uniswapPair
      ethers.parseEther("0.001"), // initialPrice
      ethers.parseEther("1000000") // initialMarketCap
    ],
    {
      initializer: "initialize",
      kind: "uups"
    }
  );
  await enhancedOracle.waitForDeployment();
  
  // Grant roles
  const DEFAULT_ADMIN_ROLE = await enhancedOracle.DEFAULT_ADMIN_ROLE();
  const hasAdmin = await enhancedOracle.hasRole(DEFAULT_ADMIN_ROLE, owner.address);
  
  if (hasAdmin) {
    const GOVERNANCE_ROLE = await enhancedOracle.GOVERNANCE_ROLE();
    const ORACLE_UPDATER_ROLE = await enhancedOracle.ORACLE_UPDATER_ROLE();
    
    await enhancedOracle.grantRole(GOVERNANCE_ROLE, governance.address);
    await enhancedOracle.grantRole(ORACLE_UPDATER_ROLE, oracleUpdater.address);
  } else {
    console.log("WARNING: Owner doesn't have DEFAULT_ADMIN_ROLE - contract initialization issue");
  }
  
  return {
    enhancedOracle,
    usdt,
    projectToken,
    owner,
    governance,
    oracleUpdater,
    user
  };
}

module.exports = {
  deployMockToken,
  deployCoreSecurityManagerFixture,
  deployEnhancedOracleFixture
};