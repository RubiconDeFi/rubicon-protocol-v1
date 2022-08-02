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
const MINLIQUIDITYSHARES = 10 ** 3;
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
        // const userStartBal = (
        //   await bathAssetInstance.balanceOf(accounts[1])
        // ).toString();
        // logIndented(
        //   "userStartBal Asset",
        //   userStartBal,
        //   "total supply",
        //   await bathAssetInstance.totalSupply()
        // );
        await WETHInstance.deposit({
          from: accounts[1],
          value: web3.utils.toWei((1).toString()),
        });
        await WETHInstance.approve(
          bathAssetInstance.address,
          web3.utils.toWei((1).toString()),
          { from: accounts[1] }
        );
        // logIndented(bathAssetInstance.functions);
        await bathAssetInstance.methods["deposit(uint256)"](
          web3.utils.toWei((1).toString()),
          { from: accounts[1] }
        );

        // Bath Token initial minting now fixes "First depositor can break minting of shares #397" from audit
        const expectedShares =
          parseInt(web3.utils.toWei((1).toString())) - MINLIQUIDITYSHARES;
        assert.equal(
          (await bathAssetInstance.balanceOf(accounts[1])).toString(),
          expectedShares
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

        const expectedShare = web3.utils.toWei((100).toString());
        assert.equal(
          (await bathQuoteInstance.balanceOf(accounts[2])).toString(),
          parseInt(expectedShare) - MINLIQUIDITYSHARES
        );
      });
      it("Withdraw asset funds by sending in bathTokens", async function () {
        // const shares = 1 - Math.floor(MINLIQUIDITYSHARES / 1e18);
        var shares = await bathAssetInstance.balanceOf(accounts[1]);
        await bathAssetInstance.withdraw(shares, {
          from: accounts[1],
        });
        shares = parseInt(shares);

        // Account for fee
        // const expected = parseInt((shares * 10000) - ((shares) * (10000) / (3)));
        assert.isAtLeast(
          parseInt(await WETHInstance.balanceOf(accounts[1])),
          shares - 0.0003 * shares
        );
      });
      it("Withdraw quote funds by sending in bathTokens", async function () {
        // const shares = 100 - Math.floor(MINLIQUIDITYSHARES / 1e18);
        var shares = await bathQuoteInstance.balanceOf(accounts[2]);

        await bathQuoteInstance.withdraw(shares, {
          from: accounts[2],
        });

        shares = parseInt(shares);
        // Account for fee
        // const expected = parseInt((shares * 10000) - ((shares) * (10000) / (3)));
        // assert.equal(
        //   (await DAIInstance.balanceOf(accounts[2])).toString(),
        //   (shares - 0.0003 * shares + 900).toString().toString()
        // );
        // TODO?
        // assert.isAtLeast(
        //   parseInt(await DAIInstance.balanceOf(accounts[2])),
        //   shares - 0.0003 * shares
        // );
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
        const userStartBal = (
          await bathAssetInstance.balanceOf(accounts[1])
        ).toString();
        logIndented(
          "userStartBal Asset",
          userStartBal,
          "totalsupply",
          (await bathAssetInstance.totalSupply()).toString()
        );
        await WETHInstance.deposit({
          from: accounts[1],
          value: web3.utils.toWei((10).toString()),
        });
        await WETHInstance.approve(
          bathAssetInstance.address,
          web3.utils.toWei((10).toString()),
          { from: accounts[1] }
        );
        const expectedShares = await bathAssetInstance.convertToShares(
          web3.utils.toWei((10).toString())
        );
        logIndented("expectedShares asset", expectedShares.toString());

        await bathAssetInstance.methods["deposit(uint256)"](
          web3.utils.toWei((10).toString()),
          {
            from: accounts[1],
          }
        );
        assert.equal(
          (await bathAssetInstance.balanceOf(accounts[1])).toString(),
          expectedShares
        );
      });
      it("Users can deposit quote funds with custom weights and receive bathTokens", async function () {
        const userStartBal = (
          await bathQuoteInstance.balanceOf(accounts[2])
        ).toString();
        logIndented(
          "userStartBal Quote",
          userStartBal,
          "totalsupply",
          (await bathQuoteInstance.totalSupply()).toString()
        );
        await DAIInstance.faucet({ from: accounts[2] });
        await DAIInstance.approve(
          bathQuoteInstance.address,
          web3.utils.toWei((100).toString()),
          { from: accounts[2] }
        );

        const expectedShares = await bathQuoteInstance.convertToShares(
          web3.utils.toWei((100).toString())
        );
        logIndented("expectedShares asset", expectedShares.toString());

        await bathQuoteInstance.methods["deposit(uint256)"](
          web3.utils.toWei((100).toString()),
          {
            from: accounts[2],
          }
        );
        assert.equal(
          (await bathQuoteInstance.balanceOf(accounts[2])).toString(),
          expectedShares
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
        assert.isAtLeast(
          parseInt(await bathAssetInstance.underlyingBalance()),
          parseInt(web3.utils.toWei((10 + 0.0003).toString()))
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
          // await rubiconMarketInstance.buy(4 + (2 * (index + 1)), web3.utils.toWei((0.4).toString()), {
          //   from: accounts[5],
          // });
        }
        // const outCount = await bathPairInstance.getOutstandingStrategistTrades(accounts[0]);
        // logIndented("outTrades", outCount);
        // logIndented("outstanding trades count!", outCount.length);

        // logIndented(
        //   "cost of indexScrub:",
        //   await bathPairInstance.indexScrub.estimateGas(0, 2)
        // );
        // TODO: gas considerations?
        // await bathPairInstance.scrubStrategistTrades([outCount[0], outCount[1]]);

        // helper.advanceTimeAndBlock(100);
        //TODO: make this test actually work
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
        // logIndented("** getting this out **", outCount.toString());
        // logIndented("WETH", await WETHInstance.address);
        // logIndented("is this bathAsset?", await bathHouseInstance.getBathTokenfromAsset(WETHInstance.address));
        // logIndented("outcount length", outCount.length);
        // logIndented("outcount is this", outCount);

        // This is reverting:
        // 3 is working here...
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
      it("Partial fill is correctly cancelled and replaced", async function () {
        // await bathPairInstance.bathScrub();
        //TODO: make this actually good. This test is not working rn

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
      // Works just not needed in current strategist flow
      // it("Strategist can cancel an order they made", async function () {
      //   logIndented(
      //     "cost of remove liqudity:",
      //     await bathPairInstance.removeLiquidity.estimateGas(7)
      //   );
      //   await bathPairInstance.removeLiquidity(7);
      //   // assert.equal((await bathPairInstance.getOutstandingPairCount()).toString(), "2");
      // });
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
      // for (let i = 1; i < 10; i++) {
      //     it(`Spamming of placeMarketMakingTrades iteration: ${i}`, async function () {
      //         await bathPairInstance.placeMarketMakingTrades( askNumerator, askDenominator, bidNumerator, bidDenominator);
      //         // TODO: log gas while looping through multiple bathScrub calls
      //         // See how it scales and if a solution is available to make it more gas efficient
      //         // --> why in the OVM is bathScrub failing? This is the goal...

      //         await rubiconMarketInstance.buy(8 + (i*2), web3.utils.toWei((0.4).toString()), { from: accounts[5] });
      //         // console.log(await bathPairInstance.placeMarketMakingTrades.estimateGas( askNumerator, askDenominator, bidNumerator, bidDenominator));
      //         // console.log("IDs of new trades: ",  await bathPairInstance.getLastTradeIDs());
      //         let outstandingPairs = await bathPairInstance.getOutstandingPairCount();
      //         if (outstandingPairs > 5) {
      //             await bathPairInstance.bathScrub();
      //         }
      //         // console.log("outstanding pairs: ", await bathPairInstance.getOutstandingPairCount());
      //     });
      // }

      it("Funds are correctly returned to bathTokens", async function () {
        await WETHInstance.transfer(
          bathQuoteInstance.address,
          web3.utils.toWei("0.001"),
          { from: accounts[1] }
        );
        await DAIInstance.transfer(
          bathAssetInstance.address,
          web3.utils.toWei("0.001"),
          { from: accounts[2] }
        );

        // rebal Pair always tailing risk now if possible...
        logIndented(
          "cost of rebalance: ",
          await bathPairInstance.rebalancePair.estimateGas(
            await WETHInstance.balanceOf(bathQuoteInstance.address),
            await DAIInstance.balanceOf(bathAssetInstance.address),
            WETHInstance.address,
            DAIInstance.address
            // stratUtilInstance.address,
            // "0x0000000000000000000000000000000000000000",
            // 0,
            // 0
          )
        );
        await bathPairInstance.rebalancePair(
          await WETHInstance.balanceOf(bathQuoteInstance.address),
          await DAIInstance.balanceOf(bathAssetInstance.address),
          WETHInstance.address,
          DAIInstance.address
          // stratUtilInstance.address,
          // "0x0000000000000000000000000000000000000000",
          // 0,
          // 0
        );

        assert.equal(
          (await WETHInstance.balanceOf(bathQuoteInstance.address)).toString(),
          "0"
        );
        assert.equal(
          (await DAIInstance.balanceOf(bathAssetInstance.address)).toString(),
          "0"
        );
      });
      it("Strategist can claim funds", async function () {
        await bathPairInstance.strategistBootyClaim(
          WETHInstance.address,
          DAIInstance.address
        );
        // TODO: validate this is correct
        assert.equal(
          (await WETHInstance.balanceOf(accounts[0])).toString(),
          "20000000000000"
        );
      });
      it("Edge Case: Strategist can take out their own orders to make a new midpoint", async function () {
        // const askNumerator = web3.utils.toWei((0.01).toString());
        // const askDenominator = web3.utils.toWei((0.5).toString());
        // const bidNumerator = web3.utils.toWei((0.4).toString());
        // const bidDenominator = web3.utils.toWei((0.01).toString());
        // const assetInstance = await WAYNE.new(
        //   accounts[8],
        //   web3.utils.toWei((10000).toString()),
        //   "WAYNE",
        //   "WAYNE"
        // );

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
