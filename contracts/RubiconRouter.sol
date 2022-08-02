// SPDX-License-Identifier: BUSL-1.1

/// @author Benjamin Hughes - Rubicon
/// @notice This contract is a router to interact with the low-level functions present in RubiconMarket and Pools
pragma solidity =0.7.6;
pragma abicoder v2;

import "./RubiconMarket.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
// import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./peripheral_contracts/WETH9.sol"; // @unsupported: ovm
import "./interfaces/IBathToken.sol";
import "./interfaces/IBathBuddy.sol";

///@dev this contract is a high-level router that utilizes Rubicon smart contracts to provide
///@dev added convenience and functionality when interacting with the Rubicon protocol
contract RubiconRouter {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    address public RubiconMarketAddress;

    address payable public wethAddress;

    bool public started;

    /// @dev track when users make offers with/for the native asset so we can permission the cancelling of those orders
    mapping(address => uint256[]) public userNativeAssetOrders;

    bool locked;

    event LogNote(string, uint256);

    event LogSwap(
        uint256 inputAmount,
        address inputERC20,
        uint256 hurdleBuyAmtMin,
        address targetERC20,
        bytes32 indexed pair,
        uint256 realizedFill,
        address recipient
    );

    receive() external payable {}

    fallback() external payable {}

    function startErUp(address _theTrap, address payable _weth) external {
        require(!started);
        RubiconMarketAddress = _theTrap;
        wethAddress = _weth;
        started = true;
    }

    /// @dev beGoneReentrantScum
    modifier beGoneReentrantScum() {
        require(!locked);
        locked = true;
        _;
        locked = false;
    }

    /// @notice Get the outstanding best N orders from both sides of the order book for a given pair
    /// @dev The asset/quote pair ordering will affect return values - asset should be the top of the pair: for example, (ETH, USDC, 10) will return (10 best ETH asks, 10 best USDC bids, 10)
    /// @param asset the ERC20 token that represents the ask/sell side of the order book
    /// @param quote the ERC20 token that represents the bid/buy side of the order book
    /// @param topNOrders the depth of the order book the caller would like to query/view for the asset-quote pair
    /// @dev "best" orders are determined by proximity to the midpoint of the pair. Closest to the midpoint is best order.
    /// @return Fixed arrays (of topNOrders length) in "best" order (returned asks/bids[0] is best and asks/bids[topNOrders] is worst) of asks and bids + topNOrders. Each offer array item is: [pay, buy, offerId]
    function getBookFromPair(
        ERC20 asset,
        ERC20 quote,
        uint256 topNOrders
    )
        public
        view
        returns (
            uint256[3][] memory,
            uint256[3][] memory,
            uint256
        )
    {
        uint256[3][] memory asks = new uint256[3][](topNOrders);
        uint256[3][] memory bids = new uint256[3][](topNOrders);
        address _RubiconMarketAddress = RubiconMarketAddress;

        //1. Get best offer for each asset
        uint256 bestAskID = RubiconMarket(_RubiconMarketAddress).getBestOffer(
            asset,
            quote
        );
        uint256 bestBidID = RubiconMarket(_RubiconMarketAddress).getBestOffer(
            quote,
            asset
        );

        uint256 lastBid = 0;
        uint256 lastAsk = 0;
        //2. Iterate from that offer down the book until topNOrders
        for (uint256 index = 0; index < topNOrders; index++) {
            if (index == 0) {
                lastAsk = bestAskID;
                lastBid = bestBidID;

                (
                    uint256 _ask_pay_amt,
                    ,
                    uint256 _ask_buy_amt,

                ) = RubiconMarket(_RubiconMarketAddress).getOffer(bestAskID);
                (
                    uint256 _bid_pay_amt,
                    ,
                    uint256 _bid_buy_amt,

                ) = RubiconMarket(_RubiconMarketAddress).getOffer(bestBidID);
                asks[index] = [_ask_pay_amt, _ask_buy_amt, bestAskID];
                bids[index] = [_bid_pay_amt, _bid_buy_amt, bestBidID];
                continue;
            }
            uint256 nextBestAsk = RubiconMarket(_RubiconMarketAddress)
                .getWorseOffer(lastAsk);
            uint256 nextBestBid = RubiconMarket(_RubiconMarketAddress)
                .getWorseOffer(lastBid);
            (uint256 ask_pay_amt, , uint256 ask_buy_amt, ) = RubiconMarket(
                _RubiconMarketAddress
            ).getOffer(nextBestAsk);
            (uint256 bid_pay_amt, , uint256 bid_buy_amt, ) = RubiconMarket(
                _RubiconMarketAddress
            ).getOffer(nextBestBid);

            asks[index] = [ask_pay_amt, ask_buy_amt, nextBestAsk];
            bids[index] = [bid_pay_amt, bid_buy_amt, nextBestBid];
            // bids[index] = nextBestBid;
            lastBid = nextBestBid;
            lastAsk = nextBestAsk;
        }

        //3. Return those topNOrders for either side of the order book
        return (asks, bids, topNOrders);
    }

    /// @dev this function returns the best offer for a pair's id and info
    function getBestOfferAndInfo(address asset, address quote)
        public
        view
        returns (
            uint256, //id
            uint256,
            ERC20,
            uint256,
            ERC20
        )
    {
        address _market = RubiconMarketAddress;
        uint256 offer = RubiconMarket(_market).getBestOffer(
            ERC20(asset),
            ERC20(quote)
        );
        (
            uint256 pay_amt,
            ERC20 pay_gem,
            uint256 buy_amt,
            ERC20 buy_gem
        ) = RubiconMarket(_market).getOffer(offer);
        return (offer, pay_amt, pay_gem, buy_amt, buy_gem);
    }

    // function for infinite approvals of Rubicon Market
    function approveAssetOnMarket(address toApprove)
        private
        beGoneReentrantScum
    {
        require(
            started &&
                RubiconMarketAddress != address(this) &&
                RubiconMarketAddress != address(0),
            "Router not initialized"
        );
        // Approve exchange
        IERC20(toApprove).safeApprove(RubiconMarketAddress, 2**256 - 1);
    }

    /// @dev this function takes the same parameters of swap and returns the expected amount
    function getExpectedSwapFill(
        uint256 pay_amt,
        uint256 buy_amt_min,
        address[] calldata route, // First address is what is being payed, Last address is what is being bought
        uint256 expectedMarketFeeBPS //20
    ) public view returns (uint256 fill_amt) {
        address _market = RubiconMarketAddress;
        uint256 currentAmount = 0;
        for (uint256 i = 0; i < route.length - 1; i++) {
            (address input, address output) = (route[i], route[i + 1]);
            uint256 _pay = i == 0
                ? pay_amt
                : (
                    currentAmount.sub(
                        currentAmount.mul(expectedMarketFeeBPS).div(10000)
                    )
                );
            uint256 wouldBeFillAmount = RubiconMarket(_market).getBuyAmount(
                ERC20(output),
                ERC20(input),
                _pay
            );
            currentAmount = wouldBeFillAmount;
        }
        require(currentAmount >= buy_amt_min, "didnt clear buy_amt_min");

        // Return the wouldbe resulting swap amount
        return (currentAmount);
    }

    /// @dev This function lets a user swap from route[0] -> route[last] at some minimum expected rate
    /// @dev pay_amt - amount to be swapped away from msg.sender of *first address in path*
    /// @dev buy_amt_min - target minimum received of *last address in path*
    function swap(
        uint256 pay_amt,
        uint256 buy_amt_min,
        address[] calldata route, // First address is what is being payed, Last address is what is being bought
        uint256 expectedMarketFeeBPS //20 /**beGoneReentrantScum*/
    ) public returns (uint256) {
        //**User must approve this contract first**
        //transfer needed amount here first
        IERC20(route[0]).safeTransferFrom(
            msg.sender,
            address(this),
            pay_amt.add(pay_amt.mul(expectedMarketFeeBPS).div(10000)) // Account for expected fee
        );
        return
            _swap(
                pay_amt,
                buy_amt_min,
                route,
                expectedMarketFeeBPS,
                msg.sender
            );
    }

    // Internal function requires that ERC20s are here before execution
    function _swap(
        uint256 pay_amt,
        uint256 buy_amt_min,
        address[] calldata route, // First address is what is being payed, Last address is what is being bought
        uint256 expectedMarketFeeBPS,
        address to // Recipient of swap outputs!
    ) internal returns (uint256) {
        require(
            expectedMarketFeeBPS < 1000,
            "Your fee is too high! Check correct value on-chain"
        );

        require(route.length > 1, "Not enough hop destinations!");

        address _market = RubiconMarketAddress;
        uint256 currentAmount = 0;
        for (uint256 i = 0; i < route.length - 1; i++) {
            (address input, address output) = (route[i], route[i + 1]);
            uint256 _pay = i == 0
                ? pay_amt
                : currentAmount.sub(
                    currentAmount.mul(expectedMarketFeeBPS).div(
                        10000 + expectedMarketFeeBPS
                    )
                );
            if (ERC20(input).allowance(address(this), _market) == 0) {
                approveAssetOnMarket(input);
            }
            uint256 fillAmount = RubiconMarket(_market).sellAllAmount(
                ERC20(input),
                _pay,
                ERC20(output),
                0 //naively assume no fill_amt here for loop purposes?
            );
            currentAmount = fillAmount;
        }
        require(currentAmount >= buy_amt_min, "didnt clear buy_amt_min");

        // send tokens back to sender if not keeping here
        if (to != address(this)) {
            IERC20(route[route.length - 1]).safeTransfer(to, currentAmount);
        }

        emit LogSwap(
            pay_amt,
            route[0],
            buy_amt_min,
            route[route.length - 1],
            keccak256(abi.encodePacked(route[0], route[route.length - 1])),
            currentAmount,
            to
        );
        return currentAmount;
    }

    /// @notice A function that returns the index of uid from array
    /// @dev uid must be in array for the purposes of this contract to enforce outstanding trades per strategist are tracked correctly
    /// @dev can be used to check if a value is in a given array, and at what index
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

    /// @dev this function takes a user's entire balance for the trade in case they want to do a max trade so there's no leftover dust
    function maxBuyAllAmount(
        ERC20 buy_gem,
        ERC20 pay_gem,
        uint256 max_fill_amount
    ) external returns (uint256 fill) {
        //swaps msg.sender's entire balance in the trade

        uint256 maxAmount = _calcAmountAfterFee(
            ERC20(buy_gem).balanceOf(msg.sender)
        );
        IERC20(buy_gem).safeTransferFrom(msg.sender, address(this), maxAmount);
        fill = RubiconMarket(RubiconMarketAddress).buyAllAmount(
            buy_gem,
            maxAmount,
            pay_gem,
            max_fill_amount
        );
        ERC20(buy_gem).transfer(msg.sender, fill);
    }

    /// @dev this function takes a user's entire balance for the trade in case they want to do a max trade so there's no leftover dust
    function maxSellAllAmount(
        ERC20 pay_gem,
        ERC20 buy_gem,
        uint256 min_fill_amount
    ) external returns (uint256 fill) {
        //swaps msg.sender entire balance in the trade

        uint256 maxAmount = _calcAmountAfterFee(
            ERC20(buy_gem).balanceOf(msg.sender)
        );
        IERC20(buy_gem).safeTransferFrom(msg.sender, address(this), maxAmount);
        fill = RubiconMarket(RubiconMarketAddress).sellAllAmount(
            pay_gem,
            maxAmount,
            buy_gem,
            min_fill_amount
        );
        ERC20(buy_gem).transfer(msg.sender, fill);
    }

    function _calcAmountAfterFee(uint256 amount)
        internal
        view
        returns (uint256)
    {
        uint256 feeBPS = RubiconMarket(RubiconMarketAddress).getFeeBPS();
        return amount.sub(amount.mul(feeBPS).div(10000));
    }

    // ** Native ETH Wrapper Functions **
    /// @dev WETH wrapper functions to obfuscate WETH complexities from ETH holders
    function buyAllAmountWithETH(
        ERC20 buy_gem,
        uint256 buy_amt,
        uint256 max_fill_amount,
        uint256 expectedMarketFeeBPS
    ) external payable returns (uint256 fill) {
        address _weth = address(wethAddress);
        uint256 _before = ERC20(_weth).balanceOf(address(this));
        uint256 max_fill_withFee = max_fill_amount.add(
            max_fill_amount.mul(expectedMarketFeeBPS).div(10000)
        );
        require(
            msg.value == max_fill_withFee,
            "must send as much ETH as max_fill_withFee"
        );
        WETH9(wethAddress).deposit{value: max_fill_withFee}(); // Pay with native ETH -> WETH
        // An amount in WETH
        fill = RubiconMarket(RubiconMarketAddress).buyAllAmount(
            buy_gem,
            buy_amt,
            ERC20(wethAddress),
            max_fill_amount
        );
        IERC20(buy_gem).safeTransfer(msg.sender, buy_amt);

        uint256 _after = ERC20(_weth).balanceOf(address(this));
        uint256 delta = _after - _before;

        // Return unspent coins to sender
        if (delta > 0) {
            WETH9(wethAddress).withdraw(delta);
            // msg.sender.transfer(delta);
            (bool success, ) = msg.sender.call{value: delta}("");
            require(success, "Transfer failed.");
        }
    }

    // Paying ERC20 to buy native ETH
    function buyAllAmountForETH(
        uint256 buy_amt,
        ERC20 pay_gem,
        uint256 max_fill_amount
    ) external beGoneReentrantScum returns (uint256 fill) {
        IERC20(pay_gem).safeTransferFrom(
            msg.sender,
            address(this),
            max_fill_amount
        ); //transfer pay here
        fill = RubiconMarket(RubiconMarketAddress).buyAllAmount(
            ERC20(wethAddress),
            buy_amt,
            pay_gem,
            max_fill_amount
        );
        WETH9(wethAddress).withdraw(buy_amt); // Fill in WETH

        // Return unspent coins to sender
        if (max_fill_amount > fill) {
            IERC20(pay_gem).safeTransfer(msg.sender, max_fill_amount - fill);
        }

        // msg.sender.transfer(buy_amt); // Return native ETH
        (bool success, ) = msg.sender.call{value: buy_amt}("");
        require(success, "Transfer failed.");

        return fill;
    }

    // Pay in native ETH
    function offerWithETH(
        uint256 pay_amt, //maker (ask) sell how much
        // ERC20 nativeETH, //maker (ask) sell which token
        uint256 buy_amt, //maker (ask) buy how much
        ERC20 buy_gem, //maker (ask) buy which token
        uint256 pos //position to insert offer, 0 should be used if unknown
    ) external payable returns (uint256) {
        require(
            msg.value == pay_amt,
            "didnt send enough native ETH for WETH offer"
        );
        uint256 _before = ERC20(buy_gem).balanceOf(address(this));
        WETH9(wethAddress).deposit{value: pay_amt}();
        uint256 id = RubiconMarket(RubiconMarketAddress).offer(
            pay_amt,
            ERC20(wethAddress),
            buy_amt,
            buy_gem,
            pos
        );

        // Track the user's order so they can cancel it
        userNativeAssetOrders[msg.sender].push(id);

        uint256 _after = ERC20(buy_gem).balanceOf(address(this));
        if (_after > _before) {
            //return any potential fill amount on the offer
            IERC20(buy_gem).safeTransfer(msg.sender, _after - _before);
        }
        return id;
    }

    // Pay in native ETH
    function offerForETH(
        uint256 pay_amt, //maker (ask) sell how much
        ERC20 pay_gem, //maker (ask) sell which token
        uint256 buy_amt, //maker (ask) buy how much
        // ERC20 nativeETH, //maker (ask) buy which token
        uint256 pos //position to insert offer, 0 should be used if unknown
    ) external beGoneReentrantScum returns (uint256) {
        IERC20(pay_gem).safeTransferFrom(msg.sender, address(this), pay_amt);

        uint256 _before = ERC20(wethAddress).balanceOf(address(this));
        uint256 id = RubiconMarket(RubiconMarketAddress).offer(
            pay_amt,
            pay_gem,
            buy_amt,
            ERC20(wethAddress),
            pos
        );

        // Track the user's order so they can cancel it
        userNativeAssetOrders[msg.sender].push(id);

        uint256 _after = ERC20(wethAddress).balanceOf(address(this));
        if (_after > _before) {
            //return any potential fill amount on the offer as native ETH
            uint256 delta = _after - _before;
            WETH9(wethAddress).withdraw(delta);
            // msg.sender.transfer(delta);
            (bool success, ) = msg.sender.call{value: delta}("");
            require(success, "Transfer failed.");
        }

        return id;
    }

    // Cancel an offer made in WETH
    function cancelForETH(uint256 id)
        external
        beGoneReentrantScum
        returns (bool outcome)
    {
        uint256 indexOrFail = getIndexFromElement(
            id,
            userNativeAssetOrders[msg.sender]
        );
        /// @dev Verify that the offer the user is trying to cancel is their own
        require(
            userNativeAssetOrders[msg.sender][indexOrFail] == id,
            "You did not provide an Id for an offer you own"
        );

        (uint256 pay_amt, ERC20 pay_gem, , ) = RubiconMarket(
            RubiconMarketAddress
        ).getOffer(id);
        require(
            address(pay_gem) == wethAddress,
            "trying to cancel a non WETH order"
        );
        // Cancel order and receive WETH here in amount of pay_amt
        outcome = RubiconMarket(RubiconMarketAddress).cancel(id);
        WETH9(wethAddress).withdraw(pay_amt);
        // msg.sender.transfer(pay_amt);
        (bool success, ) = msg.sender.call{value: pay_amt}("");
        require(success, "Transfer failed.");
    }

    // Deposit native ETH -> WETH pool
    function depositWithETH(uint256 amount, address targetPool)
        external
        payable
        beGoneReentrantScum
        returns (uint256 newShares)
    {
        IERC20 target = IBathToken(targetPool).underlyingToken();
        require(target == ERC20(wethAddress), "target pool not weth pool");
        require(msg.value == amount, "didnt send enough eth");

        if (target.allowance(address(this), targetPool) == 0) {
            target.safeApprove(targetPool, amount);
        }

        WETH9(wethAddress).deposit{value: amount}();
        newShares = IBathToken(targetPool).deposit(amount);
        //Send back bathTokens to sender
        IERC20(targetPool).safeTransfer(msg.sender, newShares);
    }

    // Withdraw native ETH <- WETH pool
    function withdrawForETH(uint256 shares, address targetPool)
        external
        payable
        beGoneReentrantScum
        returns (uint256 withdrawnWETH)
    {
        IERC20 target = IBathToken(targetPool).underlyingToken();
        require(target == ERC20(wethAddress), "target pool not weth pool");

        uint256 startingWETHBalance = ERC20(wethAddress).balanceOf(
            address(this)
        );
        IBathToken(targetPool).transferFrom(msg.sender, address(this), shares);
        withdrawnWETH = IBathToken(targetPool).withdraw(shares);
        uint256 postWithdrawWETH = ERC20(wethAddress).balanceOf(address(this));
        require(
            withdrawnWETH == (postWithdrawWETH.sub(startingWETHBalance)),
            "bad WETH value hacker"
        );
        WETH9(wethAddress).withdraw(withdrawnWETH);

        //Send back withdrawn native eth to sender
        // msg.sender.transfer(withdrawnWETH);
        (bool success, ) = msg.sender.call{value: withdrawnWETH}("");
        require(success, "Transfer failed.");
    }

    function swapWithETH(
        uint256 pay_amt,
        uint256 buy_amt_min,
        address[] calldata route, // First address is what is being payed, Last address is what is being bought
        uint256 expectedMarketFeeBPS
    ) external payable returns (uint256) {
        require(route[0] == wethAddress, "Initial value in path not WETH");
        uint256 amtWithFee = pay_amt.add(
            pay_amt.mul(expectedMarketFeeBPS).div(10000)
        );
        require(
            msg.value == amtWithFee,
            "must send enough native ETH to pay as weth and account for fee"
        );
        WETH9(wethAddress).deposit{value: amtWithFee}();
        return
            _swap(
                pay_amt,
                buy_amt_min,
                route,
                expectedMarketFeeBPS,
                msg.sender
            );
    }

    function swapForETH(
        uint256 pay_amt,
        uint256 buy_amt_min,
        address[] calldata route, // First address is what is being payed, Last address is what is being bought
        uint256 expectedMarketFeeBPS
    ) external payable returns (uint256 fill) {
        require(
            route[route.length - 1] == wethAddress,
            "target of swap is not WETH"
        );

        IERC20(route[0]).safeTransferFrom(
            msg.sender,
            address(this),
            pay_amt.add(pay_amt.mul(expectedMarketFeeBPS).div(10000))
        );

        fill = _swap(
            pay_amt,
            buy_amt_min,
            route,
            expectedMarketFeeBPS,
            address(this)
        );

        WETH9(wethAddress).withdraw(fill);
        // msg.sender.transfer(fill);
        (bool success, ) = msg.sender.call{value: fill}("");
        require(success, "Transfer failed.");
    }

    /// @dev View function to query a user's rewards they can claim via claimAllUserBonusTokens
    function checkClaimAllUserBonusTokens(
        address user,
        address[] memory targetBathTokens,
        address token
    ) public view returns (uint256 earnedAcrossPools) {
        for (uint256 index = 0; index < targetBathTokens.length; index++) {
            address targetBT = targetBathTokens[index];
            address targetBathBuddy = IBathToken(targetBT).bathBuddy();
            uint256 earned = IBathBuddy(targetBathBuddy).earned(user, token);
            earnedAcrossPools += earned;
        }
    }
}
