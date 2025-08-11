// test/fixtures/mock-deployments.js
const { ethers, upgrades } = require("hardhat");

/**
 * @title Mock Deployments
 * @notice Centralized deployment fixtures for testing
 * @dev Provides consistent deployment setup across all test suites
 */

async function deployMockTokens() {
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  
  const usdt = await MockERC20.deploy(
    "Mock USDT", 
    "USDT", 
    6, 
    ethers.parseUnits("10000000", 6) // 10M USDT
  );
  
  const qorafi = await MockERC20.deploy(
    "Qorafi Token", 
    "QORAFI", 
    18, 
    ethers.parseEther("10000000") // 10M QORAFI
  );
  
  const weth = await MockERC20.deploy(
    "Wrapped Ether", 
    "WETH", 
    18, 
    ethers.parseEther("1000000") // 1M WETH
  );
  
  return { usdt, qorafi, weth };
}

async function deployMockDEX(tokens) {
  const MockRouter = await ethers.getContractFactory("MockRouter");
  const router = await MockRouter.deploy(await tokens.weth.getAddress());
  
  const MockUniswapV2Pair = await ethers.getContractFactory("MockUniswapV2Pair");
  const qorafiUsdtPair = await MockUniswapV2Pair.deploy(
    await tokens.qorafi.getAddress(),
    await tokens.usdt.getAddress()
  );
  
  // Set initial reserves for 1:1 price (100k each)
  await qorafiUsdtPair.setReserves(
    ethers.parseEther("100000"), // 100k QORAFI
    ethers.parseUnits("100000", 6) // 100k USDT
  );
  
  // Set exchange rates in router for testing
  await router.setExchangeRate(
    await tokens.usdt.getAddress(),
    await tokens.qorafi.getAddress(),
    ethers.parseEther("1") // 1:1 rate
  );
  
  await router.setExchangeRate(
    await tokens.weth.getAddress(),
    await tokens.usdt.getAddress(),
    ethers.parseUnits("2000", 6) // 1 ETH = 2000 USDT
  );
  
  return { router, qorafiUsdtPair };
}

async function deployLibraries() {
  const SecurityLibraries = await ethers.getContractFactory("SecurityLibraries");
  const securityLibraries = await SecurityLibraries.deploy();
  
  const OracleLibraries = await ethers.getContractFactory("OracleLibraries");
  const oracleLibraries = await OracleLibraries.deploy();
  
  const UtilityLibraries = await ethers.getContractFactory("UtilityLibraries");
  const utilityLibraries = await UtilityLibraries.deploy();
  
  return { securityLibraries, oracleLibraries, utilityLibraries };
}

async function deployCoreSecurityManager(tokens, libraries, treasury) {
  const CoreSecurityManager = await ethers.getContractFactory("CoreSecurityManager", {
    libraries: {
      MEVLib: await libraries.securityLibraries.getAddress(),
      CircuitBreakerLib: await libraries.securityLibraries.getAddress(),
      ValidationLib: await libraries.securityLibraries.getAddress(),
    },
  });
  
  const coreSecurityManager = await upgrades.deployProxy(CoreSecurityManager, [
    await tokens.usdt.getAddress(),
    await tokens.qorafi.getAddress(),
    treasury.address
  ], {
    initializer: 'initialize',
    kind: 'uups',
    unsafeAllow: ['external-library-linking']
  });
  
  return coreSecurityManager;
}

async function deployAdvancedSecurityManager(tokens, libraries, treasury) {
  const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager", {
    libraries: {
      MEVLib: await libraries.securityLibraries.getAddress(),
      CircuitBreakerLib: await libraries.securityLibraries.getAddress(),
      EmergencyLib: await libraries.securityLibraries.getAddress(),
      ValidationLib: await libraries.securityLibraries.getAddress(),
    },
  });
  
  const advancedSecurityManager = await upgrades.deployProxy(AdvancedSecurityManager, [
    await tokens.usdt.getAddress(),
    await tokens.qorafi.getAddress(),
    treasury.address
  ], {
    initializer: 'initialize',
    kind: 'uups',
    unsafeAllow: ['external-library-linking']
  });
  
  // Initialize advanced features
  await advancedSecurityManager.initializeAdvanced(
    24 * 60 * 60, // 24 hours emergency delay
    1, // max 1 update per block
    3  // 3 block flash loan detection window
  );
  
  return advancedSecurityManager;
}

