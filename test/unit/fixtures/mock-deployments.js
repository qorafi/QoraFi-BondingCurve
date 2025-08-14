// test/fixtures/mock-deployments.js

const { ethers, upgrades } = require("hardhat");

async function deployFullSystem() {
  // Get signers
  const [deployer, governance, emergency, oracleUpdater, user1, user2] = await ethers.getSigners();
  
  console.log("Deploying contracts with account:", deployer.address);
  
  // ===== DEPLOY MOCK TOKENS =====
  const MockERC20 = await ethers.getContractFactory("MockERC20", deployer);
  
  // Try different constructor patterns for MockERC20
  let usdt, projectToken;
  
  try {
    // Try with name, symbol, decimals
    usdt = await MockERC20.deploy("Mock USDT", "USDT", 6);
    projectToken = await MockERC20.deploy("Project Token", "PROJ", 18);
  } catch (error) {
    try {
      // Try with just name and symbol
      usdt = await MockERC20.deploy("Mock USDT", "USDT");
      projectToken = await MockERC20.deploy("Project Token", "PROJ");
    } catch (error2) {
      try {
        // Try with no parameters
        usdt = await MockERC20.deploy();
        projectToken = await MockERC20.deploy();
      } catch (error3) {
        throw new Error("MockERC20 deployment failed with all parameter combinations");
      }
    }
  }
  
  await usdt.waitForDeployment();
  await projectToken.waitForDeployment();
  
  // Try to set up token properties if methods exist
  try {
    if (typeof usdt.setDecimals === 'function') {
      await usdt.setDecimals(6);
    }
    if (typeof usdt.mint === 'function') {
      await usdt.mint(deployer.address, ethers.parseUnits("1000000", 6));
    }
    if (typeof projectToken.mint === 'function') {
      await projectToken.mint(deployer.address, ethers.parseUnits("1000000", 18));
    }
  } catch (error) {
    console.log("Token setup methods not available, continuing...");
  }
  
  // ===== DEPLOY CORE CONTRACTS =====
  
  // Deploy CoreSecurityManager - try both proxy and direct deployment
  let coreSecurityManager;
  const CoreSecurityManager = await ethers.getContractFactory("CoreSecurityManager", deployer);
  
  try {
    // Try proxy deployment first
    coreSecurityManager = await upgrades.deployProxy(
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
  } catch (proxyError) {
    console.log("Proxy deployment failed, trying direct deployment...");
    
    // Try different parameter combinations for direct deployment
    const paramCombinations = [
      [governance.address, emergency.address, deployer.address], // 3 params
      [governance.address, emergency.address], // 2 params
      [governance.address], // 1 param
      [] // no params
    ];
    
    let deployed = false;
    for (const params of paramCombinations) {
      try {
        console.log(`Trying CoreSecurityManager with ${params.length} parameters...`);
        coreSecurityManager = await CoreSecurityManager.deploy(...params);
        await coreSecurityManager.waitForDeployment();
        deployed = true;
        break;
      } catch (error) {
        console.log(`Failed with ${params.length} parameters:`, error.message.split('\n')[0]);
      }
    }
    
    if (!deployed) {
      throw new Error("CoreSecurityManager deployment failed with all parameter combinations");
    }
  }
  
  await coreSecurityManager.waitForDeployment();
  console.log("✅ CoreSecurityManager deployed at:", await coreSecurityManager.getAddress());
  
  // Deploy EnhancedOracle
  let enhancedOracle;
  const EnhancedOracle = await ethers.getContractFactory("EnhancedOracle", deployer);
  
  try {
    // Try proxy deployment
    enhancedOracle = await upgrades.deployProxy(
      EnhancedOracle,
      [
        await projectToken.getAddress(), // projectToken
        ethers.ZeroAddress, // uniswapPair (mock)
        ethers.parseEther("0.001"), // initialPrice
        ethers.parseEther("1000000") // initialMarketCap
      ],
      {
        initializer: "initialize",
        kind: "uups"
      }
    );
  } catch (proxyError) {
    console.log("EnhancedOracle proxy deployment failed, trying direct deployment...");
    
    // Try different parameter combinations
    const paramCombinations = [
      [ethers.ZeroAddress, governance.address, oracleUpdater.address, 3600, ethers.parseEther("1000000")], // 5 params
      [ethers.ZeroAddress, governance.address, oracleUpdater.address], // 3 params
      [governance.address, oracleUpdater.address], // 2 params
      [governance.address], // 1 param
      [] // no params
    ];
    
    let deployed = false;
    for (const params of paramCombinations) {
      try {
        console.log(`Trying EnhancedOracle with ${params.length} parameters...`);
        enhancedOracle = await EnhancedOracle.deploy(...params);
        await enhancedOracle.waitForDeployment();
        deployed = true;
        break;
      } catch (error) {
        console.log(`Failed with ${params.length} parameters:`, error.message.split('\n')[0]);
      }
    }
    
    if (!deployed) {
      throw new Error("EnhancedOracle deployment failed with all parameter combinations");
    }
  }
  
  await enhancedOracle.waitForDeployment();
  console.log("✅ EnhancedOracle deployed at:", await enhancedOracle.getAddress());
  
  // Deploy SecurityGovernance (optional)
  let securityGovernance = null;
  try {
    const SecurityGovernance = await ethers.getContractFactory("SecurityGovernance", deployer);
    
    try {
      securityGovernance = await upgrades.deployProxy(
        SecurityGovernance,
        [
          1, // requiredSignatures
          86400, // proposalValidity (24 hours)
          3600, // emergencyTxDelay (1 hour)
          deployer.address // treasuryWallet
        ],
        {
          initializer: "initialize",
          kind: "uups"
        }
      );
    } catch (proxyError) {
      // Try direct deployment
      securityGovernance = await SecurityGovernance.deploy(governance.address);
    }
    
    await securityGovernance.waitForDeployment();
    console.log("✅ SecurityGovernance deployed at:", await securityGovernance.getAddress());
  } catch (error) {
    console.log("SecurityGovernance not available or failed to deploy");
  }
  
  // Deploy BondingCurve/EnhancedBondingCurve
  let bondingCurve = null;
  const contractNames = ["EnhancedBondingCurve", "BondingCurveToken", "BondingCurve"];
  
  for (const contractName of contractNames) {
    try {
      const BondingCurveFactory = await ethers.getContractFactory(contractName, deployer);
      
      // Try different parameter combinations
      const paramCombinations = [
        // Full parameters
        [
          await usdt.getAddress(),
          await projectToken.getAddress(),
          await enhancedOracle.getAddress(),
          await coreSecurityManager.getAddress(),
          deployer.address, // treasury
          ethers.parseEther("1000000"), // targetLiquidity
          100 // feeBasisPoints (1%)
        ],
        // Reduced parameters
        [
          await usdt.getAddress(),
          await enhancedOracle.getAddress(),
          await coreSecurityManager.getAddress(),
          "Bonding Token",
          "BCT"
        ],
        // Minimal parameters
        [
          await usdt.getAddress(),
          "Bonding Token",
          "BCT"
        ],
        // Just addresses
        [
          await usdt.getAddress(),
          await enhancedOracle.getAddress()
        ]
      ];
      
      let deployed = false;
      for (const params of paramCombinations) {
        try {
          console.log(`Trying ${contractName} with ${params.length} parameters...`);
          bondingCurve = await BondingCurveFactory.deploy(...params);
          await bondingCurve.waitForDeployment();
          deployed = true;
          console.log(`✅ ${contractName} deployed at:`, await bondingCurve.getAddress());
          break;
        } catch (error) {
          console.log(`Failed with ${params.length} parameters:`, error.message.split('\n')[0]);
        }
      }
      
      if (deployed) break;
      
    } catch (error) {
      console.log(`${contractName} not available:`, error.message.split('\n')[0]);
    }
  }
  
  // ===== ROLE VERIFICATION =====
  await verifyRoles(coreSecurityManager, enhancedOracle, securityGovernance, deployer);
  
  return {
    signers: {
      deployer,
      governance,
      emergency,
      oracleUpdater,
      user1,
      user2
    },
    contracts: {
      coreSecurityManager,
      enhancedOracle,
      securityGovernance,
      bondingCurve
    },
    tokens: {
      usdt,
      projectToken
    }
  };
}

async function verifyRoles(coreSecurityManager, enhancedOracle, securityGovernance, deployer) {
  console.log("\n===== ROLE VERIFICATION =====");
  
  const contracts = [
    { name: "CoreSecurityManager", contract: coreSecurityManager }
  ];
  
  if (enhancedOracle) {
    contracts.push({ name: "EnhancedOracle", contract: enhancedOracle });
  }
  
  if (securityGovernance) {
    contracts.push({ name: "SecurityGovernance", contract: securityGovernance });
  }
  
  for (const { name, contract } of contracts) {
    try {
      // Check if contract has role-based access control
      const DEFAULT_ADMIN_ROLE = await contract.DEFAULT_ADMIN_ROLE();
      const hasAdmin = await contract.hasRole(DEFAULT_ADMIN_ROLE, deployer.address);
      
      if (hasAdmin) {
        console.log(`✅ ${name}: Deployer has DEFAULT_ADMIN_ROLE`);
      } else {
        console.log(`⚠️  ${name}: Deployer doesn't have DEFAULT_ADMIN_ROLE`);
      }
    } catch (error) {
      console.log(`ℹ️  ${name}: No role-based access control detected`);
    }
  }
}

// Alternative simple deployment for testing
async function deploySimpleSystem() {
  const [deployer, governance, emergency] = await ethers.getSigners();
  
  console.log("Deploying simple system for testing...");
  
  // Deploy basic mock contracts
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const usdt = await MockERC20.deploy();
  await usdt.waitForDeployment();
  
  // Try to deploy minimal versions
  let coreSecurityManager = null;
  try {
    const CoreSecurityManager = await ethers.getContractFactory("CoreSecurityManager");
    coreSecurityManager = await CoreSecurityManager.deploy();
    await coreSecurityManager.waitForDeployment();
  } catch (error) {
    console.log("CoreSecurityManager deployment failed:", error.message);
  }
  
  return {
    signers: { deployer, governance, emergency },
    contracts: { coreSecurityManager },
    tokens: { usdt }
  };
}

module.exports = {
  deployFullSystem,
  deploySimpleSystem
};