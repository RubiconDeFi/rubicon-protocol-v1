// SPDX-License-Identifier: BUSL-1.1

/// @author Benjamin Hughes - Rubicon
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
import "../libraries/ABDKMath64x64.sol";
import "../interfaces/IStrategistUtility.sol";

contract BathPair {
    using SafeMath for uint256;
    using SafeMath for uint16;

    address public bathHouse;
    address public RubiconMarketAddress;

    bool public initialized;

    int128 internal shapeCoefNum;
    uint256 public maxOrderSizeBPS;

    uint256 internal last_stratTrade_id; // Variable used to increment strategist trade IDs

    mapping(address => uint256) public totalFillsPerAsset;

    // Unique id => StrategistTrade created in marketMaking call
    mapping(uint256 => StrategistTrade) public strategistTrades;
    // Map a strategist to their outstanding order IDs
    mapping(address => mapping(address => mapping(address => uint256[])))
        public outOffersByStrategist;

    /// @dev Tracks the fill amounts on a per-asset basis of a strategist
    /// Note: strategist => erc20asset => fill amount per asset;
    mapping(address => mapping(address => uint256)) public strategist2Fills;

    struct order {
        uint256 pay_amt;
        IERC20 pay_gem;
        uint256 buy_amt;
        IERC20 buy_gem;
    }

    // Pair agnostic
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

    event LogStrategistTrade(
        uint256 strategistTradeID,
        bytes32 askId,
        bytes32 bidId,
        address askAsset,
        address bidAsset,
        uint256 timestamp,
        address strategist
    );

    event LogScrubbedStratTrade(
        uint256 strategistIDScrubbed,
        uint256 assetFill,
        address assetAddress,
        address bathAssetAddress,
        uint256 quoteFill,
        address quoteAddress,
        address bathQuoteAddress
    );

    event LogStrategistRewardClaim(
        address strategist,
        address asset,
        uint256 amountOfReward,
        uint256 timestamp
    );

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
        maxOrderSizeBPS = _maxOrderSizeBPS;
        shapeCoefNum = _shapeCoefNum;

        initialized = true;
    }

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
            ).div(100) <= IERC20(underlyingAsset).balanceOf(bathAssetAddress),
            "Failed to meet asset pool reserve ratio"
        );
        require(
            (
                IBathToken(bathQuoteAddress).underlyingBalance().mul(
                    IBathHouse(bathHouse).reserveRatio()
                )
            ).div(100) <= IERC20(underlyingQuote).balanceOf(bathQuoteAddress),
            "Failed to meet quote pool reserve ratio"
        );
    }

    function setMaxOrderSizeBPS(uint16 val) external onlyBathHouse {
        maxOrderSizeBPS = val;
    }

    function setShapeCoefNum(int128 val) external onlyBathHouse {
        shapeCoefNum = val;
    }

    // Note: the goal is to enable a means to retrieve all outstanding orders a strategist has live in the books
    // This is helpful for them to manage orders as well as place any controls on strategists
    function getOutstandingStrategistTrades(
        address asset,
        address quote,
        address strategist
    ) external view returns (uint256[] memory) {
        return outOffersByStrategist[asset][quote][strategist];
    }

    // *** Internal Functions ***

    // Returns price denominated in the quote asset
    function getMidpointPrice(address asset, address quote)
        public
        view
        returns (
            /* asset, quote*/
            int128
        )
    {
        address _RubiconMarketAddress = RubiconMarketAddress;
        uint256 bestAskID = IRubiconMarket(_RubiconMarketAddress).getBestOffer(
            IERC20(asset),
            IERC20(quote)
        );
        uint256 bestBidID = IRubiconMarket(_RubiconMarketAddress).getBestOffer(
            IERC20(quote),
            IERC20(asset)
        );
        // Throw a zero if unable to determine midpoint from the book
        if (bestAskID == 0 || bestBidID == 0) {
            return 0;
        }
        order memory bestAsk = getOfferInfo(bestAskID);
        order memory bestBid = getOfferInfo(bestBidID);
        int128 midpoint = ABDKMath64x64.divu(
            (
                (bestAsk.buy_amt.div(bestAsk.pay_amt)).add(
                    bestBid.pay_amt.div(bestBid.buy_amt)
                )
            ),
            2
        );
        return midpoint;
    }

    // orderID of the fill
    // only log fills for each strategist - needs to be asset specific
    // isAssetFill are *quotes* that result in asset yield
    // A strategist's relative share of total fills is their amount of reward claim, that is logged here
    function logFill(
        uint256 amt,
        // bool isAssetFill,
        address strategist,
        address asset
    ) internal {
        // Goal is to map a strategist to a fill
        strategist2Fills[strategist][asset] += amt;
        totalFillsPerAsset[asset] += amt;
    }

    function _next_id() internal returns (uint256) {
        last_stratTrade_id++;
        return last_stratTrade_id;
    }

    // Note: this function results in the removal of the order from the books and it being deleted from the contract
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

    // Get offer info from Rubicon Market
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

    function getIndexFromElement(uint256 uid, uint256[] storage array)
        internal
        view
        returns (uint256 _index)
    {
        for (uint256 index = 0; index < array.length; index++) {
            if (uid == array[index]) {
                _index = index;
                return _index;
            }
        }
    }

    // *** External functions that can be called by Strategists ***

    function placeMarketMakingTrades(
        address[2] memory tokenPair, // ASSET, Then Quote
        uint256 askNumerator, // Quote / Asset
        uint256 askDenominator, // Asset / Quote
        uint256 bidNumerator, // size in ASSET
        uint256 bidDenominator // size in QUOTES
    ) external onlyApprovedStrategist(msg.sender) returns (uint256 id) {
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

        // TODO: improve this?
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

    //Function to attempt AMM inventory risk tail off
    // This function calls the strategist utility which handles the trade and returns funds to LPs
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

    // Inputs are indices through which to scrub
    // Zero indexed indices!
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

    // ** EXPERIMENTAL **
    function scrubStrategistTrades(uint256[] memory ids) external {
        for (uint256 index = 0; index < ids.length; index++) {
            uint256 _id = ids[index];
            scrubStrategistTrade(_id);
        }
    }

    // Return the largest order size that can be placed as a strategist for given pair and their liquidity pools
    // ^ I believe this is the best approach given that this function call relies on knowledge of sister liquidity pool
    // High level idea: here is the asset and pair I'm market-making for, what max size can I use?
    function getMaxOrderSize(
        address asset,
        address sisterAsset,
        address targetBathToken,
        address sisterBathToken
    ) public view returns (uint256 maxSizeAllowed) {
        require(asset != sisterAsset, "provided identical asset vales GMOS");
        int128 shapeCoef = ABDKMath64x64.div(shapeCoefNum, 1000);
        // Get LP balance for target asset
        uint256 underlyingBalance = IERC20(asset).balanceOf(targetBathToken);
        require(
            underlyingBalance > 0,
            "no bathToken liquidity to calculate max orderSize permissable"
        );

        // If no midpoint in book, allow **permissioned** strategist to maxOrderSize
        int128 midpoint = getMidpointPrice(asset, sisterAsset); //amount in sisterAsset also can be thought of as sisterAsset per asset price in the book
        if (midpoint == 0) {
            return maxOrderSizeBPS.mul(underlyingBalance).div(10000);
        }
        int128 ratio = ABDKMath64x64.divu(
            underlyingBalance,
            IERC20(sisterAsset).balanceOf(sisterBathToken)
        ); // Liquidity check of: assset / sisterAsset
        if (ABDKMath64x64.mul(ratio, midpoint) > (2**64)) {
            // Overweight asset liquidity relative to midpoint price
            return maxOrderSizeBPS.mul(underlyingBalance).div(10000);
        } else {
            // return dynamic order size
            uint256 maxSize = maxOrderSizeBPS.mul(underlyingBalance).div(10000);
            int128 shapeFactor = ABDKMath64x64.exp(
                ABDKMath64x64.mul(
                    shapeCoef,
                    ABDKMath64x64.inv(ABDKMath64x64.div(ratio, midpoint))
                )
            );
            uint256 dynamicSize = ABDKMath64x64.mulu(shapeFactor, maxSize);
            return dynamicSize;
        }
    }

    // function where strategists claim rewards proportional to their quantity of fills
    // Provide the pair on which you want to claim rewards
    function strategistBootyClaim(address asset, address quote) external {
        uint256 fillCountA = strategist2Fills[msg.sender][asset];
        uint256 fillCountQ = strategist2Fills[msg.sender][quote];
        if (fillCountA > 0) {
            uint256 booty = (
                fillCountA.mul(IERC20(asset).balanceOf(address(this)))
            ).div(totalFillsPerAsset[asset]);
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
            ).div(totalFillsPerAsset[quote]);
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
}

// Wish list:
// - Nicer way to scrub orders in bulk
