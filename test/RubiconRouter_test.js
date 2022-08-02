const BathHouse = artifacts.require("BathHouse");
const BathPair = artifacts.require("BathPair");
const BathToken = artifacts.require("BathToken");
const RubiconMarket = artifacts.require("RubiconMarket");
const RubiconRouter = artifacts.require("RubiconRouter");
const DAI = artifacts.require("TokenWithFaucet");
const WETH = artifacts.require("WETH9");
const ERC20 = artifacts.require("ERC20");
const TokenWithFaucet = artifacts.require("TokenWithFaucet");

const helper = require("./testHelpers/timeHelper.js");

//Helper function
function logIndented(...args) {
  console.log("       ", ...args);
}
const MINLIQUIDITYSHARES = 10 ** 3;

// asset quote - addresses, price - float denominated in quote!, market - rubiconMarketInstance
async function placeOrderInBook(asset, quote, price, size) {
  let market = await RubiconMarket.deployed();
  let assetContract = await WETH.deployed();
  let assetAddr = assetContract.address;
  let type = (await asset) == assetAddr ? "Ask" : "Bid";
  let num;
  let den;
  if (type == "Ask") {
    num = await size;
    den = (await price) * (await size);
  } else if (type == "Bid") {
    num = (await price) * (await size);
    den = await size;
  }

  return await market
    .offer(
      web3.utils.toWei((await num).toString(), "ether"),
      await asset,
      web3.utils.toWei((await den).toString(), "ether"),
      await quote,
      0
      // { from: accounts[3] } // ASSUMED FROM ADMIN FOR NOW
    )
    .then(async (r) => {
      // Return value is tx reciept
      //Optional
      // logIndented("Offer Placed", "Type", type, "Price", price, "Size", size);
    });
}

