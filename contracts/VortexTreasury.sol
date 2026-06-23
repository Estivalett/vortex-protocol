// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title VortexTreasury — Protocol Treasury
 * @notice Receives 20% of all protocol fees and holds them under governance control.
 *         Only the owner (VortexTimelock, i.e. governance) can withdraw funds.
 *         Tracks per-token balances for transparency.
 *
 * Revenue flow:
 *   VortexRouter → VortexTreasury (20% of 0.05% fee on each filled intent)
 *
 * Governance can withdraw ETH or any ERC-20 to an arbitrary recipient for grants,
 * buybacks, or operational expenses voted on through VortexGovernor.
 */
contract VortexTreasury is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Tracks the total ERC-20 amount deposited per token address.
    /// @dev    Native ETH deposits are tracked via address(0).
    mapping(address => uint256) public totalReceived;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Emitted when ETH is received.
     * @param sender The address that sent ETH.
     * @param amount Amount of ETH received (wei).
     */
    event EthReceived(address indexed sender, uint256 amount);

    /**
     * @notice Emitted when an ERC-20 token is received via a direct transfer.
     * @param token  ERC-20 token address.
     * @param sender Address that triggered the accounting update.
     * @param amount Amount of tokens recorded.
     */
    event TokenReceived(address indexed token, address indexed sender, uint256 amount);

    /**
     * @notice Emitted when governance withdraws native ETH.
     * @param recipient Destination address.
     * @param amount    Amount of ETH withdrawn (wei).
     */
    event EthWithdrawn(address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when governance withdraws an ERC-20 token.
     * @param token     ERC-20 token address.
     * @param recipient Destination address.
     * @param amount    Amount of tokens withdrawn.
     */
    event TokenWithdrawn(address indexed token, address indexed recipient, uint256 amount);

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @param _owner Initial owner — should be transferred to VortexTimelock
     *               immediately after Governor deployment so that all withdrawals
     *               require a governance vote.
     */
    constructor(address _owner) Ownable(_owner) {
        require(_owner != address(0), "VortexTreasury: zero owner");
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Receive / Fallback
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Accepts native ETH deposits (e.g. from Router fee distribution).
    receive() external payable {
        totalReceived[address(0)] += msg.value;
        emit EthReceived(msg.sender, msg.value);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Accounting Helper
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Records that `amount` of `token` has been transferred to this contract.
     * @dev    FIX VTX-04: Restricted to onlyOwner (previously public, allowing anyone to
     *         inflate the totalReceived counter and emit false TokenReceived events).
     * @param token  ERC-20 token address.
     * @param amount Amount to record.
     */
    function recordDeposit(address token, uint256 amount) external onlyOwner {
        require(token != address(0), "VortexTreasury: use receive() for ETH");
        totalReceived[token] += amount;
        emit TokenReceived(token, msg.sender, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Governance Withdrawals
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Withdraws `amount` of native ETH to `recipient`.
     * @dev    Only callable by the owner (VortexTimelock via governance vote).
     * @param recipient Destination address for the ETH.
     * @param amount    Amount of ETH to send (wei). Must be <= address(this).balance.
     */
    function withdraw(address payable recipient, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(recipient != address(0), "VortexTreasury: zero recipient");
        require(amount > 0,              "VortexTreasury: zero amount");
        require(address(this).balance >= amount, "VortexTreasury: insufficient ETH");

        // FIX VTX-08: keep totalReceived in sync with actual outflows
        if (totalReceived[address(0)] >= amount) {
            totalReceived[address(0)] -= amount;
        } else {
            totalReceived[address(0)] = 0;
        }

        emit EthWithdrawn(recipient, amount);

        (bool ok, ) = recipient.call{value: amount}("");
        require(ok, "VortexTreasury: ETH transfer failed");
    }

    /**
     * @notice Withdraws `amount` of ERC-20 `token` to `recipient`.
     * @dev    Only callable by the owner (VortexTimelock via governance vote).
     * @param token     ERC-20 contract address.
     * @param recipient Destination address.
     * @param amount    Amount of tokens to send.
     */
    function withdrawERC20(address token, address recipient, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        require(token     != address(0), "VortexTreasury: zero token");
        require(recipient != address(0), "VortexTreasury: zero recipient");
        require(amount > 0,              "VortexTreasury: zero amount");

        // FIX VTX-08: keep totalReceived in sync with actual outflows
        if (totalReceived[token] >= amount) {
            totalReceived[token] -= amount;
        } else {
            totalReceived[token] = 0;
        }

        emit TokenWithdrawn(token, recipient, amount);

        IERC20(token).safeTransfer(recipient, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns the current ETH balance held by the treasury.
     */
    function ethBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Returns the current ERC-20 balance held by the treasury for a given token.
     * @param token ERC-20 contract address.
     */
    function tokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }
}
