// SPDX-License-Identifier: BUSL-1.1

pragma solidity >=0.7.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBathBuddy {
    /// @notice Releases the withdrawer's relative share of all vested tokens directly to them with their withdrawal
    /// @dev Modified function of the underlying to only release the user's relative share and send it directly to them
    function release(
        IERC20 token,
        address recipient,
        uint256 sharesWithdrawn,
        uint256 initialTotalSupply,
        uint256 poolFee
    ) external;
}
