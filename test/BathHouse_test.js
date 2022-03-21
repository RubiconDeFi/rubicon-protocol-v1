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
    // DEPRECATED
    // it("public uint maxOutstandingPairCount - set correctly", async () => {
    //   // TODO: clean up key inputs like 20 into variables for easier readability and testing
    //   assert.equal(await bathHouseInstance.maxOutstandingPairCount(), 20);
    // });
    it("public address approvedPairContract - set correctly", async () => {
      assert.equal(
        await bathHouseInstance.approvedPairContract(),
        bathPairInstance.address
      );
    });
    it("public uint bpsToStrategists - set correctly", async () => {
      //TODO: this is a hardcode rn
      assert.equal(await bathHouseInstance.bpsToStrategists(), 20);
    });
    it("public mapping tokenToBathToken - initializes as empty before any createBathToken calls", async () => {
      assert.equal(
        await bathHouseInstance.tokenToBathToken(DAIInstance.address),
        0
      );
    });
    it("external onlyAdmin createBathToken - correctly spawns a new bathToken", async () => {});
    it("external onlyAdmin initBathPair - correctly initializes the sole bathPair contract", async () => {});
    it("external onlyAdmin setBathHouseAdmin - can change the admin of bathHouse securely", async () => {});
    it("external onlyAdmin setPermissionedStrategists - XXXX", async () => {});
    // *** Please note if any variables are unused in the v1 system ***
    it("external onlyAdmin setReserveRatio - XXXX", async () => {});
    it("external onlyAdmin setCancelTimeDelay - XXXX", async () => {});
    it("external onlyAdmin setPropToStrats - XXX", async () => {});
    it("external onlyAdmin setMaxOutstandingPairCount - XXX", async () => {});
    it("external onlyAdmin setBathTokenMarket - XXX", async () => {});
    it("external onlyAdmin setBathTokenFeeBPS - XXX", async () => {});

    it("external onlyAdmin setFeeTo - XXX", async () => {});
    it("external onlyAdmin setBathPairMOSBPS - XXX", async () => {});
    it("external onlyAdmin setBathPairSCN - XXX", async () => {});
    it("external onlyAdmin setMarket - XXX", async () => {});
    //IS this needed??? Check to make sure no getters for public variables
    it("external view getMarket - XXX", async () => {});
    // check major variables only need getter if non public...
    it("external view getBathTokenfromAsset - XXX", async () => {});
    it("external view isApprovedStrategist - XXX", async () => {});
    it("external view isApprovedPair - XXX", async () => {});
    it("external onlyAdmin approveStrategist - XXXX", async () => {});
  });
  describe("Case-Specific Tests", async function () {
    it("public mapping approvedStrategists - can easily approve strategists", async () => {});
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
    it("BathTokens are correctly admin'd to _____ after createBathToken", async () => {});
    it("BathPairs are correctly admin'd to _____ after initialization via initBathPair", async () => {});
    it("public mapping tokenToBathToken - seamlessly maps an ERC-20 in the system to its bathToken", async () => {});
    it("** Key variables cannot be accessed by bad actors **", async () => {});
  });
  describe("Event Logging Tests", async function () {
    // Coordinate with Subgraph on this
    it("createBathToken is returning all needed and relevant data in an event", async () => {});
    it("initBathPair is returning all needed and relevant data in an event", async () => {});

    // Want to make sure that actually used/important storage variables emit a log in their change function
    // it("setAdmin emits a note on the new admin", async () => {}); // Is this needed...?
  });
});
