// SPDX-License-Identifier: BUSL-1.1

pragma solidity >=0.7.6;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IBathBuddy {
    /// @notice Releases the withdrawer's relative share of all vested tokens directly to them with their withdrawal
    /// @dev function that only the single, permissioned bathtoken can call that rewards a user their accrued rewards
    ///            for a given token during the current rewards period ongoing on bathBuddy
    function getReward(IERC20 token, address recipient) external;

    // Determines a user rewards
    // Note, uses share logic from bathToken
    function earned(address account, address token)
        external
        view
        returns (uint256);
}
