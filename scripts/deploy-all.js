// scripts/deploy/deploy-all.js
const { ethers, upgrades } = require("hardhat");

async function main() {
  console.log("🚀 Deploying Full Qorafi Protocol...");

  const [deployer, governance, emergency, monitor, paramManager, oracleUpdater, treasury] = await ethers.getSigners();
  const accounts = { deployer, governance, emergency, monitor, paramManager, oracleUpdater, treasury };

  const deploymentInfo = {
    contracts: {},
    errors: []
  };

  console.log("Deployment Accounts:");
  for (const [name, account] of Object.entries(accounts)) {
    console.log(`  - ${name}: ${account.address}`);
  }

  // 1. Deploy Libraries
  console.log("\n📚 Step 1: Deploying Libraries...");
  const SecurityLibraries = await ethers.getContractFactory("SecurityLibraries");
  const securityLibraries = await SecurityLibraries.deploy();
  await securityLibraries.waitForDeployment();
  const securityLibrariesAddress = await securityLibraries.getAddress();
  deploymentInfo.contracts.SecurityLibraries = securityLibrariesAddress;
  console.log("✅ SecurityLibraries deployed to:", securityLibrariesAddress);

  const OracleLibraries = await ethers.getContractFactory("OracleLibraries");
  const oracleLibraries = await OracleLibraries.deploy();
  await oracleLibraries.waitForDeployment();
  const oracleLibrariesAddress = await oracleLibraries.getAddress();
  deploymentInfo.contracts.OracleLibraries = oracleLibrariesAddress;
  console.log("✅ OracleLibraries deployed to:", oracleLibrariesAddress);
  
  const UtilityLibraries = await ethers.getContractFactory("UtilityLibraries");
  const utilityLibraries = await UtilityLibraries.deploy();
  await utilityLibraries.waitForDeployment();
  const utilityLibrariesAddress = await utilityLibraries.getAddress();
  deploymentInfo.contracts.UtilityLibraries = utilityLibrariesAddress;
  console.log("✅ UtilityLibraries deployed to:", utilityLibrariesAddress);

  // 2. Deploy QoraFi Token
  console.log("\n💰 Step 2: Deploying Core QoraFi Token...");
  const QoraFi = await ethers.getContractFactory("QoraFi");
  const qorafiToken = await QoraFi.deploy("QoraFi", "QORAFI", treasury.address);
  await qorafiToken.waitForDeployment();
  const qorafiAddress = await qorafiToken.getAddress();
  deploymentInfo.contracts.qorafiToken = qorafiAddress;
  console.log("✅ QoraFi Token deployed to:", qorafiAddress);

  // 3. Deploy USQ Stablecoin System
  console.log("\n💵 Step 3: Deploying USQ Stablecoin System...");
  const USQEngine = await ethers.getContractFactory("USQEngine");
  const usqEngine = await USQEngine.deploy(treasury.address);
  await usqEngine.waitForDeployment();
  const usqEngineAddress = await usqEngine.getAddress();
  deploymentInfo.contracts.usqEngine = usqEngineAddress;
  console.log("✅ USQEngine deployed to:", usqEngineAddress);

  const usqAddress = await usqEngine.usq();
  deploymentInfo.contracts.usqToken = usqAddress;
  console.log("✅ USQ Token (from Engine) at:", usqAddress);

  const Oracle = await ethers.getContractFactory("Oracle");
  const usqOracle = await Oracle.deploy();
  await usqOracle.waitForDeployment();
  const usqOracleAddress = await usqOracle.getAddress();
  deploymentInfo.contracts.usqOracle = usqOracleAddress;
  console.log("✅ USQ Oracle deployed to:", usqOracleAddress);
  
  // 4. Deploy Mock DEX Components
  console.log("\n🔄 Step 4: Deploying Mock DEX Components...");
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const usdtToken = await MockERC20.deploy("Mock USDT", "USDT", 6, ethers.parseUnits("10000000", 6));
  await usdtToken.waitForDeployment();
  const usdtAddress = await usdtToken.getAddress();
  deploymentInfo.contracts.usdtToken = usdtAddress;
  console.log("✅ USDT Token deployed to:", usdtAddress);

  const MockUniswapV2Pair = await ethers.getContractFactory("MockUniswapV2Pair");
  const pair = await MockUniswapV2Pair.deploy(qorafiAddress, usdtAddress);
  await pair.waitForDeployment();
  await pair.setReserves(ethers.parseEther("100000"), ethers.parseUnits("100000", 6));
  const pairAddress = await pair.getAddress();
  deploymentInfo.contracts.lpPair = pairAddress;
  console.log("✅ Mock LP Pair deployed to:", pairAddress);

  const MockRouter = await ethers.getContractFactory("MockRouter");
  const router = await MockRouter.deploy("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"); // WETH address
  await router.waitForDeployment();
  const routerAddress = await router.getAddress();
  deploymentInfo.contracts.router = routerAddress;
  console.log("✅ Mock Router deployed to:", routerAddress);

  // 5. Deploy Core Security & Enhanced Oracle
  console.log("\n🛡️ Step 5: Deploying Core Security & Enhanced Oracle...");
  const CoreSecurityManager = await ethers.getContractFactory("CoreSecurityManager");
  const coreSecurityManager = await upgrades.deployProxy(CoreSecurityManager, [usdtAddress, qorafiAddress, treasury.address], { kind: 'uups' });
  await coreSecurityManager.waitForDeployment();
  const coreSecurityManagerAddress = await coreSecurityManager.getAddress();
  deploymentInfo.contracts.CoreSecurityManager = coreSecurityManagerAddress;
  console.log("✅ CoreSecurityManager deployed to:", coreSecurityManagerAddress);

  const EnhancedOracle = await ethers.getContractFactory("EnhancedOracle");
  const enhancedOracle = await upgrades.deployProxy(EnhancedOracle, [
    usdtAddress, qorafiAddress, pairAddress,
    ethers.parseEther("100000"), ethers.parseEther("10000000"),
    governance.address, oracleUpdater.address
  ], { kind: 'uups' });
  await enhancedOracle.waitForDeployment();
  const enhancedOracleAddress = await enhancedOracle.getAddress();
  deploymentInfo.contracts.EnhancedOracle = enhancedOracleAddress;
  console.log("✅ EnhancedOracle deployed to:", enhancedOracleAddress);

  // 6. Deploy Advanced & Security Governance
  console.log("\n🔬 Step 6: Deploying Advanced & Security Governance...");
  const AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager");
  const advancedSecurityManager = await upgrades.deployProxy(AdvancedSecurityManager, [usdtAddress, qorafiAddress, treasury.address], { kind: 'uups' });
  await advancedSecurityManager.waitForDeployment();
  await advancedSecurityManager.initializeAdvanced(86400, 1, 3);
  const advancedSecurityManagerAddress = await advancedSecurityManager.getAddress();
  deploymentInfo.contracts.AdvancedSecurityManager = advancedSecurityManagerAddress;
  console.log("✅ AdvancedSecurityManager deployed to:", advancedSecurityManagerAddress);

  const SecurityGovernance = await ethers.getContractFactory("SecurityGovernance");
  const securityGovernance = await upgrades.deployProxy(SecurityGovernance, [treasury.address, 86400, 2], { kind: 'uups' });
  await securityGovernance.waitForDeployment();
  const securityGovernanceAddress = await securityGovernance.getAddress();
  deploymentInfo.contracts.SecurityGovernance = securityGovernanceAddress;
  console.log("✅ SecurityGovernance deployed to:", securityGovernanceAddress);

  // 7. Deploy Staking Contracts
  console.log("\n🔒 Step 7: Deploying Staking Contracts...");
  const ProofOfLiquidity = await ethers.getContractFactory("ProofOfLiquidity");
  const proofOfLiquidity = await ProofOfLiquidity.deploy(pairAddress);
  await proofOfLiquidity.waitForDeployment();
  const proofOfLiquidityAddress = await proofOfLiquidity.getAddress();
  deploymentInfo.contracts.ProofOfLiquidity = proofOfLiquidityAddress;
  console.log("✅ ProofOfLiquidity (Vault) deployed to:", proofOfLiquidityAddress);

  const RewardEngine = await ethers.getContractFactory("RewardEngine");
  const rewardEngine = await RewardEngine.deploy(
    qorafiAddress, pairAddress, enhancedOracleAddress, proofOfLiquidityAddress, treasury.address
  );
  await rewardEngine.waitForDeployment();
  const rewardEngineAddress = await rewardEngine.getAddress();
  deploymentInfo.contracts.RewardEngine = rewardEngineAddress;
  console.log("✅ RewardEngine deployed to:", rewardEngineAddress);
  
  // 8. Deploy Rewards & Distribution Contracts
  console.log("\n🎁 Step 8: Deploying Rewards & Distribution Contracts...");
  const DelegatorDistributor = await ethers.getContractFactory("DelegatorDistributor");
  const delegatorDistributor = await DelegatorDistributor.deploy(qorafiAddress, treasury.address);
  await delegatorDistributor.waitForDeployment();
  const delegatorDistributorAddress = await delegatorDistributor.getAddress();
  deploymentInfo.contracts.DelegatorDistributor = delegatorDistributorAddress;
  console.log("✅ DelegatorDistributor deployed to:", delegatorDistributorAddress);

  const PoolRewardDistributor = await ethers.getContractFactory("PoolRewardDistributor");
  const poolRewardDistributor = await PoolRewardDistributor.deploy(
      qorafiAddress, proofOfLiquidityAddress, usqEngineAddress, treasury.address
  );
  await poolRewardDistributor.waitForDeployment();
  const poolRewardDistributorAddress = await poolRewardDistributor.getAddress();
  deploymentInfo.contracts.PoolRewardDistributor = poolRewardDistributorAddress;
  console.log("✅ PoolRewardDistributor deployed to:", poolRewardDistributorAddress);

  const levelDepositRequirements = Array(15).fill(0).map((_, i) => ethers.parseUnits(((i + 1) * 100).toString(), 6));
  const levelRewardPercentagesBPS = Array(15).fill(0).map((_, i) => (i + 1) * 50);
  const DelegatorNodeRewardsLedger = await ethers.getContractFactory("DelegatorNodeRewardsLedger");
  const delegatorNodeRewardsLedger = await DelegatorNodeRewardsLedger.deploy(
      levelDepositRequirements, levelRewardPercentagesBPS, treasury.address,
      poolRewardDistributorAddress, ethers.ZeroAddress
  );
  await delegatorNodeRewardsLedger.waitForDeployment();
  const delegatorNodeRewardsLedgerAddress = await delegatorNodeRewardsLedger.getAddress();
  deploymentInfo.contracts.DelegatorNodeRewardsLedger = delegatorNodeRewardsLedgerAddress;
  console.log("✅ DelegatorNodeRewardsLedger deployed to:", delegatorNodeRewardsLedgerAddress);

  // 9. Deploy EnhancedBondingCurve
  console.log("\n📈 Step 9: Deploying EnhancedBondingCurve...");
  const EnhancedBondingCurve = await ethers.getContractFactory("EnhancedBondingCurve");
  const enhancedBondingCurve = await upgrades.deployProxy(EnhancedBondingCurve, [
    usdtAddress, qorafiAddress, routerAddress, advancedSecurityManagerAddress,
    enhancedOracleAddress, delegatorNodeRewardsLedgerAddress
  ], { kind: 'uups' });
  await enhancedBondingCurve.waitForDeployment();
  const enhancedBondingCurveAddress = await enhancedBondingCurve.getAddress();
  deploymentInfo.contracts.EnhancedBondingCurve = enhancedBondingCurveAddress;
  console.log("✅ EnhancedBondingCurve deployed to:", enhancedBondingCurveAddress);

  // 10. Deploy RWA Contracts
  console.log("\n🏢 Step 10: Deploying RWA Contracts...");
  const QoraFiRWA = await ethers.getContractFactory("QoraFiRWA");
  const qorafiRwaToken = await QoraFiRWA.deploy();
  await qorafiRwaToken.waitForDeployment();
  const qorafiRwaAddress = await qorafiRwaToken.getAddress();
  deploymentInfo.contracts.QoraFiRWA = qorafiRwaAddress;
  console.log("✅ QoraFiRWA (ERC1155) deployed to:", qorafiRwaAddress);

  const RWAFactory = await ethers.getContractFactory("RWAFactory");
  const rwaFactory = await RWAFactory.deploy(
    qorafiRwaAddress,
    qorafiAddress,
    usqAddress,
    routerAddress,
    proofOfLiquidityAddress,
    treasury.address,
    ethers.parseEther("100"), // 100 QoraFi creation fee
    ethers.parseUnits("500", 6) // 500 USDT min staking value
  );
  await rwaFactory.waitForDeployment();
  const rwaFactoryAddress = await rwaFactory.getAddress();
  deploymentInfo.contracts.RWAFactory = rwaFactoryAddress;
  console.log("✅ RWAFactory deployed to:", rwaFactoryAddress);

  // 11. Deploy DAO Governance Contracts
  console.log("\n⚖️ Step 11: Deploying DAO Governance...");
  const QoraFiTimelock = await ethers.getContractFactory("QoraFiTimelock");
  const timelock = await QoraFiTimelock.deploy(2 * 24 * 60 * 60, [], [ethers.ZeroAddress]);
  await timelock.waitForDeployment();
  const timelockAddress = await timelock.getAddress();
  deploymentInfo.contracts.QoraFiTimelock = timelockAddress;
  console.log("✅ QoraFiTimelock deployed to:", timelockAddress);

  const QoraFiGovernor = await ethers.getContractFactory("QoraFiGovernor");
  const governor = await QoraFiGovernor.deploy(
    qorafiAddress, timelockAddress, proofOfLiquidityAddress, pairAddress,
    1, 45818, ethers.parseEther("1000"), ethers.parseEther("400000")
  );
  await governor.waitForDeployment();
  const governorAddress = await governor.getAddress();
  deploymentInfo.contracts.QoraFiGovernor = governorAddress;
  console.log("✅ QoraFiGovernor deployed to:", governorAddress);

  // 12. Final Configuration
  console.log("\n🔗 Step 12: Final Configuration...");
  await proofOfLiquidity.setRewardEngine(rewardEngineAddress);
  console.log("✅ Linked RewardEngine to ProofOfLiquidity vault.");
  
  await delegatorNodeRewardsLedger.setBondingCurveAddress(enhancedBondingCurveAddress);
  console.log("✅ Linked BondingCurve to DelegatorNodeRewardsLedger.");

  await poolRewardDistributor.setAuthorizedFunder(delegatorNodeRewardsLedgerAddress);
  console.log("✅ Set Ledger as funder for PoolRewardDistributor.");

  await qorafiToken.setFeeDestinations(usqEngineAddress, deployer.address /* dev wallet */, delegatorDistributorAddress);
  console.log("✅ Set fee destinations on QoraFi token.");

  await usqEngine.setOracle(usqOracleAddress);
  console.log("✅ Set Oracle on USQEngine.");

  await qorafiRwaToken.transferOwnership(rwaFactoryAddress);
  console.log("✅ Transferred QoraFiRWA ownership to RWAFactory.");

  const proposerRole = await timelock.PROPOSER_ROLE();
  const adminRole = await timelock.TIMELOCK_ADMIN_ROLE();

  await timelock.grantRole(proposerRole, governorAddress);
  console.log("✅ Granted Proposer role on Timelock to Governor.");
  
  await timelock.renounceRole(adminRole, deployer.address);
  console.log("✅ Renounced Timelock admin role. Timelock is now self-governed.");

  console.log("\n\n🎉 All contracts deployed successfully!");
  console.log(JSON.stringify(deploymentInfo, null, 2));
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ Deployment script failed:", error);
    process.exit(1);
  });
