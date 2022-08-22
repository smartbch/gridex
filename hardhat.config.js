require("@nomiclabs/hardhat-waffle");

module.exports = {
  solidity: {
    version: "0.8.15",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
    },
  },
  networks: {},
  mocha: {
    timeout: 4000000
  }
};