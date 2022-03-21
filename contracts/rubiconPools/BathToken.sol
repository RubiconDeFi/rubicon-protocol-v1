// SPDX-License-Identifier: BUSL-1.1

/// @author Benjamin Hughes - Rubicon
/// @notice This contract represents a single-asset liquidity pool for Rubicon Pools
/// @notice Any user can deposit assets into this pool and earn yield from successful strategist market making with their liquidity
/// @notice This contract looks to both BathPairs and the BathHouse as its admin

pragma solidity =0.7.6;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
// import "../RubiconMarket.sol";
import "../interfaces/IBathHouse.sol";
import "../interfaces/IRubiconMarket.sol";

contract BathToken {
    using SafeMath for uint256;
    bool public initialized;

    // ERC-20
    string public symbol;
    
    string public name;
    uint8 public decimals;

    address public RubiconMarketAddress;
    address public bathHouse; // admin
    address public feeTo;
    IERC20 public underlyingToken; // called "asset" in 4626
    uint256 public feeBPS;

    uint256 public totalSupply;
    uint256 public outstandingAmount; // quantity of underlyingToken that is in the orderbook and still in pools

    uint256[] deprecatedStorageArray; // Kept in to avoid storage collision on v0 bathTokens that are upgraded
    mapping(uint256 => uint256) deprecatedMapping; // Kept in to avoid storage collision on v0 bathTokens that are upgraded

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    bytes32 public DOMAIN_SEPARATOR;
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    mapping(address => uint256) public nonces;

    event Approval(
        address indexed owner,
        address indexed spender,
        uint256 value
    );
    event Transfer(address indexed from, address indexed to, uint256 value);
    event LogInit(uint256 timeOfInit);
    event LogDeposit(
        uint256 depositedAmt,
        IERC20 asset,
        uint256 sharesReceived,
        address depositor,
        uint256 underlyingBalance,
        uint256 outstandingAmount,
        uint256 totalSupply
    );
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
    event LogPoolCancel(
        uint256 orderId,
        IERC20 pool_asset,
        uint256 outstandingAmountToCancel,
        uint256 underlyingBalance,
        uint256 outstandingAmount,
        uint256 totalSupply
    );
    event LogPoolOffer(
        uint256 id,
        IERC20 pool_asset,
        uint256 underlyingBalance,
        uint256 outstandingAmount,
        uint256 totalSupply
    );
    event LogRemoveFilledTradeAmount(
        IERC20 pool_asset,
        uint256 fillAmount,
        uint256 underlyingBalance,
        uint256 outstandingAmount,
        uint256 totalSupply
    );

    /// @dev Proxy-safe initialization of storage
    function initialize(
        ERC20 token,
        address market,
        address _feeTo
    ) external {
        require(!initialized);
        string memory _symbol = string(
            abi.encodePacked(("bath"), token.symbol())
        );
        symbol = _symbol;
        underlyingToken = token;
        RubiconMarketAddress = market;
        bathHouse = msg.sender; //NOTE: assumed admin is creator on BathHouse

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
        name = string(abi.encodePacked(_symbol, (" v1")));
        decimals = token.decimals(); // v1 Change - 4626 Adherence

        // Add infinite approval of Rubicon Market for this asset
        IERC20(address(token)).approve(RubiconMarketAddress, 2**256 - 1);
        emit LogInit(block.timestamp);

        feeTo = _feeTo; //BathHouse admin is initial recipient
        feeBPS = 0; //Fee set to zero
        initialized = true;
    }

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

    // Admin functions, BathHouse only
    function setMarket(address newRubiconMarket) external onlyBathHouse {
        RubiconMarketAddress = newRubiconMarket;
    }

    function setBathHouse(address newBathHouse) external onlyBathHouse {
        bathHouse = newBathHouse;
    }

    // Admin only - approve my market infinitely
    function approveMarket() external onlyBathHouse {
        underlyingToken.approve(RubiconMarketAddress, 2**256 - 1);
    }

    function setFeeBPS(uint256 _feeBPS) external onlyBathHouse {
        feeBPS = _feeBPS;
    }

    function setFeeTo(address _feeTo) external onlyBathHouse {
        feeTo = _feeTo;
    }

    /// The underlying ERC-20 that this bathToken handles
    function underlyingERC20() external view returns (address) {
        // require(initialized);
        return address(underlyingToken);
    }

    /// @notice returns the amount of underlying ERC20 tokens in this pool in addition to
    ///         any tokens that may be outstanding in the Rubicon order book
    function underlyingBalance() public view returns (uint256) {
        // require(initialized, "BathToken not initialized");

        uint256 _pool = IERC20(underlyingToken).balanceOf(address(this));
        return _pool.add(outstandingAmount);
    }

    // ** Rubicon Market Functions: **
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

    // function that places a bid/ask in the orderbook for a given pair
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
            false // TODO: is this implicit post-only?
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

    // This function returns filled orders to the correct liquidity pool and sends strategist rewards to the Pair
    // Sends non-underlyingToken fill elsewhere in the Pools system, typically it's sister asset within a trading pair (e.g. ETH-USDC)
    function rebalance(
        address destination,
        address filledAssetToRebalance, /* sister or fill asset */
        uint256 stratProportion,
        uint256 rebalAmt
    ) external onlyPair {
        // require(initialized);
        uint256 stratReward = (stratProportion.mul(rebalAmt)).div(10000);
        IERC20(filledAssetToRebalance).transfer(
            destination,
            rebalAmt.sub(stratReward)
        );
        IERC20(filledAssetToRebalance).transfer(msg.sender, stratReward);

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

    // ** User Entrypoints: **
    // TODO: ensure adherence to emerging vault standard
    function deposit(uint256 _amount) external returns (uint256 shares) {
        uint256 _pool = underlyingBalance();
        uint256 _before = underlyingToken.balanceOf(address(this));

        underlyingToken.transferFrom(msg.sender, address(this), _amount);
        uint256 _after = underlyingToken.balanceOf(address(this));
        _amount = _after.sub(_before); // Additional check for deflationary tokens

        shares = 0;
        (totalSupply == 0) ? shares = _amount : shares = (
            _amount.mul(totalSupply)
        ).div(_pool);

        _mint(msg.sender, shares);
        // TODO: CHECK THAT _pool UPDATES BY CALLING underlyingBalance() WHEN SENT IN EMIT
        emit LogDeposit(
            _amount,
            underlyingToken,
            shares,
            msg.sender,
            underlyingBalance(),
            outstandingAmount,
            totalSupply
        );
    }

    // No rebalance implementation for lower fees and faster swaps
    function withdraw(uint256 _shares)
        external
        returns (uint256 amountWithdrawn)
    {
        uint256 r = (underlyingBalance().mul(_shares)).div(totalSupply);
        _burn(msg.sender, _shares);
        uint256 _fee = r.mul(feeBPS).div(10000);
        // If FeeTo == address(0) then the fee is effectively accrued by the pool
        if (feeTo != address(0)) {
            underlyingToken.transfer(feeTo, _fee);
        }
        amountWithdrawn = r.sub(_fee);
        underlyingToken.transfer(msg.sender, amountWithdrawn);

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
    }

    // ** Internal Functions **

    function _mint(address to, uint256 value) internal {
        totalSupply = totalSupply.add(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) internal {
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
        balanceOf[from] = balanceOf[from].sub(value);
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
}
