require("@nomicfoundation/hardhat-toolbox");

const compilerSettings = {
  optimizer: { enabled: true, runs: 200 },
  evmVersion: "cancun",
  viaIR: true,
};

module.exports = {
  solidity: {
    compilers: [
      { version: "0.8.20", settings: { ...compilerSettings } },
      { version: "0.8.24", settings: { ...compilerSettings } },
      { version: "0.8.27", settings: { ...compilerSettings } },
    ],
  },
  networks: {
    hardhat: {},
    sepolia: {
      url: process.env.SEPOLIA_RPC_URL || "",
      accounts: process.env.DEPLOYER_KEY ? [process.env.DEPLOYER_KEY] : [],
    },
    base: {
      url: process.env.BASE_RPC_URL || "https://mainnet.base.org",
      accounts: process.env.DEPLOYER_KEY ? [process.env.DEPLOYER_KEY] : [],
    },
  },
};
