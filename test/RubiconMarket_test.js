const RubiconMarket = artifacts.require("RubiconMarket");
const DAI = artifacts.require("TokenWithFaucet");
const WETH = artifacts.require("WETH9");

//Helper function
function logIndented(...args) {
  console.log("       ", ...args);
}

// Goal here will be to focus tests on any added functionality as the core logic is somewhat lindy...
// This one will require a lot of iterative work

contract("Rubicon Market", (accounts) => {
  let rubiconMarketInstance;
  let bathHouseInstance;
  let bathPairInstance;
  let bathAssetInstance;
  let bathQuoteInstance;
  let DAIInstance;
  let WETHInstance;

  describe("Deployment & Startup", async function () {
    it("Is deployed successfully", async () => {
      rubiconMarketInstance = await RubiconMarket.deployed();
      DAIInstance = await DAI.deployed();
      WETHInstance = await WETH.deployed();
    });
  });
});
