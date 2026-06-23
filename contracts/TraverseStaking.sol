// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title TraverseStaking — TRV Staking, Solver Registration & Revenue Distribution
 * @notice Allows TRV holders to stake tokens, earn a proportional share of protocol
 *         revenue (70% of all fees), and optionally register as solvers by meeting a
 *         minimum stake requirement. Registered solvers can be slashed by governance
 *         for malicious behaviour.
 *
 * Revenue accounting uses a PER-TOKEN reward-per-share accumulator so that rewards
 * can be distributed in O(1) per token, regardless of the number of stakers.
 *
 * Unstaking is subject to a 7-day cooldown to protect the protocol from stake-withdrawal
 * attacks immediately before a slash event. Crucially, queued (cooling-down) stake
 * remains slashable for the entire cooldown window.
 *
 * Security fixes applied in this revision:
 *   - TRV-09 (CRITICAL): rewards are now accrued and paid in the SAME ERC-20 token that
 *     the Router forwards (the intent's inputToken). The previous single-`rewardToken`
 *     design accrued value in the fee token but paid out in an unrelated token, which
 *     either locked rewards forever (default ETH) or drained staked principal (TRV).
 *   - TRV-10 (CRITICAL): slashing can no longer be bypassed. `slash()` no longer requires
 *     `isSolver` and reaches funds queued for withdrawal, so deregistering or unstaking
 *     just before a slash no longer protects a malicious solver.
 *   - TRV-11 (MEDIUM): fees forwarded while `totalStaked == 0` are no longer orphaned;
 *     they are carried in `undistributed[token]` and folded into the next distribution.
 */
contract TraverseStaking is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Minimum TRV stake required to register as an active solver.
    uint256 public constant SOLVER_MIN_STAKE = 10_000 * 10 ** 18;

    /// @notice Cooldown period before an unstake request can be withdrawn.
    uint256 public constant UNSTAKE_COOLDOWN = 7 days;

    /// @notice Precision multiplier for reward-per-share arithmetic.
    uint256 private constant PRECISION = 1e18;

    /// @notice Upper bound on the number of distinct reward tokens, to bound the gas
    ///         cost of per-token settlement loops.
    uint256 public constant MAX_REWARD_TOKENS = 32;

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The TRV ERC-20 token.
    IERC20 public immutable trv;

    /// @notice Address authorised to call distributeRevenue() (the Router).
    address public router;

    /// @notice Total TRV currently staked across all users (excludes cooling-down stake).
    uint256 public totalStaked;

    /// @notice List of every ERC-20 that has ever been distributed as a reward.
    address[] public rewardTokens;

    /// @notice Whether a token is already tracked in `rewardTokens`.
    mapping(address => bool) public isRewardToken;

    /// @notice Accumulated reward-per-staked-TRV-unit for each reward token (scaled by PRECISION).
    mapping(address => uint256) public rewardPerShareAccumulated;

    /// @notice Rewards forwarded while there were no stakers, carried into the next distribution.
    mapping(address => uint256) public undistributed;

    // Per-staker accounting
    struct StakeInfo {
        uint256 staked;               // TRV currently staked (earning rewards)
        bool    isSolver;             // registered as active solver
        uint256 unstakeAmount;        // amount queued for withdrawal (still slashable)
        uint256 unstakeAvailableAt;   // timestamp when cooldown ends
    }

    mapping(address => StakeInfo) public stakers;

    /// @notice Per (user, rewardToken) reward-per-share snapshot at last settlement.
    mapping(address => mapping(address => uint256)) public rewardDebt;

    /// @notice Per (user, rewardToken) unclaimed rewards accumulated so far.
    mapping(address => mapping(address => uint256)) public pendingRewardsOf;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event Staked(address indexed user, uint256 amount);
    event UnstakeQueued(address indexed user, uint256 amount, uint256 availableAt);
    event Unstaked(address indexed user, uint256 amount);
    event SolverRegistered(address indexed solver);
    event SolverDeregistered(address indexed solver);
    event SolverSlashed(address indexed solver, uint256 slashedAmount, address recipient);
    event RewardsClaimed(address indexed user, address indexed token, uint256 amount);
    event RevenueDistributed(address indexed token, uint256 amount);
    event RouterSet(address indexed router);
    event RewardTokenAdded(address indexed token);

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlyRouter() {
        require(msg.sender == router, "TraverseStaking: caller is not router");
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @param _trv   Address of the TRV token contract.
     * @param _owner Initial owner (will be transferred to Timelock post-deploy).
     */
    constructor(address _trv, address _owner) Ownable(_owner) {
        require(_trv != address(0), "TraverseStaking: zero trv");
        trv = IERC20(_trv);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin Functions
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Sets the authorised router address. Called once after Router deployment.
     * @param _router Address of TraverseRouter.
     */
    function setRouter(address _router) external onlyOwner {
        require(_router != address(0), "TraverseStaking: zero router");
        router = _router;
        emit RouterSet(_router);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Staking
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Stakes `amount` TRV on behalf of the caller.
     * @dev    Caller must have approved this contract to spend at least `amount` TRV.
     * @param amount Amount of TRV to stake (18-decimal wei).
     */
    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "TraverseStaking: zero amount");
        _settleRewards(msg.sender);

        stakers[msg.sender].staked += amount;
        totalStaked += amount;

        trv.safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(msg.sender, amount);
    }

    /**
     * @notice Queues `amount` TRV for withdrawal after the 7-day cooldown.
     * @dev    Reduces the active (reward-earning) stake immediately; tokens are locked
     *         until cooldown AND remain slashable during the cooldown window.
     *         TRV-03: a new unstake cannot be queued until the previous one is withdrawn.
     * @param amount Amount of TRV to unstake.
     */
    function unstake(uint256 amount) external nonReentrant {
        StakeInfo storage info = stakers[msg.sender];
        require(amount > 0,              "TraverseStaking: zero amount");
        require(info.staked >= amount,   "TraverseStaking: insufficient stake");
        require(info.unstakeAmount == 0, "TraverseStaking: withdraw queued amount first");

        _settleRewards(msg.sender);

        info.staked -= amount;
        totalStaked -= amount;

        // Auto-deregister solver if stake drops below minimum
        if (info.isSolver && info.staked < SOLVER_MIN_STAKE) {
            info.isSolver = false;
            emit SolverDeregistered(msg.sender);
        }

        // Queue cooldown withdrawal (still slashable)
        info.unstakeAmount      = amount;
        info.unstakeAvailableAt = block.timestamp + UNSTAKE_COOLDOWN;

        emit UnstakeQueued(msg.sender, amount, info.unstakeAvailableAt);
    }

    /**
     * @notice Withdraws queued unstake amount after the cooldown period has elapsed.
     */
    function withdrawUnstaked() external nonReentrant {
        StakeInfo storage info = stakers[msg.sender];
        require(info.unstakeAmount > 0, "TraverseStaking: nothing to withdraw");
        require(block.timestamp >= info.unstakeAvailableAt, "TraverseStaking: cooldown active");

        uint256 amount = info.unstakeAmount;
        info.unstakeAmount = 0;
        info.unstakeAvailableAt = 0;

        trv.safeTransfer(msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Solver Registration
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Registers the caller as an active solver after staking the required amount.
     * @param extraStake Additional TRV to stake on top of the existing balance (may be 0).
     */
    function registerAsSolver(uint256 extraStake) external nonReentrant {
        if (extraStake > 0) {
            _settleRewards(msg.sender);
            stakers[msg.sender].staked += extraStake;
            totalStaked += extraStake;
            trv.safeTransferFrom(msg.sender, address(this), extraStake);
            emit Staked(msg.sender, extraStake);
        }

        require(
            stakers[msg.sender].staked >= SOLVER_MIN_STAKE,
            "TraverseStaking: insufficient stake for solver"
        );
        require(!stakers[msg.sender].isSolver, "TraverseStaking: already a solver");

        stakers[msg.sender].isSolver = true;
        emit SolverRegistered(msg.sender);
    }

    /**
     * @notice Voluntarily deregisters the caller as a solver.
     * @dev    Deregistering does NOT exempt staked or cooling-down funds from slashing.
     */
    function deregisterAsSolver() external {
        require(stakers[msg.sender].isSolver, "TraverseStaking: not a solver");
        stakers[msg.sender].isSolver = false;
        emit SolverDeregistered(msg.sender);
    }

    /**
     * @notice Returns whether `solver` is currently registered as an active solver.
     */
    function isSolver(address solver) external view returns (bool) {
        return stakers[solver].isSolver;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Slashing (Governance / Owner only)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Slashes a misbehaving solver's stake, including funds in the unstake cooldown.
     * @dev    TRV-10: No `isSolver` gate and reaches `unstakeAmount`, so a solver cannot
     *         dodge a slash by deregistering or unstaking. Active stake is consumed first,
     *         then cooling-down stake. Only callable by the owner (Timelock / governance).
     * @param solver    Address of the solver to slash.
     * @param amount    Amount of TRV to seize (from active + cooling-down stake).
     * @param recipient Address that receives the slashed TRV (e.g., insurance fund).
     */
    function slash(address solver, uint256 amount, address recipient) external onlyOwner {
        require(recipient != address(0), "TraverseStaking: zero recipient");
        require(amount > 0,              "TraverseStaking: zero amount");

        StakeInfo storage info = stakers[solver];
        uint256 slashable = info.staked + info.unstakeAmount;
        require(slashable >= amount, "TraverseStaking: slash exceeds total stake");

        _settleRewards(solver);

        // Consume active (reward-earning) stake first.
        uint256 fromActive = amount <= info.staked ? amount : info.staked;
        if (fromActive > 0) {
            info.staked -= fromActive;
            totalStaked -= fromActive;
        }

        // Then consume cooling-down stake (not part of totalStaked).
        uint256 remaining = amount - fromActive;
        if (remaining > 0) {
            info.unstakeAmount -= remaining;
            if (info.unstakeAmount == 0) {
                info.unstakeAvailableAt = 0;
            }
        }

        if (info.isSolver && info.staked < SOLVER_MIN_STAKE) {
            info.isSolver = false;
            emit SolverDeregistered(solver);
        }

        trv.safeTransfer(recipient, amount);
        emit SolverSlashed(solver, amount, recipient);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Rewards
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Distributes protocol revenue (in `token`) to stakers by advancing the
     *         per-token reward-per-share accumulator. Called exclusively by the Router.
     * @dev    TRV-01: the Router already applies STAKING_SHARE_BPS (70%) before forwarding,
     *         so `amount` is distributed in full.
     *         TRV-09: rewards accrue in the exact token forwarded and are later paid in
     *         that same token — no cross-token mismatch.
     *         TRV-11: if there are no stakers yet, the amount is carried in `undistributed`
     *         and folded into the next distribution instead of being orphaned.
     * @param token  ERC-20 fee token forwarded by the Router (the intent's inputToken).
     * @param amount The staker portion of the fee (already 70% of gross fee).
     */
    function distributeRevenue(address token, uint256 amount) external onlyRouter {
        require(token != address(0), "TraverseStaking: zero token");
        if (amount == 0) return;

        if (!isRewardToken[token]) {
            require(rewardTokens.length < MAX_REWARD_TOKENS, "TraverseStaking: too many reward tokens");
            isRewardToken[token] = true;
            rewardTokens.push(token);
            emit RewardTokenAdded(token);
        }

        if (totalStaked == 0) {
            undistributed[token] += amount;
            return;
        }

        uint256 total = amount + undistributed[token];
        undistributed[token] = 0;

        rewardPerShareAccumulated[token] += (total * PRECISION) / totalStaked;
        emit RevenueDistributed(token, total);
    }

    /**
     * @notice Claims all accrued rewards (across every reward token) for the caller.
     */
    function claimRewards() external nonReentrant {
        _settleRewards(msg.sender);

        uint256 len = rewardTokens.length;
        uint256 claimedAny;
        for (uint256 i = 0; i < len; i++) {
            address token = rewardTokens[i];
            uint256 pending = pendingRewardsOf[msg.sender][token];
            if (pending > 0) {
                pendingRewardsOf[msg.sender][token] = 0;
                claimedAny += pending;
                IERC20(token).safeTransfer(msg.sender, pending);
                emit RewardsClaimed(msg.sender, token, pending);
            }
        }
        require(claimedAny > 0, "TraverseStaking: no rewards");
    }

    /**
     * @notice Returns the unclaimed reward balance of `user` for a specific `token`.
     */
    function pendingRewards(address user, address token) external view returns (uint256) {
        StakeInfo storage info = stakers[user];
        uint256 unsettled = (info.staked *
            (rewardPerShareAccumulated[token] - rewardDebt[user][token])) / PRECISION;
        return pendingRewardsOf[user][token] + unsettled;
    }

    /**
     * @notice Returns the full list of reward tokens ever distributed.
     */
    function getRewardTokens() external view returns (address[] memory) {
        return rewardTokens;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @dev Snaps pending rewards for `user` across all reward tokens and updates debts.
     */
    function _settleRewards(address user) internal {
        uint256 staked = stakers[user].staked;
        uint256 len = rewardTokens.length;
        for (uint256 i = 0; i < len; i++) {
            address token = rewardTokens[i];
            uint256 acc = rewardPerShareAccumulated[token];
            if (staked > 0) {
                uint256 earned = (staked * (acc - rewardDebt[user][token])) / PRECISION;
                if (earned > 0) {
                    pendingRewardsOf[user][token] += earned;
                }
            }
            rewardDebt[user][token] = acc;
        }
    }
}