async function deployEnhancedOracle(tokens, dex, libraries, governance, oracleUpdater) {
  const EnhancedOracle = await ethers.getContractFactory("EnhancedOracle", {
    libraries: {
      TWAPLib: await libraries.oracleLibraries.getAddress(),
      PriceValidationLib: await libraries.oracleLibraries.getAddress(),
      LiquidityMonitorLib: await libraries.oracleLibraries.getAddress(),
      FlashLoanDetectionLib: await libraries.oracleLibraries.getAddress(),
      CumulativePriceLib: await libraries.oracleLibraries.getAddress(),
    },
  });
  
  const enhancedOracle = await upgrades.deployProxy(EnhancedOracle, [
    await tokens.usdt.getAddress(),
    await tokens.qorafi.getAddress(),
    await dex.qorafiUsdtPair.getAddress(),
    ethers.parseEther("100000"), // 100k min market cap
    ethers.parseEther("10000000"), // 10M max market cap
    governance.address,
    oracleUpdater.address
  ], {
    initializer: 'initialize',
    kind: 'uups',
    unsafeAllow: ['external-library-linking']
  });
  
  return enhancedOracle;
}

async function deploySecurityGovernance(libraries, treasury) {
  const SecurityGovernance = await ethers.getContractFactory("SecurityGovernance", {
    libraries: {
      EmergencyLib: await libraries.securityLibraries.getAddress(),
      ValidationLib: await libraries.securityLibraries.getAddress(),
    },
  });
  
  const securityGovernance = await upgrades.deployProxy(SecurityGovernance, [
    treasury.address,
    24 * 60 * 60, // 24 hours emergency delay
    2 // require 2 signatures
  ], {
    initializer: 'initialize',
    kind: 'uups',
    unsafeAllow: ['external-library-linking']
  });
  
  return securityGovernance;
}

async function setupRoles(contracts, signers) {
  // Core Security Manager roles
  if (contracts.coreSecurityManager) {
    const GOVERNANCE_ROLE = await contracts.coreSecurityManager.GOVERNANCE_ROLE();
    const EMERGENCY_ROLE = await contracts.coreSecurityManager.EMERGENCY_ROLE();
    const MONITOR_ROLE = await contracts.coreSecurityManager.MONITOR_ROLE();
    
    await contracts.coreSecurityManager.grantRole(GOVERNANCE_ROLE, signers.governance.address);
    await contracts.coreSecurityManager.grantRole(EMERGENCY_ROLE, signers.emergency.address);
    await contracts.coreSecurityManager.grantRole(MONITOR_ROLE, signers.monitor.address);
  }
  
  // Advanced Security Manager roles
  if (contracts.advancedSecurityManager) {
    const GOVERNANCE_ROLE = await contracts.advancedSecurityManager.GOVERNANCE_ROLE();
    const EMERGENCY_ROLE = await contracts.advancedSecurityManager.EMERGENCY_ROLE();
    const MONITOR_ROLE = await contracts.advancedSecurityManager.MONITOR_ROLE();
    
    await contracts.advancedSecurityManager.grantRole(GOVERNANCE_ROLE, signers.governance.address);
    await contracts.advancedSecurityManager.grantRole(EMERGENCY_ROLE, signers.emergency.address);
    await contracts.advancedSecurityManager.grantRole(MONITOR_ROLE, signers.monitor.address);
  }
  
  // Enhanced Oracle roles
  if (contracts.enhancedOracle) {
    const GOVERNANCE_ROLE = await contracts.enhancedOracle.GOVERNANCE_ROLE();
    const ORACLE_UPDATER_ROLE = await contracts.enhancedOracle.ORACLE_UPDATER_ROLE();
    
    await contracts.enhancedOracle.grantRole(GOVERNANCE_ROLE, signers.governance.address);
    await contracts.enhancedOracle.grantRole(ORACLE_UPDATER_ROLE, signers.oracleUpdater.address);
  }
  
  // Security Governance roles
  if (contracts.securityGovernance) {
    const EMERGENCY_ROLE = await contracts.securityGovernance.EMERGENCY_ROLE();
    const PARAM_MANAGER_ROLE = await contracts.securityGovernance.PARAM_MANAGER_ROLE();
    const UPGRADE_ROLE = await contracts.securityGovernance.UPGRADE_ROLE();
    
    await contracts.securityGovernance.grantRole(EMERGENCY_ROLE, signers.emergency.address);
    await contracts.securityGovernance.grantRole(PARAM_MANAGER_ROLE, signers.paramManager.address);
    await contracts.securityGovernance.grantRole(PARAM_MANAGER_ROLE, signers.governance.address);
    await contracts.securityGovernance.grantRole(UPGRADE_ROLE, signers.governance.address);
  }
}