contract("Rubicon Router", (accounts) => {
  let rubiconMarketInstance;
  let rubiconRouterInstance;
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
      rubiconRouterInstance = await RubiconRouter.deployed();
      bathHouseInstance = await BathHouse.deployed();
      bathPairInstance = await BathPair.deployed();
      DAIInstance = await DAI.deployed();
      WETHInstance = await WETH.deployed();
      bathTokenImplementation = await BathToken.new();
    });
    it("BathHouse is successfully initialized", async () => {
      await bathHouseInstance.initialize(
        rubiconMarketInstance.address,
        80,
        10,
        bathTokenImplementation.address,
        accounts[9] // Proxy admin
      );
      assert.equal(await bathHouseInstance.initialized(), true);
    });
    it("accounts[0] has WETH, DAI, and approved the market", async () => {
      await WETHInstance.deposit({
        from: accounts[0],
        value: await web3.utils.toWei("100"),
      });
      await WETHInstance.approve(
        rubiconMarketInstance.address,
        web3.utils.toWei((10000).toString()),
        { from: accounts[0] }
      );
      await DAIInstance.approve(
        rubiconMarketInstance.address,
        web3.utils.toWei((10000).toString()),
        { from: accounts[0] }
      );

      // assert.equal(await WETHInstance.balanceOf(accounts[0]))
    });
    it("BathPair contract is wired up", async () => {
      await bathHouseInstance.initBathPair(bathPairInstance.address, 500, -5); // 90% reserve ratio and 3 days cancel delay
      let pair = await bathHouseInstance.approvedPairContract();
      bathPairInstance = await BathPair.at(pair);
    });
  });
  describe("Unit Tests", async function () {
    // Critical function to pull outstanding orders into the order book
    it("function getBookFromPair(ERC20 asset, ERC20 quote, uint topNOrders) public view returns (uint[] memory, uint[] memory, uint) {", async () => {
      // Note: ANY NON-ORDERS will be returned as zero in the array
      // Note: first market ID is always 1!!! This means any zeroes are non-orders or BAD orders
      // Make some orders we expect to get the ID back from in this call and be ordered correctly
      // ASKS:[price, expectedID]: ($100, 1), ($120, 3), ($140, 5)
      // BIDS:[price, expectedID]: ($90, 2), ($80, 4), ($60, 6)

      // First address denotes ask/asset
      await placeOrderInBook(
        WETHInstance.address,
        DAIInstance.address,
        100.0,
        1
      );
      await placeOrderInBook(
        DAIInstance.address,
        WETHInstance.address,
        90.0,
        1
      );
      await placeOrderInBook(
        WETHInstance.address,
        DAIInstance.address,
        120.0,
        1
      );
      await placeOrderInBook(
        DAIInstance.address,
        WETHInstance.address,
        80.0,
        1
      );
      await placeOrderInBook(
        WETHInstance.address,
        DAIInstance.address,
        140.0,
        1
      );
      await placeOrderInBook(
        DAIInstance.address,
        WETHInstance.address,
        60.0,
        1
      );
      helper.advanceTimeAndBlock(100);
      let output = await rubiconRouterInstance.getBookFromPair(
        WETHInstance.address,
        DAIInstance.address,
        10
      ); //back to view ASAP
      // logIndented("asks:", await output[0]);
      let bestAskID = (
        await rubiconMarketInstance.getBestOffer(
          WETHInstance.address,
          DAIInstance.address
        )
      ).toNumber();
      let bestBidID = (
        await rubiconMarketInstance.getBestOffer(
          DAIInstance.address,
          WETHInstance.address
        )
      ).toNumber();
      // logIndented("Best Bid:", bestBidID);

      let asks = await output[0];

      let bids = await output[1];
      assert.equal(asks[0][2].toNumber(), bestAskID);
      assert.equal(asks[1][2].toNumber(), 3);
      assert.equal(asks[2][2].toNumber(), 5);

      assert.equal(bids[0][2].toNumber(), bestBidID);
      assert.equal(bids[1][2].toNumber(), 4);
      assert.equal(bids[2][2].toNumber(), 6);
    });
  });
  describe("Case-Specific Tests", async function () {
    it("Random: ERC-20 Token with faucet behaves as expected", async () => {
      let decimals = 18;
      let newTWF = await TokenWithFaucet.new(
        accounts[3],
        "Test Coin",
        "TEST",
        decimals
      );
      assert.equal(
        await (await newTWF).balanceOf(accounts[3]),
        1000 * 10 ** decimals
      );
      await (await newTWF).faucet({ from: accounts[3] });
      assert.equal(
        await (await newTWF).balanceOf(accounts[3]),
        2 * (1000 * 10 ** decimals)
      );
    });
    // Approach:
    // Have a user with native ETH, track their balances of everything before and after
    let bathWethInstance;
    it("a bathToken can be spawned for WETH by anyone", async () => {
      let newPool = await bathHouseInstance.createBathToken(
        await WETHInstance.address,
        accounts[0]
      );
      // logIndented("new BathWETH", newPool);
      // assert.equal(
      //   await newPool,
      //   await bathHouseInstance.tokenToBathToken(await WETHInstance.address)
      // );
      // await rubiconRouterInstance.depositWithETH(web3.utils.toWei("1"), targetPool);
    });
    it("[Native ETH] - A user can deposit with native ETH", async () => {
      // Approval call needed
      let targetPool = await bathHouseInstance.tokenToBathToken(
        await WETHInstance.address
      );
      // logIndented("Querying this for WETH bath pool", targetPool);
      await WETHInstance.approve(targetPool, web3.utils.toWei("1"), {
        from: accounts[4],
      });
      await rubiconRouterInstance.depositWithETH(
        web3.utils.toWei("1"),
        targetPool,
        { from: accounts[4], value: web3.utils.toWei("1") }
      );
      bathWethInstance = await ERC20.at(targetPool);
      const expectedShares =
        parseInt(web3.utils.toWei("1")) - MINLIQUIDITYSHARES;
      assert.equal(
        (await bathWethInstance.balanceOf(accounts[4])).toString(),
        expectedShares.toString()
      );
    });
    it("[Native ETH] - A user can withdraw for native ETH", async () => {
      let targetPool = await bathHouseInstance.tokenToBathToken(
        await WETHInstance.address
      );
      let ethBalanceBefore = await web3.eth.getBalance(accounts[4]);
      // logIndented("bathToken balance", web3.utils.fromWei(await bathWethInstance.balanceOf(accounts[4])));

      // Approve bathTokens for spend by Router
      await bathWethInstance.approve(
        rubiconRouterInstance.address,
        web3.utils.toWei("1"),
        {
          from: accounts[4],
        }
      );

      const expectedShares =
        parseInt(web3.utils.toWei("1")) - MINLIQUIDITYSHARES;
      await rubiconRouterInstance.withdrawForETH(
        expectedShares.toString(),
        targetPool,
        { from: accounts[4] }
      );

      let ethBalanceAfter = await web3.eth.getBalance(accounts[4]);
      let delta = ethBalanceAfter - ethBalanceBefore;
      // Note, 999999999999737900 is what is actually received due to tx fees I believe
      let expected = await web3.utils.toWei("0.99");
      assert.isAtLeast(delta, parseInt(expected));
    });
    it("[Native ETH] - A user can swap with native ETH", async () => {
      // Use Native ETH to buy DAI
      let sellAmt = await web3.utils.toWei("0.1002");
      await rubiconRouterInstance.swapWithETH(
        await web3.utils.toWei("0.1"),
        web3.utils.toWei("9"),
        [WETHInstance.address, DAIInstance.address],
        20,
        { from: accounts[5], value: sellAmt }
      );
      let resultingBal = await DAIInstance.balanceOf(accounts[5]);
      assert.equal(parseInt(web3.utils.fromWei(resultingBal)), 9);
    });
    it("[Native ETH] - A user can swap for native ETH", async () => {
      let ethBalanceBefore = await web3.eth.getBalance(accounts[5]);

      console.log("balance before", ethBalanceBefore.toString());
      await DAIInstance.approve(
        rubiconRouterInstance.address,
        web3.utils.toWei("9"),
        {
          from: accounts[5],
        }
      );
      await rubiconRouterInstance.swapForETH(
        web3.utils.toWei("8.982"), // 99.8% to account for fee
        await web3.utils.toWei("0.0892"),
        [DAIInstance.address, WETHInstance.address],
        20,
        { from: accounts[5] }
      );
      let ethBalanceAfter = await web3.eth.getBalance(accounts[5]);
      let delta = ethBalanceAfter - ethBalanceBefore;
      // Assuming it is lower due to gas ?
      assert.isAtLeast(
        delta,
        (parseInt(await web3.utils.toWei("0.085")) * (10000 - 20)) / 10000
      );
    });
    it("[Native ETH] - A user can offer with native ETH", async () => {
      let ethBalanceBefore = await web3.eth.getBalance(accounts[6]);

      await rubiconRouterInstance.offerWithETH(
        web3.utils.toWei("0.1"),
        web3.utils.toWei("20"),
        DAIInstance.address,
        0,
        { from: accounts[6], value: web3.utils.toWei("0.1") }
      );
      let ethBalanceAfter = await web3.eth.getBalance(accounts[6]);
      let delta = ethBalanceBefore - ethBalanceAfter;
      assert.isAtLeast(delta, parseInt(await web3.utils.toWei("0.1")));
    });
    it("[Native ETH] - A user can buyAllAmount with native ETH", async () => {
      // let ethBalanceBefore = await web3.eth.getBalance(accounts[1]);
      const max_fill_amount = web3.utils.toWei("0.1");

      let buyAmt = await rubiconMarketInstance.getBuyAmount(
        DAIInstance.address,
        WETHInstance.address,
        max_fill_amount
      );
      let payAmt = await rubiconMarketInstance.getPayAmount(
        WETHInstance.address,
        DAIInstance.address,
        web3.utils.toWei("9")
      ); // This is equal to what resulting dai we get...
      // logIndented("Expected payAmt", payAmt.toString());

      await rubiconRouterInstance.buyAllAmountWithETH(
        DAIInstance.address,
        buyAmt,
        max_fill_amount,
        20,
        { from: accounts[1], value: web3.utils.toWei("0.1002") }
      );
      // let ethBalanceAfter = await web3.eth.getBalance(accounts[1]);
      // let delta = ethBalanceBefore - ethBalanceAfter;
      // logIndented("spent this much eth", web3.utils.fromWei(delta.toString()));
      assert.equal(
        (await DAIInstance.balanceOf(accounts[1])).toString(),
        buyAmt.toString()
      );
      // assert.isAtLeast(delta, parseInt(await web3.utils.toWei("0.1")));
    });
  });
});
