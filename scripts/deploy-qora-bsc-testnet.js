// ===== BSC TESTNET DEPLOYMENT SCRIPT =====
// File: scripts/deploy-qora-bsc-testnet.js

const { ethers } = require("hardhat");

async function main() {
    console.log("🚀 Deploying QORA Token to BSC Testnet...");
    
    const [deployer] = await ethers.getSigners();
    console.log("Deployer:", deployer.address);
    console.log("Network:", network.name);
    
    // Check balance
    const balance = await deployer.provider.getBalance(deployer.address);
    console.log("Balance:", ethers.formatEther(balance), "BNB");
    
    if (balance < ethers.parseEther("0.01")) {
        console.log("❌ Insufficient BNB. Get testnet BNB from:");
        console.log("   https://testnet.binance.org/faucet-smart");
        return;
    }
    
    // Deploy QORA token
    const QORAFactory = await ethers.getContractFactory("QoraFi");
    console.log("Deploying QORA Token...");
    
    const qoraToken = await QORAFactory.deploy(
        "QoraFi",
        "QORA",
        "0x5A41D7AB1306a9a629b2F4bF3cE9a8509cd9b811" // Update this treasury address
    );
    
    await qoraToken.waitForDeployment();
    const address = await qoraToken.getAddress();
    
    console.log("✅ QORA Token deployed to:", address);
    console.log("📋 Token Details:");
    console.log("  Name:", await qoraToken.name());
    console.log("  Symbol:", await qoraToken.symbol());
    console.log("  Decimals:", await qoraToken.decimals());
    
    // Verify on BSCScan Testnet
    console.log("🔍 Verify on BSCScan Testnet:");
    console.log(`   https://testnet.bscscan.com/address/${address}`);
    
    return qoraToken;
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("❌ Deployment failed:", error);
        process.exit(1);
    });

// ===== ALL MAINNETS DEPLOYMENT SCRIPT =====
// File: scripts/deploy-qora-all-mainnets.js

const { ethers } = require("hardhat");

// Network configurations
const NETWORKS = {
    ethereum: {
        name: "Ethereum Mainnet",
        explorer: "https://etherscan.io/address/",
        nativeCurrency: "ETH",
        minBalance: "0.01"
    },
    bsc: {
        name: "BNB Smart Chain",
        explorer: "https://bscscan.com/address/",
        nativeCurrency: "BNB", 
        minBalance: "0.01"
    },
    polygon: {
        name: "Polygon",
        explorer: "https://polygonscan.com/address/",
        nativeCurrency: "MATIC",
        minBalance: "1"
    },
    arbitrum: {
        name: "Arbitrum One",
        explorer: "https://arbiscan.io/address/",
        nativeCurrency: "ETH",
        minBalance: "0.005"
    },
    optimism: {
        name: "Optimism",
        explorer: "https://optimistic.etherscan.io/address/",
        nativeCurrency: "ETH",
        minBalance: "0.005"
    },
    base: {
        name: "Base",
        explorer: "https://basescan.org/address/",
        nativeCurrency: "ETH",
        minBalance: "0.005"
    },
    avalanche: {
        name: "Avalanche C-Chain",
        explorer: "https://snowtrace.io/address/",
        nativeCurrency: "AVAX",
        minBalance: "0.1"
    },
    abstract: {
        name: "Abstract Network",
        explorer: "https://abscan.org/address/",
        nativeCurrency: "ABS",
        minBalance: "0.1"
    }
};

