const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture, time } = require("@nomicfoundation/hardhat-network-helpers");
const { deployFullSystem } = require("../fixtures/mock-deployments");

describe("Governance Flow Integration", function () {
  async function deployGovernanceSystemFixture() {
    const system = await deployFullSystem();
    const { deployer, governance, emergency, user1, user2 } = system.signers;
    const { securityGovernance, coreSecurityManager, advancedSecurityManager } = system.contracts;

    // Get role constants
    const GOVERNANCE_ROLE = await securityGovernance.GOVERNANCE_ROLE();
    const PARAMETER_MANAGER_ROLE = await securityGovernance.PARAMETER_MANAGER_ROLE();
    const EMERGENCY_ROLE = await securityGovernance.EMERGENCY_ROLE();
    const EXECUTOR_ROLE = await securityGovernance.EXECUTOR_ROLE();

    // Grant necessary roles using deployer (who should have DEFAULT_ADMIN_ROLE)
    // Grant GOVERNANCE_ROLE to governance signer and additional signers for multi-sig
    await securityGovernance.connect(deployer).grantRole(GOVERNANCE_ROLE, governance.address);
    await securityGovernance.connect(deployer).grantRole(GOVERNANCE_ROLE, user1.address);
    await securityGovernance.connect(deployer).grantRole(GOVERNANCE_ROLE, user2.address);

    // Grant PARAMETER_MANAGER_ROLE for parameter updates
    await securityGovernance.connect(deployer).grantRole(PARAMETER_MANAGER_ROLE, governance.address);
    await securityGovernance.connect(deployer).grantRole(PARAMETER_MANAGER_ROLE, user1.address);

    // Grant EMERGENCY_ROLE for emergency procedures
    await securityGovernance.connect(deployer).grantRole(EMERGENCY_ROLE, emergency.address);
    await securityGovernance.connect(deployer).grantRole(EMERGENCY_ROLE, governance.address);

    // Grant EXECUTOR_ROLE for executing transactions after timelock
    await securityGovernance.connect(deployer).grantRole(EXECUTOR_ROLE, governance.address);
    await securityGovernance.connect(deployer).grantRole(EXECUTOR_ROLE, user1.address);

    // Also grant roles on the security managers if they need them
    const SEC_GOVERNANCE_ROLE = await coreSecurityManager.GOVERNANCE_ROLE();
    await coreSecurityManager.connect(deployer).grantRole(SEC_GOVERNANCE_ROLE, governance.address);
    await coreSecurityManager.connect(deployer).grantRole(SEC_GOVERNANCE_ROLE, await securityGovernance.getAddress());

    if (advancedSecurityManager) {
      const ADV_GOVERNANCE_ROLE = await advancedSecurityManager.GOVERNANCE_ROLE();
      await advancedSecurityManager.connect(deployer).grantRole(ADV_GOVERNANCE_ROLE, governance.address);
      await advancedSecurityManager.connect(deployer).grantRole(ADV_GOVERNANCE_ROLE, await securityGovernance.getAddress());
    }

    return system;
  }

  describe("Parameter Management Flow", function () {
    it("Should allow governance to propose parameter changes", async function () {
      const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
      const { governance } = signers;
      
      // Propose parameter change
      const paramId = ethers.id("maxDailyDeposit");
      const newValue = ethers.parseUnits("50000", 6);
      
      await expect(
        contracts.securityGovernance.connect(governance).proposeParameterChange(
          paramId,
          newValue
        )
      ).to.emit(contracts.securityGovernance, "ParameterChangeProposed")
        .withArgs(paramId, newValue, await governance.getAddress());
    });

    it("Should require multiple signatures for parameter execution", async function () {
      const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
      const { governance, user1 } = signers;
      
      // First, set required signatures to 2
      await contracts.securityGovernance.connect(governance).setRequiredSignatures(2);
      
      // Propose parameter change
      const paramId = ethers.id("maxDailyDeposit");
      const newValue = ethers.parseUnits("50000", 6);
      
      const tx = await contracts.securityGovernance.connect(governance).proposeParameterChange(
        paramId,
        newValue
      );
      
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => {
        try {
          const parsed = contracts.securityGovernance.interface.parseLog(log);
          return parsed.name === "ParameterChangeProposed";
        } catch {
          return false;
        }
      });
      
      const proposalId = event.args[3]; // proposalId is the 4th parameter in the event
      
      // Try to execute with only one signature (should fail)
      await expect(
        contracts.securityGovernance.connect(governance).executeParameterChange(proposalId)
      ).to.be.revertedWithCustomError(contracts.securityGovernance, "InsufficientSignatures");
      
      // Add second signature
      await contracts.securityGovernance.connect(user1).signProposal(proposalId);
      
      // Now execution should succeed
      await expect(
        contracts.securityGovernance.connect(governance).executeParameterChange(proposalId)
      ).to.not.be.reverted;
    });

    it("Should execute parameter changes after required signatures", async function () {
      const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
      const { governance } = signers;
      
      const paramId = ethers.id("maxDailyDeposit");
      const newValue = ethers.parseUnits("75000", 6);
      
      // Propose and execute (with single signature requirement)
      await contracts.securityGovernance.connect(governance).proposeParameterChange(
        paramId,
        newValue
      );
      
      // Get the proposal ID from events
      const filter = contracts.securityGovernance.filters.ParameterChangeProposed();
      const events = await contracts.securityGovernance.queryFilter(filter);
      const proposalId = events[events.length - 1].args[3];
      
      // Execute the change
      await contracts.securityGovernance.connect(governance).executeParameterChange(proposalId);
      
      // Verify the parameter was updated
      const allParams = await contracts.securityGovernance.getAllSecurityParameters();
      const param = allParams.find(p => p.id === paramId);
      expect(param.value).to.equal(newValue);
    });
  });

  describe("Emergency Procedures Flow", function () {
    it("Should allow emergency role to propose emergency transactions", async function () {
      const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
      const { emergency } = signers;
      
      const target = await contracts.coreSecurityManager.getAddress();
      const data = contracts.coreSecurityManager.interface.encodeFunctionData("pause");
      
      await expect(
        contracts.securityGovernance.connect(emergency).proposeEmergencyTransaction(
          target,
          data,
          "Emergency pause"
        )
      ).to.emit(contracts.securityGovernance, "EmergencyTransactionProposed");
    });

    it("Should enforce timelock on emergency transactions", async function () {
      const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
      const { emergency, governance } = signers;
      
      const target = await contracts.coreSecurityManager.getAddress();
      const data = contracts.coreSecurityManager.interface.encodeFunctionData("pause");
      
      // Propose emergency transaction
      const tx = await contracts.securityGovernance.connect(emergency).proposeEmergencyTransaction(
        target,
        data,
        "Emergency pause"
      );
      
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => {
        try {
          const parsed = contracts.securityGovernance.interface.parseLog(log);
          return parsed.name === "EmergencyTransactionProposed";
        } catch {
          return false;
        }
      });
      
      const txId = event.args[0]; // transaction ID
      
      // Try to execute immediately (should fail due to timelock)
      await expect(
        contracts.securityGovernance.connect(governance).executeEmergencyTransaction(txId)
      ).to.be.revertedWithCustomError(contracts.securityGovernance, "TimelockNotExpired");
    });

    it("Should execute emergency transactions after timelock", async function () {
      const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
      const { emergency, governance } = signers;
      
      const target = await contracts.coreSecurityManager.getAddress();
      const data = contracts.coreSecurityManager.interface.encodeFunctionData("pause");
      
      // Propose emergency transaction
      const tx = await contracts.securityGovernance.connect(emergency).proposeEmergencyTransaction(
        target,
        data,
        "Emergency pause"
      );
      
      const receipt = await tx.wait();
      const event = receipt.logs.find(log => {
        try {
          const parsed = contracts.securityGovernance.interface.parseLog(log);
          return parsed.name === "EmergencyTransactionProposed";
        } catch {
          return false;
        }
      });
      
      const txId = event.args[0];
      
      // Get the timelock delay and fast forward
      const delay = await contracts.securityGovernance.emergencyTxDelay();
      await time.increase(delay);
      
      // Now execution should succeed
      await expect(
        contracts.securityGovernance.connect(governance).executeEmergencyTransaction(txId)
      ).to.emit(contracts.securityGovernance, "EmergencyTransactionExecuted")
        .withArgs(txId, await governance.getAddress());
      
      // Verify the effect (contract should be paused)
      expect(await contracts.coreSecurityManager.paused()).to.be.true;
    });
  });

  describe("Contract Management Flow", function () {
    it("Should manage contracts through governance", async function () {
      const { contracts, signers, tokens } = await loadFixture(deployGovernanceSystemFixture);
      const { governance } = signers;
      
      // Add a managed contract (use USDT token as example)
      const contractAddress = await tokens.usdt.getAddress();
      
      await expect(
        contracts.securityGovernance.connect(governance).addManagedContract(
          contractAddress,
          "USDT Token"
        )
      ).to.emit(contracts.securityGovernance, "ManagedContractAdded")
        .withArgs(contractAddress, "USDT Token");
      
      // Verify it was added
      const managedContracts = await contracts.securityGovernance.getManagedContracts();
      expect(managedContracts).to.include(contractAddress);
    });

    it("Should pause and unpause managed contracts", async function () {
      const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
      const { governance } = signers;
      
      // Add the core security manager as a managed contract
      const contractAddress = await contracts.coreSecurityManager.getAddress();
      
      await contracts.securityGovernance.connect(governance).addManagedContract(
        contractAddress,
        "Core Security Manager"
      );
      
      // Create pause transaction through governance
      const pauseData = contracts.coreSecurityManager.interface.encodeFunctionData("pause");
      
      // Propose and execute pause transaction
      const proposeTx = await contracts.securityGovernance.connect(governance).proposeEmergencyTransaction(
        contractAddress,
        pauseData,
        "Pause security manager"
      );
      
      const receipt = await proposeTx.wait();
      const event = receipt.logs.find(log => {
        try {
          const parsed = contracts.securityGovernance.interface.parseLog(log);
          return parsed.name === "EmergencyTransactionProposed";
        } catch {
          return false;
        }
      });
      
      const txId = event.args[0];
      
      // Fast forward past timelock
      const delay = await contracts.securityGovernance.emergencyTxDelay();
      await time.increase(delay);
      
      // Execute the pause
      await contracts.securityGovernance.connect(governance).executeEmergencyTransaction(txId);
      
      // Verify it's paused
      expect(await contracts.coreSecurityManager.paused()).to.be.true;
      
      // Now unpause
      const unpauseData = contracts.coreSecurityManager.interface.encodeFunctionData("unpause");
      const unpauseTx = await contracts.securityGovernance.connect(governance).proposeEmergencyTransaction(
        contractAddress,
        unpauseData,
        "Unpause security manager"
      );
      
      const unpauseReceipt = await unpauseTx.wait();
      const unpauseEvent = unpauseReceipt.logs.find(log => {
        try {
          const parsed = contracts.securityGovernance.interface.parseLog(log);
          return parsed.name === "EmergencyTransactionProposed";
        } catch {
          return false;
        }
      });
      
      const unpauseTxId = unpauseEvent.args[0];
      
      await time.increase(delay);
      await contracts.securityGovernance.connect(governance).executeEmergencyTransaction(unpauseTxId);
      
      // Verify it's unpaused
      expect(await contracts.coreSecurityManager.paused()).to.be.false;
    });
  });

  describe("Role Management Flow", function () {
    it("Should manage roles through governance system", async function () {
      const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
      const { governance, user1, user2 } = signers;
      
      // Grant a new role to user2
      const PARAMETER_MANAGER_ROLE = await contracts.securityGovernance.PARAMETER_MANAGER_ROLE();
      
      await expect(
        contracts.securityGovernance.connect(governance).grantRole(
          PARAMETER_MANAGER_ROLE,
          user2.address
        )
      ).to.emit(contracts.securityGovernance, "RoleGranted");
      
      // Verify role was granted
      expect(await contracts.securityGovernance.hasRole(PARAMETER_MANAGER_ROLE, user2.address)).to.be.true;
      
      // Revoke the role
      await expect(
        contracts.securityGovernance.connect(governance).revokeRole(
          PARAMETER_MANAGER_ROLE,
          user2.address
        )
      ).to.emit(contracts.securityGovernance, "RoleRevoked");
      
      // Verify role was revoked
      expect(await contracts.securityGovernance.hasRole(PARAMETER_MANAGER_ROLE, user2.address)).to.be.false;
    });
  });

  describe("Treasury Management Flow", function () {
    it("Should manage treasury wallet through governance", async function () {
      const { contracts, signers } = await loadFixture(deployGovernanceSystemFixture);
      const { governance, user1 } = signers;
      
      const newTreasury = user1.address;
      
      // Update treasury wallet
      await expect(
        contracts.securityGovernance.connect(governance).setTreasuryWallet(newTreasury)
      ).to.emit(contracts.securityGovernance, "TreasuryWalletUpdated")
        .withArgs(newTreasury);
      
      // Verify treasury was updated
      expect(await contracts.securityGovernance.treasuryWallet()).to.equal(newTreasury);
    });
  });
});