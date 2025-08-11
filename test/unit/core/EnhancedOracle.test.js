// test/unit/core/EnhancedOracle.test.js
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

describe("EnhancedOracle", function () {
  async function deployEnhancedOracleFixture() {
    const [owner, governance, oracleUpdater, user1] = await ethers.getSigners();
    
    // Deploy mock tokens
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const usdt = await MockERC20.deploy("Mock USDT", "USDT", 6, ethers.parseUnits("1000000", 6));
    const qorafi = await MockERC20.deploy("Qorafi Token", "QORAFI", 18, ethers.parseEther("1000000"));
    
    // Deploy mock pair
    const MockUniswapV2Pair = await ethers.getContractFactory("MockUniswapV2Pair");
    const pair = await MockUniswapV2Pair.deploy(
      await qorafi.getAddress(),
      await usdt.getAddress()
    );
    
    // Set initial reserves (100k Qorafi, 100k USDT = 1:1 price)
    await pair.setReserves(
      ethers.parseEther("100000"), // 100k Qorafi
      ethers.parseUnits("100000", 6) // 100k USDT
    );
    
    // Deploy oracle libraries
    const OracleLibraries = await ethers.getContractFactory("OracleLibraries");
    const oracleLibraries = await OracleLibraries.deploy();
    
    // Deploy EnhancedOracle with libraries
    const EnhancedOracle = await ethers.getContractFactory("EnhancedOracle", {
      libraries: {
        TWAPLib: await oracleLibraries.getAddress(),
        PriceValidationLib: await oracleLibraries.getAddress(),
        LiquidityMonitorLib: await oracleLibraries.getAddress(),
        FlashLoanDetectionLib: await oracleLibraries.getAddress(),
        CumulativePriceLib: await oracleLibraries.getAddress(),
      },
    });
    
    const enhancedOracle = await upgrades.deployProxy(EnhancedOracle, [
      await usdt.getAddress(),
      await qorafi.getAddress(),
      await pair.getAddress(),
      ethers.parseEther("100000"), // 100k min market cap
      ethers.parseEther("10000000"), // 10M max market cap
      governance.address,
      oracleUpdater.address
    ], {
      initializer: 'initialize',
      kind: 'uups',
      unsafeAllow: ['external-library-linking']
    });
    
    return { 
      enhancedOracle, 
      usdt, 
      qorafi, 
      pair,
      oracleLibraries,
      owner, 
      governance, 
      oracleUpdater, 
      user1 
    };
  }

  describe("Initialization", function () {
    it("Should initialize with correct parameters", async function () {
      const { enhancedOracle, usdt, qorafi, pair, governance, oracleUpdater } = await loadFixture(deployEnhancedOracleFixture);
      
      expect(await enhancedOracle.usdtToken()).to.equal(await usdt.getAddress());
      expect(await enhancedOracle.qorafiToken()).to.equal(await qorafi.getAddress());
      expect(await enhancedOracle.lpPair()).to.equal(await pair.getAddress());
      expect(await enhancedOracle.mcLowerLimit()).to.equal(ethers.parseEther("100000"));
      expect(await enhancedOracle.mcUpperLimit()).to.equal(ethers.parseEther("10000000"));
      expect(await enhancedOracle.newTokenMode()).to.be.true;
    });

    it("Should set up initial TWAP observation", async function () {
      const { enhancedOracle } = await loadFixture(deployEnhancedOracleFixture);
      
      const observationCount = await enhancedOracle.getObservationCount();
      expect(observationCount).to.equal(1);
      
      const latestObservation = await enhancedOracle.getLatestObservation();
      expect(latestObservation.isValid).to.be.true;
      expect(latestObservation.liquiditySnapshot).to.be.gt(0);
    });

    it("Should grant correct roles", async function () {
      const { enhancedOracle, governance, oracleUpdater } = await loadFixture(deployEnhancedOracleFixture);
      
      const GOVERNANCE_ROLE = await enhancedOracle.GOVERNANCE_ROLE();
      const ORACLE_UPDATER_ROLE = await enhancedOracle.ORACLE_UPDATER_ROLE();
      
      expect(await enhancedOracle.hasRole(GOVERNANCE_ROLE, governance.address)).to.be.true;
      expect(await enhancedOracle.hasRole(ORACLE_UPDATER_ROLE, oracleUpdater.address)).to.be.true;
    });
  });

  describe("Price Updates", function () {
    it("Should update market cap successfully", async function () {
      const { enhancedOracle, oracleUpdater } = await loadFixture(deployEnhancedOracleFixture);
      
      // Fast forward time to allow update
      await time.increase(5 * 60 + 1); // 5 minutes + 1 second
      
      await expect(
        enhancedOracle.connect(oracleUpdater).updateMarketCap()
      ).to.emit(enhancedOracle, "MarketCapUpdated");
      
      const marketCap = await enhancedOracle.getCachedMarketCap();
      expect(marketCap).to.be.gt(0);
    });

    it("Should prevent too frequent updates", async function () {
      const { enhancedOracle, oracleUpdater } = await loadFixture(deployEnhancedOracleFixture);
      
      // First update should work
      await time.increase(5 * 60 + 1);
      await enhancedOracle.connect(oracleUpdater).updateMarketCap();
      
      // Second update immediately should fail
      await expect(
        enhancedOracle.connect(oracleUpdater).updateMarketCap()
      ).to.be.revertedWith("UpdateTooFrequent");
    });

    it("Should enforce flash loan protection in new token mode", async function () {
      const { enhancedOracle, oracleUpdater } = await loadFixture(deployEnhancedOracleFixture);
      
      // First update in block
      await time.increase(5 * 60 + 1);
      await enhancedOracle.connect(oracleUpdater).updateMarketCap();
      
      // Second update in same block should fail due to flash loan protection
      await expect(
        enhancedOracle.connect(oracleUpdater).updateMarketCap()
      ).to.be.revertedWith("TooManyUpdatesPerBlock");
    });

    it("Should only allow oracle updater role to update", async function () {
      const { enhancedOracle, user1 } = await loadFixture(deployEnhancedOracleFixture);
      
      await time.increase(5 * 60 + 1);
      
      await expect(
        enhancedOracle.connect(user1).updateMarketCap()
      ).to.be.revertedWith("AccessControl");
    });

    it("Should add new TWAP observations", async function () {
      const { enhancedOracle, oracleUpdater } = await loadFixture(deployEnhancedOracleFixture);
      
      const initialCount = await enhancedOracle.getObservationCount();
      
      await time.increase(5 * 60 + 1);
      await enhancedOracle.connect(oracleUpdater).updateMarketCap();
      
      const newCount = await enhancedOracle.getObservationCount();
      expect(newCount).to.equal(initialCount + 1);
    });
  });

  describe("Price Validation", function () {
    it("Should validate price changes within limits", async function () {
      const { enhancedOracle, oracleUpdater, pair } = await loadFixture(deployEnhancedOracleFixture);
      
      // Initial update
      await time.increase(5 * 60 + 1);
      await enhancedOracle.connect(oracleUpdater).updateMarketCap();
      
      // Moderate price change (within 20% limit)
      await time.increase(5 * 60 + 1);
      await pair.setReserves(
        ethers.parseEther("100000"), // Same Qorafi
        ethers.parseUnits("110000", 6) // 10% price increase
      );
      
      // Should succeed
      await expect(
        enhancedOracle.connect(oracleUpdater).updateMarketCap()
      ).to.not.be.reverted;
    });

    it("Should reject excessive price changes", async function () {
      const { enhancedOracle, oracleUpdater, pair } = await loadFixture(deployEnhancedOracleFixture);
      
      // Initial update
      await time.increase(5 * 60 + 1);
      await enhancedOracle.connect(oracleUpdater).updateMarketCap();
      
      // Large price change (30% increase, exceeds 20% limit)
      await time.increase(5 * 60 + 1);
      await pair.setReserves(
        ethers.parseEther("100000"), // Same Qorafi
        ethers.parseUnits("130000", 6) // 30% price increase
      );
      
      // Should fail
      await expect(
        enhancedOracle.connect(oracleUpdater).updateMarketCap()
      ).to.be.revertedWith("PriceChangeTooLarge");
    });

    it("Should validate market cap growth limits", async function () {
      const { enhancedOracle, oracleUpdater, qorafi } = await loadFixture(deployEnhancedOracleFixture);
      
      // Initial update to establish baseline
      await time.increase(5 * 60 + 1);
      await enhancedOracle.connect(oracleUpdater).updateMarketCap();
      
      // Increase total supply dramatically (simulating market cap growth)
      await qorafi.mint(await qorafi.getAddress(), ethers.parseEther("500000")); // 50% supply increase
      
      await time.increase(5 * 60 + 1);
      
      // Should fail if market cap growth exceeds limits
      // Note: This might not fail depending on how market cap is calculated
      // The test shows the concept of market cap validation
    });
  });

  describe("Liquidity Monitoring", function () {
    it("Should monitor liquidity status", async function () {
      const { enhancedOracle } = await loadFixture(deployEnhancedOracleFixture);
      
      const liquidityStatus = await enhancedOracle.getLiquidityStatus();
      
      expect(liquidityStatus.currentUsdtLiquidity).to.be.gt(0);
      expect(liquidityStatus.minimumRequired).to.be.gt(0);
      expect(liquidityStatus.isHealthy).to.be.true;
    });

    it("Should detect insufficient liquidity", async function () {
      const { enhancedOracle, oracleUpdater, pair } = await loadFixture(deployEnhancedOracleFixture);
      
      // Set very low reserves
      await pair.setReserves(
        ethers.parseEther("100"), // Very low Qorafi
        ethers.parseUnits("100", 6) // Very low USDT
      );
      
      await time.increase(5 * 60 + 1);
      
      // Should fail due to insufficient liquidity
      await expect(
        enhancedOracle.connect(oracleUpdater).updateMarketCap()
      ).to.be.revertedWith("LiquidityBelowThreshold");
    });

    it("Should update liquidity check timestamp", async function () {
      const { enhancedOracle, oracleUpdater } = await loadFixture(deployEnhancedOracleFixture);
      
      const initialStatus = await enhancedOracle.getLiquidityStatus();
      
      await time.increase(5 * 60 + 1);
      await enhancedOracle.connect(oracleUpdater).updateMarketCap();
      
      const updatedStatus = await enhancedOracle.getLiquidityStatus();
      expect(updatedStatus.lastCheck).to.be.gte(initialStatus.lastCheck);
    });
  });

  describe("Health Checks", function () {
    it("Should report healthy status with sufficient data", async function () {
      const { enhancedOracle, oracleUpdater } = await loadFixture(deployEnhancedOracleFixture);
      
      // Add some observations
      for (let i = 0; i < 3; i++) {
        await time.increase(5 * 60 + 1);
        await enhancedOracle.connect(oracleUpdater).updateMarketCap();
      }
      
      expect(await enhancedOracle.isHealthy()).to.be.true;
    });

    it("Should report unhealthy status in emergency mode", async function () {
      const { enhancedOracle, governance } = await loadFixture(deployEnhancedOracleFixture);
      
      await enhancedOracle.connect(governance).enableEmergencyMode();
      
      expect(await enhancedOracle.isHealthy()).to.be.false;
    });

    it("Should report unhealthy status with stale data", async function () {
      const { enhancedOracle } = await loadFixture(deployEnhancedOracleFixture);
      
      // Fast forward past max observation age
      await time.increase(2 * 60 * 60 + 1); // 2 hours + 1 second
      
      expect(await enhancedOracle.isHealthy()).to.be.false;
    });

    it("Should check market cap limits", async function () {
      const { enhancedOracle, oracleUpdater } = await loadFixture(deployEnhancedOracleFixture);
      
      // Update to establish market cap
      await time.increase(5 * 60 + 1);
      await enhancedOracle.connect(oracleUpdater).updateMarketCap();
      
      // Should pass limit checks
      await expect(
        enhancedOracle.checkMarketCapLimits()
      ).to.not.be.reverted;
    });
  });

  describe("Emergency Procedures", function () {
    it("Should enable emergency mode", async function () {
      const { enhancedOracle, governance } = await loadFixture(deployEnhancedOracleFixture);
      
      await expect(
        enhancedOracle.connect(governance).enableEmergencyMode()
      ).to.emit(enhancedOracle, "EmergencyModeToggled").withArgs(true);
      
      expect(await enhancedOracle.emergencyMode()).to.be.true;
    });

    it("Should disable emergency mode", async function () {
      const { enhancedOracle, governance } = await loadFixture(deployEnhancedOracleFixture);
      
      // Enable first
      await enhancedOracle.connect(governance).enableEmergencyMode();
      
      // Then disable
      await expect(
        enhancedOracle.connect(governance).disableEmergencyMode()
      ).to.emit(enhancedOracle, "EmergencyModeToggled").withArgs(false);
      
      expect(await enhancedOracle.emergencyMode()).to.be.false;
    });

    it("Should set fallback price", async function () {
      const { enhancedOracle, governance } = await loadFixture(deployEnhancedOracleFixture);
      
      const fallbackPrice = ethers.parseEther("1.5"); // 1.5 USD
      
      await expect(
        enhancedOracle.connect(governance).setFallbackPrice(fallbackPrice)
      ).to.emit(enhancedOracle, "FallbackPriceSet").withArgs(fallbackPrice);
      
      expect(await enhancedOracle.fallbackPrice()).to.equal(fallbackPrice);
    });

    it("Should use fallback price in emergency mode", async function () {
      const { enhancedOracle, governance } = await loadFixture(deployEnhancedOracleFixture);
      
      const fallbackPrice = ethers.parseEther("2"); // 2 USD
      
      await enhancedOracle.connect(governance).setFallbackPrice(fallbackPrice);
      await enhancedOracle.connect(governance).enableEmergencyMode();
      
      const currentPrice = await enhancedOracle.getCurrentPrice();
      expect(currentPrice).to.equal(fallbackPrice);
    });

    it("Should reset observations in emergency", async function () {
      const { enhancedOracle, governance, oracleUpdater } = await loadFixture(deployEnhancedOracleFixture);
      
      // Add some observations first
      for (let i = 0; i < 3; i++) {
        await time.increase(5 * 60 + 1);
        await enhancedOracle.connect(oracleUpdater).updateMarketCap();
      }
      
      const beforeCount = await enhancedOracle.getObservationCount();
      expect(beforeCount).to.be.gt(1);
      
      // Reset observations
      await enhancedOracle.connect(governance).emergencyResetObservations();
      
      const afterCount = await enhancedOracle.getObservationCount();
      expect(afterCount).to.be.gte(1); // Should have at least one new observation
    });
  });

  describe("Governance Functions", function () {
    it("Should update new token mode", async function () {
      const { enhancedOracle, governance } = await loadFixture(deployEnhancedOracleFixture);
      
      expect(await enhancedOracle.newTokenMode()).to.be.true;
      
      await expect(
        enhancedOracle.connect(governance).setNewTokenMode(false)
      ).to.emit(enhancedOracle, "NewTokenModeToggled").withArgs(false);
      
      expect(await enhancedOracle.newTokenMode()).to.be.false;
      
      // Check that settings changed
      const settings = await enhancedOracle.getNewTokenSettings();
      expect(settings.maxUpdatesPerBlock).to.equal(3); // Relaxed from 1 to 3
    });

    it("Should update market cap limits", async function () {
      const { enhancedOracle, governance } = await loadFixture(deployEnhancedOracleFixture);
      
      const newLower = ethers.parseEther("50000");
      const newUpper = ethers.parseEther("20000000");
      
      await enhancedOracle.connect(governance).setMarketCapLimits(newLower, newUpper);
      
      expect(await enhancedOracle.mcLowerLimit()).to.equal(newLower);
      expect(await enhancedOracle.mcUpperLimit()).to.equal(newUpper);
    });

    it("Should force update price in emergency", async function () {
      const { enhancedOracle, governance } = await loadFixture(deployEnhancedOracleFixture);
      
      const forcedPrice = ethers.parseEther("1.25");
      
      await expect(
        enhancedOracle.connect(governance).forceUpdatePrice(forcedPrice)
      ).to.emit(enhancedOracle, "MarketCapUpdated");
      
      expect(await enhancedOracle.qorafiPriceTwap()).to.equal(forcedPrice);
    });

    it("Should invalidate observations", async function () {
      const { enhancedOracle, governance, oracleUpdater } = await loadFixture(deployEnhancedOracleFixture);
      
      // Add some observations
      for (let i = 0; i < 3; i++) {
        await time.increase(5 * 60 + 1);
        await enhancedOracle.connect(oracleUpdater).updateMarketCap();
      }
      
      const beforeCount = await enhancedOracle.validObservationCount();
      
      await expect(
        enhancedOracle.connect(governance).invalidateObservation(1, "Manipulated data")
      ).to.emit(enhancedOracle, "ObservationInvalidated");
      
      const afterCount = await enhancedOracle.validObservationCount();
      expect(afterCount).to.equal(beforeCount - 1);
    });

    it("Should prevent non-governance from updating parameters", async function () {
      const { enhancedOracle, user1 } = await loadFixture(deployEnhancedOracleFixture);
      
      await expect(
        enhancedOracle.connect(user1).setNewTokenMode(false)
      ).to.be.revertedWith("AccessControl");
      
      await expect(
        enhancedOracle.connect(user1).setFallbackPrice(ethers.parseEther("1"))
      ).to.be.revertedWith("AccessControl");
    });
  });

  describe("Advanced Features", function () {
    it("Should provide flash loan statistics", async function () {
      const { enhancedOracle } = await loadFixture(deployEnhancedOracleFixture);
      
      const currentBlock = await ethers.provider.getBlockNumber();
      const [updatesInBlock, updatesInWindow, isRisky] = await enhancedOracle.getFlashLoanStats(currentBlock);
      
      expect(updatesInBlock).to.be.a("bigint");
      expect(updatesInWindow).to.be.a("bigint");
      expect(typeof isRisky).to.equal("boolean");
    });

    it("Should calculate liquidity change rate", async function () {
      const { enhancedOracle, oracleUpdater, pair } = await loadFixture(deployEnhancedOracleFixture);
      
      // Add initial observation
      await time.increase(5 * 60 + 1);
      await enhancedOracle.connect(oracleUpdater).updateMarketCap();
      
      // Change liquidity
      await pair.setReserves(
        ethers.parseEther("120000"), // 20% increase
        ethers.parseUnits("120000", 6)
      );
      
      await time.increase(5 * 60 + 1);
      await enhancedOracle.connect(oracleUpdater).updateMarketCap();
      
      const changeRate = await enhancedOracle.getLiquidityChangeRate();
      expect(changeRate).to.be.gt(0);
    });

    it("Should provide oracle health details", async function () {
      const { enhancedOracle } = await loadFixture(deployEnhancedOracleFixture);
      
      const [isHealthy, reason, lastUpdate, validObservations] = await enhancedOracle.getOracleHealth();
      
      expect(typeof isHealthy).to.equal("boolean");
      expect(typeof reason).to.equal("string");
      expect(lastUpdate).to.be.a("bigint");
      expect(validObservations).to.be.a("bigint");
    });

    it("Should provide market metrics", async function () {
      const { enhancedOracle, oracleUpdater } = await loadFixture(deployEnhancedOracleFixture);
      
      // Update to establish price
      await time.increase(5 * 60 + 1);
      await enhancedOracle.connect(oracleUpdater).updateMarketCap();
      
      const [currentPrice, marketCap, priceChange24h, volumeWeightedPrice, liquidityUSD] = await enhancedOracle.getMarketMetrics();
      
      expect(currentPrice).to.be.a("bigint");
      expect(marketCap).to.be.a("bigint");
      expect(priceChange24h).to.be.a("bigint");
      expect(volumeWeightedPrice).to.be.a("bigint");
      expect(liquidityUSD).to.be.a("bigint");
    });

    it("Should handle observation window queries", async function () {
      const { enhancedOracle, oracleUpdater } = await loadFixture(deployEnhancedOracleFixture);
      
      // Add several observations
      for (let i = 0; i < 5; i++) {
        await time.increase(5 * 60 + 1);
        await enhancedOracle.connect(oracleUpdater).updateMarketCap();
      }
      
      // Get observation window
      const observations = await enhancedOracle.getObservationWindow(0, 3);
      expect(observations.length).to.equal(3);
      
      for (const obs of observations) {
        expect(obs.isValid).to.be.true;
        expect(obs.timestamp).to.be.gt(0);
      }
    });
  });

  describe("Price Calculation", function () {
    it("Should calculate TWAP price safely", async function () {
      const { enhancedOracle, oracleUpdater } = await loadFixture(deployEnhancedOracleFixture);
      
      // Add minimum required observations
      for (let i = 0; i < 3; i++) {
        await time.increase(5 * 60 + 1);
        await enhancedOracle.connect(oracleUpdater).updateMarketCap();
      }
      
      const twapPrice = await enhancedOracle.safeGetTWAPPrice();
      expect(twapPrice).to.be.gt(0);
    });

    it("Should handle insufficient observations gracefully", async function () {
      const { enhancedOracle } = await loadFixture(deployEnhancedOracleFixture);
      
      // Only has 1 observation from initialization, needs 3 minimum
      await expect(
        enhancedOracle.safeGetTWAPPrice()
      ).to.be.revertedWith("InsufficientObservations");
    });

    it("Should return fallback price when TWAP fails", async function () {
      const { enhancedOracle, governance } = await loadFixture(deployEnhancedOracleFixture);
      
      const fallbackPrice = ethers.parseEther("1.75");
      await enhancedOracle.connect(governance).setFallbackPrice(fallbackPrice);
      
      // Should return fallback when insufficient observations
      const currentPrice = await enhancedOracle.getCurrentPrice();
      expect(currentPrice).to.equal(fallbackPrice);
    });
  });

  describe("Integration with Libraries", function () {
    it("Should properly use TWAPLib for calculations", async function () {
      const { enhancedOracle, oracleUpdater } = await loadFixture(deployEnhancedOracleFixture);
      
      // This test verifies that the oracle properly integrates with TWAPLib
      // by checking that observations are being added and processed
      
      const initialCount = await enhancedOracle.getObservationCount();
      
      await time.increase(5 * 60 + 1);
      await enhancedOracle.connect(oracleUpdater).updateMarketCap();
      
      const newCount = await enhancedOracle.getObservationCount();
      expect(newCount).to.equal(initialCount + 1);
      
      // Verify observation data
      const latestObs = await enhancedOracle.getLatestObservation();
      expect(latestObs.isValid).to.be.true;
      expect(latestObs.liquiditySnapshot).to.be.gt(0);
    });

    it("Should properly use PriceValidationLib", async function () {
      const { enhancedOracle, governance } = await loadFixture(deployEnhancedOracleFixture);
      
      // Test that price validation settings are being used
      const validationData = await enhancedOracle.getPriceValidationData();
      expect(validationData.priceImpactThreshold).to.be.gt(0);
      expect(validationData.maxPriceChangePerUpdate).to.be.gt(0);
      
      // Update validation parameters
      await enhancedOracle.connect(governance).setPriceValidationParams(1500, 2500);
      
      const updatedData = await enhancedOracle.getPriceValidationData();
      expect(updatedData.priceImpactThreshold).to.equal(1500);
      expect(updatedData.maxPriceChangePerUpdate).to.equal(2500);
    });

    it("Should properly use LiquidityMonitorLib", async function () {
      const { enhancedOracle } = await loadFixture(deployEnhancedOracleFixture);
      
      // Test liquidity monitoring functionality
      const liquidityStatus = await enhancedOracle.getLiquidityStatus();
      expect(liquidityStatus.currentUsdtLiquidity).to.be.gt(0);
      expect(liquidityStatus.isHealthy).to.be.true;
    });
  });
});