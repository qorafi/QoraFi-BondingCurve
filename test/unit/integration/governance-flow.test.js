// test/integration/governance-flow.test.js
const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");
const { deployFullSystem } = require("../fixtures/mock-deployments");
const { TEST_CONSTANTS } = require("../fixtures/test-data");

describe("Governance Flow Integration", function () {
  async function deployGovernanceSystemFixture() {
    return await deployFullSystem();
  }

  describe("Parameter Management Flow", function () {
    it("Should allow governance to propose parameter changes", async function () {
      const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
      
      await expect(contracts.securityGovernance
        .connect(signers.paramManager)
        .proposeParameterChange("maxPriceChangeBPS", 1500))
        .to.emit(contracts.securityGovernance, "ParameterChangeProposed");
      
      const governanceStats = await contracts.securityGovernance.getGovernanceStats();
      expect(governanceStats.totalProposalsCount).to.equal(1);
    });

    it("Should require multiple signatures for parameter execution", async function () {
        const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
    
        const proposalTx = await contracts.securityGovernance
          .connect(signers.paramManager)
          .proposeParameterChange("maxPriceChangeBPS", 1500);
        
        const receipt = await proposalTx.wait();
        const event = receipt.logs.find(e => e.eventName === 'ParameterChangeProposed');
        const proposalId = event.args.proposalId;
    
        await expect(
            contracts.securityGovernance.connect(signers.governance).executeParameterChange(proposalId)
        ).to.be.revertedWithCustomError(contracts.securityGovernance, "InsufficientSignatures");
    });

    it("Should execute parameter changes after required signatures", async function () {
        const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
        const { paramManager, governance } = signers;
    
        const paramName = "maxPriceChangeBPS";
        const newValue = 1500;
    
        const proposalTx = await contracts.securityGovernance.connect(paramManager).proposeParameterChange(paramName, newValue);
        const receipt = await proposalTx.wait();
        const event = receipt.logs.find(e => e.eventName === 'ParameterChangeProposed');
        const proposalId = event.args.proposalId;
    
        await expect(contracts.securityGovernance.connect(governance).signProposal(proposalId))
            .to.emit(contracts.securityGovernance, "ParameterChangeExecuted");
    
        const updatedParameter = await contracts.securityGovernance.getSecurityParameter(paramName);
        expect(updatedParameter).to.equal(newValue);
    });
  });

  describe("Emergency Procedures Flow", function () {
    it("Should allow emergency role to propose emergency transactions", async function () {
      const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
      
      const pauseData = contracts.coreSecurityManager.interface.encodeFunctionData("pause", []);
      
      await expect(contracts.securityGovernance
        .connect(signers.emergency)
        .proposeEmergencyTransaction(
          await contracts.coreSecurityManager.getAddress(),
          0,
          pauseData
        )).to.emit(contracts.securityGovernance, "EmergencyTransactionProposed");
    });

    it("Should enforce timelock on emergency transactions", async function () {
        const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
        
        const pauseData = contracts.coreSecurityManager.interface.encodeFunctionData("pause", []);
        
        const proposalTx = await contracts.securityGovernance
          .connect(signers.emergency)
          .proposeEmergencyTransaction(
            await contracts.coreSecurityManager.getAddress(),
            0,
            pauseData
          );
        
        const receipt = await proposalTx.wait();
        const event = receipt.logs.find(e => e.eventName === 'EmergencyTransactionProposed');
        const txHash = event.args.txHash;
    
        await expect(
            contracts.securityGovernance.connect(signers.governance).executeEmergencyTransaction(txHash)
        ).to.be.revertedWith("Timelock: operation is not ready");
    });

    it("Should execute emergency transactions after timelock", async function () {
        const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
        
        const pauseData = contracts.coreSecurityManager.interface.encodeFunctionData("pause", []);
        
        const proposalTx = await contracts.securityGovernance
          .connect(signers.emergency)
          .proposeEmergencyTransaction(
            await contracts.coreSecurityManager.getAddress(),
            0,
            pauseData
          );
        
        const receipt = await proposalTx.wait();
        const event = receipt.logs.find(e => e.eventName === 'EmergencyTransactionProposed');
        const txHash = event.args.txHash;
    
        await time.increase(TEST_CONSTANTS.ONE_DAY + 1);
    
        await expect(
            contracts.securityGovernance.connect(signers.governance).executeEmergencyTransaction(txHash)
        ).to.emit(contracts.securityGovernance, "EmergencyTransactionExecuted");
    
        expect(await contracts.coreSecurityManager.paused()).to.be.true;
    });
  });

  describe("Contract Management Flow", function () {
    it("Should manage contracts through governance", async function () {
      const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
      
      await contracts.securityGovernance
        .connect(signers.governance)
        .addManagedContract(
          await contracts.coreSecurityManager.getAddress(),
          "CoreSecurityManager"
        );
      
      const managedContract = await contracts.securityGovernance.getManagedContract(
        await contracts.coreSecurityManager.getAddress()
      );
      
      expect(managedContract.isManaged).to.be.true;
      expect(managedContract.contractType).to.equal("CoreSecurityManager");
    });

    it("Should pause and unpause managed contracts", async function () {
        const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
    
        await contracts.securityGovernance
          .connect(signers.governance)
          .addManagedContract(
            await contracts.coreSecurityManager.getAddress(),
            "CoreSecurityManager"
          );
        
        await contracts.securityGovernance
          .connect(signers.emergency)
          .pauseManagedContract(await contracts.coreSecurityManager.getAddress());
        
        expect(await contracts.coreSecurityManager.paused()).to.be.true;
        
        await contracts.securityGovernance
          .connect(signers.governance)
          .unpauseManagedContract(await contracts.coreSecurityManager.getAddress());
        
        expect(await contracts.coreSecurityManager.paused()).to.be.false;
    });
  });

  describe("Role Management Flow", function () {
    it("Should manage roles through governance system", async function () {
      const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
      
      const PARAM_MANAGER_ROLE = await contracts.securityGovernance.PARAM_MANAGER_ROLE();
      
      await contracts.securityGovernance
        .connect(signers.governance)
        .grantRole(PARAM_MANAGER_ROLE, signers.user2.address);
      
      expect(await contracts.securityGovernance.hasRole(PARAM_MANAGER_ROLE, signers.user2.address)).to.be.true;
      
      await contracts.securityGovernance
        .connect(signers.governance)
        .revokeRole(PARAM_MANAGER_ROLE, signers.user2.address);
      
      expect(await contracts.securityGovernance.hasRole(PARAM_MANAGER_ROLE, signers.user2.address)).to.be.false;
    });
  });

  describe("Treasury Management Flow", function () {
    it("Should manage treasury wallet through governance", async function () {
      const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
      
      const currentTreasury = await contracts.securityGovernance.getTreasuryWallet();
      expect(currentTreasury).to.equal(signers.treasury.address);
      
      await contracts.securityGovernance
        .connect(signers.governance)
        .setTreasuryWallet(signers.user2.address);
      
      const newTreasury = await contracts.securityGovernance.getTreasuryWallet();
      expect(newTreasury).to.equal(signers.user2.address);
    });
  });
});