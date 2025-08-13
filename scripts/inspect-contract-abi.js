// scripts/inspect-contract-abi.js
const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function main() {
  console.log("🔍 Inspecting Contract ABIs...\n");
  
  try {
    // Method 1: Try to get contract factory
    console.log("📋 Attempting to load AdvancedSecurityManager...");
    
    let AdvancedSecurityManager;
    let abi;
    
    try {
      AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager");
      abi = AdvancedSecurityManager.interface;
      console.log("✅ Contract factory loaded successfully");
    } catch (factoryError) {
      console.log("⚠️ Contract factory failed, trying alternative methods...");
      console.log("Factory error:", factoryError.message);
      
      // Method 2: Try to read from artifacts
      try {
        const artifactPath = path.join(__dirname, "../artifacts/contracts/security/AdvancedSecurityManager.sol/AdvancedSecurityManager.json");
        if (fs.existsSync(artifactPath)) {
          const artifact = JSON.parse(fs.readFileSync(artifactPath, 'utf8'));
          abi = new ethers.utils.Interface(artifact.abi);
          console.log("✅ Loaded from artifacts");
        } else {
          console.log("❌ Artifact file not found at:", artifactPath);
          
          // Method 3: Try different path
          const altPath = path.join(__dirname, "../artifacts/contracts/AdvancedSecurityManager.sol/AdvancedSecurityManager.json");
          if (fs.existsSync(altPath)) {
            const artifact = JSON.parse(fs.readFileSync(altPath, 'utf8'));
            abi = new ethers.utils.Interface(artifact.abi);
            console.log("✅ Loaded from alternative path");
          }
        }
      } catch (artifactError) {
        console.log("❌ Artifact loading failed:", artifactError.message);
      }
    }
    
    if (!abi) {
      console.log("❌ Could not load contract ABI. Let's try to compile first...");
      
      // Try to compile contracts
      console.log("🔨 Attempting to compile contracts...");
      const { exec } = require('child_process');
      const util = require('util');
      const execPromise = util.promisify(exec);
      
      try {
        await execPromise('npx hardhat compile');
        console.log("✅ Compilation completed");
        
        // Try again after compilation
        AdvancedSecurityManager = await ethers.getContractFactory("AdvancedSecurityManager");
        abi = AdvancedSecurityManager.interface;
        console.log("✅ Contract loaded after compilation");
      } catch (compileError) {
        console.log("❌ Compilation failed:", compileError.message);
        return;
      }
    }
    
    if (!abi || !abi.fragments) {
      console.log("❌ ABI or fragments property is null/undefined");
      console.log("ABI object:", abi);
      return;
    }
    
    console.log("\n📋 AdvancedSecurityManager ABI Analysis:");
    console.log("==========================================");
    
    // Analyze functions - filter fragments for functions only
    console.log("📝 All Functions in AdvancedSecurityManager:");
    const functionFragments = abi.fragments.filter(fragment => fragment.type === 'function');
    const functions = functionFragments.map(f => `${f.name}(${f.inputs.map(i => i.type).join(',')})`);
    
    if (functions.length === 0) {
      console.log("  ⚠️ No functions found in ABI");
    } else {
      functions.sort().forEach((func, index) => {
        const fragment = functionFragments[functions.indexOf(func)];
        const inputs = fragment.inputs.map(i => `${i.type} ${i.name || ''}`).join(', ');
        const outputs = fragment.outputs.map(o => o.type).join(', ') || 'void';
        console.log(`  ✅ ${fragment.name}(${inputs}) -> ${outputs}`);
      });
      
      console.log(`\n📊 Total Functions: ${functions.length}`);
    }
    
    // Check for specific expected functions
    console.log("\n🔍 Checking for Expected Advanced Functions:");
    const expectedFunctions = [
      'emergencyMode',
      'emergencyTransactionDelay', 
      'getRiskConfig',
      'activateEmergencyMode',
      'deactivateEmergencyMode',
      'updateUserRiskScore',
      'flagUser',
      'getFlashLoanProtectionStatus',
      'advancedPreDepositCheck',
      'canUserDepositAdvanced',
      'activateAdvancedEmergencyMode',
      'getUserRiskAssessment',
      'getSystemHealthStatus'
    ];
    
    expectedFunctions.forEach(funcName => {
      const found = functions.find(f => f.includes(funcName + '('));
      if (found) {
        console.log(`  ✅ ${funcName}: FOUND (${found})`);
      } else {
        console.log(`  ❌ ${funcName}: MISSING`);
      }
    });
    
    // Check for events
    console.log("\n📝 Events in AdvancedSecurityManager:");
    const eventFragments = abi.fragments.filter(fragment => fragment.type === 'event');
    if (eventFragments.length > 0) {
      eventFragments.sort((a, b) => a.name.localeCompare(b.name)).forEach(event => {
        console.log(`  📢 ${event.name}`);
      });
      console.log(`\n📊 Total Events: ${eventFragments.length}`);
    } else {
      console.log("  No events found");
    }
    
    // Compare with CoreSecurityManager
    console.log("\n📋 Comparing with CoreSecurityManager:");
    console.log("=====================================");
    
    try {
      const CoreSecurityManager = await ethers.getContractFactory("CoreSecurityManager");
      const coreAbi = CoreSecurityManager.interface;
      
      if (coreAbi && coreAbi.fragments) {
        const coreFunctionFragments = coreAbi.fragments.filter(fragment => fragment.type === 'function');
        const coreFunctions = coreFunctionFragments.map(f => `${f.name}(${f.inputs.map(i => i.type).join(',')})`);
        
        console.log(`Core functions: ${coreFunctions.length}`);
        console.log(`Advanced functions: ${functions.length}`);
        
        // Check inheritance
        const inheritedFunctions = coreFunctions.filter(coreFunc => {
          const coreFuncName = coreFunc.split('(')[0];
          return functions.some(advFunc => advFunc.split('(')[0] === coreFuncName);
        });
        
        console.log(`Inherited functions: ${inheritedFunctions.length}`);
        console.log(`New advanced functions: ${functions.length - inheritedFunctions.length}`);
        
        // Show functions that should be inherited but aren't
        const missingInheritance = coreFunctions.filter(coreFunc => {
          const coreFuncName = coreFunc.split('(')[0];
          return !functions.some(advFunc => advFunc.split('(')[0] === coreFuncName);
        });
        
        if (missingInheritance.length > 0) {
          console.log("\n⚠️ Core functions missing from Advanced:");
          missingInheritance.slice(0, 10).forEach(func => { // Limit to first 10
            console.log(`  ❌ ${func}`);
          });
          if (missingInheritance.length > 10) {
            console.log(`  ... and ${missingInheritance.length - 10} more`);
          }
        } else {
          console.log("\n✅ All core functions properly inherited!");
        }
        
        // Show new advanced-only functions
        const newFunctions = functions.filter(advFunc => {
          const advFuncName = advFunc.split('(')[0];
          return !coreFunctions.some(coreFunc => coreFunc.split('(')[0] === advFuncName);
        });
        
        if (newFunctions.length > 0) {
          console.log("\n🆕 New Advanced-only functions:");
          newFunctions.forEach(func => {
            console.log(`  ➕ ${func}`);
          });
        }
        
      } else {
        console.log("⚠️ Could not access CoreSecurityManager functions");
      }
      
    } catch (coreError) {
      console.log("⚠️ Could not load CoreSecurityManager for comparison:", coreError.message);
    }
    
    // Additional diagnostics
    console.log("\n🔧 Diagnostic Information:");
    console.log("==========================");
    console.log(`Hardhat network: ${hre.network.name}`);
    console.log(`Ethers version: ${ethers.version}`);
    
    // Try to check if contracts are compiled
    const artifactsDir = path.join(__dirname, "../artifacts");
    if (fs.existsSync(artifactsDir)) {
      console.log("✅ Artifacts directory exists");
      const contractFiles = fs.readdirSync(artifactsDir, { recursive: true })
        .filter(file => file.endsWith('.json') && file.includes('AdvancedSecurityManager'));
      console.log(`Found ${contractFiles.length} AdvancedSecurityManager artifacts`);
    } else {
      console.log("❌ Artifacts directory not found");
    }
    
  } catch (error) {
    console.error("❌ Error inspecting contract ABI:", error);
    console.error("Stack trace:", error.stack);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });