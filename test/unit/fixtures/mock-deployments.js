// test/fixtures/mock-deployments.js
const { ethers, upgrades } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");
const { TEST_CONSTANTS } = require("./test-data");

/**
 * @title Mock Deployments
 * @notice Centralized deployment fixtures for testing
 * @dev Provides a consistent, fully configured deployment for all integration tests.
 */

async function deployFullSystem() {
  // 1. GET SIGNERS
  const [
    deployer, governance, emergency, monitor, paramManager, 
    oracleUpdater, treasury, user1, user2, user3
  ] = await ethers.getSigners();
  
  const signers = {
    deployer, governance, emergency, monitor, paramManager,
    oracleUpdater, treasury, user1, user2, user3
  };

  // 2. DEPLOY LIBRARIES
  const SecurityLibraries = await ethers.getContractFactory("SecurityLibraries");
  const securityLibraries = await SecurityLibraries.deploy();
  
  const OracleLibraries = await ethers.getContractFactory("OracleLibraries");
  const oracleLibraries = await OracleLibraries.deploy();
  
  const UtilityLibraries = await ethers.getContractFactory("UtilityLibraries");
  const utilityLibraries = await UtilityLibraries.deploy();

  const libraries = { securityLibraries, oracleLibraries, utilityLibraries };

  // 3. DEPLOY MOCK TOKENS & DEX
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const usdt = await MockERC20.deploy("Mock USDT", "USDT", 6, ethers.parseUnits("10000000", 6));
  const qorafi = await MockERC20.deploy("Qorafi Token", "QORAFI", 18, ethers.parseEther("10000000"));
  const weth = await MockERC20.deploy("Wrapped Ether", "WETH", 18, ethers.parseEther("1000000"));
  const tokens = { usdt, qorafi, weth };

  const MockRouter = await ethers.getContractFactory("MockRouter");
  const router = await MockRouter.deploy(await weth.getAddress());
  
  const MockUniswapV2Pair = await ethers.getContractFactory("MockUniswapV2Pair");
  const qorafiUsdtPair = await MockUniswapV2Pair.deploy(await qorafi.getAddress(), await usdt.getAddress());
  await qorafiUsdtPair.setReserves(ethers.parseEther("100000"), ethers.parseUnits("100000", 6));
  const dex = { router, qorafiUsdtPair };

  // 4. DEPLOY CORE & ADVANCED CONTRACTS
  const CoreSecurityManager = await ethers.getContractFactory("CoreSecurityManager");
  const coreSecurityManager = await upgrades.deployProxy(CoreSecurityManager, [await usdt.getAddress(), await qorafi.getAddress(), treasury.address], { kind: 'uups' });

  const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager");
  const advancedSecurityManager = await upgrades.deployProxy(AdvancedSecurityManager, [await usdt.getAddress(), await qorafi.getAddress(), treasury.address], { kind: 'uups' });
  await advancedSecurityManager.initializeAdvanced(24 * 60 * 60, 1, 3);

  const EnhancedOracle = await ethers.getContractFactory("EnhancedOracle");
  const enhancedOracle = await upgrades.deployProxy(EnhancedOracle, [
    await usdt.getAddress(), await qorafi.getAddress(), await dex.qorafiUsdtPair.getAddress(),
    ethers.parseEther("100000"), ethers.parseEther("10000000"),
    governance.address, oracleUpdater.address
  ], { kind: 'uups' });

  const SecurityGovernance = await ethers.getContractFactory("SecurityGovernance");
  const securityGovernance = await upgrades.deployProxy(SecurityGovernance, [treasury.address, 24 * 60 * 60, 2], { kind: 'uups' });

  const EnhancedBondingCurve = await ethers.getContractFactory("EnhancedBondingCurve");
  const enhancedBondingCurve = await upgrades.deployProxy(EnhancedBondingCurve, [
      await tokens.usdt.getAddress(),
      await tokens.qorafi.getAddress(),
      await dex.router.getAddress(),
      await advancedSecurityManager.getAddress(),
      await enhancedOracle.getAddress(),
      ethers.ZeroAddress
  ], { kind: 'uups' });

  const contracts = {
    coreSecurityManager,
    advancedSecurityManager,
    enhancedOracle,
    securityGovernance,
    enhancedBondingCurve,
    ...dex
  };

  // 5. SETUP ROLES
  await setupRoles(contracts, signers);

  // 6. SETUP BALANCES
  await tokens.usdt.mint(signers.user1.address, ethers.parseUnits("1000000", 6));
  await tokens.qorafi.mint(signers.user1.address, ethers.parseEther("100000"));

  // 7. INITIALIZE ORACLE
  for (let i = 0; i < 5; i++) {
    await time.increase(TEST_CONSTANTS.MIN_ORACLE_UPDATE_INTERVAL + 1);
    await enhancedOracle.connect(oracleUpdater).updateMarketCap();
  }
  
  return { contracts, tokens, libraries, signers };
}

