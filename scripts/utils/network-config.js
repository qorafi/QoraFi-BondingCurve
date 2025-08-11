/ scripts/utils/network-config.js
const networkConfigs = {
  localhost: {
    chainId: 31337,
    name: "Localhost",
    rpc: "http://127.0.0.1:8545",
    blockExplorer: "",
    nativeCurrency: {
      symbol: "ETH",
      decimals: 18
    },
    contracts: {
      usdt: "0x0000000000000000000000000000000000000001", // Mock address
      weth: "0x0000000000000000000000000000000000000002",
      router: "0x0000000000000000000000000000000000000003"
    }
  },
  bscTestnet: {
    chainId: 97,
    name: "BSC Testnet",
    rpc: "https://data-seed-prebsc-1-s1.binance.org:8545/",
    blockExplorer: "https://testnet.bscscan.com",
    nativeCurrency: {
      symbol: "tBNB",
      decimals: 18
    },
    contracts: {
      usdt: "0x7ef95a0FEE0Dd31b22626fA2e10Ee6A223F8a684", // USDT testnet
      weth: "0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd", // WBNB testnet
      router: "0xD99D1c33F9fC3444f8101754aBC46c52416550D1" // PancakeSwap testnet
    }
  },
  bscMainnet: {
    chainId: 56,
    name: "BSC Mainnet",
    rpc: "https://bsc-dataseed1.binance.org/",
    blockExplorer: "https://bscscan.com",
    nativeCurrency: {
      symbol: "BNB",
      decimals: 18
    },
    contracts: {
      usdt: "0x55d398326f99059fF775485246999027B3197955", // USDT mainnet
      weth: "0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", // WBNB mainnet
      router: "0x10ED43C718714eb63d5aA57B78B54704E256024E" // PancakeSwap mainnet
    }
  },
  sepolia: {
    chainId: 11155111,
    name: "Sepolia Testnet",
    rpc: `https://eth-sepolia.g.alchemy.com/v2/${process.env.ALCHEMY_API_KEY}`,
    blockExplorer: "https://sepolia.etherscan.io",
    nativeCurrency: {
      symbol: "ETH",
      decimals: 18
    },
    contracts: {
      usdt: "0x7169D38820dfd117C3FA1f22a697dBA58d90BA06", // Mock USDT on Sepolia
      weth: "0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14", // WETH on Sepolia
      router: "0x1b02dA8Cb0d097eB8D57A175b88c7D8b47997506" // Sushiswap router
    }
  }
};

function getNetworkConfig(networkName) {
  const config = networkConfigs[networkName];
  if (!config) {
    throw new Error(`Network configuration not found for: ${networkName}`);
  }
  return config;
}

function isTestnet(networkName) {
  return ["localhost", "bscTestnet", "sepolia"].includes(networkName);
}

function getBlockExplorerUrl(networkName, address, type = "address") {
  const config = getNetworkConfig(networkName);
  if (!config.blockExplorer) return "";
  return `${config.blockExplorer}/${type}/${address}`;
}

module.exports = {
  networkConfigs,
  getNetworkConfig,
  isTestnet,
  getBlockExplorerUrl
};