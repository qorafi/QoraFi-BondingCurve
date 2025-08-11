# 🛡️ Qorafi DeFi Protocol - Testing Framework

A comprehensive testing suite for the modular DeFi protocol with advanced security features.

## 📁 Test Structure

```
test/
├── unit/                          # Unit tests for individual components
│   ├── core/                      # Core functionality tests
│   │   ├── CoreSecurityManager.test.js
│   │   └── EnhancedOracle.test.js
│   ├── advanced/                  # Advanced features tests
│   │   ├── AdvancedSecurityManager.test.js
│   │   └── SecurityGovernance.test.js
│   └── libraries/                 # Library tests
│       ├── SecurityLibraries.test.js
│       ├── OracleLibraries.test.js
│       └── UtilityLibraries.test.js
├── integration/                   # Integration tests
│   ├── complete-system.test.js    # End-to-end system tests
│   ├── emergency-procedures.test.js
│   └── governance-flow.test.js
├── fixtures/                      # Test utilities and data
│   ├── mock-deployments.js        # Deployment fixtures
│   └── test-data.js               # Test constants and helpers
└── reports/                       # Generated test reports
```

## 🚀 Quick Start

### Run All Tests
```bash
npm test
```

### Run Specific Test Suites
```bash
# Unit tests only
npm run test:unit

# Integration tests only  
npm run test:integration

# Core functionality tests
npm run test:core

# Advanced features tests
npm run test:advanced
```

### Coverage Analysis
```bash
npm run coverage
```

### Gas Analysis
```bash
npm run gas-report
```

### Comprehensive Test Runner
```bash
# Run complete test suite with reporting
node scripts/test/run-all-tests.js

# Run specific test categories
node scripts/test/run-all-tests.js --unit-only
node scripts/test/run-all-tests.js --integration-only
node scripts/test/run-all-tests.js --coverage-only
```

## 🧪 Test Categories

### **Unit Tests**
Test individual contract functionality in isolation:

- **Core Security Manager**: MEV protection, circuit breakers, validation
- **Enhanced Oracle**: TWAP calculations, price validation, flash loan detection  
- **Advanced Security Manager**: Risk scoring, emergency procedures, behavior analytics
- **Security Governance**: Multi-sig proposals, parameter management, emergency transactions
- **Libraries**: Modular components (Security, Oracle, Utility libraries)

### **Integration Tests**
Test cross-contract interactions and workflows:

- **Complete System**: End-to-end user journeys and system coordination
- **Emergency Procedures**: System-wide emergency response and recovery
- **Governance Flow**: Multi-signature workflows and parameter propagation

## 🛡️ Security Testing

### **Attack Simulation**
The test suite includes simulation of various attack vectors:

- **Flash Loan Attacks**: Oracle manipulation detection
- **MEV Attacks**: Front-running and sandwich attack protection
- **Governance Attacks**: Parameter manipulation attempts
- **Circuit Breaker Stress**: High volume threshold testing

### **Risk Management Testing**
- User risk scoring and flagging
- Suspicious activity detection
- Behavior analytics validation
- Emergency response coordination

### **Oracle Security**
- Price manipulation detection
- Liquidity monitoring
- TWAP calculation validation
- Fallback price mechanisms

## 📊 Test Data & Helpers

### **Test Constants**
```javascript
const TEST_CONSTANTS = {
  SMALL_DEPOSIT: ethers.parseUnits("100", 6),      // 100 USDT
  MEDIUM_DEPOSIT: ethers.parseUnits("1000", 6),    // 1,000 USDT
  LARGE_DEPOSIT: ethers.parseUnits("10000", 6),    // 10,000 USDT
  
  MEV_MAX_PER_BLOCK: ethers.parseUnits("50000", 6), // 50k USDT
  CIRCUIT_BREAKER_THRESHOLD: ethers.parseUnits("100000", 6), // 100k USDT
  HIGH_RISK_THRESHOLD: 8000,                        // 80%
};
```

### **Test Helpers**
```javascript
// Time manipulation
await TEST_HELPERS.fastForwardTime(3600); // 1 hour

// User behavior simulation
const deposits = await TEST_HELPERS.simulateUserBehavior(contracts, user, 5);

// Oracle updates simulation  
const updates = await TEST_HELPERS.simulateOraclePriceUpdates(oracle, priceChanges, updater);

// System state validation
const state = await TEST_HELPERS.validateSystemState(contracts);
```

