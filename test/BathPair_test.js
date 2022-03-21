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
    it("public address bathHouse - set correctly", async () => {});
    it("public address RubiconMarketAddress - set correctly", async () => {});
    it("public bool initialized - correctly initialized", async () => {});
    // TODO: Need a getter?
    it("internal int128 shapeCoefNum - correctly initialized", async () => {});
    //TODO: check this homie out
    it("public uint maxOrderSizeBPS - correctly initialized", async () => {});
    // TODO: should this be internal?

    // ** Here we want to walk through each step of the full market-making flow while checking how key variables change **

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
    // 1a-1n make a test for each check along the way

    // 2. Simulate some fill on the pair of orders
    // 2a-2n ''
    it("function logFill( uint256 amt,  address strategist, address asset) internal { - XXX", async () => {});

    // 3. Scrub all orders (filled and otherwise) and verify that bathTokens and key variables are updated accordingly

    // 4. Rebalance the pools
    it("function rebalancePair( uint256 assetRebalAmt,  uint256 quoteRebalAmt,  address _underlyingAsset, address _underlyingQuote) external onlyApprovedStrategist(msg.sender) {- XXX", async () => {});

    // Check the following during the above:
    it("public uint last_stratTrade_id - increments up correctly with a new order", async () => {});
    it("public mapping (address=>uint) totalFillsPerAsset - correctly logs an asset-specific fill for a strategist", async () => {});
    it("public mapping (uint=>StrategistTrade) strategistTrades - correctly adds in all *needed* info with a new strategist trade", async () => {});
    it("public mapping (address=>uint[]) outOffersByStrategist - correctly logs the outstanding array of orders a strategist has and removes scrubbed orders", async () => {});
    it("public mapping (address=>(address=>uint)) strategist2Fills - correctly adds in all *needed* info with a new strategist trade", async () => {});

    // Functions to test for proper functionality GRAB BAG:
    it("function getOutstandingTrades(address strategist) external view returns (uint256[] memory) - XXX", async () => {});
    it("function getMidpointPrice(address underlyingAsset, address underlyingQuote) internal view returns (int128) - XXX", async () => {});
    it("function handleStratOrderAtID( uint256 id, address bathAssetAddress, address bathQuoteAddress) internal { - XXX", async () => {});
    it(" ??? attempTail off??? Remove??? - XXX", async () => {});
    it("function scrubStrategistTrade(uint256 id,address bathAssetAddress,address bathQuoteAddress) public onlyApprovedStrategist(msg.sender) {- XXX", async () => {});
    it("function scrubStrategistTrades(uint256[] memory ids,address bathAssetAddress,address bathQuoteAddress) external { - XXX", async () => {});
    it("function getMaxOrderSize( address asset, address sisterAsset, address targetBathToken, address sisterBathToken) public view returns (uint256 maxSizeAllowed) { - XXX", async () => {});
    it("function strategistBootyClaim(address asset, address quote) external { - XXX", async () => {});
  });
  describe("Case-Specific Tests", async function () {
    it("A strategist can place a bid OR an ask", async () => {});
    it("getMaxOrderSize scales correctly according to an understood shape curve", async () => {});
    it("Only approved strategists can submit orders and access user liquidity", async () => {});
    it("What is the maximum liquidity a strategist can utilize? Via what mechanism?", async () => {});
    it("The strategist can scrub multiple trades at once - log gas costs", async () => {});
  });
  describe("Event Logging Tests", async function () {
    it("Any new strategist trade emits an event with the data we need", async () => {});
    it("A rebalance emits data correctly", async () => {});
    it("A scrubbing of an outstanding order ?needed? emits data correctly", async () => {});
  });
});
