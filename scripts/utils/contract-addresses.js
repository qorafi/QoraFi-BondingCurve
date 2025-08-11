// scripts/utils/contract-addresses.js
const fs = require('fs');
const path = require('path');

class ContractAddresses {
  constructor(networkName) {
    this.networkName = networkName;
    this.deploymentDir = path.join(__dirname, '../../deployments', networkName);
    this.addresses = this.loadAddresses();
  }

  loadAddresses() {
    const addresses = {};
    
    if (!fs.existsSync(this.deploymentDir)) {
      return addresses;
    }

    try {
      // Load all deployment files
      const files = fs.readdirSync(this.deploymentDir);
      
      for (const file of files) {
        if (file.endsWith('.json')) {
          const filePath = path.join(this.deploymentDir, file);
          const data = JSON.parse(fs.readFileSync(filePath, 'utf8'));
          
          // Merge addresses from this deployment file
          Object.assign(addresses, data);
        }
      }
    } catch (error) {
      console.warn(`Warning: Could not load addresses for ${this.networkName}:`, error.message);
    }

    return addresses;
  }

  get(contractName) {
    const contract = this.addresses[contractName];
    if (!contract) {
      throw new Error(`Contract address not found: ${contractName} on ${this.networkName}`);
    }
    return contract.address;
  }

  getImplementation(contractName) {
    const contract = this.addresses[contractName];
    if (!contract) {
      throw new Error(`Contract address not found: ${contractName} on ${this.networkName}`);
    }
    return contract.implementation || contract.address;
  }

  getAll() {
    return this.addresses;
  }

  exists(contractName) {
    return !!this.addresses[contractName];
  }

  // Get addresses for a specific category
  getLibraries() {
    return {
      SecurityLibraries: this.get('SecurityLibraries'),
      OracleLibraries: this.get('OracleLibraries'),
      UtilityLibraries: this.get('UtilityLibraries')
    };
  }

  getCoreContracts() {
    return {
      CoreSecurityManager: this.get('CoreSecurityManager'),
      EnhancedOracle: this.get('EnhancedOracle')
    };
  }

  getAdvancedContracts() {
    return {
      AdvancedSecurityManager: this.get('AdvancedSecurityManager'),
      SecurityGovernance: this.get('SecurityGovernance')
    };
  }
}

module.exports = ContractAddresses;

// scripts/utils/deployment-helpers.js
const fs = require('fs');
const path = require('path');

async function saveDeployment(networkName, category, deployments) {
  const deploymentDir = path.join(__dirname, '../../deployments', networkName);
  
  // Create directory if it doesn't exist
  if (!fs.existsSync(deploymentDir)) {
    fs.mkdirSync(deploymentDir, { recursive: true });
  }

  const filePath = path.join(deploymentDir, `${category}.json`);
  
  // Add timestamp and network info
  const deploymentData = {
    ...deployments,
    _metadata: {
      network: networkName,
      deployedAt: new Date().toISOString(),
      category: category,
      deployer: deployments.deployer || 'unknown'
    }
  };

  fs.writeFileSync(filePath, JSON.stringify(deploymentData, null, 2));
  console.log(`💾 Deployment saved to: ${filePath}`);
}

async function loadDeployment(networkName, category) {
  const deploymentDir = path.join(__dirname, '../../deployments', networkName);
  const filePath = path.join(deploymentDir, `${category}.json`);
  
  if (!fs.existsSync(filePath)) {
    console.warn(`⚠️ Deployment file not found: ${filePath}`);
    return null;
  }

  try {
    const data = fs.readFileSync(filePath, 'utf8');
    return JSON.parse(data);
  } catch (error) {
    console.error(`❌ Error loading deployment file ${filePath}:`, error);
    return null;
  }
}

async function getAllDeployments(networkName) {
  const deploymentDir = path.join(__dirname, '../../deployments', networkName);
  
  if (!fs.existsSync(deploymentDir)) {
    return {};
  }

  const deployments = {};
  const files = fs.readdirSync(deploymentDir);
  
  for (const file of files) {
    if (file.endsWith('.json')) {
      const category = file.replace('.json', '');
      deployments[category] = await loadDeployment(networkName, category);
    }
  }

  return deployments;
}

async function verifyDeployment(networkName, contractName, address) {
  try {
    const code = await ethers.provider.getCode(address);
    const isDeployed = code !== '0x';
    
    console.log(`🔍 ${contractName} on ${networkName}:`);
    console.log(`   Address: ${address}`);
    console.log(`   Deployed: ${isDeployed ? '✅' : '❌'}`);
    
    return isDeployed;
  } catch (error) {
    console.error(`❌ Error verifying ${contractName}:`, error);
    return false;
  }
}

async function estimateGasCosts(contractFactory, constructorArgs = []) {
  try {
    const deployTx = contractFactory.getDeployTransaction(...constructorArgs);
    const gasEstimate = await ethers.provider.estimateGas(deployTx);
    const gasPrice = await ethers.provider.getGasPrice();
    const cost = gasEstimate * gasPrice;
    
    return {
      gasEstimate: gasEstimate.toString(),
      gasPrice: ethers.formatUnits(gasPrice, 'gwei'),
      costInETH: ethers.formatEther(cost),
      costInWei: cost.toString()
    };
  } catch (error) {
    console.error('Error estimating gas costs:', error);
    return null;
  }
}

function formatDeploymentSummary(deployments) {
  console.log("\n📋 Deployment Summary:");
  console.log("=" * 50);
  
  Object.entries(deployments).forEach(([category, contracts]) => {
    if (category.startsWith('_')) return; // Skip metadata
    
    console.log(`\n📁 ${category.toUpperCase()}:`);
    Object.entries(contracts).forEach(([name, info]) => {
      if (name.startsWith('_')) return; // Skip metadata
      console.log(`   ${name}: ${info.address}`);
      if (info.implementation) {
        console.log(`   ${name} (impl): ${info.implementation}`);
      }
    });
  });
  
  console.log("\n" + "=" * 50);
}

module.exports = {
  saveDeployment,
  loadDeployment,
  getAllDeployments,
  verifyDeployment,
  estimateGasCosts,
  formatDeploymentSummary
};