// SPDX-License-Identifier: BUSL-1.1

pragma solidity >=0.7.6;

interface IBathPair {
    function initialized() external returns (bool);

    function initialize(uint256 _maxOrderSizeBPS, int128 _shapeCoefNum)
        external;

    function setMaxOrderSizeBPS(uint16 val) external;

    function setShapeCoefNum(int128 val) external;
}