async function deployToCurrentNetwork() {
    const networkName = network.name;
    const networkConfig = NETWORKS[networkName];
    
    if (!networkConfig) {
        console.log(`❌ Unsupported network: ${networkName}`);
        console.log("Supported networks:", Object.keys(NETWORKS).join(", "));
        return;
    }
    
    console.log(`🚀 Deploying QORA Token to ${networkConfig.name}...`);
    console.log(`📡 Network: ${networkName}`);
    
    const [deployer] = await ethers.getSigners();
    console.log("👤 Deployer:", deployer.address);
    
    // Check balance
    const balance = await deployer.provider.getBalance(deployer.address);
    const balanceFormatted = ethers.formatEther(balance);
    console.log(`💰 Balance: ${balanceFormatted} ${networkConfig.nativeCurrency}`);
    
    const minBalance = ethers.parseEther(networkConfig.minBalance);
    if (balance < minBalance) {
        console.log(`❌ Insufficient ${networkConfig.nativeCurrency}. Need at least ${networkConfig.minBalance}`);
        return;
    }
    
    try {
        // Deploy QORA token
        const QORAFactory = await ethers.getContractFactory("QoraFi");
        console.log("📦 Deploying QORA Token...");
        
        // Estimate gas
        const deploymentData = QORAFactory.getDeployTransaction(
            "QoraFi Token",
            "QORA",
            "0x5A41D7AB1306a9a629b2F4bF3cE9a8509cd9b811" // Update treasury address
        );
        
        const gasEstimate = await deployer.estimateGas(deploymentData);
        const gasPrice = await deployer.provider.getFeeData();
        const estimatedCost = gasEstimate * gasPrice.gasPrice;
        
        console.log(`⛽ Estimated gas: ${gasEstimate.toString()}`);
        console.log(`💸 Estimated cost: ${ethers.formatEther(estimatedCost)} ${networkConfig.nativeCurrency}`);
        
        // Deploy
        const qoraToken = await QORAFactory.deploy(
            "QoraFi Token",
            "QORA",
            "0x5A41D7AB1306a9a629b2F4bF3cE9a8509cd9b811" // Update this treasury address
        );
        
        console.log("⏳ Waiting for deployment...");
        await qoraToken.waitForDeployment();
        
        const address = await qoraToken.getAddress();
        
        console.log("");
        console.log("🎉 DEPLOYMENT SUCCESSFUL! 🎉");
        console.log("===============================");
        console.log(`📍 Network: ${networkConfig.name}`);
        console.log(`📍 Address: ${address}`);
        console.log(`🔍 Explorer: ${networkConfig.explorer}${address}`);
        
        // Verify token details
        console.log("");
        console.log("📋 Token Details:");
        console.log(`   Name: ${await qoraToken.name()}`);
        console.log(`   Symbol: ${await qoraToken.symbol()}`);
        console.log(`   Decimals: ${await qoraToken.decimals()}`);
        console.log(`   Total Supply: ${ethers.formatEther(await qoraToken.totalSupply())}`);
        
        // Save deployment info
        const deploymentInfo = {
            network: networkName,
            networkName: networkConfig.name,
            address: address,
            deployer: deployer.address,
            timestamp: new Date().toISOString(),
            txHash: qoraToken.deploymentTransaction().hash,
            explorer: networkConfig.explorer + address
        };
        
        const fs = require('fs');
        const deploymentFile = `deployments/${networkName}-qora-deployment.json`;
        fs.writeFileSync(deploymentFile, JSON.stringify(deploymentInfo, null, 2));
        console.log(`💾 Deployment info saved: ${deploymentFile}`);
        
        return qoraToken;
        
    } catch (error) {
        console.log("");
        console.log("❌ DEPLOYMENT FAILED:");
        console.log("Error:", error.message);
        
        if (error.message.includes("insufficient funds")) {
            console.log(`💡 Solution: Add more ${networkConfig.nativeCurrency} to ${deployer.address}`);
        } else if (error.message.includes("gas")) {
            console.log("💡 Solution: Try increasing gas limit or gas price");
        }
        
        throw error;
    }
}

async function main() {
    await deployToCurrentNetwork();
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error("❌ Deployment failed:", error);
        process.exit(1);
    });

// ===== BATCH DEPLOYMENT SCRIPT =====
// File: scripts/deploy-qora-batch.js

const { exec } = require('child_process');
const { promisify } = require('util');
const execAsync = promisify(exec);

const MAINNET_NETWORKS = [
    'ethereum',
    'bsc', 
    'polygon',
    'arbitrum',
    'optimism',
    'base',
    'avalanche',
    'abstract'
];

