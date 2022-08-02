// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0 <0.8.0;

import "../interfaces/IBathBuddy.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";

// Inheritance
// import "./interfaces/IStakingRewards.sol";
// import "./RewardsDistributionRecipient.sol";
// import "./Pausable.sol";
import "../rubiconPools/BathToken.sol";

/**
 * @title BathBuddy
 * @dev *** This contract is a modified version of StakingRewards.sol by Synthetix
 * @dev https://github.com/Synthetixio/synthetix/blob/develop/contracts/StakingRewards.sol
 *
 * @dev The ~only~ external entrypoint used in the system is the getReward(token) function called by the Bath Token. Extra care should be taken to make sure only the beneficiary can ever access the funds and send them to the withdrawer (and fee to self)
 * @dev This should be permissioned so only legitimate BathToken flows can access it
 * @dev This contract handles the vesting ERC20 tokens for a given Bath Token. Custody of multiple tokens
 * can be given to this contract, which will release the token to the beneficiary following a given vesting schedule depending on what tokens have been notified().
 *
 */

/// @dev NOTE: There is an implicit assumption that having bathToken shares means you are staked. This BathBuddy is paired with a SINGLE bathToken
/// @dev It only accepts calls from that BathToken, specifically when a user wants to claim funds, base function and exit, withdraw() and get all rewards
contract BathBuddy is ReentrancyGuard, IBathBuddy, Pausable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */

    // WILL BE BATH HOUSE IS OWNER
    /// BATH TOKEN ONLY ENTRYPOINTs
    address public owner;
    address public myBathTokenBuddy;
    bool public friendshipStarted;

    /// @dev set to block.timestamp + rewards duration to track an active rewards period after notifyRewardAmount()
    mapping(address => uint256) public periodFinish; // Token specific
    mapping(address => uint256) public rewardRates; // Token specific reward rates
    mapping(address => uint256) public rewardsDuration; // Can be kept global but can also be token specific
    mapping(address => uint256) public lastUpdateTime; //Token specific
    mapping(address => uint256) public rewardsPerTokensStored; // Token specific

    // Token then user always
    mapping(address => mapping(address => uint256))
        public userRewardsPerTokenPaid; // ATTEMPTED TOKEN AGNOSTIC
    mapping(address => mapping(address => uint256)) public tokenRewards; // ATTEMPTED TOKEN AGNOSTIC

    /* ========== CONSTRUCTOR ========== */

    // IDEA: This can be bathBuddy if all rewardsToken logic comes from bath token
    // So long as all share logic is just being read from BathToken correctly, then bathbuddy can still sit on top and dish out ERC20s?
    // Implicitly staked or not depending on your bathToken share balance!?
    // Reliance on bathToken share state when dispensing rewards

    // Proxy-safe constructor
    function spawnBuddy(address _owner, address newBud) external {
        require(!friendshipStarted, "I already have a buddy!");
        owner = _owner;
        myBathTokenBuddy = newBud;

        // Note, rewards duration must be set by admin

        // Constructor pattern
        friendshipStarted = true;
    }

    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }

    // Enforce only soul-bound Bath Token has calling rights
    modifier onlyBuddy() {
        require(
            msg.sender == myBathTokenBuddy &&
                msg.sender != address(0) &&
                friendshipStarted,
            "You are not my buddy!"
        );
        _;
    }

    /* ========== VIEWS ========== */
    // BATH TOKEN DOES ALL SHARE ACCOUNTING! CAREFUL!

    function lastTimeRewardApplicable(address token)
        public
        view
        returns (uint256)
    {
        return
            block.timestamp < periodFinish[token]
                ? block.timestamp
                : periodFinish[token];
    }

    function rewardPerToken(address token) public view returns (uint256) {
        require(friendshipStarted, "I have not started a bathToken friendship");

        if (IERC20(myBathTokenBuddy).totalSupply() == 0) {
            return rewardsPerTokensStored[token];
        }
        return
            rewardsPerTokensStored[token].add(
                lastTimeRewardApplicable(token)
                    .sub(lastUpdateTime[token])
                    .mul(rewardRates[token])
                    .mul(1e18)
                    .div(IERC20(myBathTokenBuddy).totalSupply())
            );
    }

    // Determines a user rewards
    // Note, uses share logic from bathToken
    function earned(address account, address token)
        public
        view
        override
        returns (uint256)
    {
        require(friendshipStarted, "I have not started a bathToken friendship");

        return
            IERC20(myBathTokenBuddy) // Care with this?
                .balanceOf(account)
                .mul(
                    rewardPerToken(token).sub(
                        userRewardsPerTokenPaid[token][account]
                    )
                )
                .div(1e18)
                .add(tokenRewards[token][account]);
    }

    function getRewardForDuration(address token)
        external
        view
        returns (uint256)
    {
        return rewardRates[token].mul(rewardsDuration[token]);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    // IDEA: add this core logic to bathTokens and extrapolate to potentially multiple bath tokens if possible
    // Msg.sender calls BathToken (becomes holderRecipient here) which calls any time to get all rewards accrued for provided token
    /// @param holderRecipient allows the BathToken to pass through correct reward amounts to callers of the function @ BATH TOKEN LEVEL
    function getReward(IERC20 rewardsToken, address holderRecipient)
        external
        override
        nonReentrant
        whenNotPaused
        updateReward(holderRecipient, address(rewardsToken))
        onlyBuddy
    {
        uint256 reward = tokenRewards[address(rewardsToken)][holderRecipient];
        if (reward > 0) {
            tokenRewards[address(rewardsToken)][holderRecipient] = 0;
            rewardsToken.safeTransfer(holderRecipient, reward);
            emit RewardPaid(holderRecipient, reward);
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // Seems useful to add more reward amounts
    // Can set the new reward amount over the defined rewards Duration
    function notifyRewardAmount(uint256 reward, IERC20 rewardsToken)
        external
        onlyOwner
        updateReward(address(0), address(rewardsToken))
    {
        if (block.timestamp >= periodFinish[address(rewardsToken)]) {
            rewardRates[address(rewardsToken)] = reward.div(
                rewardsDuration[address(rewardsToken)]
            );
        } else {
            uint256 remaining = periodFinish[address(rewardsToken)].sub(
                block.timestamp
            );
            uint256 leftover = remaining.mul(
                rewardRates[address(rewardsToken)]
            );
            rewardRates[address(rewardsToken)] = reward.add(leftover).div(
                rewardsDuration[address(rewardsToken)]
            );
        }

        // Ensure the provided reward amount is not more than the balance in the contract.
        // This keeps the reward rate in the right range, preventing overflows due to
        // very high values of rewardRate in the earned and rewardsPerToken functions;
        // Reward + leftover must be less than 2^256 / 10^18 to avoid overflow.
        // Note********** ERC20s must be here*************
        uint256 balance = rewardsToken.balanceOf(address(this));
        require(
            rewardRates[address(rewardsToken)] <=
                balance.div(rewardsDuration[address(rewardsToken)]),
            "Provided reward too high"
        );

        lastUpdateTime[address(rewardsToken)] = block.timestamp;
        periodFinish[address(rewardsToken)] = block.timestamp.add(
            rewardsDuration[address(rewardsToken)]
        );
        emit RewardAdded(reward);
    }

    // This must be set before notifying a new rewards program for a given token
    // Must be used before? notifyRewardAmount to set the new period
    function setRewardsDuration(uint256 _rewardsDuration, address token)
        external
        onlyOwner
    {
        require(
            block.timestamp > periodFinish[token],
            "Previous rewards period must be complete before changing the duration for the new period"
        );
        rewardsDuration[token] = _rewardsDuration;
        emit RewardsDurationUpdated(rewardsDuration[token]);
    }

    /* ========== MODIFIERS ========== */

    // Rewards set here
    modifier updateReward(address account, address token) {
        rewardsPerTokensStored[token] = rewardPerToken(token);
        lastUpdateTime[token] = lastTimeRewardApplicable(token);
        if (account != address(0)) {
            tokenRewards[token][account] = earned(account, token);
            userRewardsPerTokenPaid[token][account] = rewardsPerTokensStored[
                token
            ];
        }
        _;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(uint256 reward);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event RewardsDurationUpdated(uint256 newDuration);
    event Recovered(address token, uint256 amount);
}
