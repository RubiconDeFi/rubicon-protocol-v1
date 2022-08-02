// SPDX-License-Identifier: BUSL-1.1

pragma solidity >=0.7.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBathToken is IERC20 {
    function removeFilledTradeAmount(uint256 amt) external;

    function cancel(uint256 id, uint256 amt) external;

    function placeOffer(
        uint256 pay_amt,
        IERC20 pay_gem,
        uint256 buy_amt,
        IERC20 buy_gem
    ) external returns (uint256);

    function rebalance(
        address destination,
        address filledAssetToRebalance,
        uint256 stratTakeProportion,
        uint256 rebalAmt
    ) external;

    function approveMarket() external;

    function asset() external view returns (address assetTokenAddress); //4626

    // Storage var that hold rewards tokens
    function bathBuddy() external view returns (address);

    function setBathBuddy(address newBathHouse) external;

    function underlyingToken() external returns (IERC20 erc20);

    function bathHouse() external returns (address admin);

    function setBathHouse(address newBathHouse) external;

    function setMarket(address newRubiconMarket) external;

    function setBonusToken(address newBonusToken) external;

    function setFeeBPS(uint256 _feeBPS) external;

    function setFeeTo(address _feeTo) external;

    function RubiconMarketAddress() external returns (address market);

    function outstandingAmount() external returns (uint256 amount);

    function underlyingBalance() external view returns (uint256);

    function deposit(uint256 amount) external returns (uint256 shares);

    function deposit(uint256 assets, address receiver)
        external
        returns (uint256 shares);

    function withdraw(uint256 shares) external returns (uint256 amount);

    function DOMAIN_SEPARATOR() external view returns (bytes32);

    function PERMIT_TYPEHASH() external pure returns (bytes32);

    function nonces(address owner) external view returns (uint256);

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
