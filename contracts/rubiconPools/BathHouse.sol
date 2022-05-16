// SPDX-License-Identifier: BUSL-1.1

/// @title  The administrator contract of Rubicon Pools
/// @author Rubicon DeFi Inc. - bghughes.eth
/// @notice The BathHouse initializes proxy-wrapped bathTokens, manages approved strategists, and sets system variables

pragma solidity =0.7.6;

import "./BathToken.sol";
import "../interfaces/IBathPair.sol";
import "../interfaces/IBathToken.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/TransparentUpgradeableProxy.sol";

contract BathHouse {
    /// *** Storage Variables ***

    /// @notice Rubicon Bath House
    string public name;

    /// @notice The administrator of the Bath House contract
    address public admin;

    /// @notice The proxy administrator of Bath Tokens
    address public proxyManager;

    /// @notice The core Rubicon Market of the Pools system
    address public RubiconMarketAddress;

    /// @notice A mapping of approved strategists to access Pools liquidity
    mapping(address => bool) public approvedStrategists;

    /// @notice The initialization status of BathHouse
    bool public initialized;

    /// @notice If true, strategists are permissioned and must be approved by admin
    bool public permissionedStrategists;

    /// @notice Key, system-wide risk parameter for all liquity Pools
    /// @notice This represents the proportion of a pool's underlying assets that must remain in the pool
    /// @dev This protects a run on the bank scenario and ensures users can withdraw while allowing funds to be utilized for yield in the market
    uint256 public reserveRatio;

    /// @notice A variable time delay after which a strategist must return funds to the Bath Token
    uint256 public timeDelay;

    /// @notice The lone Bath Pair contract of the system which acts as the strategist entry point and logic contract
    address public approvedPairContract;

    /// @notice The basis point fee that is paid to strategists from LPs on capital that is successfully rebalanced to a Bath Token
    uint8 public bpsToStrategists;

    /// @notice Key mapping for determining the address of a Bath Token based on its underlying asset
    /// @dev Source of truth mapping that logs all ERC20 Liquidity pools underlying asset => bathToken Address
    mapping(address => address) public tokenToBathToken;

    /// @notice The BathToken.sol implementation that any new bathTokens inherit
    /// @dev The implementation of any ~newly spawned~ proxy-wrapped Bath Tokens via _createBathToken
    address public newBathTokenImplementation;

    /// *** Events ***

    /// @notice An event that signals the creation of a new Bath Token
    event LogNewBathToken(
        address underlyingToken,
        address bathTokenAddress,
        address bathTokenFeeAdmin,
        uint256 timestamp,
        address bathTokenCreator
    );

    /// @notice An event that signals the permissionless spawning of a new Bath Token
    event LogOpenCreationSignal(
        ERC20 newERC20Underlying,
        address spawnedBathToken,
        uint256 initialNewBathTokenDeposit,
        ERC20 pairedExistingAsset,
        address pairedExistingBathToken,
        uint256 pairedBathTokenDeposit,
        address signaler
    );

    /// *** Modifiers ***

    /// @notice This modifier enforces that only the admin can call these functions
    modifier onlyAdmin() {
        require(msg.sender == admin);
        _;
    }

    /// *** External Functions ***

    /// @notice The constructor-like initialization function
    /// @dev Proxy-safe initialization of storage that sets key storage variables
    /// @dev Admin is set to msg.sender
    function initialize(
        address market,
        uint256 _reserveRatio,
        uint256 _timeDelay,
        address _newBathTokenImplementation,
        address _proxyAdmin
    ) external {
        require(!initialized);
        name = "Rubicon Bath House";
        admin = msg.sender;
        timeDelay = _timeDelay;

        // Set Bath Token reserve ratio globally
        require(_reserveRatio <= 100);
        require(_reserveRatio > 0);
        reserveRatio = _reserveRatio;

        // Set BPS reward fee for successful strategist market-making
        /// @notice [(10000 - {bpsToStrategists}) / 10000] BPS of MM-ing activity is passed to users
        bpsToStrategists = 20;

        // Set key storage variables
        RubiconMarketAddress = market;
        permissionedStrategists = true;
        newBathTokenImplementation = _newBathTokenImplementation;
        proxyManager = _proxyAdmin;

        // Automatically approve admin as an approved strategist
        approveStrategist(admin);

        // Complete contract instantiation
        initialized = true;
    }

    /// @notice Permissionless entry point to spawn a Bath Token while posting liquidity to a ~pair of Bath Tokens~
    /// @notice Please note, creating a Bath Token in this fashion ~does not~ gaurentee markets will be made for the new pair. This function signals the desire to have a new pair supported on Rubicon for strategists to consider market-making for
    /// @notice The best desiredPairedAsset to select is a popular quote currency. Many traditional systems quote in USD while the ETH quote is superior - the choice is yours sweet msg.sender
    /// @dev The user must approve the bathHouse to spend their ERC20s
    /// @dev The user can only spawn a Bath Token for an ERC20 that is not yet in the Pools system and they must post liquidity on the other side of the pair for an ~extant Bath Token~
    function openBathTokenSpawnAndSignal(
        ERC20 newBathTokenUnderlying,
        uint256 initialLiquidityNew, // Must approve this contract to spend
        ERC20 desiredPairedAsset, // Must be paired with an existing quote for v1
        uint256 initialLiquidityExistingBathToken
    ) external returns (address newBathToken) {
        // Check that it doesn't already exist
        require(
            getBathTokenfromAsset(newBathTokenUnderlying) == address(0),
            "bathToken already exists for that ERC20"
        );
        require(
            getBathTokenfromAsset(desiredPairedAsset) != address(0),
            "bathToken does not exist for that desiredPairedAsset"
        );

        // Spawn a bathToken for the new asset
        address newOne = _createBathToken(newBathTokenUnderlying, address(0)); // NOTE: address(0) as feeAdmin means fee is paid to pool holders

        // Deposit initial liquidity posted of newBathTokenUnderlying
        require(
            newBathTokenUnderlying.transferFrom(
                msg.sender,
                address(this),
                initialLiquidityNew
            ),
            "Couldn't transferFrom your initial liquidity - make sure to approve BathHouse.sol"
        );

        newBathTokenUnderlying.approve(newOne, initialLiquidityNew);

        // Deposit assets and send Bath Token shares to msg.sender
        IBathToken(newOne).deposit(initialLiquidityNew, msg.sender);

        // desiredPairedAsset must be pulled and deposited into bathToken
        require(
            desiredPairedAsset.transferFrom(
                msg.sender,
                address(this),
                initialLiquidityExistingBathToken
            ),
            "Couldn't transferFrom your initial liquidity - make sure to approve BathHouse.sol"
        );
        address pairedPool = getBathTokenfromAsset((desiredPairedAsset));
        desiredPairedAsset.approve(
            pairedPool,
            initialLiquidityExistingBathToken
        );

        // Deposit assets and send Bath Token shares to msg.sender
        IBathToken(pairedPool).deposit(
            initialLiquidityExistingBathToken,
            msg.sender
        );

        // emit an event describing the new pair, underlyings and bathTokens
        emit LogOpenCreationSignal(
            newBathTokenUnderlying,
            newOne,
            initialLiquidityNew,
            desiredPairedAsset,
            pairedPool,
            initialLiquidityExistingBathToken,
            msg.sender
        );

        newBathToken = newOne;
    }

    /// ** Admin-Only Functions **

    /// @notice An admin-only function to create a new Bath Token for any ERC20
    function createBathToken(ERC20 underlyingERC20, address _feeAdmin)
        external
        onlyAdmin
        returns (address newBathTokenAddress)
    {
        newBathTokenAddress = _createBathToken(underlyingERC20, _feeAdmin);
    }

    /// @notice A migration function that allows the admin to write arbitrarily to tokenToBathToken
    function adminWriteBathToken(ERC20 overwriteERC20, address newBathToken)
        external
        onlyAdmin
    {
        tokenToBathToken[address(overwriteERC20)] = newBathToken;
        emit LogNewBathToken(
            address(overwriteERC20),
            newBathToken,
            address(0),
            block.timestamp,
            msg.sender
        );
    }

    /// @notice Function to initialize and store the address of the ~lone~ bathPair contract for the Rubicon protocol
    function initBathPair(
        address _bathPairAddress,
        uint256 _maxOrderSizeBPS,
        int128 _shapeCoefNum
    ) external onlyAdmin returns (address newPair) {
        require(
            approvedPairContract == address(0),
            "BathPair already approved"
        );
        require(
            IBathPair(_bathPairAddress).initialized() != true,
            "BathPair already initialized"
        );
        newPair = _bathPairAddress;

        IBathPair(newPair).initialize(_maxOrderSizeBPS, _shapeCoefNum);

        approvedPairContract = newPair;
    }

    /// @notice Admin-only function to set a new Admin
    function setBathHouseAdmin(address newAdmin) external onlyAdmin {
        admin = newAdmin;
    }

    /// @notice Admin-only function to approve a new permissioned strategist
    function approveStrategist(address strategist) public onlyAdmin {
        approvedStrategists[strategist] = true;
    }

    /// @notice Admin-only function to set whether or not strategists are permissioned
    function setPermissionedStrategists(bool _new) external onlyAdmin {
        permissionedStrategists = _new;
    }

    /// @notice Admin-only function to set timeDelay
    function setCancelTimeDelay(uint256 value) external onlyAdmin {
        timeDelay = value;
    }

    /// @notice Admin-only function to set reserveRatio
    function setReserveRatio(uint256 rr) external onlyAdmin {
        require(rr <= 100);
        require(rr > 0);
        reserveRatio = rr;
    }

    /// @notice Admin-only function to set a Bath Token's timeDelay
    function setBathTokenMarket(address bathToken, address newMarket)
        external
        onlyAdmin
    {
        IBathToken(bathToken).setMarket(newMarket);
    }

    /// @notice Admin-only function to add a bonus token to a Bath Token's reward schema
    function setBonusToken(address bathToken, address newBonusToken)
        external
        onlyAdmin
    {
        IBathToken(bathToken).setBonusToken(newBonusToken);
    }

    /// @notice Admin-only function to set a Bath Token's Bath House admin
    function setBathTokenBathHouse(address bathToken, address newAdmin)
        external
        onlyAdmin
    {
        IBathToken(bathToken).setBathHouse(newAdmin);
    }

    /// @notice Admin-only function to set a Bath Token's feeBPS
    function setBathTokenFeeBPS(address bathToken, uint256 newBPS)
        external
        onlyAdmin
    {
        IBathToken(bathToken).setFeeBPS(newBPS);
    }

    /// @notice Admin-only function to approve the Bath Token's underlying token on the assigned market
    /// @dev required in case the market address ever changes.. #battleScars
    function bathTokenApproveSetMarket(address targetBathToken)
        external
        onlyAdmin
    {
        IBathToken(targetBathToken).approveMarket();
    }

    /// @notice Admin-only function to set a Bath Token's fee recipient (typically the Bath Token itself)
    function setBathTokenFeeTo(address bathToken, address feeTo)
        external
        onlyAdmin
    {
        IBathToken(bathToken).setFeeTo(feeTo);
    }

    /// @notice Admin-only function to set a Bath Token's target Rubicon Market
    function setMarket(address newMarket) external onlyAdmin {
        RubiconMarketAddress = newMarket;
    }

    /// *** View Functions ***

    // Getter Functions for parameters
    function getMarket() external view returns (address) {
        return RubiconMarketAddress;
    }

    function getReserveRatio() external view returns (uint256) {
        return reserveRatio;
    }

    function getCancelTimeDelay() external view returns (uint256) {
        return timeDelay;
    }

    /// @notice Returns the address of any bathToken in the system based on its corresponding underlying asset
    function getBathTokenfromAsset(ERC20 asset) public view returns (address) {
        return tokenToBathToken[address(asset)];
    }

    function getBPSToStrats() public view returns (uint8) {
        return bpsToStrategists;
    }

    /// *** System Security Checks ***

    /// @notice A function to check whether or not an address is an approved strategist
    function isApprovedStrategist(address wouldBeStrategist)
        external
        view
        returns (bool)
    {
        if (
            approvedStrategists[wouldBeStrategist] == true ||
            !permissionedStrategists
        ) {
            return true;
        } else {
            return false;
        }
    }

    /// @notice A function to check whether or not an address is the approved system instance of BathPair.sol
    function isApprovedPair(address pair) public view returns (bool outcome) {
        pair == approvedPairContract ? outcome = true : outcome = false;
    }

    /// *** Internal Functions ***

    /// @dev Low-level functionality to spawn a Bath Token using the OZ Transparent Upgradeable Proxy standard
    /// @param underlyingERC20 The underlying ERC-20 asset that underlies the newBathTokenAddress
    /// @param _feeAdmin Recipient of pool withdrawal fees, typically the pool itself
    function _createBathToken(ERC20 underlyingERC20, address _feeAdmin)
        internal
        returns (address newBathTokenAddress)
    {
        require(initialized, "BathHouse not initialized");
        address _underlyingERC20 = address(underlyingERC20);
        require(
            _underlyingERC20 != address(0),
            "Cant create bathToken for zero address"
        );

        // Check that it isn't already logged in the registry
        require(
            tokenToBathToken[_underlyingERC20] == address(0),
            "bathToken already exists"
        );

        // Creates a new bathToken that is upgradeable by the proxyManager
        require(
            newBathTokenImplementation != address(0),
            "no implementation set for bathTokens"
        );

        // Note, the option of a fee recipient for pool withdrawls exists. For all pools this is set to the pool itself in production and is visible via ~feeTo~ on any respective contract
        // Note, fee admin presently ignored in the Bath Token initialization() call via defaulting to itself; though, this is still upgradeable by the Bath House admin via
        bytes memory _initData = abi.encodeWithSignature(
            "initialize(address,address,address)",
            _underlyingERC20,
            (RubiconMarketAddress),
            (_feeAdmin)
        );


            TransparentUpgradeableProxy newBathToken
         = new TransparentUpgradeableProxy(
            newBathTokenImplementation,
            proxyManager,
            _initData
        );

        // New Bath Token Address
        newBathTokenAddress = address(newBathToken);

        // Write to source-of-truth router mapping for this ERC-20 => Bath Token
        tokenToBathToken[_underlyingERC20] = newBathTokenAddress;

        // Log Data
        emit LogNewBathToken(
            _underlyingERC20,
            newBathTokenAddress,
            _feeAdmin,
            block.timestamp,
            msg.sender
        );
    }
}
