// SPDX-License-Identifier: BUSL-1.1

/// @author Rubicon DeFi Inc. - bghughes.eth
/// @notice This contract represents a single-asset liquidity pool for Rubicon Pools
/// @notice Any user can deposit assets into this pool and earn yield from successful strategist market making with their liquidity
/// @notice This contract looks to both BathPairs and the BathHouse as its admin

pragma solidity =0.7.6;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
// import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "../interfaces/IBathHouse.sol";
import "../interfaces/IRubiconMarket.sol";
import "../interfaces/IBathBuddy.sol";

contract BathToken {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /// *** Storage Variables ***

    /// @notice The initialization status of the Bath Token
    bool public initialized;

    /// @notice  ** ERC-20 **
    string public symbol;
    string public name;
    uint8 public decimals;

    /// @notice The RubiconMarket.sol instance that all pool liquidity is intially directed to as market-making offers
    address public RubiconMarketAddress;

    /// @notice The Bath House admin of the Bath Token
    address public bathHouse;

    /// @notice The withdrawal fee recipient, typically the Bath Token itself
    address public feeTo;

    /// @notice The underlying ERC-20 token which is the core asset of the Bath Token vault
    IERC20 public underlyingToken;

    /// @notice The basis point fee rate that is paid on withdrawing the underlyingToken and bonusTokens
    uint256 public feeBPS;

    /// @notice ** ERC-20 **
    uint256 public totalSupply;

    /// @notice The amount of underlying deposits that are outstanding attempting market-making on the order book for yield
    /// @dev quantity of underlyingToken that is in the orderbook that the pool still has a claim on
    /// @dev The underlyingToken is effectively mark-to-marketed when it enters the book and it could be returned at a loss due to poor strategist performance
    /// @dev outstandingAmount is NOT inclusive of any non-underlyingToken assets sitting on the Bath Tokens that have filled to here and are awaiting rebalancing to the underlyingToken by strategists
    uint256 public outstandingAmount;

    /// @dev Intentionally unused DEPRECATED STORAGE VARIABLE to maintain contiguous state on proxy-wrapped contracts. Consider it a beautiful scar of incremental progress 📈
    /// @dev Keeping deprecated variables maintains consistent network-agnostic contract abis when moving to new chains and versions
    uint256[] deprecatedStorageArray; // Kept in to avoid storage collision bathTokens that are proxy upgraded

    /// @dev Intentionally unused DEPRECATED STORAGE VARIABLE to maintain contiguous state on proxy-wrapped contracts. Consider it a beautiful scar of incremental progress 📈
    mapping(uint256 => uint256) deprecatedMapping; // Kept in to avoid storage collision on bathTokens that are upgraded
    // *******************************************

    /// @notice  ** ERC-20 **
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    /// @notice EIP-2612
    bytes32 public DOMAIN_SEPARATOR;

    /// @notice EIP-2612
    /// @dev keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    /// @notice EIP-2612
    mapping(address => uint256) public nonces;

    /// @notice Array of Bonus ERC-20 tokens that are given as liquidity incentives to pool withdrawers
    address[] public bonusTokens;

    /// @notice Address of the OZ Vesting Wallet which acts as means to vest bonusToken incentives to pool HODLers
    IBathBuddy public bathBuddy;

    /// @dev Reentrancy protection
    bool locked;

    /// *** Events ***

    /// @notice ** ERC-20 **
    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );

    /// @notice ** ERC-20 **
    event Transfer(address indexed from, address indexed to, uint256 value);

    /// @notice Time of Bath Token instantiation
    event LogInit(uint256 timeOfInit);

    /// @notice Log details about a pool deposit
    event LogDeposit(
        uint256 depositedAmt,
        IERC20 asset,
        uint256 sharesReceived,
        address depositor,
        uint256 underlyingBalance,
        uint256 outstandingAmount,
        uint256 totalSupply
    );

    /// @notice Log details about a pool withdraw
    event LogWithdraw(
        uint256 amountWithdrawn,
        IERC20 asset,
        uint256 sharesWithdrawn,
        address withdrawer,
        uint256 fee,
        address feeTo,
        uint256 underlyingBalance,
        uint256 outstandingAmount,
        uint256 totalSupply
    );

    /// @notice Log details about a pool rebalance
    event LogRebalance(
        IERC20 pool_asset,
        address destination,
        IERC20 transferAsset,
        uint256 rebalAmt,
        uint256 stratReward,
        uint256 underlyingBalance,
        uint256 outstandingAmount,
        uint256 totalSupply
    );

    /// @notice Log details about a pool order canceled in the Rubicon Market book
    event LogPoolCancel(
        uint256 orderId,
        IERC20 pool_asset,
        uint256 outstandingAmountToCancel,
        uint256 underlyingBalance,
        uint256 outstandingAmount,
        uint256 totalSupply
    );

    /// @notice Log details about a pool order placed in the Rubicon Market book
    event LogPoolOffer(
        uint256 id,
        IERC20 pool_asset,
        uint256 underlyingBalance,
        uint256 outstandingAmount,
        uint256 totalSupply
    );

    /// @notice Log the credit to outstanding amount for funds that have been filled market-making
    event LogRemoveFilledTradeAmount(
        IERC20 pool_asset,
        uint256 fillAmount,
        uint256 underlyingBalance,
        uint256 outstandingAmount,
        uint256 totalSupply
    );

    /// @notice * EIP 4626 *
    event Deposit(
        address indexed caller,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    /// @notice * EIP 4626 *
    event Withdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares
    );

    /// @notice Log bonus token reward event
    event LogClaimBonusTokn(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assets,
        uint256 shares,
        IERC20 bonusToken
    );

    /// *** Constructor ***

    /// @notice Proxy-safe initialization of storage; the constructor
    function initialize(
        ERC20 token,
        address market,
        address _feeTo
    ) external nonReentrant {
        require(!initialized);
        string memory _symbol = string(
            abi.encodePacked(("bath"), token.symbol())
        );
        symbol = _symbol;
        underlyingToken = token;
        RubiconMarketAddress = market;
        bathHouse = msg.sender; //NOTE: assumed admin is creator on BathHouse

        name = string(abi.encodePacked(_symbol, (" v1")));
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                chainId,
                address(this)
            )
        );
        decimals = token.decimals(); // v1 Change - 4626 Adherence

        // Complete constract instantiation via CEI pattern
        initialized = true;

        // Add infinite approval of Rubicon Market for this asset
        IERC20(address(token)).approve(RubiconMarketAddress, 2**256 - 1);
        emit LogInit(block.timestamp);

        feeTo = address(this); //This contract is the fee recipient, rewarding HODLers
        feeBPS = 3; //Fee set to 3 BPS initially
    }

    /// *** Modifiers ***

    modifier onlyPair() {
        require(
            IBathHouse(bathHouse).isApprovedPair(msg.sender) == true,
            "not an approved pair - bathToken"
        );
        _;
    }

    modifier onlyBathHouse() {
        require(
            msg.sender == bathHouse,
            "caller is not bathHouse - BathToken.sol"
        );
        _;
    }

    /// @dev nonReentrant
    modifier nonReentrant() {
        require(!locked);
        locked = true;
        _;
        locked = false;
    }

    /// *** External Functions - Only Bath House / Admin ***

    /// @notice Admin-only function to set a Bath Token's market address
    function setMarket(address newRubiconMarket) external onlyBathHouse {
        RubiconMarketAddress = newRubiconMarket;
    }

    /// @notice Admin-only function to set a Bath Token's Bath House admin
    function setBathHouse(address newBathHouse) external onlyBathHouse {
        bathHouse = newBathHouse;
    }

    /// @notice Admin-only function to approve Bath Token's RubiconMarketAddress with the maximum integer value (infinite approval)
    function approveMarket() external onlyBathHouse {
        underlyingToken.approve(RubiconMarketAddress, 2**256 - 1);
    }

    /// @notice Admin-only function to set a Bath Token's feeBPS
    function setFeeBPS(uint256 _feeBPS) external onlyBathHouse {
        require(_feeBPS <= 300, "Fee can never exceed 300 bps");
        feeBPS = _feeBPS;
    }

    /// @notice Admin-only function to set a Bath Token's fee recipient, typically the pool itself
    function setFeeTo(address _feeTo) external onlyBathHouse {
        feeTo = _feeTo;
    }

    /// @notice Admin-only function to set THE BathBuddy which holds all ERC20 rewards
    function setBathBuddy(address newBuddy) external onlyBathHouse {
        bathBuddy = IBathBuddy(newBuddy);
    }

    /// @notice Admin-only function to add a bonus token to bonusTokens for pool incentives
    function setBonusToken(address newBonusERC20) external onlyBathHouse {
        bonusTokens.push(newBonusERC20);
        require(bonusTokens.length < 5, "too many tokens in this party");
    }

    /// *** External Functions - Only Approved Bath Pair / Strategist Contract ***

    /// ** Rubicon Market Functions **

    /// @notice The function for a strategist to cancel an outstanding Market Offer
    function cancel(uint256 id, uint256 amt) external onlyPair {
        outstandingAmount = outstandingAmount.sub(amt);
        IRubiconMarket(RubiconMarketAddress).cancel(id);

        emit LogPoolCancel(
            id,
            IERC20(underlyingToken),
            amt,
            underlyingBalance(),
            outstandingAmount,
            totalSupply
        );
    }

    /// @notice A function called by BathPair to maintain proper accounting of outstandingAmount
    function removeFilledTradeAmount(uint256 amt) external onlyPair {
        outstandingAmount = outstandingAmount.sub(amt);
        emit LogRemoveFilledTradeAmount(
            IERC20(underlyingToken),
            amt,
            underlyingBalance(),
            outstandingAmount,
            totalSupply
        );
    }

    /// @notice The function that places a bid and/or ask in the orderbook for a given pair from this pool
    function placeOffer(
        uint256 pay_amt,
        ERC20 pay_gem,
        uint256 buy_amt,
        ERC20 buy_gem
    ) external onlyPair returns (uint256) {
        // Place an offer in RubiconMarket
        // If incomplete offer return 0
        if (
            pay_amt == 0 ||
            pay_gem == ERC20(0) ||
            buy_amt == 0 ||
            buy_gem == ERC20(0)
        ) {
            return 0;
        }

        uint256 id = IRubiconMarket(RubiconMarketAddress).offer(
            pay_amt,
            pay_gem,
            buy_amt,
            buy_gem,
            0,
            false
        );
        outstandingAmount = outstandingAmount.add(pay_amt);

        emit LogPoolOffer(
            id,
            IERC20(underlyingToken),
            underlyingBalance(),
            outstandingAmount,
            totalSupply
        );
        return (id);
    }

    /// @notice This function returns filled orders to the correct liquidity pool and sends strategist rewards to the Bath Pair
    /// @dev Sends non-underlyingToken fill elsewhere in the Pools system, typically it's sister asset within a trading pair (e.g. ETH-USDC)
    /// @dev Strategists presently accrue rewards in the filled asset not underlyingToken
    function rebalance(
        address destination,
        address filledAssetToRebalance, /* sister or fill asset */
        uint256 stratProportion,
        uint256 rebalAmt
    ) external onlyPair {
        require(filledAssetToRebalance != asset(), "must not be underlying");
        uint256 stratReward = (stratProportion.mul(rebalAmt)).div(10000);
        IERC20(filledAssetToRebalance).safeTransfer(
            destination,
            rebalAmt.sub(stratReward)
        );
        IERC20(filledAssetToRebalance).safeTransfer(msg.sender, stratReward);

        emit LogRebalance(
            IERC20(underlyingToken),
            destination,
            IERC20(filledAssetToRebalance),
            rebalAmt,
            stratReward,
            underlyingBalance(),
            outstandingAmount,
            totalSupply
        );
    }

    /// *** EIP 4626 Implementation ***
    // https://eips.ethereum.org/EIPS/eip-4626#specification

    /// @notice Withdraw your bathTokens for the underlyingToken
    function withdraw(uint256 _shares)
        external
        nonReentrant
        returns (uint256 amountWithdrawn)
    {
        return _withdraw(_shares, msg.sender);
    }

    /// @notice * EIP 4626 *
    function asset() public view returns (address assetTokenAddress) {
        assetTokenAddress = address(underlyingToken);
    }

    /// @notice * EIP 4626 *
    function totalAssets() public view returns (uint256 totalManagedAssets) {
        return underlyingBalance();
    }

    /// @notice * EIP 4626 *
    function convertToShares(uint256 assets)
        public
        view
        returns (uint256 shares)
    {
        // Note: Inflationary tokens may affect this logic
        (totalSupply == 0) ? shares = assets : shares = (
            assets.mul(totalSupply)
        ).div(totalAssets());
    }

    // Note: MUST NOT be inclusive of any fees that are charged against assets in the Vault.
    /// @notice * EIP 4626 *
    function convertToAssets(uint256 shares)
        public
        view
        returns (uint256 assets)
    {
        assets = (totalAssets().mul(shares)).div(totalSupply);
    }

    // Note: Unused function param to adhere to standard
    /// @notice * EIP 4626 *
    function maxDeposit(address receiver)
        public
        pure
        returns (uint256 maxAssets)
    {
        maxAssets = 2**256 - 1; // No limit on deposits in current implementation  = Max UINT
    }

    /// @notice * EIP 4626 *
    function previewDeposit(uint256 assets)
        public
        view
        returns (uint256 shares)
    {
        // The exact same logic is used, no deposit fee - only difference is deflationary token check (rare condition and probably redundant)
        shares = convertToShares(assets);
    }

    // Single asset override to reflect old functionality
    function deposit(uint256 assets)
        public
        nonReentrant
        returns (uint256 shares)
    {
        // Note: msg.sender is the same throughout the same contract context
        return _deposit(assets, msg.sender);
    }

    /// @notice * EIP 4626 *
    function deposit(uint256 assets, address receiver)
        public
        nonReentrant
        returns (uint256 shares)
    {
        return _deposit(assets, receiver);
    }

    // Note: Unused function param to adhere to standard
    /// @notice * EIP 4626 *
    function maxMint(address receiver) public pure returns (uint256 maxShares) {
        maxShares = 2**256 - 1; // No limit on shares that could be created via deposit in current implementation - Max UINT
    }

    // Given I want these shares, how much do I have to deposit
    /// @notice * EIP 4626 *
    function previewMint(uint256 shares) public view returns (uint256 assets) {
        (totalSupply == 0) ? assets = shares : assets = (
            shares.mul(totalAssets())
        ).div(totalSupply);
    }

    // Mints exactly shares Vault shares to receiver by depositing amount of underlying tokens.
    /// @notice * EIP 4626 *
    function mint(uint256 shares, address receiver)
        public
        nonReentrant
        returns (uint256 assets)
    {
        assets = previewMint(shares);
        uint256 _shares = _deposit(assets, receiver);
        require(_shares == shares, "did not mint expected share count");
    }

    // A user can withdraw whatever they hold
    /// @notice * EIP 4626 *
    function maxWithdraw(address owner)
        public
        view
        returns (uint256 maxAssets)
    {
        if (totalSupply == 0) {
            maxAssets = 0;
        } else {
            uint256 ownerShares = balanceOf[owner];
            maxAssets = convertToAssets(ownerShares);
        }
    }

    /// @notice * EIP 4626 *
    function previewWithdraw(uint256 assets)
        public
        view
        returns (uint256 shares)
    {
        if (totalSupply == 0) {
            shares = 0;
        } else {
            shares = convertToShares(
                assets.add(assets.mul(feeBPS).div((uint256(10000).sub(feeBPS))))
            );
        }
    }

    /// @notice * EIP 4626 *
    function withdraw(
        uint256 assets,
        address receiver,
        address owner
    ) public nonReentrant returns (uint256 shares) {
        require(
            owner == msg.sender,
            "This implementation does not support non-sender owners from withdrawing user shares"
        );
        uint256 expectedShares = previewWithdraw(assets);
        uint256 assetsReceived = _withdraw(expectedShares, receiver);
        require(
            assetsReceived >= assets,
            "You cannot withdraw the amount of assets you expected"
        );
        shares = expectedShares;
    }

    // Constraint: msg.sender is owner of shares when withdrawing
    /// @notice * EIP 4626 *
    function maxRedeem(address owner) public view returns (uint256 maxShares) {
        return balanceOf[owner];
    }

    // Constraint: msg.sender is owner of shares when withdrawing
    /// @notice * EIP 4626 *
    function previewRedeem(uint256 shares)
        public
        view
        returns (uint256 assets)
    {
        uint256 r = (underlyingBalance().mul(shares)).div(totalSupply);
        uint256 _fee = r.mul(feeBPS).div(10000);
        assets = r.sub(_fee);
    }

    /// @notice * EIP 4626 *
    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public nonReentrant returns (uint256 assets) {
        require(
            owner == msg.sender,
            "This implementation does not support non-sender owners from withdrawing user shares"
        );
        assets = _withdraw(shares, receiver);
    }

    /// *** Internal Functions ***

    /// @notice Deposit assets for the user and mint Bath Token shares to receiver
    function _deposit(uint256 assets, address receiver)
        internal
        returns (uint256 shares)
    {
        uint256 _pool = underlyingBalance();
        uint256 _before = underlyingToken.balanceOf(address(this));

        // **Assume caller is depositor**
        underlyingToken.safeTransferFrom(msg.sender, address(this), assets);
        uint256 _after = underlyingToken.balanceOf(address(this));
        assets = _after.sub(_before); // Additional check for deflationary tokens

        if (totalSupply == 0) {
            uint256 minLiquidityShare = 10**3;
            shares = assets.sub(minLiquidityShare);
            // Handle protecting from an initial supply spoof attack
            _mint(address(0), (minLiquidityShare));
        } else {
            shares = (assets.mul(totalSupply)).div(_pool);
        }

        // Send shares to designated target
        _mint(receiver, shares);

        require(shares != 0, "No shares minted");
        emit LogDeposit(
            assets,
            underlyingToken,
            shares,
            msg.sender,
            underlyingBalance(),
            outstandingAmount,
            totalSupply
        );
        emit Deposit(msg.sender, msg.sender, assets, shares);
    }

    /// @dev assumes that msg.sender is the shareholder
    /// @notice Withdraw share for the user and send underlyingToken to receiver with any accrued yield and incentive tokens
    function _withdraw(uint256 _shares, address receiver)
        internal
        returns (uint256 amountWithdrawn)
    {
        uint256 r = (underlyingBalance().mul(_shares)).div(totalSupply);
        _burn(msg.sender, _shares);
        uint256 _fee = r.mul(feeBPS).div(10000);
        // If FeeTo == address(0) then the fee is effectively accrued by the pool
        if (feeTo != address(0)) {
            underlyingToken.safeTransfer(feeTo, _fee);
        }
        amountWithdrawn = r.sub(_fee);
        underlyingToken.safeTransfer(receiver, amountWithdrawn);

        emit LogWithdraw(
            amountWithdrawn,
            underlyingToken,
            _shares,
            msg.sender,
            _fee,
            feeTo,
            underlyingBalance(),
            outstandingAmount,
            totalSupply
        );
        emit Withdraw(
            msg.sender,
            receiver,
            msg.sender,
            amountWithdrawn,
            _shares
        );
    }

    // // User can recieve the awards they have accrued on BathBuddy
    function getBonusTokenReward(address rewardToken) public {
        IBathBuddy(bathBuddy).getReward(IERC20(rewardToken), msg.sender);
    }

    // // User can recieve the awards they have accrued on BathBuddy
    function getAllBonusTokenReward() public {
        distributeBonusTokenRewards(msg.sender);
    }

    /// Must allow the custom receiver option of the 4626 withdraw call path
    /// @notice Function to distibute non-underlyingToken Bath Token incentives to pool withdrawers
    /// @dev Note that bonusTokens adhere to the same feeTo and feeBPS pattern
    /// @dev Note the edge case in which the bonus token is the underlyingToken, here we simply release() to the pool and skip
    function distributeBonusTokenRewards(address receiver) internal {
        // Note, receiver must be owner <- enforced in the two withdraw entry paths
        // require(msg.sender == receiver, "You cannot claim someone else`s bonus tokens");
        // Verbose check:
        // require(initialTotalSupply == sharesWithdrawn + totalSupply);
        if (bonusTokens.length > 0) {
            for (uint256 index = 0; index < bonusTokens.length; index++) {
                IERC20 token = IERC20(bonusTokens[index]);
                require(address(token) != address(0), "bad bonus token");
                // Hit BathBuddy permissioned, nonReentrant function to handle paying out
                IBathBuddy(bathBuddy).getReward(token, receiver);

                emit LogClaimBonusTokn(
                    msg.sender,
                    receiver,
                    msg.sender,
                    IBathBuddy(bathBuddy).earned(msg.sender, address(token)),
                    balanceOf[msg.sender],
                    token
                );
            }
        }
    }

    /// *** ERC - 20 Standard ***

    function _mint(address to, uint256 value) internal {
        // Used for bonus token accounting
        distributeBonusTokenRewards(to);
        totalSupply = totalSupply.add(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) internal {
        // Used for bonus token accounting
        distributeBonusTokenRewards(from);
        balanceOf[from] = balanceOf[from].sub(value);
        totalSupply = totalSupply.sub(value);
        emit Transfer(from, address(0), value);
    }

    function _approve(
        address owner,
        address spender,
        uint256 value
    ) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _transfer(
        address from,
        address to,
        uint256 value
    ) private {
        // Bonus tokens
        distributeBonusTokenRewards(from);
        balanceOf[from] = balanceOf[from].sub(value);
        // Bonus tokens
        distributeBonusTokenRewards(to);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(from, to, value);
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool) {
        if (allowance[from][msg.sender] != uint256(-1)) {
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(
                value
            );
        }
        _transfer(from, to, value);
        return true;
    }

    /// @notice EIP 2612
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(deadline >= block.timestamp, "bathToken: EXPIRED");
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(
                    abi.encode(
                        PERMIT_TYPEHASH,
                        owner,
                        spender,
                        value,
                        nonces[owner]++,
                        deadline
                    )
                )
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(
            recoveredAddress != address(0) && recoveredAddress == owner,
            "bathToken: INVALID_SIGNATURE"
        );
        _approve(owner, spender, value);
    }

    /// *** View Functions ***

    /// @notice The underlying ERC-20 that this bathToken handles
    function underlyingERC20() external view returns (address) {
        return address(underlyingToken);
    }

    /// @notice The best-guess total claim on assets the Bath Token has
    /// @dev returns the amount of underlying ERC20 tokens in this pool in addition to any tokens that are outstanding in the Rubicon order book seeking market-making yield (outstandingAmount)
    function underlyingBalance() public view returns (uint256) {
        uint256 _pool = IERC20(underlyingToken).balanceOf(address(this));
        return _pool.add(outstandingAmount);
    }
}
