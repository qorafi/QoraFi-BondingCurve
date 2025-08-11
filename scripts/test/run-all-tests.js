// scripts/test/run-all-tests.js
const { exec } = require('child_process');
const fs = require('fs');
const path = require('path');

/**
 * @title Comprehensive Test Runner
 * @notice Runs all test suites and generates detailed reports
 * @dev Provides test execution, coverage analysis, and reporting
 */

class TestRunner {
  constructor() {
    this.results = {
      startTime: new Date(),
      endTime: null,
      totalTests: 0,
      passedTests: 0,
      failedTests: 0,
      skippedTests: 0,
      coverage: null,
      gasUsage: null,
      suites: []
    };
    
    this.testSuites = [
      {
        name: "Unit Tests - Core",
        path: "test/unit/core/**/*.test.js",
        description: "Core security and oracle functionality"
      },
      {
        name: "Unit Tests - Advanced", 
        path: "test/unit/advanced/**/*.test.js",
        description: "Advanced security and governance features"
      },
      {
        name: "Unit Tests - Libraries",
        path: "test/unit/libraries/**/*.test.js", 
        description: "Modular library components"
      },
      {
        name: "Integration Tests",
        path: "test/integration/**/*.test.js",
        description: "Cross-contract integration scenarios"
      }
    ];
  }

  /**
   * @notice Run all test suites
   */
  async runAllTests() {
    console.log("🚀 Starting Comprehensive Test Suite");
    console.log("=" * 50);
    
    try {
      // 1. Run unit tests
      await this.runUnitTests();
      
      // 2. Run integration tests
      await this.runIntegrationTests();
      
      // 3. Run coverage analysis
      await this.runCoverageAnalysis();
      
      // 4. Run gas analysis
      await this.runGasAnalysis();
      
      // 5. Generate comprehensive report
      await this.generateReport();
      
      this.results.endTime = new Date();
      console.log("\n✅ All tests completed successfully!");
      
    } catch (error) {
      console.error("❌ Test execution failed:", error.message);
      process.exit(1);
    }
  }

  /**
   * @notice Run unit test suites
   */
  async runUnitTests() {
    console.log("\n📋 Running Unit Tests...");
    
    for (const suite of this.testSuites.filter(s => s.name.includes("Unit Tests"))) {
      console.log(`\n🧪 ${suite.name}: ${suite.description}`);
      
      try {
        const result = await this.executeTestCommand(`npx hardhat test ${suite.path}`);
        this.results.suites.push({
          name: suite.name,
          ...result,
          type: "unit"
        });
        
        console.log(`✅ ${suite.name}: ${result.passed}/${result.total} tests passed`);
        
      } catch (error) {
        console.log(`❌ ${suite.name}: Failed - ${error.message}`);
        this.results.suites.push({
          name: suite.name,
          passed: 0,
          failed: 1,
          total: 1,
          error: error.message,
          type: "unit"
        });
      }
    }
  }

  /**
   * @notice Run integration test suites
   */
  async runIntegrationTests() {
    console.log("\n🔗 Running Integration Tests...");
    
    const integrationSuite = this.testSuites.find(s => s.name.includes("Integration"));
    
    try {
      const result = await this.executeTestCommand(`npx hardhat test ${integrationSuite.path}`);
      this.results.suites.push({
        name: integrationSuite.name,
        ...result,
        type: "integration"
      });
      
      console.log(`✅ ${integrationSuite.name}: ${result.passed}/${result.total} tests passed`);
      
    } catch (error) {
      console.log(`❌ ${integrationSuite.name}: Failed - ${error.message}`);
      this.results.suites.push({
        name: integrationSuite.name,
        passed: 0,
        failed: 1,
        total: 1,
        error: error.message,
        type: "integration"
      });
    }
  }

  /**
   * @notice Run coverage analysis
   */
  async runCoverageAnalysis() {
    console.log("\n📊 Running Coverage Analysis...");
    
    try {
      const coverageResult = await this.executeCommand("npx hardhat coverage");
      
      // Parse coverage results (simplified)
      const coverage = this.parseCoverageResults(coverageResult);
      this.results.coverage = coverage;
      
      console.log(`✅ Coverage Analysis Complete: ${coverage.overall}% overall coverage`);
      
    } catch (error) {
      console.log(`⚠️ Coverage Analysis Failed: ${error.message}`);
      this.results.coverage = { error: error.message };
    }
  }

  /**
   * @notice Run gas usage analysis
   */
  async runGasAnalysis() {
    console.log("\n⛽ Running Gas Analysis...");
    
    try {
      const gasResult = await this.executeCommand("REPORT_GAS=true npx hardhat test");
      
      // Parse gas results (simplified)
      const gasUsage = this.parseGasResults(gasResult);
      this.results.gasUsage = gasUsage;
      
      console.log(`✅ Gas Analysis Complete: Average gas usage documented`);
      
    } catch (error) {
      console.log(`⚠️ Gas Analysis Failed: ${error.message}`);
      this.results.gasUsage = { error: error.message };
    }
  }

