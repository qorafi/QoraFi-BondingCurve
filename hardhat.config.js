require("@nomicfoundation/hardhat-toolbox");
require("hardhat-deploy");
require("hardhat-gas-reporter");
require("solidity-coverage");
require("dotenv").config();

const PRIVATE_KEY = process.env.PRIVATE_KEY || "0x0000000000000000000000000000000000000000000000000000000000000000";
const BSC_API_KEY = process.env.BSC_API_KEY || "";
const ETHEREUM_API_KEY = process.env.ETHEREUM_API_KEY || "";

module.exports = {
  solidity: {
    version: "0.8.30",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      viaIR: true, // Enable IR compilation for better optimization
    },
  },
  networks: {
    hardhat: {
      chainId: 31337,
      gas: 12000000,
      blockGasLimit: 12000000,
      allowUnlimitedContractSize: true,
    },
    localhost: {
      url: "http://127.0.0.1:8545",
      chainId: 31337,
    },
    bscTestnet: {
      url: "https://data-seed-prebsc-1-s1.binance.org:8545/",
      chainId: 97,
      accounts: [PRIVATE_KEY],
      gas: 6000000,
      gasPrice: 10000000000, // 10 gwei
    },
    bscMainnet: {
      url: "https://bsc-dataseed1.binance.org/",
      chainId: 56,
      accounts: [PRIVATE_KEY],
      gas: 6000000,
      gasPrice: 5000000000, // 5 gwei
    },
    sepolia: {
      url: `https://eth-sepolia.g.alchemy.com/v2/${process.env.ALCHEMY_API_KEY}`,
      chainId: 11155111,
      accounts: [PRIVATE_KEY],
    },
  },
  etherscan: {
    apiKey: {
      bsc: BSC_API_KEY,
      bscTestnet: BSC_API_KEY,
      sepolia: ETHEREUM_API_KEY,
    },
  },
  gasReporter: {
    enabled: process.env.REPORT_GAS !== undefined,
    currency: "USD",
    gasPrice: 5, // gwei
    coinmarketcap: process.env.COINMARKETCAP_API_KEY,
  },
  namedAccounts: {
    deployer: {
      default: 0,
    },
    governance: {
      default: 1,
    },
    treasury: {
      default: 2,
    },
  },
  paths: {
    sources: "./contracts",
    tests: "./test",
    cache: "./cache",
    artifacts: "./artifacts",
    deploy: "./scripts/deploy",
  },
};