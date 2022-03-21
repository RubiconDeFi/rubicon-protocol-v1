require('dotenv').config();

module.exports = {
  networks: {
    development: {
      host: "127.0.0.1",
      port: 8545,
      network_id: "*", // Match any network id
      gas: 0xfffffffff,  
    },
  },
  compilers: {
  solc: {
    version: "0.7.6",
    settings: {
    optimizer: {
        enabled: true,
        runs: 200
    }}
  }}
};
