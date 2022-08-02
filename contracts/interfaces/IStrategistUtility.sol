// SPDX-License-Identifier: BUSL-1.1

pragma solidity >=0.7.6;

interface IStrategistUtility {
    // feels bad to be an AMM
    function UNIdump(
        uint256 amountIn,
        address swapThis,
        address forThis,
        uint256 hurdle,
        uint24 _poolFee,
        address to
    ) external returns (uint256);

    function UNIdumpMulti(
        uint256 amount,
        address[] memory assets,
        uint24[] memory fees,
        uint256 hurdle,
        address destination
    ) external returns (uint256 amountOut);
}
