// SPDX-License-Identifier: BUSL-1.1

/// @author Benjamin Hughes - Rubicon
/// @notice This contract acts as the admin for the Rubicon Pools system
/// @notice The BathHouse approves library contracts and initializes bathTokens
/// @notice this contract has protocol-wide, sensitive, and useful getters to map assets <> bathTokens TODO

pragma solidity =0.7.6;

// import "./BathPair.sol";
import "./BathToken.sol";
import "../interfaces/IBathPair.sol";
import "../interfaces/IBathToken.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/proxy/TransparentUpgradeableProxy.sol";

contract BathHouse {
    string public name;

    address public admin;
    address public proxyManager;

    address public RubiconMarketAddress;

    // List of approved strategies
    mapping(address => bool) public approvedStrategists;

    bool public initialized;
    bool public permissionedStrategists; //if true strategists are permissioned

    // Key, system-wide risk parameters for Pools
    uint256 public reserveRatio; // proportion of the pool that must remain present in the pair

    // The delay after which unfilled orders are cancelled
    uint256 public timeDelay; // *Deprecate post Optimism*??? Presently unused

    //NEW
    address public approvedPairContract; // Ensure that only one BathPair.sol is in operation

    //NEW
    uint8 public bpsToStrategists;

    //NEW
    mapping(address => address) public tokenToBathToken; //Source of truth mapping that logs all ERC20 Liquidity pools underlying asset => bathToken Address

    // The BathToken.sol implementation that any new bathTokens become
    address public newBathTokenImplementation;

    //NEW
    // Event to log new BathPairs and their bathTokens
    event LogNewBathToken(
        address underlyingToken,
        address bathTokenAddress,
        address bathTokenFeeAdmin,
        uint256 timestamp,
        address bathTokenCreator
    );

    event LogOpenCreationSignal(
        ERC20 newERC20Underlying,
        address spawnedBathToken,
        uint256 initialNewBathTokenDeposit,
        ERC20 pairedExistingAsset,
        address pairedExistingBathToken,
        uint256 pairedBathTokenDeposit,
        address signaler
    );

    modifier onlyAdmin() {
        require(msg.sender == admin);
        _;
    }

    /// @dev Proxy-safe initialization of storage
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
        require(_reserveRatio <= 100);
        require(_reserveRatio > 0);
        reserveRatio = _reserveRatio;

        bpsToStrategists = 20;

        RubiconMarketAddress = market;
        approveStrategist(admin);
        permissionedStrategists = true;
        initialized = true;
        newBathTokenImplementation = _newBathTokenImplementation;
        proxyManager = _proxyAdmin;
    }

    // ** Bath Token Actions **
    // **Logs the publicmapping of new ERC20 to resulting bathToken
    function createBathToken(ERC20 underlyingERC20, address _feeAdmin)
        external
        onlyAdmin
        returns (address newBathTokenAddress)
    {
        newBathTokenAddress = _createBathToken(underlyingERC20, _feeAdmin);
    }

    // **Logs the publicmapping of new ERC20 to resulting bathToken
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
        bytes memory _initData = abi.encodeWithSignature(
            "initialize(address,address,address)",
            _underlyingERC20,
            (RubiconMarketAddress),
            (_feeAdmin)
        );
        TransparentUpgradeableProxy newBathToken = new TransparentUpgradeableProxy(
                newBathTokenImplementation,
                proxyManager,
                _initData
            );

        newBathTokenAddress = address(newBathToken);
        tokenToBathToken[_underlyingERC20] = newBathTokenAddress;
        emit LogNewBathToken(
            _underlyingERC20,
            newBathTokenAddress,
            _feeAdmin,
            block.timestamp,
            msg.sender
        );
    }

    /// Permissionless entry point to spawn a bathToken while posting liquidity to a ~pair~
    /// The user must approve the bathHouse to spend their ERC20s
    function openBathTokenSpawnAndSignal(
        ERC20 newBathTokenUnderlying,
        uint256 initialLiquidityNew, // Must approve this contract to spend
        ERC20 desiredPairedAsset, // MUST be paired with an existing quote for v1
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
        address newOne = _createBathToken(newBathTokenUnderlying, address(0)); // NOTE: address(0) as feeAdmin means fee is paid to pool

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
        uint256 newBTShares = IBathToken(newOne).deposit(initialLiquidityNew);
        IBathToken(newOne).transfer(msg.sender, newBTShares);

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
        uint256 pairedPoolShares = IBathToken(pairedPool).deposit(
            initialLiquidityExistingBathToken
        );
        IBathToken(pairedPool).transfer(msg.sender, pairedPoolShares);

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

    // A migrationFunction that allows writing arbitrarily to tokenToBathToken
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

    /// Function to initialize the ~lone~ bathPair contract for the Rubicon protocol
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

    function setBathHouseAdmin(address newAdmin) external onlyAdmin {
        admin = newAdmin;
    }

    function setPermissionedStrategists(bool _new) external onlyAdmin {
        permissionedStrategists = _new;
    }

    // Setter Functions for paramters - onlyAdmin
    function setCancelTimeDelay(uint256 value) external onlyAdmin {
        timeDelay = value;
    }

    function setReserveRatio(uint256 rr) external onlyAdmin {
        require(rr <= 100);
        require(rr > 0);
        reserveRatio = rr;
    }

    function setBathTokenMarket(address bathToken, address newMarket)
        external
        onlyAdmin
    {
        IBathToken(bathToken).setMarket(newMarket);
    }

    function setBathTokenBathHouse(address bathToken, address newAdmin)
        external
        onlyAdmin
    {
        IBathToken(bathToken).setBathHouse(newAdmin);
    }

    function setBathTokenFeeBPS(address bathToken, uint256 newBPS)
        external
        onlyAdmin
    {
        IBathToken(bathToken).setFeeBPS(newBPS);
    }

    function bathTokenApproveSetMarket(address targetBathToken)
        external
        onlyAdmin
    {
        IBathToken(targetBathToken).approveMarket();
    }

    function setFeeTo(address bathToken, address feeTo) external onlyAdmin {
        IBathToken(bathToken).setFeeTo(feeTo);
    }

    function setBathPairMOSBPS(address bathPair, uint16 mosbps)
        external
        onlyAdmin
    {
        IBathPair(bathPair).setMaxOrderSizeBPS(mosbps);
    }

    function setBathPairSCN(address bathPair, int128 val) external onlyAdmin {
        IBathPair(bathPair).setShapeCoefNum(val);
    }

    function setMarket(address newMarket) external onlyAdmin {
        RubiconMarketAddress = newMarket;
    }

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

    // Return the address of any bathToken in the system with this corresponding underlying asset
    function getBathTokenfromAsset(ERC20 asset) public view returns (address) {
        return tokenToBathToken[address(asset)];
    }

    function getBPSToStrats() public view returns (uint8) {
        return bpsToStrategists;
    }

    // ** Security Checks used throughout Pools **
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

    function isApprovedPair(address pair) public view returns (bool outcome) {
        pair == approvedPairContract ? outcome = true : outcome = false;
    }

    function approveStrategist(address strategist) public onlyAdmin {
        approvedStrategists[strategist] = true;
    }
}
