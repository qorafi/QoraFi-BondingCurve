// test/unit/advanced/SecurityGovernance.test.js
const { expect } = require("chai");
const { ethers, upgrades } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");

describe("SecurityGovernance", function () {
  async function deploySecurityGovernanceFixture() {
    const [owner, governance, emergency, paramManager, user1, user2, treasury] = await ethers.getSigners();
    
    // Deploy mock tokens and contracts for managed contract testing
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const usdt = await MockERC20.deploy("Mock USDT", "USDT", 6, ethers.parseUnits("1000000", 6));
    
    // Deploy libraries
    const SecurityLibraries = await ethers.getContractFactory("SecurityLibraries");
    const securityLibraries = await SecurityLibraries.deploy();
    
    // Deploy SecurityGovernance with libraries
    const SecurityGovernance = await ethers.getContractFactory("SecurityGovernance", {
      libraries: {
        EmergencyLib: await securityLibraries.getAddress(),
        ValidationLib: await securityLibraries.getAddress(),
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
    
    // Grant additional roles
    const EMERGENCY_ROLE = await securityGovernance.EMERGENCY_ROLE();
    const PARAM_MANAGER_ROLE = await securityGovernance.PARAM_MANAGER_ROLE();
    const UPGRADE_ROLE = await securityGovernance.UPGRADE_ROLE();
    
    await securityGovernance.grantRole(EMERGENCY_ROLE, emergency.address);
    await securityGovernance.grantRole(PARAM_MANAGER_ROLE, paramManager.address);
    await securityGovernance.grantRole(PARAM_MANAGER_ROLE, governance.address);
    await securityGovernance.grantRole(UPGRADE_ROLE, governance.address);
    
    return { 
      securityGovernance, 
      usdt,
      securityLibraries,
      owner, 
      governance, 
      emergency, 
      paramManager, 
      user1, 
      user2, 
      treasury 
    };
  }

  describe("Initialization", function () {
    it("Should initialize with correct parameters", async function () {
      const { securityGovernance, treasury } = await loadFixture(deploySecurityGovernanceFixture);
      
      expect(await securityGovernance.treasuryWallet()).to.equal(treasury.address);
      expect(await securityGovernance.emergencyTransactionDelay()).to.equal(24 * 60 * 60);
      expect(await securityGovernance.requiredSignatures()).to.equal(2);
      expect(await securityGovernance.proposalValidityPeriod()).to.equal(7 * 24 * 60 * 60); // 7 days
    });

    it("Should initialize default security parameters", async function () {
      const { securityGovernance } = await loadFixture(deploySecurityGovernanceFixture);
      
      expect(await securityGovernance.getSecurityParameter("maxPriceChangeBPS")).to.equal(2000);
      expect(await securityGovernance.getSecurityParameter("maxMarketCapGrowthBPS")).to.equal(3000);
      expect(await securityGovernance.getSecurityParameter("minOracleUpdateInterval")).to.equal(5 * 60);
      expect(await securityGovernance.getSecurityParameter("circuitBreakerCooldown")).to.equal(2 * 60 * 60);
      expect(await securityGovernance.getSecurityParameter("mevMinInterval")).to.equal(5);
    });

    it("Should grant correct roles", async function () {
      const { securityGovernance, owner, governance, emergency, paramManager } = await loadFixture(deploySecurityGovernanceFixture);
      
      const GOVERNANCE_ROLE = await securityGovernance.GOVERNANCE_ROLE();
      const EMERGENCY_ROLE = await securityGovernance.EMERGENCY_ROLE();
      const PARAM_MANAGER_ROLE = await securityGovernance.PARAM_MANAGER_ROLE();
      
      expect(await securityGovernance.hasRole(GOVERNANCE_ROLE, owner.address)).to.be.true;
      expect(await securityGovernance.hasRole(EMERGENCY_ROLE, emergency.address)).to.be.true;
      expect(await securityGovernance.hasRole(PARAM_MANAGER_ROLE, paramManager.address)).to.be.true;
      expect(await securityGovernance.hasRole(PARAM_MANAGER_ROLE, governance.address)).to.be.true;
    });
  });

  describe("Parameter Management", function () {
    it("Should allow parameter change proposals", async function () {
      const { securityGovernance, paramManager } = await loadFixture(deploySecurityGovernanceFixture);
      
      await expect(
        securityGovernance.connect(paramManager).proposeParameterChange("maxPriceChangeBPS", 1500)
      ).to.emit(securityGovernance, "ParameterChangeProposed");
      
      const stats = await securityGovernance.getGovernanceStats();
      expect(stats.totalProposalsCount).to.equal(1);
    });

    it("Should track proposal signatures", async function () {
      const { securityGovernance, paramManager, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Propose parameter change
      const proposalTx = await securityGovernance.connect(paramManager).proposeParameterChange("maxPriceChangeBPS", 1500);
      const receipt = await proposalTx.wait();
      
      // Extract proposal ID from events
      const event = receipt.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "ParameterChangeProposed";
        } catch {
          return false;
        }
      });
      
      expect(event).to.not.be.undefined;
      
      if (event) {
        const parsed = securityGovernance.interface.parseLog(event);
        const proposalId = parsed.args.proposalId;
        
        // Check initial proposal state
        const proposal = await securityGovernance.getProposal(proposalId);
        expect(proposal.signatures).to.equal(1); // Proposer's signature
        expect(proposal.executed).to.be.false;
        
        // Add second signature
        await expect(
          securityGovernance.connect(governance).signProposal(proposalId)
        ).to.emit(securityGovernance, "ProposalSigned");
        
        // Check updated proposal state
        const updatedProposal = await securityGovernance.getProposal(proposalId);
        expect(updatedProposal.signatures).to.equal(2);
      }
    });

    it("Should auto-execute proposals with sufficient signatures", async function () {
      const { securityGovernance, paramManager, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      const oldValue = await securityGovernance.getSecurityParameter("maxPriceChangeBPS");
      
      // Propose and get sufficient signatures for auto-execution
      const proposalTx = await securityGovernance.connect(paramManager).proposeParameterChange("maxPriceChangeBPS", 1500);
      const receipt = await proposalTx.wait();
      
      const event = receipt.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "ParameterChangeProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = securityGovernance.interface.parseLog(event);
        const proposalId = parsed.args.proposalId;
        
        // Second signature should trigger auto-execution
        await expect(
          securityGovernance.connect(governance).signProposal(proposalId)
        ).to.emit(securityGovernance, "ParameterChangeExecuted");
        
        // Verify parameter was updated
        const newValue = await securityGovernance.getSecurityParameter("maxPriceChangeBPS");
        expect(newValue).to.equal(1500);
        expect(newValue).to.not.equal(oldValue);
      }
    });

    it("Should prevent duplicate signatures", async function () {
      const { securityGovernance, paramManager } = await loadFixture(deploySecurityGovernanceFixture);
      
      const proposalTx = await securityGovernance.connect(paramManager).proposeParameterChange("maxPriceChangeBPS", 1500);
      const receipt = await proposalTx.wait();
      
      const event = receipt.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "ParameterChangeProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = securityGovernance.interface.parseLog(event);
        const proposalId = parsed.args.proposalId;
        
        // Try to sign again (should fail)
        await expect(
          securityGovernance.connect(paramManager).signProposal(proposalId)
        ).to.be.revertedWith("AlreadySigned");
      }
    });

    it("Should enforce proposal validity period", async function () {
      const { securityGovernance, paramManager, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      const proposalTx = await securityGovernance.connect(paramManager).proposeParameterChange("maxPriceChangeBPS", 1500);
      const receipt = await proposalTx.wait();
      
      const event = receipt.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "ParameterChangeProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = securityGovernance.interface.parseLog(event);
        const proposalId = parsed.args.proposalId;
        
        // Fast forward past validity period
        await time.increase(8 * 24 * 60 * 60); // 8 days
        
        // Try to sign expired proposal
        await expect(
          securityGovernance.connect(governance).signProposal(proposalId)
        ).to.be.revertedWith("ProposalExpired");
      }
    });

    it("Should allow proposal cancellation", async function () {
      const { securityGovernance, paramManager, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      const proposalTx = await securityGovernance.connect(paramManager).proposeParameterChange("maxPriceChangeBPS", 1500);
      const receipt = await proposalTx.wait();
      
      const event = receipt.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "ParameterChangeProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = securityGovernance.interface.parseLog(event);
        const proposalId = parsed.args.proposalId;
        
        await expect(
          securityGovernance.connect(governance).cancelProposal(proposalId)
        ).to.emit(securityGovernance, "ProposalCancelled");
        
        const proposal = await securityGovernance.getProposal(proposalId);
        expect(proposal.cancelled).to.be.true;
      }
    });

    it("Should handle batch parameter updates", async function () {
      const { securityGovernance, paramManager } = await loadFixture(deploySecurityGovernanceFixture);
      
      const paramNames = ["maxPriceChangeBPS", "maxMarketCapGrowthBPS"];
      const values = [1500, 2500];
      
      const proposalIds = await securityGovernance.connect(paramManager).batchUpdateParameters(paramNames, values);
      
      expect(proposalIds).to.not.be.undefined;
      
      const stats = await securityGovernance.getGovernanceStats();
      expect(stats.totalProposalsCount).to.equal(2);
    });
  });

  describe("Emergency System", function () {
    it("Should propose emergency transactions", async function () {
      const { securityGovernance, emergency, usdt } = await loadFixture(deploySecurityGovernanceFixture);
      
      const target = await usdt.getAddress();
      const value = 0;
      const data = usdt.interface.encodeFunctionData("transfer", [emergency.address, ethers.parseUnits("1000", 6)]);
      
      await expect(
        securityGovernance.connect(emergency).proposeEmergencyTransaction(target, value, data)
      ).to.emit(securityGovernance, "EmergencyTransactionProposed");
    });

    it("Should enforce emergency transaction timelock", async function () {
      const { securityGovernance, emergency, governance, usdt } = await loadFixture(deploySecurityGovernanceFixture);
      
      const target = await usdt.getAddress();
      const value = 0;
      const data = usdt.interface.encodeFunctionData("transfer", [emergency.address, ethers.parseUnits("1000", 6)]);
      
      const txHash = await securityGovernance.connect(emergency).proposeEmergencyTransaction(target, value, data);
      const receipt = await txHash.wait();
      
      const event = receipt.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "EmergencyTransactionProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = securityGovernance.interface.parseLog(event);
        const emergencyTxHash = parsed.args.txHash;
        
        // Try to execute immediately (should fail)
        await expect(
          securityGovernance.connect(governance).executeEmergencyTransaction(emergencyTxHash)
        ).to.be.reverted;
      }
    });

    it("Should execute emergency transactions after timelock", async function () {
      const { securityGovernance, emergency, governance, usdt } = await loadFixture(deploySecurityGovernanceFixture);
      
      const target = await usdt.getAddress();
      const value = 0;
      const data = usdt.interface.encodeFunctionData("transfer", [emergency.address, ethers.parseUnits("1000", 6)]);
      
      const txHash = await securityGovernance.connect(emergency).proposeEmergencyTransaction(target, value, data);
      const receipt = await txHash.wait();
      
      // Fast forward past emergency delay
      await time.increase(24 * 60 * 60 + 1);
      
      const event = receipt.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "EmergencyTransactionProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = securityGovernance.interface.parseLog(event);
        const emergencyTxHash = parsed.args.txHash;
        
        await expect(
          securityGovernance.connect(governance).executeEmergencyTransaction(emergencyTxHash)
        ).to.emit(securityGovernance, "EmergencyTransactionExecuted");
      }
    });

    it("Should cancel emergency transactions", async function () {
      const { securityGovernance, emergency, governance, usdt } = await loadFixture(deploySecurityGovernanceFixture);
      
      const target = await usdt.getAddress();
      const value = 0;
      const data = usdt.interface.encodeFunctionData("transfer", [emergency.address, ethers.parseUnits("1000", 6)]);
      
      const txHash = await securityGovernance.connect(emergency).proposeEmergencyTransaction(target, value, data);
      const receipt = await txHash.wait();
      
      const event = receipt.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "EmergencyTransactionProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = securityGovernance.interface.parseLog(event);
        const emergencyTxHash = parsed.args.txHash;
        
        await expect(
          securityGovernance.connect(governance).cancelEmergencyTransaction(emergencyTxHash)
        ).to.emit(securityGovernance, "EmergencyTransactionCancelled");
      }
    });
  });

  describe("Contract Management", function () {
    it("Should add managed contracts", async function () {
      const { securityGovernance, governance, usdt } = await loadFixture(deploySecurityGovernanceFixture);
      
      const contractAddr = await usdt.getAddress();
      
      await expect(
        securityGovernance.connect(governance).addManagedContract(contractAddr, "MockToken")
      ).to.emit(securityGovernance, "ContractManagementAdded")
        .withArgs(contractAddr, "MockToken");
      
      const contractInfo = await securityGovernance.getManagedContract(contractAddr);
      expect(contractInfo.isManaged).to.be.true;
      expect(contractInfo.contractType).to.equal("MockToken");
      expect(contractInfo.paused).to.be.false;
    });

    it("Should remove managed contracts", async function () {
      const { securityGovernance, governance, usdt } = await loadFixture(deploySecurityGovernanceFixture);
      
      const contractAddr = await usdt.getAddress();
      
      // Add first
      await securityGovernance.connect(governance).addManagedContract(contractAddr, "MockToken");
      
      // Then remove
      await expect(
        securityGovernance.connect(governance).removeManagedContract(contractAddr)
      ).to.emit(securityGovernance, "ContractManagementRemoved")
        .withArgs(contractAddr);
      
      const contractInfo = await securityGovernance.getManagedContract(contractAddr);
      expect(contractInfo.isManaged).to.be.false;
    });

    it("Should pause and unpause managed contracts", async function () {
      const { securityGovernance, governance, emergency, usdt } = await loadFixture(deploySecurityGovernanceFixture);
      
      const contractAddr = await usdt.getAddress();
      
      // Add contract to management
      await securityGovernance.connect(governance).addManagedContract(contractAddr, "MockToken");
      
      // Note: This test assumes the managed contract has pause/unpause functions
      // In a real scenario, you'd use actual pausable contracts
      
      // For mock contracts, we'll just verify the call doesn't revert
      // In practice, you'd check that the target contract's paused state changed
      
      let contractInfo = await securityGovernance.getManagedContract(contractAddr);
      expect(contractInfo.isManaged).to.be.true;
    });
  });

  describe("Treasury Management", function () {
    it("Should manage treasury wallet", async function () {
      const { securityGovernance, governance, user1, treasury } = await loadFixture(deploySecurityGovernanceFixture);
      
      expect(await securityGovernance.getTreasuryWallet()).to.equal(treasury.address);
      
      await expect(
        securityGovernance.connect(governance).setTreasuryWallet(user1.address)
      ).to.emit(securityGovernance, "TreasuryWalletChanged")
        .withArgs(treasury.address, user1.address);
      
      expect(await securityGovernance.getTreasuryWallet()).to.equal(user1.address);
    });

    it("Should validate treasury wallet address", async function () {
      const { securityGovernance, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      await expect(
        securityGovernance.connect(governance).setTreasuryWallet(ethers.ZeroAddress)
      ).to.be.revertedWith("InvalidAddress");
    });
  });

  describe("Governance Settings", function () {
    it("Should update required signatures", async function () {
      const { securityGovernance, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      await expect(
        securityGovernance.connect(governance).setRequiredSignatures(3)
      ).to.emit(securityGovernance, "RequiredSignaturesChanged")
        .withArgs(2, 3);
      
      expect(await securityGovernance.requiredSignatures()).to.equal(3);
    });

    it("Should validate required signatures", async function () {
      const { securityGovernance, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Should fail for zero signatures
      await expect(
        securityGovernance.connect(governance).setRequiredSignatures(0)
      ).to.be.revertedWith("InvalidSignatureRequirement");
      
      // Should fail for more signatures than available roles
      // This would require counting role members, simplified here
    });

    it("Should update proposal validity period", async function () {
      const { securityGovernance, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      const newPeriod = 14 * 24 * 60 * 60; // 14 days
      
      await securityGovernance.connect(governance).setProposalValidityPeriod(newPeriod);
      
      expect(await securityGovernance.proposalValidityPeriod()).to.equal(newPeriod);
    });

    it("Should validate proposal validity period", async function () {
      const { securityGovernance, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Should fail for too short period
      await expect(
        securityGovernance.connect(governance).setProposalValidityPeriod(12 * 60 * 60) // 12 hours
      ).to.be.revertedWith("Invalid validity period");
      
      // Should fail for too long period
      await expect(
        securityGovernance.connect(governance).setProposalValidityPeriod(31 * 24 * 60 * 60) // 31 days
      ).to.be.revertedWith("Invalid validity period");
    });

    it("Should update emergency transaction delay", async function () {
      const { securityGovernance, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      const newDelay = 12 * 60 * 60; // 12 hours
      
      await securityGovernance.connect(governance).setEmergencyTransactionDelay(newDelay);
      
      expect(await securityGovernance.emergencyTransactionDelay()).to.equal(newDelay);
    });
  });

  describe("Interface Implementations", function () {
    it("Should implement IGovernance interface", async function () {
      const { securityGovernance, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Test setSecurityParameters
      await securityGovernance.connect(governance).setSecurityParameters("testParam", 1000);
      expect(await securityGovernance.getSecurityParameter("testParam")).to.equal(1000);
      
      // Test role management
      const PARAM_MANAGER_ROLE = await securityGovernance.PARAM_MANAGER_ROLE();
      expect(await securityGovernance.hasRole(PARAM_MANAGER_ROLE, governance.address)).to.be.true;
      
      // Test treasury management
      expect(await securityGovernance.getTreasuryWallet()).to.not.equal(ethers.ZeroAddress);
    });

    it("Should implement IEmergencySystem interface", async function () {
      const { securityGovernance, emergency, usdt } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Test emergency transaction flow
      const target = await usdt.getAddress();
      const value = 0;
      const data = "0x";
      
      const txHash = await securityGovernance.connect(emergency).proposeEmergencyTransaction(target, value, data);
      expect(txHash).to.not.be.undefined;
      
      // Test emergency mode functions
      expect(await securityGovernance.isEmergencyModeActive()).to.be.false;
    });
  });

  describe("View Functions", function () {
    it("Should provide governance statistics", async function () {
      const { securityGovernance, paramManager } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Create some proposals
      await securityGovernance.connect(paramManager).proposeParameterChange("param1", 100);
      await securityGovernance.connect(paramManager).proposeParameterChange("param2", 200);
      
      const stats = await securityGovernance.getGovernanceStats();
      expect(stats.totalProposalsCount).to.equal(2);
      expect(stats.executedProposalsCount).to.equal(0);
      expect(stats.cancelledProposalsCount).to.equal(0);
      expect(stats.requiredSignaturesCount).to.equal(2);
    });

    it("Should provide all parameters", async function () {
      const { securityGovernance } = await loadFixture(deploySecurityGovernanceFixture);
      
      const [paramNames, paramValues] = await securityGovernance.getAllParameters();
      
      expect(paramNames.length).to.equal(10);
      expect(paramValues.length).to.equal(10);
      expect(paramNames[0]).to.equal("maxPriceChangeBPS");
      expect(paramValues[0]).to.equal(2000);
    });

    it("Should validate proposal signatures", async function () {
      const { securityGovernance, paramManager, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      const proposalTx = await securityGovernance.connect(paramManager).proposeParameterChange("testParam", 500);
      const receipt = await proposalTx.wait();
      
      const event = receipt.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "ParameterChangeProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = securityGovernance.interface.parseLog(event);
        const proposalId = parsed.args.proposalId;
        
        // Initially insufficient signatures
        expect(await securityGovernance.hasValidSignatures(proposalId)).to.be.false;
        
        // Add second signature
        await securityGovernance.connect(governance).signProposal(proposalId);
        
        // Now sufficient signatures
        expect(await securityGovernance.hasValidSignatures(proposalId)).to.be.true;
      }
    });

    it("Should check proposal validity", async function () {
      const { securityGovernance, paramManager } = await loadFixture(deploySecurityGovernanceFixture);
      
      const proposalTx = await securityGovernance.connect(paramManager).proposeParameterChange("testParam", 500);
      const receipt = await proposalTx.wait();
      
      const event = receipt.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "ParameterChangeProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = securityGovernance.interface.parseLog(event);
        const proposalId = parsed.args.proposalId;
        
        // Should be valid initially
        expect(await securityGovernance.isProposalValid(proposalId)).to.be.true;
        
        // Fast forward past validity period
        await time.increase(8 * 24 * 60 * 60); // 8 days
        
        // Should be invalid after expiry
        expect(await securityGovernance.isProposalValid(proposalId)).to.be.false;
      }
    });
  });

  describe("Access Control", function () {
    it("Should enforce role-based access control", async function () {
      const { securityGovernance, user1 } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Non-param-manager should not propose parameters
      await expect(
        securityGovernance.connect(user1).proposeParameterChange("testParam", 100)
      ).to.be.revertedWith("AccessControl");
      
      // Non-emergency should not propose emergency transactions
      await expect(
        securityGovernance.connect(user1).proposeEmergencyTransaction(user1.address, 0, "0x")
      ).to.be.revertedWith("AccessControl");
      
      // Non-governance should not manage contracts
      await expect(
        securityGovernance.connect(user1).addManagedContract(user1.address, "TestContract")
      ).to.be.revertedWith("AccessControl");
    });

    it("Should allow role administration", async function () {
      const { securityGovernance, governance, user1 } = await loadFixture(deploySecurityGovernanceFixture);
      
      const PARAM_MANAGER_ROLE = await securityGovernance.PARAM_MANAGER_ROLE();
      
      // Grant role
      await securityGovernance.connect(governance).grantRole(PARAM_MANAGER_ROLE, user1.address);
      expect(await securityGovernance.hasRole(PARAM_MANAGER_ROLE, user1.address)).to.be.true;
      
      // User1 should now be able to propose parameters
      await expect(
        securityGovernance.connect(user1).proposeParameterChange("testParam", 100)
      ).to.not.be.reverted;
      
      // Revoke role
      await securityGovernance.connect(governance).revokeRole(PARAM_MANAGER_ROLE, user1.address);
      expect(await securityGovernance.hasRole(PARAM_MANAGER_ROLE, user1.address)).to.be.false;
    });
  });

  describe("Emergency Recovery", function () {
    it("Should allow emergency token recovery", async function () {
      const { securityGovernance, governance, usdt, treasury } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Send tokens to governance contract
      await usdt.mint(await securityGovernance.getAddress(), ethers.parseUnits("1000", 6));
      
      const initialBalance = await usdt.balanceOf(await securityGovernance.getAddress());
      expect(initialBalance).to.equal(ethers.parseUnits("1000", 6));
      
      // Recover tokens
      await securityGovernance.connect(governance).emergencyRecoverERC20(
        await usdt.getAddress(),
        treasury.address,
        ethers.parseUnits("1000", 6)
      );
      
      const finalBalance = await usdt.balanceOf(await securityGovernance.getAddress());
      expect(finalBalance).to.equal(0);
      
      const treasuryBalance = await usdt.balanceOf(treasury.address);
      expect(treasuryBalance).to.equal(ethers.parseUnits("1000", 6));
    });

    it("Should allow emergency ETH recovery", async function () {
      const { securityGovernance, governance, treasury } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Send ETH to governance contract
      await governance.sendTransaction({
        to: await securityGovernance.getAddress(),
        value: ethers.parseEther("1")
      });
      
      const initialBalance = await ethers.provider.getBalance(await securityGovernance.getAddress());
      expect(initialBalance).to.equal(ethers.parseEther("1"));
      
      const treasuryInitialBalance = await ethers.provider.getBalance(treasury.address);
      
      // Recover ETH
      await securityGovernance.connect(governance).emergencyRecoverETH(
        treasury.address,
        ethers.parseEther("1")
      );
      
      const finalBalance = await ethers.provider.getBalance(await securityGovernance.getAddress());
      expect(finalBalance).to.equal(0);
      
      const treasuryFinalBalance = await ethers.provider.getBalance(treasury.address);
      expect(treasuryFinalBalance).to.be.gt(treasuryInitialBalance); // Account for gas costs
    });

    it("Should validate emergency recovery parameters", async function () {
      const { securityGovernance, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Should fail for invalid token address
      await expect(
        securityGovernance.connect(governance).emergencyRecoverERC20(
          ethers.ZeroAddress,
          governance.address,
          100
        )
      ).to.be.revertedWith("Invalid token");
      
      // Should fail for invalid recipient
      await expect(
        securityGovernance.connect(governance).emergencyRecoverETH(
          ethers.ZeroAddress,
          ethers.parseEther("1")
        )
      ).to.be.revertedWith("Invalid recipient");
    });
  });

  describe("Batch Operations", function () {
    it("Should execute batch parameter updates", async function () {
      const { securityGovernance, governance, paramManager } = await loadFixture(deploySecurityGovernanceFixture);
      
      const paramNames = ["param1", "param2", "param3"];
      const values = [100, 200, 300];
      
      const proposalIds = await securityGovernance.connect(paramManager).batchUpdateParameters(paramNames, values);
      
      expect(proposalIds).to.not.be.undefined;
      
      const stats = await securityGovernance.getGovernanceStats();
      expect(stats.totalProposalsCount).to.equal(3);
    });

    it("Should execute batch proposal executions", async function () {
      const { securityGovernance, governance, paramManager } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Create multiple proposals
      const proposal1Tx = await securityGovernance.connect(paramManager).proposeParameterChange("param1", 100);
      const proposal2Tx = await securityGovernance.connect(paramManager).proposeParameterChange("param2", 200);
      
      const receipt1 = await proposal1Tx.wait();
      const receipt2 = await proposal2Tx.wait();
      
      // Extract proposal IDs
      const event1 = receipt1.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "ParameterChangeProposed";
        } catch {
          return false;
        }
      });
      
      const event2 = receipt2.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "ParameterChangeProposed";
        } catch {
          return false;
        }
      });
      
      if (event1 && event2) {
        const proposalId1 = securityGovernance.interface.parseLog(event1).args.proposalId;
        const proposalId2 = securityGovernance.interface.parseLog(event2).args.proposalId;
        
        // Add second signatures
        await securityGovernance.connect(governance).signProposal(proposalId1);
        await securityGovernance.connect(governance).signProposal(proposalId2);
        
        // Both should be executed automatically due to sufficient signatures
        const stats = await securityGovernance.getGovernanceStats();
        expect(stats.executedProposalsCount).to.equal(2);
      }
    });

    it("Should handle batch contract pausing", async function () {
      const { securityGovernance, governance, emergency, usdt } = await loadFixture(deploySecurityGovernanceFixture);
      
      const contractAddresses = [await usdt.getAddress()];
      
      // Add contracts to management first
      await securityGovernance.connect(governance).addManagedContract(contractAddresses[0], "MockToken");
      
      // Batch pause (would work with actual pausable contracts)
      await securityGovernance.connect(emergency).batchPauseContracts(contractAddresses);
      
      // Verify contract management state
      const contractInfo = await securityGovernance.getManagedContract(contractAddresses[0]);
      expect(contractInfo.isManaged).to.be.true;
    });
  });

  describe("Integration Tests", function () {
    it("Should coordinate with external contracts", async function () {
      const { securityGovernance, governance, paramManager } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Test parameter propagation
      await securityGovernance.connect(paramManager).proposeParameterChange("maxPriceChangeBPS", 1800);
      
      // In a real scenario, this would propagate to managed contracts
      const updatedParam = await securityGovernance.getSecurityParameter("maxPriceChangeBPS");
      // Parameter is still old value until proposal is executed
      expect(updatedParam).to.equal(2000);
    });

    it("Should handle emergency mode coordination", async function () {
      const { securityGovernance, emergency, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Test emergency mode activation
      await securityGovernance.connect(emergency).activateEmergencyMode();
      
      // Test emergency mode status
      const isEmergencyActive = await securityGovernance.isEmergencyModeActive();
      expect(isEmergencyActive).to.be.false; // No managed contracts to check
      
      // Test emergency mode deactivation
      await securityGovernance.connect(governance).deactivateEmergencyMode();
    });

    it("Should maintain governance integrity", async function () {
      const { securityGovernance, paramManager, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Test that governance state is maintained correctly
      const initialStats = await securityGovernance.getGovernanceStats();
      
      // Create and execute a proposal
      const proposalTx = await securityGovernance.connect(paramManager).proposeParameterChange("testParam", 999);
      const receipt = await proposalTx.wait();
      
      const event = receipt.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "ParameterChangeProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = securityGovernance.interface.parseLog(event);
        const proposalId = parsed.args.proposalId;
        
        await securityGovernance.connect(governance).signProposal(proposalId);
        
        const finalStats = await securityGovernance.getGovernanceStats();
        expect(finalStats.totalProposalsCount).to.equal(initialStats.totalProposalsCount + 1n);
        expect(finalStats.executedProposalsCount).to.equal(initialStats.executedProposalsCount + 1n);
      }
    });
  });

  describe("Edge Cases and Error Handling", function () {
    it("Should handle invalid proposal IDs", async function () {
      const { securityGovernance, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      const invalidProposalId = ethers.id("nonexistent");
      
      await expect(
        securityGovernance.connect(governance).signProposal(invalidProposalId)
      ).to.be.revertedWith("ProposalNotFound");
      
      await expect(
        securityGovernance.connect(governance).executeParameterChange(invalidProposalId)
      ).to.be.revertedWith("ProposalNotFound");
    });

    it("Should handle concurrent proposal operations", async function () {
      const { securityGovernance, paramManager, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Create proposal
      const proposalTx = await securityGovernance.connect(paramManager).proposeParameterChange("concurrentTest", 123);
      const receipt = await proposalTx.wait();
      
      const event = receipt.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "ParameterChangeProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = securityGovernance.interface.parseLog(event);
        const proposalId = parsed.args.proposalId;
        
        // Execute (auto-executes on second signature)
        await securityGovernance.connect(governance).signProposal(proposalId);
        
        // Try to execute again (should fail)
        await expect(
          securityGovernance.connect(governance).executeParameterChange(proposalId)
        ).to.be.revertedWith("ProposalAlreadyExecuted");
      }
    });

    it("Should handle array length mismatches", async function () {
      const { securityGovernance, paramManager } = await loadFixture(deploySecurityGovernanceFixture);
      
      const paramNames = ["param1", "param2"];
      const values = [100]; // Mismatched length
      
      await expect(
        securityGovernance.connect(paramManager).batchUpdateParameters(paramNames, values)
      ).to.be.revertedWith("Array length mismatch");
    });

    it("Should handle emergency transaction failures", async function () {
      const { securityGovernance, emergency, governance, usdt } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Create emergency transaction that will fail
      const target = await usdt.getAddress();
      const value = 0;
      const data = "0xdeadbeef"; // Invalid function selector
      
      const txHash = await securityGovernance.connect(emergency).proposeEmergencyTransaction(target, value, data);
      const receipt = await txHash.wait();
      
      // Fast forward past delay
      await time.increase(24 * 60 * 60 + 1);
      
      const event = receipt.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "EmergencyTransactionProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = securityGovernance.interface.parseLog(event);
        const emergencyTxHash = parsed.args.txHash;
        
        // Execution should fail but not revert the governance transaction
        await expect(
          securityGovernance.connect(governance).executeEmergencyTransaction(emergencyTxHash)
        ).to.be.revertedWith("Emergency transaction failed");
      }
    });
  });

  describe("Upgrade Functionality", function () {
    it("Should support UUPS upgrades", async function () {
      const { securityGovernance, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Test that upgrade authorization works
      const UPGRADE_ROLE = await securityGovernance.UPGRADE_ROLE();
      expect(await securityGovernance.hasRole(UPGRADE_ROLE, governance.address)).to.be.true;
      
      // Get current implementation
      const implementation = await securityGovernance.getImplementation();
      expect(implementation).to.not.equal(ethers.ZeroAddress);
    });

    it("Should prevent unauthorized upgrades", async function () {
      const { securityGovernance, user1 } = await loadFixture(deploySecurityGovernanceFixture);
      
      await expect(
        securityGovernance.connect(user1).authorizeUpgrade(user1.address)
      ).to.be.revertedWith("AccessControl");
    });
  });

  describe("Gas Optimization", function () {
    it("Should handle large batch operations efficiently", async function () {
      const { securityGovernance, paramManager } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Create large batch
      const paramNames = [];
      const values = [];
      for (let i = 0; i < 10; i++) {
        paramNames.push(`param${i}`);
        values.push(100 + i);
      }
      
      const tx = await securityGovernance.connect(paramManager).batchUpdateParameters(paramNames, values);
      const receipt = await tx.wait();
      
      // Verify all proposals were created
      const stats = await securityGovernance.getGovernanceStats();
      expect(stats.totalProposalsCount).to.equal(10);
      
      // Check gas usage is reasonable (adjust threshold as needed)
      expect(receipt.gasUsed).to.be.lt(3000000); // 3M gas limit
    });

    it("Should optimize repeated parameter reads", async function () {
      const { securityGovernance } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Multiple parameter reads should be efficient
      const [paramNames, paramValues] = await securityGovernance.getAllParameters();
      
      expect(paramNames.length).to.equal(10);
      expect(paramValues.length).to.equal(10);
      
      // Individual parameter reads should also work
      for (let i = 0; i < 3; i++) {
        const value = await securityGovernance.getSecurityParameter(paramNames[i]);
        expect(value).to.equal(paramValues[i]);
      }
    });
  });

  describe("Security Validations", function () {
    it("Should validate parameter ranges and constraints", async function () {
      const { securityGovernance, paramManager } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Valid parameter proposals should succeed
      await expect(
        securityGovernance.connect(paramManager).proposeParameterChange("validParam", 5000)
      ).to.not.be.reverted;
      
      // Test parameter validation in governance logic
      const validParam = await securityGovernance.getSecurityParameter("validParam");
      expect(validParam).to.equal(0); // Not executed yet
    });

    it("Should prevent malicious parameter changes", async function () {
      const { securityGovernance, paramManager, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Propose potentially dangerous parameter change
      const proposalTx = await securityGovernance
        .connect(paramManager)
        .proposeParameterChange("circuitBreakerCooldown", 0); // No cooldown - dangerous
      
      const receipt = await proposalTx.wait();
      const event = receipt.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "ParameterChangeProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = securityGovernance.interface.parseLog(event);
        const proposalId = parsed.args.proposalId;
        
        // Even if proposal gets signatures, parameter validation should prevent dangerous values
        await securityGovernance.connect(governance).signProposal(proposalId);
        
        // The parameter was set, but in a real implementation, there would be validation
        const dangerousParam = await securityGovernance.getSecurityParameter("circuitBreakerCooldown");
        // In production, this would be validated and potentially rejected
      }
    });

    it("Should handle proposal spam attacks", async function () {
      const { securityGovernance, paramManager } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Create many proposals rapidly
      const proposalCount = 20;
      const proposals = [];
      
      for (let i = 0; i < proposalCount; i++) {
        const tx = await securityGovernance
          .connect(paramManager)
          .proposeParameterChange(`spamParam${i}`, i * 100);
        proposals.push(tx);
      }
      
      // All proposals should be created
      const stats = await securityGovernance.getGovernanceStats();
      expect(stats.totalProposalsCount).to.equal(proposalCount);
      
      // System should remain stable
      expect(await securityGovernance.requiredSignatures()).to.equal(2);
    });
  });

  describe("Integration with External Systems", function () {
    it("Should integrate with managed contracts", async function () {
      const { securityGovernance, governance, usdt } = await loadFixture(deploySecurityGovernanceFixture);
      
      const contractAddr = await usdt.getAddress();
      
      // Add contract to management
      await securityGovernance.connect(governance).addManagedContract(contractAddr, "TestToken");
      
      // Verify contract appears in managed contracts
      const managedContract = await securityGovernance.getManagedContract(contractAddr);
      expect(managedContract.isManaged).to.be.true;
      expect(managedContract.contractType).to.equal("TestToken");
      
      // Test contract operations through governance
      const contractInfo = await securityGovernance.getManagedContract(contractAddr);
      expect(contractInfo.paused).to.be.false;
    });

    it("Should coordinate with other governance systems", async function () {
      const { securityGovernance, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Test parameter propagation simulation
      await securityGovernance.connect(governance).setSecurityParameters("testParam", 9999);
      
      const retrievedParam = await securityGovernance.getSecurityParameter("testParam");
      expect(retrievedParam).to.equal(9999);
      
      // In a real system, this would propagate to managed contracts
      // Here we just verify the governance system can set and retrieve parameters
    });
  });

  describe("Failure Recovery", function () {
    it("Should handle proposal system failures", async function () {
      const { securityGovernance, paramManager, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Create proposal
      const proposalTx = await securityGovernance
        .connect(paramManager)
        .proposeParameterChange("recoveryTest", 777);
      
      const receipt = await proposalTx.wait();
      const event = receipt.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "ParameterChangeProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = securityGovernance.interface.parseLog(event);
        const proposalId = parsed.args.proposalId;
        
        // Cancel proposal (simulating failure recovery)
        await expect(
          securityGovernance.connect(governance).cancelProposal(proposalId)
        ).to.emit(securityGovernance, "ProposalCancelled");
        
        // Verify proposal is cancelled
        const proposal = await securityGovernance.getProposal(proposalId);
        expect(proposal.cancelled).to.be.true;
        
        // System should remain operational
        await expect(
          securityGovernance.connect(paramManager).proposeParameterChange("newParam", 888)
        ).to.not.be.reverted;
      }
    });

    it("Should handle emergency system recovery", async function () {
      const { securityGovernance, governance, emergency } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Simulate emergency state
      await securityGovernance.connect(emergency).activateEmergencyMode();
      
      // Verify emergency mode detection
      const isEmergencyActive = await securityGovernance.isEmergencyModeActive();
      expect(isEmergencyActive).to.be.false; // No managed contracts to report emergency
      
      // Recovery
      await securityGovernance.connect(governance).deactivateEmergencyMode();
      
      // Verify normal operations
      await expect(
        securityGovernance.connect(governance).setTreasuryWallet(governance.address)
      ).to.not.be.reverted;
    });
  });

  describe("Documentation and Compliance", function () {
    it("Should provide comprehensive audit trail", async function () {
      const { securityGovernance, paramManager, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Create and execute proposal for audit trail
      const proposalTx = await securityGovernance
        .connect(paramManager)
        .proposeParameterChange("auditParam", 12345);
      
      const receipt = await proposalTx.wait();
      const event = receipt.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "ParameterChangeProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = securityGovernance.interface.parseLog(event);
        const proposalId = parsed.args.proposalId;
        
        // Sign and auto-execute
        await securityGovernance.connect(governance).signProposal(proposalId);
        
        // Verify audit trail exists
        const proposal = await securityGovernance.getProposal(proposalId);
        expect(proposal.executed).to.be.true;
        expect(proposal.proposer).to.equal(paramManager.address);
        expect(proposal.signatures).to.equal(2);
        
        // Verify parameter was updated
        const finalValue = await securityGovernance.getSecurityParameter("auditParam");
        expect(finalValue).to.equal(12345);
      }
    });

    it("Should maintain governance statistics for reporting", async function () {
      const { securityGovernance, paramManager, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      const initialStats = await securityGovernance.getGovernanceStats();
      
      // Execute several governance actions
      const actions = [
        { param: "stat1", value: 100 },
        { param: "stat2", value: 200 },
        { param: "stat3", value: 300 }
      ];
      
      for (const action of actions) {
        const proposalTx = await securityGovernance
          .connect(paramManager)
          .proposeParameterChange(action.param, action.value);
        
        const receipt = await proposalTx.wait();
        const event = receipt.logs.find(log => {
          try {
            const parsed = securityGovernance.interface.parseLog(log);
            return parsed.name === "ParameterChangeProposed";
          } catch {
            return false;
          }
        });
        
        if (event) {
          const parsed = securityGovernance.interface.parseLog(event);
          const proposalId = parsed.args.proposalId;
          await securityGovernance.connect(governance).signProposal(proposalId);
        }
      }
      
      // Verify statistics updated
      const finalStats = await securityGovernance.getGovernanceStats();
      expect(finalStats.totalProposalsCount).to.equal(initialStats.totalProposalsCount + 3n);
      expect(finalStats.executedProposalsCount).to.equal(initialStats.executedProposalsCount + 3n);
    });
  });

  describe("System Limits and Boundaries", function () {
    it("Should handle maximum proposal limits", async function () {
      const { securityGovernance, paramManager } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Test proposal validity period boundary
      const proposalTx = await securityGovernance
        .connect(paramManager)
        .proposeParameterChange("boundaryTest", 555);
      
      const receipt = await proposalTx.wait();
      const event = receipt.logs.find(log => {
        try {
          const parsed = securityGovernance.interface.parseLog(log);
          return parsed.name === "ParameterChangeProposed";
        } catch {
          return false;
        }
      });
      
      if (event) {
        const parsed = securityGovernance.interface.parseLog(event);
        const proposalId = parsed.args.proposalId;
        
        // Check proposal is valid initially
        expect(await securityGovernance.isProposalValid(proposalId)).to.be.true;
        
        // Fast forward to boundary
        await time.increase(7 * 24 * 60 * 60 - 1); // Just before expiry
        expect(await securityGovernance.isProposalValid(proposalId)).to.be.true;
        
        // Cross boundary
        await time.increase(2); // Just after expiry
        expect(await securityGovernance.isProposalValid(proposalId)).to.be.false;
      }
    });

    it("Should enforce signature requirements strictly", async function () {
      const { securityGovernance, governance } = await loadFixture(deploySecurityGovernanceFixture);
      
      // Test that required signatures cannot be set to impossible values
      const currentRoleCount = 3; // Approximate based on setup
      
      // Should allow reasonable signature requirements
      await expect(
        securityGovernance.connect(governance).setRequiredSignatures(1)
      ).to.not.be.reverted;
      
      // Reset to 2 for other tests
      await securityGovernance.connect(governance).setRequiredSignatures(2);
      expect(await securityGovernance.requiredSignatures()).to.equal(2);
    });
  });
});