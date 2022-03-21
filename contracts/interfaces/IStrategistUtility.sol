// SPDX-License-Identifier: BUSL-1.1

pragma solidity >=0.7.6;

interface IStrategistUtility {
    function UNIdump(
        uint256 amountIn,
        address swapThis,
        address forThis,
        uint256 hurdle,
        uint24 _poolFee,
        address to
    ) external returns (uint256);
}