async function setupTokenBalances(tokens, signers, contracts) {
  // Mint tokens to users for testing
  await tokens.usdt.mint(signers.user1.address, ethers.parseUnits("100000", 6)); // 100k USDT
  await tokens.usdt.mint(signers.user2.address, ethers.parseUnits("50000", 6));  // 50k USDT
  await tokens.usdt.mint(signers.treasury.address, ethers.parseUnits("1000000", 6)); // 1M USDT
  
  await tokens.qorafi.mint(signers.user1.address, ethers.parseEther("10000")); // 10k QORAFI
  await tokens.qorafi.mint(signers.user2.address, ethers.parseEther("5000"));  // 5k QORAFI
  await tokens.qorafi.mint(signers.treasury.address, ethers.parseEther("1000000")); // 1M QORAFI
  
  await tokens.weth.mint(signers.user1.address, ethers.parseEther("100")); // 100 WETH
  await tokens.weth.mint(signers.user2.address, ethers.parseEther("50"));  // 50 WETH
  
  // Set up LP pair liquidity
  if (contracts.qorafiUsdtPair) {
    await tokens.qorafi.mint(await contracts.qorafiUsdtPair.getAddress(), ethers.parseEther("500000"));
    await tokens.usdt.mint(await contracts.qorafiUsdtPair.getAddress(), ethers.parseUnits("500000", 6));
  }
}

/**
 * @notice Deploys a complete DeFi system for testing
 * @return Object containing all contracts, tokens, and signers
 */
async function deployFullSystem() {
  // Get signers
  const [
    deployer, 
    governance, 
    emergency, 
    monitor, 
    paramManager, 
    oracleUpdater, 
    treasury, 
    user1, 
    user2, 
    user3
  ] = await ethers.getSigners();
  
  const signers = {
    deployer,
    governance,
    emergency,
    monitor,
    paramManager,
    oracleUpdater,
    treasury,
    user1,
    user2,
    user3
  };
  
  // Deploy all components
  const tokens = await deployMockTokens();
  const libraries = await deployLibraries();
  const dex = await deployMockDEX(tokens);
  
  const coreSecurityManager = await deployCoreSecurityManager(tokens, libraries, treasury);
  const advancedSecurityManager = await deployAdvancedSecurityManager(tokens, libraries, treasury);
  const enhancedOracle = await deployEnhancedOracle(tokens, dex, libraries, governance, oracleUpdater);
  const securityGovernance = await deploySecurityGovernance(libraries, treasury);
  
  const contracts = {
    coreSecurityManager,
    advancedSecurityManager,
    enhancedOracle,
    securityGovernance,
    ...dex
  };
  
  // Setup roles and balances
  await setupRoles(contracts, signers);
  await setupTokenBalances(tokens, signers, contracts);
  
  return {
    contracts,
    tokens,
    libraries,
    signers
  };
}

/**
 * @notice Deploys minimal system for unit tests
 * @return Object containing minimal contracts and signers
 */
async function deployMinimalSystem() {
  const [deployer, governance, user1, user2, treasury] = await ethers.getSigners();
  
  const tokens = await deployMockTokens();
  const libraries = await deployLibraries();
  
  return {
    tokens,
    libraries,
    signers: { deployer, governance, user1, user2, treasury }
  };
}

/**
 * @notice Deploys only core contracts for focused testing
 * @return Object containing core contracts only
 */
async function deployCoreSystem() {
  const [deployer, governance, emergency, monitor, treasury, user1, user2] = await ethers.getSigners();
  
  const tokens = await deployMockTokens();
  const libraries = await deployLibraries();
  const dex = await deployMockDEX(tokens);
  
  const coreSecurityManager = await deployCoreSecurityManager(tokens, libraries, treasury);
  const enhancedOracle = await deployEnhancedOracle(tokens, dex, libraries, governance, deployer);
  
  const contracts = { coreSecurityManager, enhancedOracle, ...dex };
  const signers = { deployer, governance, emergency, monitor, treasury, user1, user2 };
  
  return { contracts, tokens, libraries, signers };
}

/**
 * @notice Deploys only advanced contracts for focused testing
 * @return Object containing advanced contracts only
 */
async function deployAdvancedSystem() {
  const [
    deployer, 
    governance, 
    emergency, 
    monitor, 
    paramManager, 
    treasury, 
    user1, 
    user2
  ] = await ethers.getSigners();
  
  const tokens = await deployMockTokens();
  const libraries = await deployLibraries();
  
  const advancedSecurityManager = await deployAdvancedSecurityManager(tokens, libraries, treasury);
  const securityGovernance = await deploySecurityGovernance(libraries, treasury);
  
  const contracts = { advancedSecurityManager, securityGovernance };
  const signers = { 
    deployer, 
    governance, 
    emergency, 
    monitor, 
    paramManager, 
    treasury, 
    user1, 
    user2 
  };
  
  await setupRoles(contracts, signers);
  
  return { contracts, tokens, libraries, signers };
}

module.exports = {
  deployFullSystem,
  deployMinimalSystem,
  deployCoreSystem,
  deployAdvancedSystem,
  deployMockTokens,
  deployLibraries,
  deployCoreSecurityManager,
  deployAdvancedSecurityManager,
  deployEnhancedOracle,
  deploySecurityGovernance,
  setupRoles,
  setupTokenBalances
};