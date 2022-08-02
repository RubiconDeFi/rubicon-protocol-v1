const BathHouse = artifacts.require("BathHouse");
const BathPair = artifacts.require("BathPair");
const BathToken = artifacts.require("BathToken");
const RubiconMarket = artifacts.require("RubiconMarket");
const DAI = artifacts.require("TokenWithFaucet");
const WETH = artifacts.require("WETH9");
const TokenWithFaucet = artifacts.require("TokenWithFaucet");

//Helper function
function logIndented(...args) {
  console.log("       ", ...args);
}

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

//Special attention to:
// - Lossless outstanding amount in bathTokens - closed loop!
// - Permissions and potential exploits

//Edge Case:
// - oustanding amount minor change - is this relevant? How does it affect mint ratio?

contract("Bath Token", (accounts) => {
  let rubiconMarketInstance;
  let bathHouseInstance;
  let bathPairInstance;
  let bathAssetInstance;
  let bathQuoteInstance;
  let DAIInstance;
  let WETHInstance;
  let bathTokenImplementation;

  describe("Deployment & Startup", async function () {
    it("Is deployed successfully", async () => {
      rubiconMarketInstance = await RubiconMarket.deployed();
      bathHouseInstance = await BathHouse.deployed();
      bathPairInstance = await BathPair.deployed();
      DAIInstance = await DAI.deployed();
      WETHInstance = await WETH.deployed();
      bathTokenImplementation = await BathToken.new();

    });
    it("Is successfully initialized", async () => {
      await bathHouseInstance.initialize(
        rubiconMarketInstance.address,
        80,
        10,
        bathTokenImplementation.address,
        accounts[9] // Proxy admin
        // 20
      );
      assert.equal(await bathHouseInstance.initialized(), true);
    });
    it("Is wired to the BathPair contract", async () => {
      await bathHouseInstance.initBathPair(bathPairInstance.address, 500, -5); // 90% reserve ratio and 3 days cancel delay
      let pair = await bathHouseInstance.approvedPairContract();
      logIndented("getting this pair", pair);
      bathPairInstance = await BathPair.at(pair);
    });
    it("BathTokens can be spun up for testing via createBathToken", async () => {
      // Deploy an arbitrary ERC-20 with a custom name and decimals
      const newCoinSymbol = "TEST";
      let newCoin = await TokenWithFaucet.new(
        accounts[0],
        "Test Coin",
        newCoinSymbol,
        8
      );
      // logIndented("Getting this new coin", newCoin.address);
      let expectZero = await bathHouseInstance.tokenToBathToken(
        newCoin.address
      );
      assert.equal(expectZero, ZERO_ADDRESS);
      // Deploy a bathToken for that ERC-20
      await bathHouseInstance.createBathToken(newCoin.address, accounts[0]);
      let newBathToken = await bathHouseInstance.tokenToBathToken(
        newCoin.address
      );
      // logIndented("Getting this new bathToken", newBathToken);
      let bathToken = await BathToken.at(newBathToken);
      let bathTokenName = await bathToken.name();
      let bathTokenSymbol = await bathToken.symbol();
      const expectedBathTokenName = "bath" + newCoinSymbol;
      assert.equal(bathTokenSymbol, expectedBathTokenName);
      assert.equal(bathTokenName, expectedBathTokenName + " v1");

      // logIndented("name", bathTokenName);
      // logIndented("symbol", bathTokenSymbol);
    });
    it("BathTokens are successfully initialized whenever they are created", async () => {});
  });
});