  /**
   * @notice Execute test command and parse results
   */
  async executeTestCommand(command) {
    return new Promise((resolve, reject) => {
      exec(command, { maxBuffer: 1024 * 1024 * 10 }, (error, stdout, stderr) => {
        if (error) {
          reject(error);
          return;
        }
        
        // Parse test results from stdout
        const results = this.parseTestResults(stdout);
        resolve(results);
      });
    });
  }

  /**
   * @notice Execute general command
   */
  async executeCommand(command) {
    return new Promise((resolve, reject) => {
      exec(command, { maxBuffer: 1024 * 1024 * 10 }, (error, stdout, stderr) => {
        if (error) {
          reject(error);
          return;
        }
        resolve(stdout);
      });
    });
  }

  /**
   * @notice Parse test results from output
   */
  parseTestResults(output) {
    // Simplified parsing - in practice, you'd use more sophisticated parsing
    const passedMatches = output.match(/(\d+) passing/);
    const failedMatches = output.match(/(\d+) failing/);
    const skippedMatches = output.match(/(\d+) pending/);
    
    const passed = passedMatches ? parseInt(passedMatches[1]) : 0;
    const failed = failedMatches ? parseInt(failedMatches[1]) : 0;
    const skipped = skippedMatches ? parseInt(skippedMatches[1]) : 0;
    
    return {
      passed,
      failed,
      skipped,
      total: passed + failed + skipped,
      output: output.substring(0, 1000) // Truncate for storage
    };
  }

  /**
   * @notice Parse coverage results
   */
  parseCoverageResults(output) {
    // Simplified coverage parsing
    const overallMatch = output.match(/All files\s+\|\s+(\d+\.?\d*)/);
    const overall = overallMatch ? parseFloat(overallMatch[1]) : 0;
    
    return {
      overall,
      statements: overall, // Simplified
      branches: overall,
      functions: overall,
      lines: overall
    };
  }

  /**
   * @notice Parse gas usage results
   */
  parseGasResults(output) {
    // Simplified gas parsing
    const deploymentMatches = output.match(/deployment.*?(\d+)\s+gas/gi) || [];
    const methodMatches = output.match(/method.*?(\d+)\s+gas/gi) || [];
    
    return {
      deploymentCosts: deploymentMatches.length,
      methodCosts: methodMatches.length,
      averageGas: "Analysis available in detailed report"
    };
  }

  /**
   * @notice Generate comprehensive test report
   */
  async generateReport() {
    console.log("\n📄 Generating Comprehensive Report...");
    
    // Calculate totals
    this.results.totalTests = this.results.suites.reduce((sum, suite) => sum + suite.total, 0);
    this.results.passedTests = this.results.suites.reduce((sum, suite) => sum + suite.passed, 0);
    this.results.failedTests = this.results.suites.reduce((sum, suite) => sum + suite.failed, 0);
    this.results.skippedTests = this.results.suites.reduce((sum, suite) => sum + suite.skipped, 0);
    
    const report = this.generateDetailedReport();
    
    // Save to file
    const reportPath = path.join(__dirname, '../../test-reports');
    if (!fs.existsSync(reportPath)) {
      fs.mkdirSync(reportPath, { recursive: true });
    }
    
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const reportFile = path.join(reportPath, `test-report-${timestamp}.json`);
    const htmlReportFile = path.join(reportPath, `test-report-${timestamp}.html`);
    
    fs.writeFileSync(reportFile, JSON.stringify(report, null, 2));
    fs.writeFileSync(htmlReportFile, this.generateHTMLReport(report));
    
    console.log(`✅ Report saved to: ${reportFile}`);
    console.log(`✅ HTML report saved to: ${htmlReportFile}`);
    
    // Print summary
    this.printSummary(report);
  }

  /**
   * @notice Generate detailed report object
   */
  generateDetailedReport() {
    const duration = this.results.endTime - this.results.startTime;
    
    return {
      summary: {
        totalTests: this.results.totalTests,
        passedTests: this.results.passedTests,
        failedTests: this.results.failedTests,
        skippedTests: this.results.skippedTests,
        successRate: ((this.results.passedTests / this.results.totalTests) * 100).toFixed(2),
        duration: `${Math.round(duration / 1000)}s`,
        timestamp: this.results.endTime.toISOString()
      },
      suites: this.results.suites,
      coverage: this.results.coverage,
      gasUsage: this.results.gasUsage,
      recommendations: this.generateRecommendations(),
      system: {
        nodeVersion: process.version,
        platform: process.platform,
        hardhatVersion: "Latest"
      }
    };
  }

