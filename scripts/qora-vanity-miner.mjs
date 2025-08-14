// Simple QORA Token Vanity Address Miner
import { Worker, isMainThread, parentPort, workerData } from 'worker_threads';
import { ethers } from 'ethers';
import { readFileSync, writeFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// ===== CONFIGURATION =====
const CONFIG = {
    FACTORY_ADDRESS: "0x4e59b44847b379578588920cA78FbF26c0B4956C",
    TARGET_PATTERN: /^0x[qQ][oO]/i,  // Start with 0xQO (easy pattern)
    WORKER_COUNT: 8,
    ITERATIONS_PER_WORKER: 500_000,
    TREASURY_ADDRESS: "0x5A41D7AB1306a9a629b2F4bF3cE9a8509cd9b811" // CHANGE THIS!
};

// Read contract bytecode
let contractBytecode;
try {
    const contractPath = join(__dirname, '../artifacts/contracts/tokens/QoraFi.sol/QoraFi.json');
    const contractArtifact = JSON.parse(readFileSync(contractPath, 'utf8'));
    contractBytecode = contractArtifact.bytecode;
} catch (error) {
    console.error('❌ Failed to load contract. Run: npx hardhat compile');
    process.exit(1);
}

if (isMainThread) {
    console.log('🔍 QORA Token Vanity Address Miner');
    console.log('Pattern:', CONFIG.TARGET_PATTERN);
    console.log('Workers:', CONFIG.WORKER_COUNT);
    console.log('');
    
    let totalAttempts = 0;
    let startTime = Date.now();
    let found = false;
    
    // Create deployment bytecode
    const abiCoder = ethers.AbiCoder.defaultAbiCoder();
    const constructorParams = abiCoder.encode(
        ['string', 'string', 'address'],
        ["QoraFi Token", "QORA", CONFIG.TREASURY_ADDRESS]
    );
    const fullBytecode = contractBytecode + constructorParams.slice(2);
    const initCodeHash = ethers.keccak256(fullBytecode);
    
    console.log('Contract hash:', initCodeHash);
    console.log('Mining started...');
    console.log('');
    
    // Progress reporting
    const statusInterval = setInterval(() => {
        if (!found) {
            const elapsed = (Date.now() - startTime) / 1000;
            const rate = Math.round(totalAttempts / elapsed);
            console.log(`Attempts: ${totalAttempts.toLocaleString()} | Rate: ${rate.toLocaleString()}/sec | Time: ${Math.round(elapsed)}s`);
        }
    }, 5000);
    
    // Spawn workers
    for (let i = 0; i < CONFIG.WORKER_COUNT; i++) {
        const worker = new Worker(__filename, {
            workerData: {
                workerId: i,
                factoryAddress: CONFIG.FACTORY_ADDRESS,
                initCodeHash: initCodeHash,
                targetPattern: CONFIG.TARGET_PATTERN.source,
                iterationsPerBatch: CONFIG.ITERATIONS_PER_WORKER
            }
        });
        
        worker.on('message', (message) => {
            if (message.type === 'progress') {
                totalAttempts += message.attempts;
            } else if (message.type === 'found') {
                found = true;
                clearInterval(statusInterval);
                
                const elapsed = (Date.now() - startTime) / 1000;
                console.log('');
                console.log('🎉 VANITY ADDRESS FOUND! 🎉');
                console.log('Address:', message.address);
                console.log('Salt:', message.salt);
                console.log('Time:', Math.round(elapsed) + 's');
                console.log('Total attempts:', totalAttempts.toLocaleString());
                
                // Generate deployment script
                generateDeploymentScript(message.salt, message.address);
                process.exit(0);
            }
        });
    }
    
} else {
    // Worker thread
    const { workerId, factoryAddress, initCodeHash, targetPattern, iterationsPerBatch } = workerData;
    const pattern = new RegExp(targetPattern, 'i');
    
    let attempts = 0;
    
    while (true) {
        const salt = ethers.randomBytes(32);
        const address = ethers.getCreate2Address(factoryAddress, salt, initCodeHash);
        attempts++;
        
        if (pattern.test(address)) {
            parentPort.postMessage({
                type: 'found',
                address: address,
                salt: ethers.hexlify(salt),
                workerId: workerId
            });
            break;
        }
        
        if (attempts % iterationsPerBatch === 0) {
            parentPort.postMessage({
                type: 'progress',
                attempts: iterationsPerBatch,
                workerId: workerId
            });
            attempts = 0;
        }
    }
}

function generateDeploymentScript(salt, address) {
    const script = `const { ethers } = require("hardhat");

async function main() {
    console.log("Deploying QORA Token with vanity address...");
    console.log("Target address: ${address}");
    
    const QORAFactory = await ethers.getContractFactory("QoraFi");
    const qoraToken = await QORAFactory.deploy(
        "QoraFi Token",
        "QORA", 
        "${CONFIG.TREASURY_ADDRESS}"
    );
    
    await qoraToken.waitForDeployment();
    console.log("QORA Token deployed to:", await qoraToken.getAddress());
    
    return qoraToken;
}

main().catch(console.error);`;
    
    const filename = `scripts/deploy-qora-${address.slice(2, 6)}.js`;
    writeFileSync(filename, script);
    console.log('');
    console.log('📝 Deployment script saved:', filename);
    console.log('');
    console.log('🚀 Next steps:');
    console.log('1. Test: npx hardhat run', filename, '--network sepolia');
    console.log('2. Deploy: npx hardhat run', filename, '--network mainnet');
    console.log('');
    console.log('Salt for CREATE2:', salt);
    console.log('Use this salt to get the same address on all chains!');
}