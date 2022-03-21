// SPDX-License-Identifier: BUSL-1.1

pragma solidity >=0.7.6;

interface IBathHouse {
    function getMarket() external view returns (address);

    function initialized() external returns (bool);

    function reserveRatio() external view returns (uint);

    function tokenToBathToken(address erc20Address)
        external view
        returns (address bathTokenAddress);

    function isApprovedStrategist(address wouldBeStrategist)
        external
        view
        returns (bool);

    function getBPSToStrats() external view returns (uint8);

    function isApprovedPair(address pair) external view returns (bool);
}