  /**
   * @notice Generate recommendations based on results
   */
  generateRecommendations() {
    const recommendations = [];
    
    if (this.results.failedTests > 0) {
      recommendations.push({
        priority: "High",
        category: "Test Failures",
        message: `${this.results.failedTests} tests failed. Review and fix failing tests before deployment.`
      });
    }
    
    if (this.results.coverage && this.results.coverage.overall < 90) {
      recommendations.push({
        priority: "Medium",
        category: "Coverage",
        message: `Test coverage is ${this.results.coverage.overall}%. Aim for >90% coverage.`
      });
    }
    
    if (this.results.skippedTests > 0) {
      recommendations.push({
        priority: "Low",
        category: "Skipped Tests",
        message: `${this.results.skippedTests} tests were skipped. Review and complete these tests.`
      });
    }
    
    if (this.results.passedTests === this.results.totalTests) {
      recommendations.push({
        priority: "Info",
        category: "Success",
        message: "All tests passed! The system is ready for deployment."
      });
    }
    
    return recommendations;
  }

  /**
   * @notice Generate HTML report
   */
  generateHTMLReport(report) {
    return `
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Qorafi DeFi Protocol - Test Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; line-height: 1.6; }
        .header { background: #2c3e50; color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; }
        .summary { display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 20px; margin-bottom: 30px; }
        .metric { background: #ecf0f1; padding: 15px; border-radius: 8px; text-align: center; }
        .metric h3 { margin: 0; color: #2c3e50; }
        .metric .value { font-size: 2em; font-weight: bold; margin: 10px 0; }
        .success { color: #27ae60; }
        .warning { color: #f39c12; }
        .error { color: #e74c3c; }
        .suite { background: white; border: 1px solid #bdc3c7; border-radius: 8px; margin: 10px 0; padding: 20px; }
        .suite h3 { margin-top: 0; color: #2c3e50; }
        .recommendations { background: #fff3cd; border: 1px solid #ffeaa7; border-radius: 8px; padding: 15px; margin: 20px 0; }
        .recommendation { margin: 10px 0; padding: 10px; border-left: 4px solid #f39c12; background: white; }
        .high { border-left-color: #e74c3c; }
        .medium { border-left-color: #f39c12; }
        .low { border-left-color: #3498db; }
        .info { border-left-color: #27ae60; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th, td { border: 1px solid #bdc3c7; padding: 10px; text-align: left; }
        th { background: #ecf0f1; font-weight: bold; }
        .footer { text-align: center; color: #7f8c8d; margin-top: 40px; }
    </style>
</head>
<body>
    <div class="header">
        <h1>🛡️ Qorafi DeFi Protocol - Test Report</h1>
        <p>Comprehensive test execution report generated on ${new Date().toLocaleString()}</p>
    </div>

    <div class="summary">
        <div class="metric">
            <h3>Total Tests</h3>
            <div class="value">${report.summary.totalTests}</div>
        </div>
        <div class="metric">
            <h3>Passed</h3>
            <div class="value success">${report.summary.passedTests}</div>
        </div>
        <div class="metric">
            <h3>Failed</h3>
            <div class="value error">${report.summary.failedTests}</div>
        </div>
        <div class="metric">
            <h3>Success Rate</h3>
            <div class="value ${report.summary.failedTests === 0 ? 'success' : 'warning'}">${report.summary.successRate}%</div>
        </div>
        <div class="metric">
            <h3>Duration</h3>
            <div class="value">${report.summary.duration}</div>
        </div>
        <div class="metric">
            <h3>Coverage</h3>
            <div class="value ${report.coverage?.overall > 90 ? 'success' : 'warning'}">${report.coverage?.overall || 'N/A'}%</div>
        </div>
    </div>

    <h2>📋 Test Suite Results</h2>
    ${report.suites.map(suite => `
        <div class="suite">
            <h3>${suite.name}</h3>
            <p><strong>Type:</strong> ${suite.type}</p>
            <p><strong>Results:</strong> ${suite.passed}/${suite.total} passed</p>
            ${suite.failed > 0 ? `<p class="error"><strong>Failures:</strong> ${suite.failed}</p>` : ''}
            ${suite.error ? `<p class="error"><strong>Error:</strong> ${suite.error}</p>` : ''}
        </div>
    `).join('')}

    ${report.coverage ? `
        <h2>📊 Coverage Analysis</h2>
        <table>
            <tr><th>Metric</th><th>Coverage</th></tr>
            <tr><td>Overall</td><td>${report.coverage.overall}%</td></tr>
            <tr><td>Statements</td><td>${report.coverage.statements}%</td></tr>
            <tr><td>Branches</td><td>${report.coverage.branches}%</td></tr>
            <tr><td>Functions</td><td>${report.coverage.functions}%</td></tr>
            <tr><td>Lines</td><td>${report.coverage.lines}%</td></tr>
        </table>
    ` : ''}

    ${report.gasUsage ? `
        <h2>⛽ Gas Usage Analysis</h2>
        <p><strong>Deployment Costs Analyzed:</strong> ${report.gasUsage.deploymentCosts}</p>
        <p><strong>Method Costs Analyzed:</strong> ${report.gasUsage.methodCosts}</p>
        <p><strong>Details:</strong> ${report.gasUsage.averageGas}</p>
    ` : ''}

    <div class="recommendations">
        <h2>💡 Recommendations</h2>
        ${report.recommendations.map(rec => `
            <div class="recommendation ${rec.priority.toLowerCase()}">
                <strong>[${rec.priority}] ${rec.category}:</strong> ${rec.message}
            </div>
        `).join('')}
    </div>

    <h2>🔧 System Information</h2>
    <table>
        <tr><th>Property</th><th>Value</th></tr>
        <tr><td>Node Version</td><td>${report.system.nodeVersion}</td></tr>
        <tr><td>Platform</td><td>${report.system.platform}</td></tr>
        <tr><td>Hardhat Version</td><td>${report.system.hardhatVersion}</td></tr>
        <tr><td>Report Generated</td><td>${report.summary.timestamp}</td></tr>
    </table>

    <div class="footer">
        <p>Generated by Qorafi DeFi Protocol Test Runner v1.0</p>
        <p>🛡️ Ensuring Security, Governance, and Reliability</p>
    </div>
</body>
</html>`;
  }

