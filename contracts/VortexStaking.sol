// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title VortexStaking — VTX Staking, Solver Registration & Revenue Distribution
 * @notice Allows VTX holders to stake tokens, earn a proportional share of protocol
 *         revenue (70% of all fees), and optionally register as solvers by meeting a
 *         minimum stake requirement. Registered solvers can be slashed by governance
 *         for malicious behaviour.
 *
 * Revenue accounting uses a reward-per-share accumulator pattern so that rewards can
 * be distributed in O(1) regardless of the number of stakers.
 *
 * Unstaking is subject to a 7-day cooldown to protect the protocol from stake-withdrawal
 * attacks immediately before a slash event.
 */
contract VortexStaking is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Minimum VTX stake required to register as an active solver.
    uint256 public constant SOLVER_MIN_STAKE = 10_000 * 10 ** 18;

    /// @notice Cooldown period before an unstake request can be withdrawn.
    uint256 public constant UNSTAKE_COOLDOWN = 7 days;

    /// @notice Precision multiplier for reward-per-share arithmetic.
    uint256 private constant PRECISION = 1e18;

    /// @notice Delay required before a proposed rewardToken change takes effect.
    uint256 public constant REWARD_TOKEN_CHANGE_DELAY = 2 days;

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The VTX ERC-20 token.
    IERC20 public immutable vtx;

    /// @notice Address authorised to call distributeRevenue() (the Router).
    address public router;

    /// @notice Accumulated reward per staked VTX unit (scaled by PRECISION).
    uint256 public rewardPerShareAccumulated;

    /// @notice Total VTX currently staked across all users.
    uint256 public totalStaked;

    // Per-staker accounting
    struct StakeInfo {
        uint256 staked;               // VTX currently staked
        uint256 rewardDebt;           // reward-per-share snapshot at last update
        uint256 pendingRewards;       // unclaimed rewards accumulated so far
        bool    isSolver;             // registered as active solver
        uint256 unstakeAmount;        // amount queued for withdrawal
        uint256 unstakeAvailableAt;   // timestamp when cooldown ends
    }

    mapping(address => StakeInfo) public stakers;

    // Revenue token(s) distributed to stakers (protocol fees arrive as native ETH
    // or ERC-20 depending on the chain; we support any ERC-20 reward token here).
    // For simplicity, rewards are tracked in a single reward token set by the owner.
    address public rewardToken; // address(0) = native ETH

    /// @notice Pending reward token waiting for the 2-day delay to expire.
    address public pendingRewardToken;

    /// @notice Timestamp after which pendingRewardToken can be applied.
    uint256 public rewardTokenChangeAvailableAt;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event Staked(address indexed user, uint256 amount);
    event UnstakeQueued(address indexed user, uint256 amount, uint256 availableAt);
    event Unstaked(address indexed user, uint256 amount);
    event SolverRegistered(address indexed solver);
    event SolverDeregistered(address indexed solver);
    event SolverSlashed(address indexed solver, uint256 slashedAmount, address recipient);
    event RewardsClaimed(address indexed user, uint256 amount);
    event RevenueDistributed(uint256 amount);
    event RouterSet(address indexed router);
    event RewardTokenChangeProposed(address indexed token, uint256 availableAt);
    event RewardTokenSet(address indexed token);

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyRouter() {
        require(msg.sender == router, "VortexStaking: caller is not router");
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @param _vtx   Address of the VTX token contract.
     * @param _owner Initial owner (will be transferred to Timelock post-deploy).
     */
    constructor(address _vtx, address _owner) Ownable(_owner) {
        require(_vtx != address(0), "VortexStaking: zero vtx");
        vtx = IERC20(_vtx);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin Functions
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Sets the authorised router address. Called once after Router deployment.
     * @param _router Address of VortexRouter.
     */
    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "VortexStaking: zero router");
        router = _router;
        emit RouterSet(_router);
    }

    /**
     * @notice Proposes a new reward token. Takes effect after REWARD_TOKEN_CHANGE_DELAY (2 days).
     * @dev    FIX VTX-05: Two-step delayed change prevents mid-stream reward token swaps that
     *         would break pending reward accounting for existing stakers.
     * @param _newRewardToken ERC-20 contract address, or address(0) for native ETH.
     */
    function proposeRewardTokenChange(address _newRewardToken) external onlyOwner {
        pendingRewardToken        = _newRewardToken;
        rewardTokenChangeAvailableAt = block.timestamp + REWARD_TOKEN_CHANGE_DELAY;
        emit RewardTokenChangeProposed(_newRewardToken, rewardTokenChangeAvailableAt);
    }

    /**
     * @notice Applies the pending reward token change after the 2-day delay has elapsed.
     */
    function applyRewardTokenChange() external onlyOwner {
        require(rewardTokenChangeAvailableAt != 0, "VortexStaking: no change pending");
        require(block.timestamp >= rewardTokenChangeAvailableAt, "VortexStaking: delay active");
        rewardToken               = pendingRewardToken;
        pendingRewardToken        = address(0);
        rewardTokenChangeAvailableAt = 0;
        emit RewardTokenSet(rewardToken);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Staking
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Stakes `amount` VTX on behalf of the caller.
     * @dev    Caller must have approved this contract to spend at least `amount` VTX.
     * @param amount Amount of VTX to stake (18-decimal wei).
     */
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "VortexStaking: zero amount");
        _settleRewards(msg.sender);

        stakers[msg.sender].staked += amount;
        totalStaked += amount;

        vtx.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Queues `amount` VTX for withdrawal after the 7-day cooldown.
     * @dev    Reduces the active stake immediately; tokens are locked until cooldown.
     *         If the user is a solver and remaining stake falls below the minimum,
     *         solver status is revoked automatically.
     * @param amount Amount of VTX to unstake.
     */
    function unstake(uint256 amount) external nonReentrant {
        StakeInfo storage info = stakers[msg.sender];
        require(amount > 0,              "VortexStaking: zero amount");
        require(info.staked >= amount,   "VortexStaking: insufficient stake");
        // FIX VTX-03: Prevent cooldown reset. Require existing queued withdrawal to be
        // claimed before queuing a new one, so earlier amounts are never delayed further.
        require(info.unstakeAmount == 0, "VortexStaking: withdraw queued amount first");

        _settleRewards(msg.sender);

        info.staked -= amount;
        totalStaked -= amount;

        // Auto-deregister solver if stake drops below minimum
        if (info.isSolver && info.staked < SOLVER_MIN_STAKE) {
            info.isSolver = false;
            emit SolverDeregistered(msg.sender);
        }

        // Queue cooldown withdrawal
        info.unstakeAmount      = amount;
        info.unstakeAvailableAt = block.timestamp + UNSTAKE_COOLDOWN;

        emit UnstakeQueued(msg.sender, amount, info.unstakeAvailableAt);
    }

    /**
     * @notice Withdraws queued unstake amount after the cooldown period has elapsed.
     */
    function withdrawUnstaked() external nonReentrant {
        StakeInfo storage info = stakers[msg.sender];
        require(info.unstakeAmount > 0, "VortexStaking: nothing to withdraw");
        require(block.timestamp >= info.unstakeAvailableAt, "VortexStaking: cooldown active");

        uint256 amount = info.unstakeAmount;
        info.unstakeAmount = 0;
        info.unstakeAvailableAt = 0;

        vtx.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Solver Registration
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Registers the caller as an active solver after staking the required amount.
     * @dev    The caller must already have at least SOLVER_MIN_STAKE VTX staked.
     *         Additional VTX can be staked in the same call by passing a non-zero `extraStake`.
     * @param extraStake Additional VTX to stake on top of the existing balance (may be 0).
     */
    function registerAsSolver(uint256 extraStake) external nonReentrant {
        if (extraStake > 0) {
            _settleRewards(msg.sender);
            stakers[msg.sender].staked += extraStake;
            totalStaked += extraStake;
            vtx.safeTransferFrom(msg.sender, address(this), extraStake);
            emit Staked(msg.sender, extraStake);
        }

        require(
            stakers[msg.sender].staked >= SOLVER_MIN_STAKE,
            "VortexStaking: insufficient stake for solver"
        );
        require(!stakers[msg.sender].isSolver, "VortexStaking: already a solver");

        stakers[msg.sender].isSolver = true;
        emit SolverRegistered(msg.sender);
    }

    /**
     * @notice Voluntarily deregisters the caller as a solver.
     */
    function deregisterAsSolver() external {
        require(stakers[msg.sender].isSolver, "VortexStaking: not a solver");
        stakers[msg.sender].isSolver = false;
        emit SolverDeregistered(msg.sender);
    }

    /**
     * @notice Returns whether `solver` is currently registered as an active solver.
     * @param solver Address to check.
     */
    function isSolver(address solver) external view returns (bool) {
        return stakers[solver].isSolver;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Slashing (Governance / Owner only)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Slashes a misbehaving solver's stake.
     * @dev    Only callable by the owner (Timelock / governance).
     * @param solver    Address of the solver to slash.
     * @param amount    Amount of staked VTX to seize.
     * @param recipient Address that receives the slashed VTX (e.g., insurance fund).
     */
    function slash(address solver, uint256 amount, address recipient) external onlyOwner {
        StakeInfo storage info = stakers[solver];
        require(info.isSolver, "VortexStaking: not a solver");
        require(info.staked >= amount, "VortexStaking: slash exceeds stake");
        require(recipient != address(0), "VortexStaking: zero recipient");

        _settleRewards(solver);

        info.staked -= amount;
        totalStaked -= amount;

        if (info.staked < SOLVER_MIN_STAKE) {
            info.isSolver = false;
            emit SolverDeregistered(solver);
        }

        vtx.safeTransfer(recipient, amount);
        emit SolverSlashed(solver, amount, recipient);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Rewards
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Distributes protocol revenue to stakers by advancing the reward-per-share
     *         accumulator. Called exclusively by VortexRouter when fees are collected.
     * @dev    FIX VTX-01: The Router already applies STAKING_SHARE_BPS (70%) before
     *         transferring `amount` here. We must NOT apply any share factor again —
     *         doing so would cause double-reduction and permanently lock the remainder.
     *         `amount` is forwarded in full to the reward accumulator.
     * @param amount The staker portion of the fee (already 70% of gross fee, sent by Router).
     */
    function distributeRevenue(uint256 amount) external onlyRouter {
        if (totalStaked == 0 || amount == 0) return;

        // amount is already the correct staker portion — distribute 100% of it.
        rewardPerShareAccumulated += (amount * PRECISION) / totalStaked;

        emit RevenueDistributed(amount);
    }

    /**
     * @notice Claims all accrued rewards for the caller.
     */
    function claimRewards() external nonReentrant {
        _settleRewards(msg.sender);

        uint256 pending = stakers[msg.sender].pendingRewards;
        require(pending > 0, "VortexStaking: no rewards");

        stakers[msg.sender].pendingRewards = 0;

        _transferReward(msg.sender, pending);
        emit RewardsClaimed(msg.sender, pending);
    }

    /**
     * @notice Returns the unclaimed reward balance for `user`.
     * @param user Address to query.
     */
    function pendingRewards(address user) external view returns (uint256) {
        StakeInfo storage info = stakers[user];
        uint256 unsettled = (info.staked * (rewardPerShareAccumulated - info.rewardDebt)) / PRECISION;
        return info.pendingRewards + unsettled;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Snaps pending rewards for `user` into pendingRewards and updates rewardDebt.
     */
    function _settleRewards(address user) internal {
        StakeInfo storage info = stakers[user];
        if (info.staked > 0) {
            uint256 earned = (info.staked * (rewardPerShareAccumulated - info.rewardDebt)) / PRECISION;
            info.pendingRewards += earned;
        }
        info.rewardDebt = rewardPerShareAccumulated;
    }

    /**
     * @dev Transfers `amount` of rewardToken (or ETH) to `recipient`.
     */
    function _transferReward(address recipient, uint256 amount) internal {
        if (rewardToken == address(0)) {
            (bool ok, ) = payable(recipient).call{value: amount}("");
            require(ok, "VortexStaking: ETH transfer failed");
        } else {
            IERC20(rewardToken).safeTransfer(recipient, amount);
        }
    }

    /// @notice Accept ETH rewards from Router when rewardToken == address(0).
    receive() external payable {}
}