async function setupRoles(contracts, signers) {
    const { deployer, governance, emergency, monitor, paramManager, oracleUpdater } = signers;
    const { coreSecurityManager, advancedSecurityManager, enhancedOracle, securityGovernance } = contracts;

    const coreAdmin = deployer;
    const advancedAdmin = deployer;
    const oracleAdmin = governance;
    const securityGovAdmin = deployer;

    // Grant roles to user signers
    if (coreSecurityManager) {
        const GOVERNANCE_ROLE = await coreSecurityManager.GOVERNANCE_ROLE();
        const EMERGENCY_ROLE = await coreSecurityManager.EMERGENCY_ROLE();
        await coreSecurityManager.connect(coreAdmin).grantRole(GOVERNANCE_ROLE, governance.address);
        await coreSecurityManager.connect(coreAdmin).grantRole(EMERGENCY_ROLE, emergency.address);
    }
    
    if (advancedSecurityManager) {
        const MONITOR_ROLE = await advancedSecurityManager.MONITOR_ROLE();
        const EMERGENCY_ROLE = await advancedSecurityManager.EMERGENCY_ROLE();
        await advancedSecurityManager.connect(advancedAdmin).grantRole(MONITOR_ROLE, monitor.address);
        await advancedSecurityManager.connect(advancedAdmin).grantRole(EMERGENCY_ROLE, emergency.address);
    }
    
    if (enhancedOracle) {
        const ORACLE_UPDATER_ROLE = await enhancedOracle.ORACLE_UPDATER_ROLE();
        await enhancedOracle.connect(oracleAdmin).grantRole(ORACLE_UPDATER_ROLE, oracleUpdater.address);
    }
    
    if (securityGovernance) {
        const EMERGENCY_ROLE = await securityGovernance.EMERGENCY_ROLE();
        const PARAM_MANAGER_ROLE = await securityGovernance.PARAM_MANAGER_ROLE();
        await securityGovernance.connect(securityGovAdmin).grantRole(EMERGENCY_ROLE, emergency.address);
        await securityGovernance.connect(securityGovAdmin).grantRole(PARAM_MANAGER_ROLE, paramManager.address);
        await securityGovernance.connect(securityGovAdmin).grantRole(PARAM_MANAGER_ROLE, governance.address);
    }

    // Grant cross-contract permissions
    if (securityGovernance && coreSecurityManager) {
        const PAUSER_ROLE = await coreSecurityManager.PAUSER_ROLE();
        await coreSecurityManager.connect(coreAdmin).grantRole(PAUSER_ROLE, await securityGovernance.getAddress());
    }
    if (securityGovernance && advancedSecurityManager) {
        const PAUSER_ROLE = await advancedSecurityManager.PAUSER_ROLE();
        await advancedSecurityManager.connect(advancedAdmin).grantRole(PAUSER_ROLE, await securityGovernance.getAddress());
    }
}

module.exports = { deployFullSystem };