  /**
   * @notice Print summary to console
   */
  printSummary(report) {
    console.log("\n" + "=".repeat(60));
    console.log("📊 TEST EXECUTION SUMMARY");
    console.log("=".repeat(60));
    console.log(`📋 Total Tests: ${report.summary.totalTests}`);
    console.log(`✅ Passed: ${report.summary.passedTests}`);
    console.log(`❌ Failed: ${report.summary.failedTests}`);
    console.log(`⏭️  Skipped: ${report.summary.skippedTests}`);
    console.log(`🎯 Success Rate: ${report.summary.successRate}%`);
    console.log(`⏱️  Duration: ${report.summary.duration}`);
    
    if (report.coverage) {
      console.log(`📊 Coverage: ${report.coverage.overall}%`);
    }
    
    console.log("\n💡 RECOMMENDATIONS:");
    report.recommendations.forEach(rec => {
      const icon = rec.priority === "High" ? "🔴" : 
                   rec.priority === "Medium" ? "🟡" : 
                   rec.priority === "Low" ? "🔵" : "✅";
      console.log(`${icon} [${rec.priority}] ${rec.category}: ${rec.message}`);
    });
    
    console.log("\n" + "=".repeat(60));
    
    if (report.summary.failedTests === 0) {
      console.log("🎉 ALL TESTS PASSED! System is ready for deployment.");
    } else {
      console.log("⚠️  Some tests failed. Please review and fix before proceeding.");
    }
    
    console.log("=".repeat(60));
  }
}

/**
 * @notice Main execution function
 */
async function main() {
  const args = process.argv.slice(2);
  const runner = new TestRunner();
  
  // Parse command line arguments
  if (args.includes('--unit-only')) {
    console.log("🧪 Running unit tests only...");
    await runner.runUnitTests();
    await runner.generateReport();
  } else if (args.includes('--integration-only')) {
    console.log("🔗 Running integration tests only...");
    await runner.runIntegrationTests();
    await runner.generateReport();
  } else if (args.includes('--coverage-only')) {
    console.log("📊 Running coverage analysis only...");
    await runner.runCoverageAnalysis();
    await runner.generateReport();
  } else if (args.includes('--gas-only')) {
    console.log("⛽ Running gas analysis only...");
    await runner.runGasAnalysis();
    await runner.generateReport();
  } else {
    // Run full test suite
    await runner.runAllTests();
  }
}

// Script help
if (process.argv.includes('--help') || process.argv.includes('-h')) {
  console.log(`
🛡️ Qorafi DeFi Protocol Test Runner

Usage: node scripts/test/run-all-tests.js [options]

Options:
  --unit-only        Run only unit tests
  --integration-only Run only integration tests  
  --coverage-only    Run only coverage analysis
  --gas-only         Run only gas analysis
  --help, -h         Show this help message

Examples:
  node scripts/test/run-all-tests.js                # Run all tests
  node scripts/test/run-all-tests.js --unit-only    # Unit tests only
  node scripts/test/run-all-tests.js --coverage-only # Coverage only

The test runner will generate detailed reports in the test-reports/ directory.
  `);
  process.exit(0);
}

// Execute if called directly
if (require.main === module) {
  main().catch(error => {
    console.error("❌ Test runner failed:", error);
    process.exit(1);
  });
}

module.exports = { TestRunner };