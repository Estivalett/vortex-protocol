// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

import "./VortexIntent.sol";

interface IVortexStaking {
    function isSolver(address solver) external view returns (bool);
    function distributeRevenue(uint256 amount) external;
}

/**
 * @title VortexRouter — Cross-Chain Intent Router with Competitive Solver Auction
 * @notice Core protocol contract. Users submit signed intents describing a desired
 *         cross-chain swap; registered solvers compete to fill them by offering the
 *         best output. The solver that calls fillIntent() first with an output meeting
 *         or exceeding minOutput wins the auction and executes the trade.
 *
 * Fee model (0.05% of inputAmount):
 *   - 70% → VortexStaking (distributed proportionally to stakers)
 *   - 20% → Treasury
 *   - 10% → Operations wallet
 *
 * Security:
 *   - ReentrancyGuard on all state-mutating external functions.
 *   - Checks-Effects-Interactions pattern throughout.
 *   - EIP-712 signature validation on every intent submission.
 */
contract VortexRouter is VortexIntent, ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Constants
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Protocol fee in basis points (0.05% = 5 bps).
    uint256 public constant FEE_BPS = 5;

    /// @notice Basis-point denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    /// @notice FIX VTX-06: Minimum input amount to prevent fee evasion via dust amounts.
    ///         At 5 bps, inputs below 20_000 wei produce a zero fee due to integer division.
    uint256 public constant MIN_INPUT_AMOUNT = 20_000;

    /// @notice FIX VTX-07: Maximum allowed deadline offset from block.timestamp (7 days).
    ///         Prevents perpetual intents that lock user funds indefinitely.
    uint256 public constant MAX_DEADLINE_OFFSET = 7 days;

    /// @notice Staking contract receives 70% of collected fees.
    uint256 public constant STAKING_SHARE_BPS = 7_000;

    /// @notice Treasury receives 20% of collected fees.
    uint256 public constant TREASURY_SHARE_BPS = 2_000;

    /// @notice Operations wallet receives 10% of collected fees.
    uint256 public constant OPS_SHARE_BPS = 1_000;

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice VortexStaking contract — validates solvers and receives staker fees.
    IVortexStaking public staking;

    /// @notice Treasury address — receives 20% of fees.
    address public treasury;

    /// @notice Operations address — receives 10% of fees.
    address public opsWallet;

    /// @notice Whether the protocol is paused (emergency stop).
    bool public paused;

    /// @notice FIX VTX-02: Cross-chain routing disabled by default.
    ///         True cross-chain delivery cannot be verified on-chain without a messaging
    ///         layer (LayerZero, Wormhole, etc.). Until that proof mechanism is integrated,
    ///         only same-chain intents are permitted (sourceChain == destChain).
    ///         Owner (governance) can enable cross-chain when proof infrastructure is ready.
    bool public crossChainEnabled;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event StakingSet(address indexed staking);
    event TreasurySet(address indexed treasury);
    event OpsWalletSet(address indexed opsWallet);
    event ProtocolPaused(bool paused);
    event CrossChainEnabled(bool enabled);
    event FeeDistributed(
        bytes32 indexed intentHash,
        uint256 totalFee,
        uint256 stakingPortion,
        uint256 treasuryPortion,
        uint256 opsPortion
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier whenNotPaused() {
        require(!paused, "VortexRouter: paused");
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @param _staking    Address of the VortexStaking contract.
     * @param _treasury   Address of the VortexTreasury contract.
     * @param _opsWallet  Address of the operations multisig.
     * @param _owner      Initial owner — transferred to Timelock post-deploy.
     */
    constructor(
        address _staking,
        address _treasury,
        address _opsWallet,
        address _owner
    )
        VortexIntent("VortexRouter", "1")
        Ownable(_owner)
    {
        require(_staking   != address(0), "VortexRouter: zero staking");
        require(_treasury  != address(0), "VortexRouter: zero treasury");
        require(_opsWallet != address(0), "VortexRouter: zero opsWallet");

        staking   = IVortexStaking(_staking);
        treasury  = _treasury;
        opsWallet = _opsWallet;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Updates the staking contract address.
     * @param _staking New staking contract address.
     */
    function setStaking(address _staking) external onlyOwner {
        require(_staking != address(0), "VortexRouter: zero address");
        staking = IVortexStaking(_staking);
        emit StakingSet(_staking);
    }

    /**
     * @notice Updates the treasury address.
     * @param _treasury New treasury address.
     */
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "VortexRouter: zero address");
        treasury = _treasury;
        emit TreasurySet(_treasury);
    }

    /**
     * @notice Updates the operations wallet address.
     * @param _opsWallet New operations wallet address.
     */
    function setOpsWallet(address _opsWallet) external onlyOwner {
        require(_opsWallet != address(0), "VortexRouter: zero address");
        opsWallet = _opsWallet;
        emit OpsWalletSet(_opsWallet);
    }

    /**
     * @notice Pauses or unpauses the protocol.
     * @param _paused True to pause, false to unpause.
     */
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit ProtocolPaused(_paused);
    }

    /**
     * @notice Enables or disables cross-chain routing (sourceChain != destChain).
     * @dev    FIX VTX-02: Cross-chain delivery cannot be verified on-chain in the current
     *         architecture. Enable only after integrating a cross-chain messaging proof layer.
     * @param _enabled True to allow cross-chain intents, false to restrict to same-chain.
     */
    function setCrossChainEnabled(bool _enabled) external onlyOwner {
        crossChainEnabled = _enabled;
        emit CrossChainEnabled(_enabled);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Core Intent Lifecycle
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Submits a signed intent to the protocol.
     * @dev    Validates the EIP-712 signature against `msg.sender`, then records the
     *         intent and pulls inputAmount of inputToken from the user.
     *         The user must approve this contract before calling.
     *
     * @param inputToken  Token the user is providing.
     * @param outputToken Token the user wants to receive.
     * @param inputAmount Amount of inputToken to lock in this contract.
     * @param minOutput   Minimum acceptable output amount (slippage floor).
     * @param sourceChain Chain ID where this intent originates.
     * @param destChain   Chain ID where the output should be delivered.
     * @param deadline    Unix timestamp after which the intent expires.
     * @param signature   EIP-712 signature over the intent struct by `msg.sender`.
     * @return intentHash The unique identifier for this intent.
     */
    function submitIntent(
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 minOutput,
        uint256 sourceChain,
        uint256 destChain,
        uint256 deadline,
        bytes calldata signature
    )
        external
        nonReentrant
        whenNotPaused
        returns (bytes32 intentHash)
    {
        // ── Checks ───────────────────────────────────────────────────────────
        require(inputToken  != address(0),                            "VortexRouter: zero inputToken");
        require(outputToken != address(0),                            "VortexRouter: zero outputToken");
        // FIX VTX-06: enforce minimum to prevent dust fee evasion
        require(inputAmount >= MIN_INPUT_AMOUNT,                      "VortexRouter: inputAmount below minimum");
        require(minOutput    > 0,                                     "VortexRouter: zero minOutput");
        // FIX VTX-07: enforce maximum deadline to prevent perpetual intent lock-up
        require(deadline > block.timestamp,                           "VortexRouter: deadline in past");
        require(deadline <= block.timestamp + MAX_DEADLINE_OFFSET,    "VortexRouter: deadline too far");
        // FIX VTX-02: same-chain only until cross-chain proof layer is integrated
        if (!crossChainEnabled) {
            require(sourceChain == destChain, "VortexRouter: cross-chain not enabled");
        }

        uint256 currentNonce = nonces[msg.sender];

        intentHash = _hashIntent(
            msg.sender,
            inputToken,
            outputToken,
            inputAmount,
            minOutput,
            sourceChain,
            destChain,
            deadline,
            currentNonce
        );

        address signer = _recoverSigner(intentHash, signature);
        require(signer == msg.sender, "VortexRouter: invalid signature");
        require(intents[intentHash].user == address(0), "VortexRouter: intent exists");

        // ── Effects ──────────────────────────────────────────────────────────
        nonces[msg.sender] = currentNonce + 1;

        intents[intentHash] = Intent({
            user:        msg.sender,
            solver:      address(0),
            inputToken:  inputToken,
            outputToken: outputToken,
            inputAmount: inputAmount,
            minOutput:   minOutput,
            sourceChain: sourceChain,
            destChain:   destChain,
            deadline:    deadline,
            nonce:       currentNonce,
            status:      IntentStatus.PENDING
        });

        emit IntentCreated(
            intentHash,
            msg.sender,
            inputToken,
            outputToken,
            inputAmount,
            minOutput,
            sourceChain,
            destChain,
            deadline,
            currentNonce
        );

        // ── Interactions ─────────────────────────────────────────────────────
        IERC20(inputToken).safeTransferFrom(msg.sender, address(this), inputAmount);
    }

    /**
     * @notice Fills a pending intent. The calling solver must be registered in VortexStaking
     *         and must deliver at least `intent.minOutput` of outputToken to the user.
     * @dev    The solver should have pre-approved this contract for `actualOutput` of
     *         outputToken. Protocol fee is deducted from inputAmount before the remainder
     *         is sent to the solver as compensation for the cross-chain leg.
     *
     * @param intentHash   Hash of the intent to fill.
     * @param actualOutput Actual output amount the solver is delivering to the user.
     *                     Must be >= intent.minOutput.
     */
    function fillIntent(bytes32 intentHash, uint256 actualOutput)
        external
        nonReentrant
        whenNotPaused
    {
        // ── Checks ───────────────────────────────────────────────────────────
        Intent storage intent = intents[intentHash];

        require(intent.user   != address(0),           "VortexRouter: unknown intent");
        require(intent.status == IntentStatus.PENDING,  "VortexRouter: not pending");
        require(block.timestamp <= intent.deadline,     "VortexRouter: intent expired");
        require(actualOutput >= intent.minOutput,       "VortexRouter: output below min");
        require(staking.isSolver(msg.sender),           "VortexRouter: not a registered solver");

        // ── Fee Calculation ──────────────────────────────────────────────────
        uint256 fee          = (intent.inputAmount * FEE_BPS) / BPS_DENOMINATOR;
        uint256 netInput     = intent.inputAmount - fee;

        uint256 stakingPortion  = (fee * STAKING_SHARE_BPS)  / BPS_DENOMINATOR;
        uint256 treasuryPortion = (fee * TREASURY_SHARE_BPS) / BPS_DENOMINATOR;
        uint256 opsPortion      = fee - stakingPortion - treasuryPortion;

        // ── Effects ──────────────────────────────────────────────────────────
        intent.status = IntentStatus.FILLED;
        intent.solver = msg.sender;

        emit IntentFilled(intentHash, msg.sender, intent.user, actualOutput, fee);
        emit FeeDistributed(intentHash, fee, stakingPortion, treasuryPortion, opsPortion);

        // ── Interactions (Checks-Effects-Interactions) ────────────────────────

        // 1. Solver delivers outputToken to the user
        IERC20(intent.outputToken).safeTransferFrom(msg.sender, intent.user, actualOutput);

        // 2. Transfer net inputToken to solver (compensation for cross-chain leg)
        IERC20(intent.inputToken).safeTransfer(msg.sender, netInput);

        // 3. Distribute fee: treasury & ops first (simple transfers)
        IERC20(intent.inputToken).safeTransfer(treasury,  treasuryPortion);
        IERC20(intent.inputToken).safeTransfer(opsWallet, opsPortion);

        // 4. Forward staking portion to staking contract, then notify
        IERC20(intent.inputToken).safeTransfer(address(staking), stakingPortion);
        staking.distributeRevenue(stakingPortion);
    }

    /**
     * @notice Cancels a pending intent and returns the inputAmount to the user.
     * @dev    Only the intent creator can cancel. The intent must still be PENDING.
     * @param intentHash Hash of the intent to cancel.
     */
    function cancelIntent(bytes32 intentHash) external nonReentrant {
        // ── Checks ───────────────────────────────────────────────────────────
        Intent storage intent = intents[intentHash];

        require(intent.user   == msg.sender,           "VortexRouter: not intent owner");
        require(intent.status == IntentStatus.PENDING,  "VortexRouter: not pending");

        // ── Effects ──────────────────────────────────────────────────────────
        intent.status = IntentStatus.CANCELLED;
        emit IntentCancelled(intentHash, msg.sender);

        // ── Interactions ─────────────────────────────────────────────────────
        IERC20(intent.inputToken).safeTransfer(msg.sender, intent.inputAmount);
    }

    /**
     * @notice Marks an expired intent as EXPIRED and returns inputAmount to the user.
     * @dev    Anyone can call this to clean up an expired intent, but funds always
     *         return to the original user.
     * @param intentHash Hash of the intent to expire.
     */
    function expireIntent(bytes32 intentHash) external nonReentrant {
        Intent storage intent = intents[intentHash];

        require(intent.user   != address(0),           "VortexRouter: unknown intent");
        require(intent.status == IntentStatus.PENDING,  "VortexRouter: not pending");
        require(block.timestamp > intent.deadline,      "VortexRouter: not yet expired");

        // ── Effects ──────────────────────────────────────────────────────────
        intent.status = IntentStatus.EXPIRED;
        emit IntentExpired(intentHash, intent.user);

        // ── Interactions ─────────────────────────────────────────────────────
        IERC20(intent.inputToken).safeTransfer(intent.user, intent.inputAmount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns the full Intent struct for a given hash.
     * @param intentHash Hash of the intent to look up.
     * @return The stored Intent struct.
     */
    function getIntent(bytes32 intentHash) external view returns (Intent memory) {
        return intents[intentHash];
    }

    /**
     * @notice Returns the current nonce for `user`.
     * @param user Address to query.
     */
    function getUserNonce(address user) external view returns (uint256) {
        return nonces[user];
    }

    /**
     * @notice Computes the protocol fee for a given input amount.
     * @param inputAmount Amount to calculate fee on.
     * @return fee The fee amount in the same units as inputAmount.
     */
    function computeFee(uint256 inputAmount) external pure returns (uint256 fee) {
        fee = (inputAmount * FEE_BPS) / BPS_DENOMINATOR;
    }
}
