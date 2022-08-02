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
// - TODO: need to add ***** arbitrary bathToken reward ERC-20s **

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
  describe("Unit Tests", async function () {
    it("bool public initialized; - XXX", async () => {});
    it("string public symbol; - set correctly", async () => {});
    it("string public name; - set correctly", async () => {});
    it("uint8 public decimals; - set correctly", async () => {});
    it("address public RubiconMarketAddress; - set correctly", async () => {});
    it("address public bathHouse; - set correctly", async () => {});
    it("address public feeTo; - set correctly", async () => {});
    it("IERC20 public underlyingToken; - set correctly!", async () => {});
    // TODO: verify the way in which these feeBPS map around...
    it("uint256 public feeBPS; - set correctly", async () => {});
    it("uint256 public totalSupply; - increments correctly with new deposits", async () => {});
    it("uint256 public outstandingAmount; - losslessly tracks outstanding liquidity", async () => {});
    it("*** go for the Permit variables to verify ***??", async () => {});
    it("function setMarket(address newRubiconMarket) external { - works as expected", async () => {});
    it("function setBathHouse(address newBathHouse) external { - works as expected", async () => {});
    it("function setFeeBPS(uint256 _feeBPS) external { - works as expected", async () => {});
    it("function setFeeTo(address _feeTo) external { - works as expected", async () => {});
    it("function underlying() external view returns (address) { - works as expected", async () => {});
    it("function underlyingBalance() public view returns (uint256) { - works as expected", async () => {});
    it("function cancel(uint256 id, uint256 amt) external onlyPair { - works as expected", async () => {});
    it("function removeFilledTradeAmount(uint256 amt) external onlyPair { - works as expected", async () => {});
    it("function placeOffer( uint256 pay_amt, ERC20 pay_gem, uint256 buy_amt, ERC20 buy_gem) external onlyPair returns (uint256) { - works as expected", async () => {});
    it("function rebalance( address sisterBath, address underlyingAsset, /* sister asset */ uint256 stratProportion, uint256 rebalAmt) external onlyPair { - works as expected", async () => {});
    it("function deposit(uint256 _amount) external returns (uint256 shares) { - works as expected", async () => {});
    it("function withdraw(uint256 _shares) external returns (uint256 amountWithdrawn) { - works as expected", async () => {});
    // Make requiring initialization a modifier or assume it ? just revisit
    it("function approveMarket() external {", async () => {});
  });
  describe("Case-Specific Tests", async function () {
    it("A user is minted the right amount of shares when depositing", async () => {});
    it("Utilization/outstanding orders cause none (or minor?) variation in the mint/withdraw ratio", async () => {});
    it("A user withdraws assets at the correct ratio", async () => {});
    it("A strategist cannot exceed the reserve ratio of this pool ? TODO/Revisit", async () => {});
    it("Arbitrary tokens can be earned as yield and passed to shareholders", async () => {});
    it("In what situation can the share model or yield accrual be exploited?", async () => {});
    it("Ensure that permissionless pool creation is possible though onlyApproved strategists can do anything with ERC-20 liquidity", async () => {});
  });
  describe("Event Logging Tests", async function () {
    it("ALL ERC-20 actions capture an event", async () => {});
    it("All deposits capture all relevant info and some added data for performance tracking", async () => {});
    it("All withdraws capture all relevant info and some added data for performance tracking", async () => {});
    it("Any time funds are removed from the pool we know about it", async () => {});
    it("Any time funds are returned to the pool we know about it", async () => {});
    it("Any time a bathToken is spawned we capture all needed info in an event", async () => {}); // could be bathhouse
  });
});
