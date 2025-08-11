// test/unit/core/CoreSecurityManager.test.js
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

describe("CoreSecurityManager", function () {
  async function deployCoreSecurityManagerFixture() {
    const [owner, user1, user2, treasury] = await ethers.getSigners();
    
    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const usdt = await MockERC20.deploy("Mock USDT", "USDT", 6, ethers.parseUnits("1000000", 6));
    const qorafi = await MockERC20.deploy("Qorafi Token", "QORAFI", 18, ethers.parseEther("1000000"));
    
    // Deploy libraries first
    const SecurityLibraries = await ethers.getContractFactory("SecurityLibraries");
    const securityLibraries = await SecurityLibraries.deploy();
    
    // Deploy CoreSecurityManager with libraries
    const CoreSecurityManager = await ethers.getContractFactory("CoreSecurityManager", {
      libraries: {
        MEVLib: await securityLibraries.getAddress(),
        CircuitBreakerLib: await securityLibraries.getAddress(),
        ValidationLib: await securityLibraries.getAddress(),
      },
    });
    
    const coreSecurityManager = await upgrades.deployProxy(CoreSecurityManager, [
      await usdt.getAddress(),
      await qorafi.getAddress(),
      treasury.address
    ], {
      initializer: 'initialize',
      kind: 'uups',
      unsafeAllow: ['external-library-linking']
    });
    
    return { 
      coreSecurityManager, 
      usdt, 
      qorafi, 
      owner, 
      user1, 
      user2, 
      treasury 
    };
  }

  describe("Initialization", function () {
    it("Should initialize with correct parameters", async function () {
      const { coreSecurityManager, usdt, qorafi, treasury } = await loadFixture(deployCoreSecurityManagerFixture);
      
      expect(await coreSecurityManager.usdtToken()).to.equal(await usdt.getAddress());
      expect(await coreSecurityManager.qorafiToken()).to.equal(await qorafi.getAddress());
      expect(await coreSecurityManager.treasuryWallet()).to.equal(treasury.address);
      expect(await coreSecurityManager.newTokenMode()).to.be.true;
    });

    it("Should set up initial security parameters", async function () {
      const { coreSecurityManager } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const cbStatus = await coreSecurityManager.getCircuitBreakerStatus();
      expect(cbStatus.volumeThreshold).to.equal(ethers.parseUnits("100000", 6));
      
      const newTokenSettings = await coreSecurityManager.getNewTokenSettings();
      expect(newTokenSettings.newTokenModeActive).to.be.true;
      expect(newTokenSettings.maxGasPriceSetting).to.equal(ethers.parseUnits("20", "gwei"));
    });
  });

  describe("MEV Protection", function () {
    it("Should allow first deposit", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const depositAmount = ethers.parseUnits("1000", 6);
      const [canDeposit, reason] = await coreSecurityManager.canUserDeposit(user1.address, depositAmount);
      
      expect(canDeposit).to.be.true;
      expect(reason).to.equal("OK");
    });

    it("Should prevent deposits that exceed daily limits", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const largeAmount = ethers.parseUnits("30000", 6); // Exceeds 25k daily limit
      const [canDeposit, reason] = await coreSecurityManager.canUserDeposit(user1.address, largeAmount);
      
      expect(canDeposit).to.be.false;
      expect(reason).to.include("limit");
    });

    it("Should track user MEV status correctly", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const mevStatus = await coreSecurityManager.getUserMEVStatus(user1.address);
      expect(mevStatus.lastBlock).to.equal(0);
      expect(mevStatus.canDeposit).to.be.true;
      expect(mevStatus.dailyUsed).to.equal(0);
    });
  });

  describe("Circuit Breaker", function () {
    it("Should trigger when volume threshold is exceeded", async function () {
      const { coreSecurityManager } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // This would require simulating large volume
      const largeVolume = ethers.parseUnits("150000", 6); // Exceeds 100k threshold
      
      await expect(
        coreSecurityManager.checkCircuitBreaker(largeVolume)
      ).to.emit(coreSecurityManager, "CircuitBreakerTriggered");
    });

    it("Should reset after cooldown period", async function () {
      const { coreSecurityManager } = await loadFixture(deployCoreSecurityManagerFixture);
      
      // Trigger circuit breaker
      const largeVolume = ethers.parseUnits("150000", 6);
      await coreSecurityManager.checkCircuitBreaker(largeVolume);
      
      // Fast forward time
      await time.increase(2 * 60 * 60 + 1); // 2 hours + 1 second
      
      const cbStatus = await coreSecurityManager.getCircuitBreakerStatus();
      expect(cbStatus.triggered).to.be.false;
    });
  });

  describe("Governance", function () {
    it("Should allow governance to update parameters", async function () {
      const { coreSecurityManager, owner } = await loadFixture(deployCoreSecurityManagerFixture);
      
      const newGasPrice = ethers.parseUnits("30", "gwei");
      await coreSecurityManager.connect(owner).setMaxGasPrice(newGasPrice);
      
      const settings = await coreSecurityManager.getNewTokenSettings();
      expect(settings.maxGasPriceSetting).to.equal(newGasPrice);
    });

    it("Should prevent non-governance from updating parameters", async function () {
      const { coreSecurityManager, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      await expect(
        coreSecurityManager.connect(user1).setMaxGasPrice(ethers.parseUnits("30", "gwei"))
      ).to.be.revertedWith("AccessControl");
    });
  });

  describe("Emergency Functions", function () {
    it("Should allow pauser to pause contract", async function () {
      const { coreSecurityManager, owner } = await loadFixture(deployCoreSecurityManagerFixture);
      
      await coreSecurityManager.connect(owner).pause();
      expect(await coreSecurityManager.isPaused()).to.be.true;
    });

    it("Should prevent operations when paused", async function () {
      const { coreSecurityManager, owner, user1 } = await loadFixture(deployCoreSecurityManagerFixture);
      
      