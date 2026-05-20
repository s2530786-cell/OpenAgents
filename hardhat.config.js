require("@nomicfoundation/hardhat-toolbox");

const lotteryOnly = process.env.HARDHAT_LOTTERY_ONLY === "1";

module.exports = {
  paths: lotteryOnly
    ? {
        sources: "./contracts/lottery",
        tests: "./test",
        cache: "./cache-lottery",
        artifacts: "./artifacts-lottery",
      }
    : undefined,
  solidity: {
    compilers: [
      {
        version: "0.8.20",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
      {
        version: "0.8.24",
        settings: { optimizer: { enabled: true, runs: 200 } },
      },
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
