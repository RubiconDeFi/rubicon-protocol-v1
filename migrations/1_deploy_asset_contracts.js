var WETH = artifacts.require("./contracts/WETH9.sol");
var DAI = artifacts.require("./contracts/peripheral_contracts/TokenWithFaucet.sol");

module.exports = function(deployer, network, accounts) {
  var admin = accounts[0];

  // Deploy test WETH and DAI for using in tests
  deployer.deploy(WETH);
  deployer.deploy(DAI, admin, "DAI Stablecoin", "DAI", 18);
};