async function deployToAllNetworks() {
    console.log('🚀 Starting batch deployment to all mainnets...');
    console.log('Networks:', MAINNET_NETWORKS.join(', '));
    console.log('');
    
    const results = [];
    
    for (const network of MAINNET_NETWORKS) {
        try {
            console.log(`📡 Deploying to ${network}...`);
            
            const { stdout, stderr } = await execAsync(
                `npx hardhat run scripts/deploy-qora-all-mainnets.js --network ${network}`
            );
            
            console.log(stdout);
            if (stderr) console.log('Warnings:', stderr);
            
            results.push({ network, status: 'SUCCESS' });
            console.log(`✅ ${network} deployment completed`);
            
        } catch (error) {
            console.log(`❌ ${network} deployment failed:`, error.message);
            results.push({ network, status: 'FAILED', error: error.message });
        }
        
        console.log('---');
    }
    
    // Summary
    console.log('📊 DEPLOYMENT SUMMARY:');
    console.log('======================');
    results.forEach(result => {
        const status = result.status === 'SUCCESS' ? '✅' : '❌';
        console.log(`${status} ${result.network}: ${result.status}`);
        if (result.error) {
            console.log(`   Error: ${result.error}`);
        }
    });
    
    const successful = results.filter(r => r.status === 'SUCCESS').length;
    console.log('');
    console.log(`🎯 Total: ${successful}/${results.length} successful deployments`);
}

if (require.main === module) {
    deployToAllNetworks()
        .then(() => process.exit(0))
        .catch(console.error);
}

// ===== HARDHAT CONFIG ADDITIONS =====
// Add this to your hardhat.config.cjs

/*
require("@nomicfoundation/hardhat-toolbox");
require("@openzeppelin/hardhat-upgrades");
require("dotenv").config();

module.exports = {
  solidity: "0.8.24",
  networks: {
    // Testnets
    bscTestnet: {
      url: "https://data-seed-prebsc-1-s1.binance.org:8545/",
      accounts: [process.env.PRIVATE_KEY],
      chainId: 97,
      gasPrice: 20000000000, // 20 gwei
    },
    sepolia: {
      url: `https://sepolia.infura.io/v3/${process.env.INFURA_API_KEY}`,
      accounts: [process.env.PRIVATE_KEY],
      chainId: 11155111,
    },
    
    // Mainnets
    ethereum: {
      url: `https://mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
      accounts: [process.env.PRIVATE_KEY],
      chainId: 1,
      gasPrice: 20000000000,
    },
    bsc: {
      url: "https://bsc-dataseed1.binance.org/",
      accounts: [process.env.PRIVATE_KEY],
      chainId: 56,
      gasPrice: 5000000000, // 5 gwei
    },
    polygon: {
      url: `https://polygon-mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
      accounts: [process.env.PRIVATE_KEY],
      chainId: 137,
      gasPrice: 30000000000, // 30 gwei
    },
    arbitrum: {
      url: `https://arbitrum-mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
      accounts: [process.env.PRIVATE_KEY],
      chainId: 42161,
    },
    optimism: {
      url: `https://optimism-mainnet.infura.io/v3/${process.env.INFURA_API_KEY}`,
      accounts: [process.env.PRIVATE_KEY],
      chainId: 10,
    },
    base: {
      url: "https://mainnet.base.org",
      accounts: [process.env.PRIVATE_KEY],
      chainId: 8453,
    },
    avalanche: {
      url: "https://api.avax.network/ext/bc/C/rpc",
      accounts: [process.env.PRIVATE_KEY],
      chainId: 43114,
    }
  },
  etherscan: {
    apiKey: {
      mainnet: process.env.ETHERSCAN_API_KEY,
      bsc: process.env.BSCSCAN_API_KEY,
      polygon: process.env.POLYGONSCAN_API_KEY,
      arbitrumOne: process.env.ARBISCAN_API_KEY,
      optimisticEthereum: process.env.OPTIMISTIC_ETHERSCAN_API_KEY,
      base: process.env.BASESCAN_API_KEY,
      avalanche: process.env.SNOWTRACE_API_KEY,
    }
  }
};
*/