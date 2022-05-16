// SPDX-License-Identifier: MIT

pragma solidity >=0.7.6;

interface IVestingWallet {
    function beneficiary() external view returns (address);

    function release(address token) external;

    function vestedAmount(address token, uint64 timestamp)
        external
        view
        returns (uint256);
}
