const BathHouse = artifacts.require("BathHouse");
const BathPair = artifacts.require("BathPair");
const BathToken = artifacts.require("BathToken");
const RubiconMarket = artifacts.require("RubiconMarket");
const DAI = artifacts.require("TokenWithFaucet");
const WETH = artifacts.require("WETH9");
const TokenWithFaucet = artifacts.require("TokenWithFaucet");
const BigNumber = require("bignumber.js");
const ERC20 = artifacts.require("ERC20");

//Helper function
function logIndented(...args) {
  console.log("       ", ...args);
}

//Special attention to:
// - Making sure that MaxOrderSize and ABDK math library are working as expected
// - Permissionless market-making flows
// - Lossless outstanding amount in bathTokens - closed loop!
// - ** Attempt to plot shape curve

contract("Bath Pair", (accounts) => {
  let rubiconMarketInstance;
  let bathHouseInstance;
  let bathPairInstance;
  let bathAssetInstance;
  let bathQuoteInstance;
  let DAIInstance;
  let WETHInstance;
  let bathTokenImplementation;
  let asset1; //Arbitrary ERC20s for testing
  let asset2; //Arbitrary ERC20s for testing

  describe("Deployment & Startup", async function () {
    it("Is deployed successfully", async () => {
      rubiconMarketInstance = await RubiconMarket.deployed();
      bathHouseInstance = await BathHouse.deployed();
      bathPairInstance = await BathPair.deployed();
      DAIInstance = await DAI.deployed();
      WETHInstance = await WETH.deployed();
      bathTokenImplementation = await BathToken.new();
    });
    it("BathHouse successfully initialized", async () => {
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
    it("Two bathTokens are spawned and liquid for testing out BathPair", async () => {
      await bathHouseInstance.createBathToken(
        await WETHInstance.address,
        accounts[0]
      );
      await bathHouseInstance.createBathToken(
        await DAIInstance.address,
        accounts[0]
      );
      // Admin deposits WETH and DAI into the pools
      await WETHInstance.deposit({
        from: accounts[0],
        value: web3.utils.toWei("100"),
      });
      // Central Query on BathHouse to get any *unique* bathToken's address
      let bathWETHAddress = await bathHouseInstance.tokenToBathToken(
        await WETHInstance.address,
        { from: accounts[0] }
      );
      let bathDaiAddress = await bathHouseInstance.tokenToBathToken(
        await DAIInstance.address,
        { from: accounts[0] }
      );
      let bathWETH = await BathToken.at(await bathWETHAddress);
      let bathDAI = await BathToken.at(await bathDaiAddress);
      // logIndented(await (await DAIInstance.balanceOf(accounts[0])).toString())
      await WETHInstance.approve(bathWETHAddress, web3.utils.toWei("100"), {
        from: accounts[0],
      });
      await DAIInstance.approve(bathDaiAddress, web3.utils.toWei("1000"), {
        from: accounts[0],
      });
      await bathDAI.deposit(web3.utils.toWei("1000"));
      await bathWETH.deposit(web3.utils.toWei("100"));
    });
  });
  describe("Unit Tests", async function () {
    // 1. Place market making trades
    it("function placeMarketMakingTrades - a strategist can market-make for any ERC-20 pair", async () => {
      // WETH-DAI: 1: ($90, $110)
      // Ass1-Ass2: 1: ($1, $2) (denominated in Ass2...)
      let targetDaiBid = new BigNumber(90);
      let targetDaiAsk = new BigNumber(110);
      let ethOrderSize = new BigNumber(0.25); // for both orders

      let askNum = await ethOrderSize;
      let askDen = await ethOrderSize.multipliedBy(targetDaiAsk);
      let bidNum = await ethOrderSize.multipliedBy(targetDaiBid);
      let bidDen = await ethOrderSize;

      logIndented(
        "cost of placeMarketMakingTrades",
        await bathPairInstance.placeMarketMakingTrades.estimateGas(
          [WETHInstance.address, DAIInstance.address],
          web3.utils.toWei(askNum.toString()),
          web3.utils.toWei(askDen.toString()),
          web3.utils.toWei(bidNum.toString()),
          web3.utils.toWei(bidDen.toString())
        )
      );
      // Place MM trades on WETH - DAI
      await bathPairInstance.placeMarketMakingTrades(
        [WETHInstance.address, DAIInstance.address],
        web3.utils.toWei(askNum.toString()),
        web3.utils.toWei(askDen.toString()),
        web3.utils.toWei(bidNum.toString()),
        web3.utils.toWei(bidDen.toString())
      );
    });
  });
});
