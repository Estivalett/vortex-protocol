// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title VortexVesting — VTX Token Vesting with Cliff + Linear Schedule
 * @notice Manages token vesting schedules for team members, investors, and advisors.
 *         Each beneficiary has a configurable cliff period followed by linear vesting.
 *         Only the owner (deployer/governance) can create or revoke schedules.
 *
 * Vesting categories supported:
 *   - Team & Founders : 12-month cliff, 36-month linear (total 48 months)
 *   - Seed Investors  : 6-month cliff, 24-month linear (total 30 months)
 *   - Series A        : 3-month cliff, 18-month linear (total 21 months)
 *   - Advisors        : 6-month cliff, 12-month linear (total 18 months)
 *
 * Security:
 *   - ReentrancyGuard on all token-moving functions.
 *   - Revocation sends unvested tokens back to owner (treasury/multisig).
 *   - Once revoked, a schedule is permanently terminated.
 */
contract VortexVesting is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Category label for off-chain display and tooling.
    enum Category { TEAM, SEED, SERIES_A, ADVISOR, CUSTOM }

    struct VestingSchedule {
        address beneficiary;    // Recipient of vested tokens
        uint256 totalAmount;    // Total VTX allocated under this schedule
        uint256 claimedAmount;  // VTX already claimed by beneficiary
        uint256 startTime;      // Unix timestamp when vesting begins
        uint256 cliffDuration;  // Seconds from startTime before any tokens vest
        uint256 vestingDuration;// Total vesting period in seconds (including cliff)
        Category category;      // Label for off-chain tooling
        bool revoked;           // Whether this schedule has been revoked
    }

    // ─────────────────────────────────────────────────────────────────────────
    // State
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice VTX token contract.
    IERC20 public immutable vtx;

    /// @notice Total VTX locked across all active schedules.
    uint256 public totalLocked;

    /// @notice All vesting schedules, indexed by sequential ID.
    mapping(uint256 => VestingSchedule) public schedules;

    /// @notice All schedule IDs for a given beneficiary.
    mapping(address => uint256[]) public beneficiarySchedules;

    /// @notice Next schedule ID (auto-increments).
    uint256 public nextScheduleId;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event ScheduleCreated(
        uint256 indexed scheduleId,
        address indexed beneficiary,
        uint256 totalAmount,
        uint256 startTime,
        uint256 cliffDuration,
        uint256 vestingDuration,
        Category category
    );

    event TokensClaimed(
        uint256 indexed scheduleId,
        address indexed beneficiary,
        uint256 amount
    );

    event ScheduleRevoked(
        uint256 indexed scheduleId,
        address indexed beneficiary,
        uint256 unvestedReturned
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @param _vtx   Address of the VTX ERC-20 token.
     * @param _owner Deployer / multisig that manages schedules.
     */
    constructor(address _vtx, address _owner) Ownable(_owner) {
        require(_vtx != address(0), "VortexVesting: zero vtx");
        vtx = IERC20(_vtx);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Admin — Schedule Management
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Creates a new vesting schedule for `beneficiary`.
     * @dev    The caller must have approved this contract for `totalAmount` VTX
     *         before calling. Tokens are pulled from the caller (owner/treasury).
     *
     * @param beneficiary     Recipient address.
     * @param totalAmount     Total VTX to vest (18-decimal wei).
     * @param startTime       Unix timestamp when vesting begins (can be in the past for retroactive).
     * @param cliffDuration   Seconds from startTime before first tokens unlock.
     * @param vestingDuration Total duration of the vesting schedule in seconds.
     * @param category        Label for the schedule type.
     * @return scheduleId     ID of the newly created schedule.
     */
    function createSchedule(
        address  beneficiary,
        uint256  totalAmount,
        uint256  startTime,
        uint256  cliffDuration,
        uint256  vestingDuration,
        Category category
    ) external onlyOwner nonReentrant returns (uint256 scheduleId) {
        require(beneficiary    != address(0),          "VortexVesting: zero beneficiary");
        require(totalAmount     > 0,                   "VortexVesting: zero amount");
        require(vestingDuration > 0,                   "VortexVesting: zero duration");
        require(cliffDuration  <= vestingDuration,     "VortexVesting: cliff > vesting");

        scheduleId = nextScheduleId++;

        schedules[scheduleId] = VestingSchedule({
            beneficiary:     beneficiary,
            totalAmount:     totalAmount,
            claimedAmount:   0,
            startTime:       startTime,
            cliffDuration:   cliffDuration,
            vestingDuration: vestingDuration,
            category:        category,
            revoked:         false
        });

        beneficiarySchedules[beneficiary].push(scheduleId);
        totalLocked += totalAmount;

        // Pull tokens from owner (must be pre-approved)
        vtx.safeTransferFrom(msg.sender, address(this), totalAmount);

        emit ScheduleCreated(
            scheduleId, beneficiary, totalAmount,
            startTime, cliffDuration, vestingDuration, category
        );
    }

    /**
     * @notice Batch creates multiple vesting schedules in one transaction.
     * @dev    Saves gas and simplifies the initial token distribution ceremony.
     */
    function createScheduleBatch(
        address[]  calldata beneficiaries,
        uint256[]  calldata totalAmounts,
        uint256[]  calldata startTimes,
        uint256[]  calldata cliffDurations,
        uint256[]  calldata vestingDurations,
        Category[] calldata categories
    ) external onlyOwner nonReentrant returns (uint256[] memory scheduleIds) {
        uint256 n = beneficiaries.length;
        require(
            n == totalAmounts.length &&
            n == startTimes.length   &&
            n == cliffDurations.length &&
            n == vestingDurations.length &&
            n == categories.length,
            "VortexVesting: length mismatch"
        );

        scheduleIds = new uint256[](n);
        uint256 totalPull;

        for (uint256 i = 0; i < n; i++) {
            require(beneficiaries[i]   != address(0),                "VortexVesting: zero beneficiary");
            require(totalAmounts[i]     > 0,                         "VortexVesting: zero amount");
            require(vestingDurations[i] > 0,                         "VortexVesting: zero duration");
            require(cliffDurations[i]  <= vestingDurations[i],       "VortexVesting: cliff > vesting");

            uint256 sid = nextScheduleId++;
            schedules[sid] = VestingSchedule({
                beneficiary:     beneficiaries[i],
                totalAmount:     totalAmounts[i],
                claimedAmount:   0,
                startTime:       startTimes[i],
                cliffDuration:   cliffDurations[i],
                vestingDuration: vestingDurations[i],
                category:        categories[i],
                revoked:         false
            });
            beneficiarySchedules[beneficiaries[i]].push(sid);
            scheduleIds[i] = sid;
            totalPull += totalAmounts[i];

            emit ScheduleCreated(
                sid, beneficiaries[i], totalAmounts[i],
                startTimes[i], cliffDurations[i], vestingDurations[i], categories[i]
            );
        }

        totalLocked += totalPull;
        vtx.safeTransferFrom(msg.sender, address(this), totalPull);
    }

    /**
     * @notice Permanently revokes a vesting schedule.
     * @dev    Vested-but-unclaimed tokens remain claimable by the beneficiary.
     *         Unvested tokens are returned to the owner (treasury/multisig).
     * @param scheduleId ID of the schedule to revoke.
     */
    function revokeSchedule(uint256 scheduleId) external onlyOwner nonReentrant {
        VestingSchedule storage s = schedules[scheduleId];
        require(s.beneficiary != address(0), "VortexVesting: unknown schedule");
        require(!s.revoked,                  "VortexVesting: already revoked");

        s.revoked = true;

        uint256 vested    = _vestedAmount(s);
        uint256 unclaimed = vested - s.claimedAmount;
        uint256 unvested  = s.totalAmount - vested;

        totalLocked -= unvested;

        // Unvested portion returns to owner
        if (unvested > 0) {
            vtx.safeTransfer(owner(), unvested);
        }

        emit ScheduleRevoked(scheduleId, s.beneficiary, unvested);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Beneficiary — Claim
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Claims all available vested tokens for a specific schedule.
     * @dev    Anyone can call on behalf of the beneficiary (tokens always go to beneficiary).
     * @param scheduleId ID of the schedule to claim from.
     */
    function claim(uint256 scheduleId) external nonReentrant {
        VestingSchedule storage s = schedules[scheduleId];
        require(s.beneficiary != address(0), "VortexVesting: unknown schedule");

        uint256 claimable = _claimableAmount(s);
        require(claimable > 0, "VortexVesting: nothing to claim");

        s.claimedAmount += claimable;
        totalLocked     -= claimable;

        vtx.safeTransfer(s.beneficiary, claimable);
        emit TokensClaimed(scheduleId, s.beneficiary, claimable);
    }

    /**
     * @notice Claims from all schedules belonging to the caller in one transaction.
     */
    function claimAll() external nonReentrant {
        uint256[] storage ids = beneficiarySchedules[msg.sender];
        uint256 totalClaim;

        for (uint256 i = 0; i < ids.length; i++) {
            VestingSchedule storage s = schedules[ids[i]];
            uint256 claimable = _claimableAmount(s);
            if (claimable > 0) {
                s.claimedAmount += claimable;
                totalLocked     -= claimable;
                totalClaim      += claimable;
                emit TokensClaimed(ids[i], msg.sender, claimable);
            }
        }

        require(totalClaim > 0, "VortexVesting: nothing to claim");
        vtx.safeTransfer(msg.sender, totalClaim);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // View Helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns the amount of VTX claimable right now for a schedule.
     * @param scheduleId Schedule to query.
     */
    function claimableAmount(uint256 scheduleId) external view returns (uint256) {
        return _claimableAmount(schedules[scheduleId]);
    }

    /**
     * @notice Returns total vested amount (claimed + claimable) at the current timestamp.
     * @param scheduleId Schedule to query.
     */
    function vestedAmount(uint256 scheduleId) external view returns (uint256) {
        return _vestedAmount(schedules[scheduleId]);
    }

    /**
     * @notice Returns all schedule IDs for a beneficiary.
     */
    function getScheduleIds(address beneficiary) external view returns (uint256[] memory) {
        return beneficiarySchedules[beneficiary];
    }

    /**
     * @notice Returns full schedule details.
     */
    function getSchedule(uint256 scheduleId) external view returns (VestingSchedule memory) {
        return schedules[scheduleId];
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal
    // ─────────────────────────────────────────────────────────────────────────

    function _vestedAmount(VestingSchedule storage s) internal view returns (uint256) {
        if (block.timestamp < s.startTime + s.cliffDuration) {
            return 0; // still in cliff
        }
        if (block.timestamp >= s.startTime + s.vestingDuration) {
            return s.totalAmount; // fully vested
        }
        // Linear vesting between cliff end and vesting end
        uint256 elapsed = block.timestamp - s.startTime;
        return (s.totalAmount * elapsed) / s.vestingDuration;
    }

    function _claimableAmount(VestingSchedule storage s) internal view returns (uint256) {
        if (s.revoked) {
            // After revocation, only already-vested tokens remain claimable
            uint256 vested = _vestedAmount(s);
            return vested > s.claimedAmount ? vested - s.claimedAmount : 0;
        }
        return _vestedAmount(s) - s.claimedAmount;
    }
}
