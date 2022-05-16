// SPDX-License-Identifier: BUSL-1.1

/// @author Rubicon DeFi Inc. - bghughes.eth
/// @notice This contract allows a strategist to use user funds in order to market make for a Rubicon pair
/// @notice The BathPair is the admin for the pair's liquidity and has many security checks in place
/// @notice This contract is also where strategists claim rewards for successful market making

pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "../interfaces/IBathToken.sol";
import "../interfaces/IBathHouse.sol";
import "../interfaces/IRubiconMarket.sol";
import "../interfaces/IStrategistUtility.sol";

contract BathPair {
    /// *** Libraries ***
    using SafeMath for uint256;
    using SafeMath for uint16;

    /// *** Storage Variables ***

    /// @notice The Bath House admin of this contract; used with onlyBathHouse()
    address public bathHouse;

    /// @notice The Rubicon Market strategists direct all activity towards. There is only one market, RubiconMarket.sol, in the Rubicon Protocol
    address public RubiconMarketAddress;

    /// @notice The initialization status of BathPair
    bool public initialized;

    /// @dev Keeping deprecated variables maintains consistent network-agnostic contract abis when moving to new chains and versions
    int128 internal deprecatedStorageVarKept420Proxy;

    /// @notice Intentionally unused DEPRECATED STORAGE VARIABLE to maintain contiguous state on proxy-wrapped contracts. Consider it a beautiful scar of incremental progress 📈
    /// @dev Keeping deprecated variables maintains consistent network-agnostic contract abis when moving to new chains and versions
    uint256 public deprecatedStorageVarKept4Proxy;

    /// @dev The id of the last StrategistTrade made by any strategist on this contract
    /// @dev This value is globally unique, and increments with every trade
    uint256 internal last_stratTrade_id;

    /// @notice The total amount of successful offer fills that all strategists have made for a given asset
    mapping(address => uint256) public totalFillsPerAsset;

    /// @notice Unique id => StrategistTrade created in marketMaking call
    mapping(uint256 => StrategistTrade) public strategistTrades;

    /// @notice Map a strategist to their outstanding order IDs
    mapping(address => mapping(address => mapping(address => uint256[])))
        public outOffersByStrategist;

    /// @notice Tracks the market-kaing fill amounts on a per-asset basis of a strategist
    /// @dev strategist => erc20asset => fill amount per asset;
    mapping(address => mapping(address => uint256)) public strategist2Fills;

    /// *** Structs ***

    struct order {
        uint256 pay_amt;
        IERC20 pay_gem;
        uint256 buy_amt;
        IERC20 buy_gem;
    }

    struct StrategistTrade {
        uint256 askId;
        uint256 askPayAmt;
        address askAsset;
        uint256 bidId;
        uint256 bidPayAmt;
        address bidAsset;
        address strategist;
        uint256 timestamp;
    }

    /// *** Events ***

    /// @notice Log a new market-making trade placed by a strategist, resulting in a StrategitTrade
    event LogStrategistTrade(
        uint256 strategistTradeID,
        bytes32 askId,
        bytes32 bidId,
        address askAsset,
        address bidAsset,
        uint256 timestamp,
        address strategist
    );

    /// @notice Logs the cancellation of a StrategistTrade
    event LogScrubbedStratTrade(
        uint256 strategistIDScrubbed,
        uint256 assetFill,
        address assetAddress,
        address bathAssetAddress,
        uint256 quoteFill,
        address quoteAddress,
        address bathQuoteAddress
    );

    /// @notice Log when a strategist claims their market-making rewards (effectively a rebate for good performance)
    event LogStrategistRewardClaim(
        address strategist,
        address asset,
        uint256 amountOfReward,
        uint256 timestamp
    );

    /// *** External Functions ***

    /// @notice Constructor-like initialization function
    /// @dev Proxy-safe initialization of storage
    function initialize(uint256 _maxOrderSizeBPS, int128 _shapeCoefNum)
        external
    {
        require(!initialized);
        address _bathHouse = msg.sender; //Assume the initializer is BathHouse
        require(
            IBathHouse(_bathHouse).getMarket() !=
                address(0x0000000000000000000000000000000000000000) &&
                IBathHouse(_bathHouse).initialized(),
            "BathHouse not initialized"
        );
        bathHouse = _bathHouse;

        RubiconMarketAddress = IBathHouse(_bathHouse).getMarket();

        // Shape variables for dynamic inventory management
        /// *** DEprecate but keep storage variable on OP
        deprecatedStorageVarKept4Proxy = _maxOrderSizeBPS;

        /// @dev A deprecated storage variable! Turns out order books are elegant and complex math is simply computed off-chain, and priced in on-chain orders at the speed of Ethereum L2s!
        deprecatedStorageVarKept420Proxy = _shapeCoefNum;

        initialized = true;
    }

    /// *** Modifiers ***

    modifier onlyBathHouse() {
        require(msg.sender == bathHouse);
        _;
    }

    modifier onlyApprovedStrategist(address targetStrategist) {
        require(
            IBathHouse(bathHouse).isApprovedStrategist(targetStrategist) ==
                true,
            "you are not an approved strategist - bathPair"
        );
        _;
    }

    // *** Internal Functions ***

    /// @notice This function enforces that the Bath House reserveRatio (a % of underlying pool liquidity) is enforced across all pools
    /// @dev This function should ensure that reserveRatio % of the underlying liquidity always remains on the Bath Token. Utilization should be 1 - reserveRatio in practice assuming strategists use all available liquidity.
    function enforceReserveRatio(
        address underlyingAsset,
        address underlyingQuote
    )
        internal
        view
        returns (address bathAssetAddress, address bathQuoteAddress)
    {
        bathAssetAddress = IBathHouse(bathHouse).tokenToBathToken(
            underlyingAsset
        );
        bathQuoteAddress = IBathHouse(bathHouse).tokenToBathToken(
            underlyingQuote
        );
        require(
            (
                IBathToken(bathAssetAddress).underlyingBalance().mul(
                    IBathHouse(bathHouse).reserveRatio()
                )
            )
            .div(100) <= IERC20(underlyingAsset).balanceOf(bathAssetAddress),
            "Failed to meet asset pool reserve ratio"
        );
        require(
            (
                IBathToken(bathQuoteAddress).underlyingBalance().mul(
                    IBathHouse(bathHouse).reserveRatio()
                )
            )
            .div(100) <= IERC20(underlyingQuote).balanceOf(bathQuoteAddress),
            "Failed to meet quote pool reserve ratio"
        );
    }

    /// @notice Log whenever a strategist rebalances a fill amount and log the amount while incrementing total fills for that specific asset
    /// @dev Only log fills for each strategist in an asset specific manner
    /// @dev Goal is to map a strategist to a fill
    function logFill(
        uint256 amt,
        address strategist,
        address asset
    ) internal {
        strategist2Fills[strategist][asset] += amt;
        totalFillsPerAsset[asset] += amt;
    }

    /// @notice Internal function to provide the next unique StrategistTrade ID
    function _next_id() internal returns (uint256) {
        last_stratTrade_id++;
        return last_stratTrade_id;
    }

    /// @notice This function results in the removal of the Strategist Trade (bid and/or ask on Rubicon Market) from the books and it being deleted from the contract
    /// @dev The local array of strategist IDs that exists for any given strategist [query via getOutstandingStrategistTrades()] acts as an acitve RAM for outstanding strategist trades
    /// @dev Cancels outstanding orders and manages the ledger of outstandingAmount() on bathTokens as Strategist Trades are cancelled/scrubbed or expired
    function handleStratOrderAtID(uint256 id) internal {
        StrategistTrade memory info = strategistTrades[id];
        address _asset = info.askAsset;
        address _quote = info.bidAsset;

        address bathAssetAddress = IBathHouse(bathHouse).tokenToBathToken(
            _asset
        );
        address bathQuoteAddress = IBathHouse(bathHouse).tokenToBathToken(
            _quote
        );
        order memory offer1 = getOfferInfo(info.askId); //ask
        order memory offer2 = getOfferInfo(info.bidId); //bid
        uint256 askDelta = info.askPayAmt - offer1.pay_amt;
        uint256 bidDelta = info.bidPayAmt - offer2.pay_amt;

        // if real
        if (info.askId != 0) {
            // if delta > 0 - delta is fill => handle any amount of fill here
            if (askDelta > 0) {
                logFill(askDelta, info.strategist, info.askAsset);
                IBathToken(bathAssetAddress).removeFilledTradeAmount(askDelta);
                // not a full fill
                if (askDelta != info.askPayAmt) {
                    IBathToken(bathAssetAddress).cancel(
                        info.askId,
                        info.askPayAmt.sub(askDelta)
                    );
                }
            }
            // otherwise didn't fill so cancel
            else {
                IBathToken(bathAssetAddress).cancel(info.askId, info.askPayAmt); // pas amount too
            }
        }

        // if real
        if (info.bidId != 0) {
            // if delta > 0 - delta is fill => handle any amount of fill here
            if (bidDelta > 0) {
                logFill(bidDelta, info.strategist, info.bidAsset);
                IBathToken(bathQuoteAddress).removeFilledTradeAmount(bidDelta);
                // not a full fill
                if (bidDelta != info.bidPayAmt) {
                    IBathToken(bathQuoteAddress).cancel(
                        info.bidId,
                        info.bidPayAmt.sub(bidDelta)
                    );
                }
            }
            // otherwise didn't fill so cancel
            else {
                IBathToken(bathQuoteAddress).cancel(info.bidId, info.bidPayAmt); // pass amount too
            }
        }

        // Delete the order from outOffersByStrategist
        uint256 target = getIndexFromElement(
            id,
            outOffersByStrategist[_asset][_quote][info.strategist]
        );
        uint256[] storage current = outOffersByStrategist[_asset][_quote][
            info.strategist
        ];
        current[target] = current[current.length - 1];
        current.pop(); // Assign the last value to the value we want to delete and pop, best way to do this in solc AFAIK

        emit LogScrubbedStratTrade(
            id,
            askDelta,
            _asset,
            bathAssetAddress,
            bidDelta,
            _quote,
            bathQuoteAddress
        );
    }

    /// @notice Get information about a Rubicon Market offer and return it as an order
    function getOfferInfo(uint256 id) internal view returns (order memory) {
        (
            uint256 ask_amt,
            IERC20 ask_gem,
            uint256 bid_amt,
            IERC20 bid_gem
        ) = IRubiconMarket(RubiconMarketAddress).getOffer(id);
        order memory offerInfo = order(ask_amt, ask_gem, bid_amt, bid_gem);
        return offerInfo;
    }

    /// @notice A function that returns the index of uid from array
    /// @dev uid must be in array for the purposes of this contract to enforce outstanding trades per strategist are tracked correctly
    function getIndexFromElement(uint256 uid, uint256[] storage array)
        internal
        view
        returns (uint256 _index)
    {
        bool assigned = false;
        for (uint256 index = 0; index < array.length; index++) {
            if (uid == array[index]) {
                _index = index;
                assigned = true;
                return _index;
            }
        }
        require(assigned, "Didnt Find that element in live list, cannot scrub");
    }

    // *** External Functions - Only Approved Strategists ***

    /// @notice Key entry point for strategists to use Bath Token (LP) funds to place market-making trades on the Rubicon Order Book
    function placeMarketMakingTrades(
        address[2] memory tokenPair, // ASSET, Then Quote
        uint256 askNumerator, // Quote / Asset
        uint256 askDenominator, // Asset / Quote
        uint256 bidNumerator, // size in ASSET
        uint256 bidDenominator // size in QUOTES
    ) public onlyApprovedStrategist(msg.sender) returns (uint256 id) {
        // Require at least one order is non-zero
        require(
            (askNumerator > 0 && askDenominator > 0) ||
                (bidNumerator > 0 && bidDenominator > 0),
            "one order must be non-zero"
        );

        address _underlyingAsset = tokenPair[0];
        address _underlyingQuote = tokenPair[1];

        (
            address bathAssetAddress,
            address bathQuoteAddress
        ) = enforceReserveRatio(_underlyingAsset, _underlyingQuote);

        require(
            bathAssetAddress != address(0) && bathQuoteAddress != address(0),
            "tokenToBathToken error"
        );

        // Calculate new bid and/or ask
        order memory ask = order(
            askNumerator,
            IERC20(_underlyingAsset),
            askDenominator,
            IERC20(_underlyingQuote)
        );
        order memory bid = order(
            bidNumerator,
            IERC20(_underlyingQuote),
            bidDenominator,
            IERC20(_underlyingAsset)
        );

        // Place new bid and/or ask
        // Note: placeOffer returns a zero if an incomplete order
        uint256 newAskID = IBathToken(bathAssetAddress).placeOffer(
            ask.pay_amt,
            ask.pay_gem,
            ask.buy_amt,
            ask.buy_gem
        );

        uint256 newBidID = IBathToken(bathQuoteAddress).placeOffer(
            bid.pay_amt,
            bid.pay_gem,
            bid.buy_amt,
            bid.buy_gem
        );

        // Strategist trade is recorded so they can get paid and the trade is logged for time
        StrategistTrade memory outgoing = StrategistTrade(
            newAskID,
            ask.pay_amt,
            _underlyingAsset,
            newBidID,
            bid.pay_amt,
            _underlyingQuote,
            msg.sender,
            block.timestamp
        );

        // Give each trade a unique id for easy handling by strategists
        id = _next_id();
        strategistTrades[id] = outgoing;
        // Allow strategists to easily call a list of their outstanding offers
        outOffersByStrategist[_underlyingAsset][_underlyingQuote][msg.sender]
            .push(id);

        emit LogStrategistTrade(
            id,
            bytes32(outgoing.askId),
            bytes32(outgoing.bidId),
            outgoing.askAsset,
            outgoing.bidAsset,
            block.timestamp,
            outgoing.strategist
        );
    }

    /// @notice A function to batch together many placeMarketMakingTrades() in a single transaction
    function batchMarketMakingTrades(
        address[2] memory tokenPair, // ASSET, Then Quote
        uint256[] memory askNumerators, // Quote / Asset
        uint256[] memory askDenominators, // Asset / Quote
        uint256[] memory bidNumerators, // size in ASSET
        uint256[] memory bidDenominators // size in QUOTES
    ) external onlyApprovedStrategist(msg.sender) {
        require(
            askNumerators.length == askDenominators.length &&
                askDenominators.length == bidNumerators.length &&
                bidNumerators.length == bidDenominators.length,
            "not all order lengths match"
        );
        uint256 quantity = askNumerators.length;

        for (uint256 index = 0; index < quantity; index++) {
            placeMarketMakingTrades(
                tokenPair,
                askNumerators[index],
                askDenominators[index],
                bidNumerators[index],
                bidDenominators[index]
            );
        }
    }

    /// @notice A function to requote an outstanding order and replace it with a new Strategist Trade
    /// @dev Note that this function will create a new unique id for the requote'd ID due to the low-level functionality
    function requote(
        uint256 id,
        address[2] memory tokenPair, // ASSET, Then Quote
        uint256 askNumerator, // Quote / Asset
        uint256 askDenominator, // Asset / Quote
        uint256 bidNumerator, // size in ASSET
        uint256 bidDenominator // size in QUOTES
    ) external onlyApprovedStrategist(msg.sender) {
        // 1. Scrub strat trade
        scrubStrategistTrade(id);

        // 2. Place another
        placeMarketMakingTrades(
            tokenPair,
            askNumerator,
            askDenominator,
            bidNumerator,
            bidDenominator
        );
    }

    /// @notice - function to rebalance fill between two pools
    function rebalancePair(
        uint256 assetRebalAmt, //amount of ASSET in the quote buffer
        uint256 quoteRebalAmt, //amount of QUOTE in the asset buffer
        address _underlyingAsset,
        address _underlyingQuote
    ) external onlyApprovedStrategist(msg.sender) {
        address _bathHouse = bathHouse;
        address _bathAssetAddress = IBathHouse(_bathHouse).tokenToBathToken(
            _underlyingAsset
        );
        address _bathQuoteAddress = IBathHouse(_bathHouse).tokenToBathToken(
            _underlyingQuote
        );
        require(
            _bathAssetAddress != address(0) && _bathQuoteAddress != address(0),
            "tokenToBathToken error"
        );

        // This should be localized to the bathToken in future versions
        uint16 stratReward = IBathHouse(_bathHouse).getBPSToStrats();

        // Simply rebalance given amounts
        if (assetRebalAmt > 0) {
            IBathToken(_bathQuoteAddress).rebalance(
                _bathAssetAddress,
                _underlyingAsset,
                stratReward,
                assetRebalAmt
            );
        }
        if (quoteRebalAmt > 0) {
            IBathToken(_bathAssetAddress).rebalance(
                _bathQuoteAddress,
                _underlyingQuote,
                stratReward,
                quoteRebalAmt
            );
        }
    }

    /// @notice Function to attempt inventory risk tail off on an AMM
    /// @dev This function calls the strategist utility which handles the trade and returns funds to LPs
    function tailOff(
        address targetPool,
        address tokenToHandle,
        address targetToken,
        address _stratUtil, // delegatecall target
        uint256 amount, //fill amount to handle
        uint256 hurdle, //must clear this on tail off
        uint24 _poolFee
    ) external onlyApprovedStrategist(msg.sender) {
        // transfer here
        uint16 stratRewardBPS = IBathHouse(bathHouse).getBPSToStrats();

        IBathToken(targetPool).rebalance(
            _stratUtil,
            tokenToHandle,
            stratRewardBPS,
            amount
        );

        // Should always exceed hurdle given amountOutMinimum
        IStrategistUtility(_stratUtil).UNIdump(
            amount.sub((stratRewardBPS.mul(amount)).div(10000)),
            tokenToHandle,
            targetToken,
            hurdle,
            _poolFee,
            targetPool
        );
    }

    /// @notice Cancel an outstanding strategist offers and return funds to LPs while logging fills
    function scrubStrategistTrade(uint256 id)
        public
        onlyApprovedStrategist(msg.sender)
    {
        require(
            msg.sender == strategistTrades[id].strategist,
            "you are not the strategist that made this order"
        );
        handleStratOrderAtID(id);
    }

    /// @notice Batch scrub outstanding strategist trades and return funds to LPs
    function scrubStrategistTrades(uint256[] memory ids)
        external
        onlyApprovedStrategist(msg.sender)
    {
        for (uint256 index = 0; index < ids.length; index++) {
            uint256 _id = ids[index];
            scrubStrategistTrade(_id);
        }
    }

    /// @notice Function where strategists claim rewards proportional to their quantity of fills
    /// @dev This function should allow a strategist to claim ERC20s sitting on this contract (earned via rebalancing) relative to their share or strategist activity on the pair
    /// @dev Provide the pair on which you want to claim rewards
    function strategistBootyClaim(address asset, address quote)
        external
        onlyApprovedStrategist(msg.sender)
    {
        uint256 fillCountA = strategist2Fills[msg.sender][asset];
        uint256 fillCountQ = strategist2Fills[msg.sender][quote];
        if (fillCountA > 0) {
            uint256 booty = (
                fillCountA.mul(IERC20(asset).balanceOf(address(this)))
            )
            .div(totalFillsPerAsset[asset]);
            IERC20(asset).transfer(msg.sender, booty);
            emit LogStrategistRewardClaim(
                msg.sender,
                asset,
                booty,
                block.timestamp
            );
            totalFillsPerAsset[asset] -= fillCountA;
            strategist2Fills[msg.sender][asset] -= fillCountA;
        }
        if (fillCountQ > 0) {
            uint256 booty = (
                fillCountQ.mul(IERC20(quote).balanceOf(address(this)))
            )
            .div(totalFillsPerAsset[quote]);
            IERC20(quote).transfer(msg.sender, booty);
            emit LogStrategistRewardClaim(
                msg.sender,
                quote,
                booty,
                block.timestamp
            );
            totalFillsPerAsset[quote] -= fillCountQ;
            strategist2Fills[msg.sender][quote] -= fillCountQ;
        }
    }

    /// *** View Functions ***

    /// @notice The goal of this function is to enable a means to retrieve all outstanding orders a strategist has live in the books
    /// @dev This is helpful to manage orders as well as track all strategist orders (like their RAM of StratTrade IDs) and place any would-be constraints on strategists
    function getOutstandingStrategistTrades(
        address asset,
        address quote,
        address strategist
    ) public view returns (uint256[] memory) {
        return outOffersByStrategist[asset][quote][strategist];
    }
}
