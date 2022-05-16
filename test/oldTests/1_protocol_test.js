const BathHouse = artifacts.require("BathHouse");
const BathPair = artifacts.require("BathPair");
const BathToken = artifacts.require("BathToken");
const RubiconMarket = artifacts.require("RubiconMarket");
const DAI = artifacts.require("TokenWithFaucet");
const WETH = artifacts.require("WETH9");
const TokenWithFaucet = artifacts.require("TokenWithFaucet");

const { parseUnits } = require("ethers/lib/utils.js");
const helper = require("../testHelpers/timeHelper.js");

function logIndented(...args) {
  console.log("       ", ...args);
}

// ganache-cli --gasLimit=0x1fffffffffffff --gasPrice=0x1 --allowUnlimitedContractSize --defaultBalanceEther 9000
// ganache-cli --gasLimit=9000000 --gasPrice=0x1 --defaultBalanceEther 9000 --allowUnlimitedContractSize

contract(
  "Rubicon Exchange and Pools Original Tests",
  async function (accounts) {
    let newPair;
    let bathPairInstance;
    let bathAssetInstance;
    let bathQuoteInstance;
    let bathHouseInstance;
    let bathTokenImplementation;

    describe("Deployment", async function () {
      it("is deployed", async function () {
        rubiconMarketInstance = await RubiconMarket.deployed();
        bathHouseInstance = await BathHouse.deployed();
        DAIInstance = await DAI.deployed();
        WETHInstance = await WETH.deployed();
        bathPairInstance = await BathPair.deployed();
        bathTokenImplementation = await BathToken.new();
      });
    });

    describe("Bath House Initialization of Bath Pair and Bath Tokens", async function () {
      it("Bath House is deployed and initialized", async function () {
        // Call initialize on Bath house
        return await bathHouseInstance.initialize(
          rubiconMarketInstance.address,
          80,
          10,
          bathTokenImplementation.address,
          accounts[9] // Proxy admin
          // 20
        );
      });

      it("Bath Token for asset is deployed and initialized", async function () {
        await bathHouseInstance.createBathToken(
          WETHInstance.address,
          accounts[0]
        );
        let newBathTokenAddr = await bathHouseInstance.tokenToBathToken(
          WETHInstance.address
        );
        logIndented("new bathWETH!", newBathTokenAddr.toString());
        bathAssetInstance = await BathToken.at(newBathTokenAddr);
        assert.equal(
          await bathAssetInstance.RubiconMarketAddress(),
          rubiconMarketInstance.address
        );
      });
      it("Bath Token for quote is deployed and initialized", async function () {
        await bathHouseInstance.createBathToken(
          DAIInstance.address,
          accounts[0]
        );
        let newBathTokenAddr = await bathHouseInstance.tokenToBathToken(
          DAIInstance.address
        );
        // logIndented("new addr!",await bathHouseInstance.tokenToBathToken(WETHInstance.address));
        bathQuoteInstance = await BathToken.at(newBathTokenAddr);
        assert.equal(
          await bathQuoteInstance.RubiconMarketAddress(),
          rubiconMarketInstance.address
        );
      });
      // Now is initialized from the BathHouse itself
      it("Bath Pair is deployed and initialized w/ BathHouse", async function () {
        await bathHouseInstance.initBathPair(bathPairInstance.address, 500, -5); // 90% reserve ratio and 3 days cancel delay
        livePair = await bathHouseInstance.approvedPairContract();
        logIndented("New BathPair: ", newPair);
        assert.equal(livePair.toString(), bathPairInstance.address);
      });
      it("can correctly spawn bathWETH and bathDAI", async function () {
        let assetName = await bathAssetInstance.symbol();
        let quoteName = await bathQuoteInstance.symbol();
        assert.equal(assetName, "bathWETH");
        assert.equal(quoteName, "bathDAI");
      });
      it("bath tokens have the right name", async function () {
        assert.equal(await bathAssetInstance.symbol(), "bathWETH");
        assert.equal(await bathQuoteInstance.symbol(), "bathDAI");
      });
      it("User can deposit asset funds with custom weights and receive bathTokens", async function () {
        await WETHInstance.deposit({
          from: accounts[1],
          value: web3.utils.toWei((1).toString()),
        });
        await WETHInstance.approve(
          bathAssetInstance.address,
          web3.utils.toWei((1).toString()),
          { from: accounts[1] }
        );
        logIndented(bathAssetInstance.functions);
        await bathAssetInstance.methods["deposit(uint256)"](
          web3.utils.toWei((1).toString()),
          { from: accounts[1] }
        );

        assert.equal(
          (await bathAssetInstance.balanceOf(accounts[1])).toString(),
          web3.utils.toWei((1).toString())
        );
      });
      it("User can deposit quote funds with custom weights and receive bathTokens", async function () {
        // Faucets 1000
        await DAIInstance.faucet({ from: accounts[2] });
        await DAIInstance.approve(
          bathQuoteInstance.address,
          web3.utils.toWei((100).toString()),
          { from: accounts[2] }
        );
        await bathQuoteInstance.methods["deposit(uint256)"](
          web3.utils.toWei((100).toString()),
          {
            from: accounts[2],
          }
        );
        assert.equal(
          (await bathQuoteInstance.balanceOf(accounts[2])).toString(),
          web3.utils.toWei((100).toString())
        );
      });
      it("Withdraw asset funds by sending in bathTokens", async function () {
        const shares = 1;
        await bathAssetInstance.withdraw(web3.utils.toWei((shares).toString()), {
          from: accounts[1],
        });
        // Account for fee
        // const expected = parseInt((shares * 10000) - ((shares) * (10000) / (3)));
        assert.equal(
          (await WETHInstance.balanceOf(accounts[1])).toString(),
          await web3.utils.toWei((shares - 0.0003 * shares).toString()).toString()
        );
      });
      it("Withdraw quote funds by sending in bathTokens", async function () {
        const shares = 100;
        await bathQuoteInstance.withdraw(web3.utils.toWei((shares).toString()), {
          from: accounts[2],
        });

        // Account for fee
        // const expected = parseInt((shares * 10000) - ((shares) * (10000) / (3)));
        assert.equal(
          (await DAIInstance.balanceOf(accounts[2])).toString(),
          web3.utils.toWei(((shares - 0.0003 * shares) + 900).toString()).toString()
        );
      });
      it("both users have no bath Tokens post withdraw", async function () {
        assert.equal("0", await bathAssetInstance.balanceOf(accounts[1]));
        assert.equal("0", await bathQuoteInstance.balanceOf(accounts[2]));
      });
    });

    // Test Market making functionality:
    describe("Liquidity Providing Tests", async function () {
      // Bid and ask made by Pools throughout the test
      const askNumerator = web3.utils.toWei((0.01).toString());
      const askDenominator = web3.utils.toWei((0.5).toString());
      const bidNumerator = web3.utils.toWei((0.4).toString());
      const bidDenominator = web3.utils.toWei((0.01).toString());

      it("User can deposit asset funds with custom weights and receive bathTokens", async function () {
        await WETHInstance.deposit({
          from: accounts[1],
          value: web3.utils.toWei((10).toString()),
        });
        await WETHInstance.approve(
          bathAssetInstance.address,
          web3.utils.toWei((10).toString()),
          { from: accounts[1] }
        );

        await bathAssetInstance.methods["deposit(uint256)"](
          web3.utils.toWei((10).toString()),
          {
            from: accounts[1],
          }
        );
        assert.equal(
          (await bathAssetInstance.balanceOf(accounts[1])).toString(),
          web3.utils.toWei((10).toString())
        );
      });
      it("Users can deposit quote funds with custom weights and receive bathTokens", async function () {
        await DAIInstance.faucet({ from: accounts[2] });
        await DAIInstance.approve(
          bathQuoteInstance.address,
          web3.utils.toWei((100).toString()),
          { from: accounts[2] }
        );

        await bathQuoteInstance.methods["deposit(uint256)"](
          web3.utils.toWei((100).toString()),
          {
            from: accounts[2],
          }
        );
        assert.equal(
          (await bathQuoteInstance.balanceOf(accounts[2])).toString(),
          web3.utils.toWei((100).toString())
        );
      });
      it("Place a starting pair to clear checks", async function () {
        await WETHInstance.deposit({
          from: accounts[3],
          value: web3.utils.toWei((0.5).toString()),
        });
        await WETHInstance.approve(
          rubiconMarketInstance.address,
          web3.utils.toWei((0.5).toString()),
          { from: accounts[3] }
        );
        await rubiconMarketInstance.offer(
          web3.utils.toWei((0.1).toString(), "ether"),
          WETHInstance.address,
          web3.utils.toWei((5).toString(), "ether"),
          DAIInstance.address,
          0,
          { from: accounts[3] }
        );

        // To trigger faucet again:
        // helper.advanceTimeAndBlock(8700);
        await DAIInstance.faucet({ from: accounts[4] });
        await DAIInstance.approve(
          rubiconMarketInstance.address,
          web3.utils.toWei((70).toString()),
          { from: accounts[4] }
        );
        await rubiconMarketInstance.offer(
          web3.utils.toWei((4).toString(), "ether"),
          DAIInstance.address,
          web3.utils.toWei((0.1).toString(), "ether"),
          WETHInstance.address,
          0,
          { from: accounts[4], gas: 0x1ffffff }
        );
      });
      it("placeMarketMaking Trades can be called by approved strategist successfully", async function () {
        await bathPairInstance.placeMarketMakingTrades(
          [WETHInstance.address, DAIInstance.address],
          askNumerator,
          askDenominator,
          bidNumerator,
          bidDenominator
        );
      });
      it("bathTokens maintains the correct underlyingBalance()", async function () {
        assert.equal(
          (await bathAssetInstance.underlyingBalance()).toString(),
          web3.utils.toWei((10 + 0.0003).toString())
        );
      });
      it("Taker can fill part of trade", async function () {
        await WETHInstance.deposit({
          from: accounts[5],
          value: web3.utils.toWei((100).toString()),
        });
        await WETHInstance.approve(
          rubiconMarketInstance.address,
          web3.utils.toWei((100).toString()),
          { from: accounts[5] }
        );

        await rubiconMarketInstance.buy(4, web3.utils.toWei((0.4).toString()), {
          from: accounts[5],
        });
      });
      it("scrubStrategistTrades can be used by approved strategists", async function () {
        let target = 2;
        // let goalScrub = target + outCount.toNumber();
        for (let index = 0; index < target; index++) {
          await bathPairInstance.placeMarketMakingTrades(
            [WETHInstance.address, DAIInstance.address],
            askNumerator,
            askDenominator,
            bidNumerator,
            bidDenominator
          );
        }
        assert.equal(
          (
            await bathPairInstance.getOutstandingStrategistTrades(
              WETHInstance.address,
              DAIInstance.address,
              accounts[0]
            )
          ).length.toString(),
          "3"
        );
      });
      it("bathTokens are correctly logging outstandingAmount", async function () {
        let target = 6;
        for (let index = 0; index < target; index++) {
          await bathPairInstance.placeMarketMakingTrades(
            [WETHInstance.address, DAIInstance.address],
            askNumerator,
            askDenominator,
            bidNumerator,
            bidDenominator
          );
        }
        helper.advanceTimeAndBlock(100);
        // Wipe the book of strategist trades!
        const outCount = await bathPairInstance.getOutstandingStrategistTrades(
          WETHInstance.address,
          DAIInstance.address,
          accounts[0]
        );
        for (let index = 0; index < outCount.length; index++) {
          const element = outCount[index];
          // logIndented("Attempting to scrub this id:", element.toNumber());
          await bathPairInstance.scrubStrategistTrade(await element.toNumber());
          helper.advanceTimeAndBlock(1);
        }

        assert.equal(
          (await bathAssetInstance.outstandingAmount()).toString(),
          "0"
        );
        assert.equal(
          (await bathQuoteInstance.outstandingAmount()).toString(),
          "0"
        );
      });
      it("One cannot scrub already scrubbed orders", async function () {
        await bathPairInstance.scrubStrategistTrade(1).catch((e) => {
          logIndented("Should be an error reason:", e.reason);
        });
      });
      it("Can placeMarketMakingTrades", async function () {
        // await bathPairInstance.bathScrub();
        await bathPairInstance.placeMarketMakingTrades(
          [WETHInstance.address, DAIInstance.address],
          askNumerator,
          askDenominator,
          bidNumerator,
          bidDenominator
        );
      });
      it("Zero order can be placed - bid or ask", async function () {
        await bathPairInstance.placeMarketMakingTrades(
          [WETHInstance.address, DAIInstance.address],
          0,
          0,
          bidNumerator,
          bidDenominator
        );
        await bathPairInstance.placeMarketMakingTrades(
          [WETHInstance.address, DAIInstance.address],
          askNumerator,
          askDenominator,
          0,
          0
        );
      });
      it("New strategist can be added to pools ", async function () {
        await bathHouseInstance.approveStrategist(accounts[6]);
        await bathPairInstance.placeMarketMakingTrades(
          [WETHInstance.address, DAIInstance.address],
          askNumerator,
          askDenominator,
          bidNumerator,
          bidDenominator,
          { from: accounts[6] }
        );
        // await bathPairInstance.removeLiquidity(10, {from: accounts[6]});
      });
      it("Strategist can claim funds", async function () {
        await bathPairInstance.strategistBootyClaim(
          WETHInstance.address,
          DAIInstance.address
        );
        assert.equal(
          (await WETHInstance.balanceOf(accounts[0])).toString(),
          "20000000000000"
        );
      });
      it("Edge Case: Strategist can take out their own orders to make a new midpoint", async function () {
        await DAIInstance.faucet({ from: accounts[7] });
        await DAIInstance.approve(
          rubiconMarketInstance.address,
          web3.utils.toWei((1000).toString()),
          { from: accounts[7] }
        );
        await WETHInstance.deposit({
          from: accounts[8],
          value: web3.utils.toWei((2).toString()),
        });
        await WETHInstance.approve(
          rubiconMarketInstance.address,
          web3.utils.toWei((1000).toString()),
          { from: accounts[8] }
        );

        await rubiconMarketInstance.offer(
          web3.utils.toWei((1).toString()),
          DAIInstance.address,
          web3.utils.toWei((1).toString()),
          WETHInstance.address,
          0,
          { from: accounts[7] }
        );
        await rubiconMarketInstance.offer(
          web3.utils.toWei((1).toString()),
          WETHInstance.address,
          web3.utils.toWei((2).toString()),
          DAIInstance.address,
          0,
          { from: accounts[8] }
        );

        // midpoint around $2 - $1
        await bathPairInstance.placeMarketMakingTrades(
          [WETHInstance.address, DAIInstance.address],
          web3.utils.toWei((0.2).toString()),
          web3.utils.toWei((0.4).toString()),
          web3.utils.toWei((1).toString()),
          web3.utils.toWei((1).toString())
        );

        await bathPairInstance.placeMarketMakingTrades(
          [WETHInstance.address, DAIInstance.address],
          web3.utils.toWei((0.1).toString()),
          web3.utils.toWei((0.3).toString()),
          web3.utils.toWei((1).toString()),
          web3.utils.toWei((1).toString())
        );

        await bathPairInstance.placeMarketMakingTrades(
          [WETHInstance.address, DAIInstance.address],
          web3.utils.toWei((0.1).toString()),
          web3.utils.toWei((0.3).toString()),
          web3.utils.toWei((1).toString()),
          web3.utils.toWei((0.7).toString())
        );

        await bathPairInstance.placeMarketMakingTrades(
          [WETHInstance.address, DAIInstance.address],
          web3.utils.toWei((0.2).toString()),
          web3.utils.toWei((0.4).toString()),
          web3.utils.toWei((1).toString()),
          web3.utils.toWei((1).toString())
        );

        await bathPairInstance.placeMarketMakingTrades(
          [WETHInstance.address, DAIInstance.address],
          web3.utils.toWei((0.2).toString()),
          web3.utils.toWei((0.4).toString()),
          web3.utils.toWei((1).toString()),
          web3.utils.toWei((1).toString())
        );

        await bathPairInstance.placeMarketMakingTrades(
          [WETHInstance.address, DAIInstance.address],
          web3.utils.toWei((0.2).toString()),
          web3.utils.toWei((0.4).toString()),
          web3.utils.toWei((1).toString()),
          web3.utils.toWei((1).toString())
        );

        await bathPairInstance.placeMarketMakingTrades(
          [WETHInstance.address, DAIInstance.address],
          web3.utils.toWei((0.2).toString()),
          web3.utils.toWei((0.4).toString()),
          web3.utils.toWei((1).toString()),
          web3.utils.toWei((1).toString())
        );

        //try $5-$3
        await bathPairInstance.placeMarketMakingTrades(
          [WETHInstance.address, DAIInstance.address],
          web3.utils.toWei((0.1).toString()),
          web3.utils.toWei((0.5).toString()),
          web3.utils.toWei((3).toString()),
          web3.utils.toWei((1).toString())
        );

        //try $0.5 - 0.2
        await bathPairInstance.placeMarketMakingTrades(
          [WETHInstance.address, DAIInstance.address],
          web3.utils.toWei((0.1).toString()),
          web3.utils.toWei((0.05).toString()),
          web3.utils.toWei((0.2).toString()),
          web3.utils.toWei((1).toString())
        );
      });
    });
  }
);