### **Mock Deployments**
```javascript
// Deploy complete system
const { contracts, tokens, signers } = await deployFullSystem();

// Deploy minimal system for unit tests
const { tokens, libraries, signers } = await deployMinimalSystem();

// Deploy specific components
const { contracts, signers } = await deployCoreSystem();
```

## 🎯 Test Scenarios

### **User Journey Testing**
```javascript
it("Should handle complete user deposit flow", async function () {
  // 1. Check initial eligibility
  // 2. Perform advanced security checks
  // 3. Update user behavior tracking  
  // 4. Verify state changes
});
```

### **Emergency Response Testing**
```javascript
it("Should coordinate emergency mode across all contracts", async function () {
  // 1. Trigger emergency on multiple contracts
  // 2. Verify coordinated response
  // 3. Test recovery procedures
  // 4. Validate system integrity
});
```

### **Governance Testing**
```javascript
it("Should handle complex governance workflow", async function () {
  // 1. Multiple parameter proposals
  // 2. Multi-signature collection
  // 3. Automatic execution
  // 4. Parameter propagation
});
```

## 📈 Coverage & Reporting

### **Coverage Targets**
- **Overall Coverage**: >90%
- **Critical Functions**: 100%
- **Security Features**: 100%
- **Emergency Procedures**: 100%

### **Automated Reporting**
The test runner generates comprehensive reports including:

- Test execution summary
- Coverage analysis
- Gas usage optimization
- Security validation results
- Performance metrics
- Recommendations for improvement

### **HTML Reports**
Rich HTML reports are generated with:
- Visual test result dashboards
- Coverage heatmaps
- Gas optimization recommendations
- Security audit trails

## 🔧 Configuration

### **Hardhat Configuration**
```javascript
// hardhat.config.js
module.exports = {
  solidity: {
    version: "0.8.30",
    settings: {
      optimizer: { enabled: true, runs: 200 },
      viaIR: true
    }
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency: "USD"
  }
};
```

### **Test Environment**
- **Solidity Version**: 0.8.30
- **Hardhat Network**: Local development chain
- **Gas Optimization**: Enabled with 200 runs
- **Library Linking**: Support for external libraries

## 🚨 Continuous Integration

### **GitHub Actions Integration**
```yaml
# .github/workflows/test.yml
- name: Run Tests
  run: |
    npm install
    npm run compile
    npm test
    npm run coverage
```

### **Pre-commit Hooks**
```bash
# Run tests before commit
npm run test:unit
npm run test:integration
```

## 🎨 Best Practices

### **Test Writing Guidelines**
1. **Descriptive Names**: Use clear, descriptive test names
2. **Single Responsibility**: Each test should verify one specific behavior
3. **Setup/Teardown**: Use proper fixtures and cleanup
4. **Error Testing**: Test both success and failure scenarios
5. **Gas Optimization**: Monitor and optimize gas usage

### **Security Testing**
1. **Attack Vectors**: Test all known attack patterns
2. **Edge Cases**: Validate boundary conditions
3. **State Consistency**: Verify system state integrity
4. **Access Control**: Validate role-based permissions
5. **Emergency Procedures**: Test all emergency scenarios

### **Performance Testing**
1. **Gas Limits**: Ensure operations stay within gas limits
2. **Batch Operations**: Optimize for batch processing
3. **Concurrent Access**: Test concurrent user operations
4. **Stress Testing**: Validate under high load conditions

## 📚 Additional Resources

- [Hardhat Testing Guide](https://hardhat.org/tutorial/testing-contracts.html)
- [OpenZeppelin Test Helpers](https://docs.openzeppelin.com/test-helpers/)
- [Solidity Testing Best Practices](https://consensys.github.io/smart-contract-best-practices/)
- [DeFi Security Testing](https://github.com/crytic/building-secure-contracts)

## 🤝 Contributing

When adding new tests:

1. Follow the existing test structure and naming conventions
2. Add comprehensive documentation for complex test scenarios
3. Include both positive and negative test cases
4. Update test data and helpers as needed
5. Ensure adequate test coverage for new features

## 📞 Support

For questions about the testing framework:
- Review existing test examples in the codebase
- Check the test data helpers for utility functions
- Refer to the deployment fixtures for setup patterns
- Consult the integration tests for cross-contract scenarios

---

🛡️ **Security First**: This testing framework prioritizes security validation to ensure the DeFi protocol is robust, reliable, and ready for production deployment.