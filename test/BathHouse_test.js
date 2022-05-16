const { ethers } = require("ethers");

const BathHouse = artifacts.require("BathHouse");
const BathPair = artifacts.require("BathPair");
const BathToken = artifacts.require("BathToken");
const RubiconMarket = artifacts.require("RubiconMarket");
const DAI = artifacts.require("TokenWithFaucet");
const WETH = artifacts.require("WETH9");
const TokenWithFaucet = artifacts.require("TokenWithFaucet");
var should = require("chai").should();

//Helper function
function logIndented(...args) {
  console.log("       ", ...args);
}

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

// Note, on this contract we are ignoring the variables which are unused and
//  marked with *Deprecate post Optimism*
contract("Bath House", (accounts) => {
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
      // logIndented("getting this pair", pair);
      bathPairInstance = await BathPair.at(pair);
      assert.equal(await bathPairInstance.initialized(), true);
    });
  });
  describe("Unit Tests", async function () {
    it("public string name - set correctly", async () => {
      assert.equal(await bathHouseInstance.name(), "Rubicon Bath House");
    });
    it("public address admin - set correctly", async () => {
      assert.equal(await bathHouseInstance.admin(), accounts[0]);
    });
    it("public address RubiconMarketAddress - set correctly", async () => {
      assert.equal(
        await bathHouseInstance.RubiconMarketAddress(),
        rubiconMarketInstance.address
      );
    });
    it("public mapping approvedStrategists - set correctly w/ approved admin", async () => {
      assert.equal(
        await bathHouseInstance.approvedStrategists(accounts[0]),
        true
      );
    });
    it("public bool permissionedStrategists - set correctly", async () => {
      assert.equal(await bathHouseInstance.permissionedStrategists(), true);
    });
    it("public uint reserveRatio - set correctly", async () => {
      assert.equal(await bathHouseInstance.reserveRatio(), 80);
    });
    it("public uint timeDelay - set correctly", async () => {
      assert.equal(await bathHouseInstance.timeDelay(), 10);
    });
    it("public address approvedPairContract - set correctly", async () => {
      assert.equal(
        await bathHouseInstance.approvedPairContract(),
        bathPairInstance.address
      );
    });
    it("public uint bpsToStrategists - set correctly", async () => {
      assert.equal(await bathHouseInstance.bpsToStrategists(), 20);
    });
    it("public mapping tokenToBathToken - initializes as empty before any createBathToken calls", async () => {
      assert.equal(
        await bathHouseInstance.tokenToBathToken(DAIInstance.address),
        0
      );
    });
  });
  describe("Case-Specific Tests", async function () {
    it("BathTokens can be created permissionlessly - openBathTokenSpawnAndSignal", async () => {
      // Will create a pool permissionlessly
      let signaler = accounts[1];

      // Create a new arbitrary ERC-20
      const newCoinSymbol = "TEST";
      const decimals = 8;
      let newCoin = await TokenWithFaucet.new(
        signaler,
        "Test Coin",
        newCoinSymbol,
        decimals
      );
      let expectZero = await bathHouseInstance.tokenToBathToken(
        newCoin.address
      );
      assert.equal(expectZero, ZERO_ADDRESS); // new asset w/o a bathToken

      const desiredPairedAsset = await DAIInstance.address;
      // Create the bathDAI pool if it doesn't exist
      const daiExist = await bathHouseInstance.getBathTokenfromAsset(
        desiredPairedAsset
      );
      if (daiExist == ZERO_ADDRESS) {
        await bathHouseInstance.createBathToken(
          desiredPairedAsset,
          ZERO_ADDRESS
        );
      }
      const newBathToken = await bathHouseInstance.getBathTokenfromAsset(
        desiredPairedAsset
      );
      should.not.equal(newBathToken, ZERO_ADDRESS); // existing asset w/ a bathToken

      // Approve TEST and DAI on bathHouse
      const initialLiquidityNew = ethers.utils.parseUnits("100", decimals);
      const initialLiquidityExistingBathToken = ethers.utils.parseUnits(
        "100",
        18
      );
      await newCoin.approve(bathHouseInstance.address, initialLiquidityNew, {
        from: signaler,
      });
      await DAIInstance.faucet({ from: signaler });
      await DAIInstance.approve(
        bathHouseInstance.address,
        initialLiquidityExistingBathToken,
        { from: signaler }
      );

      // Call open creation function
      await bathHouseInstance.openBathTokenSpawnAndSignal(
        await newCoin.address,
        initialLiquidityNew,
        desiredPairedAsset,
        initialLiquidityExistingBathToken,
        { from: signaler }
      );
      // console.log("here's the outcome", await newbathToken);
      const newbathTokenAddress = await bathHouseInstance.getBathTokenfromAsset(
        newCoin.address
      );
      const _newBathToken = await BathToken.at(newbathTokenAddress);
      const rawUserBalance = await _newBathToken.balanceOf(accounts[1]);
      const userBalance = ethers.utils.formatUnits(
        rawUserBalance.toString(),
        decimals
      );
      should.equal(userBalance.split(".")[0], "100");
    });
  });
});
