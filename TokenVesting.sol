// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/// @title TokenVesting
/// @notice Allows the owner to create multiple vesting schedules per user, with claim functionality, and emergency withdrawal options.
contract TokenVesting is ReentrancyGuard {
    /// @notice Structure of each vesting schedule
    struct VestingSchedule {
        uint256 totalAmount;           // Total tokens allocated
        uint256 claimedAmount;         // Amount already claimed
        uint256 unlockAtStartAmount;   // Tokens unlocked at the start (e.g., 10%)
        uint256 claimable;             // Currently claimable (mostly used for UI tracking)
        uint256 cliff;                 // Cliff time — before this, only unlockAtStart is available
        uint256 start;                 // Start of linear vesting (usually = cliff)
        uint256 end;                   // End of linear vesting
    }

    IERC20 public immutable token;           // Token being vested
    address public owner;                    // Contract owner
    address public emergencyWallet;          // Wallet to transfer unclaimed tokens in emergency

    mapping(address => VestingSchedule[]) public vestings;

    modifier onlyOwner() {
        require(msg.sender == owner, "Not authorized");
        _;
    }

    // ---------------- Events ----------------
    event Vested(address indexed beneficiary, uint256 totalAmount, uint256 unlockedNow);
    event Claimed(address indexed beneficiary, uint256 claimed);
    event EmergencyWithdrawal(address indexed user, uint256 amount, address to);
    event EmergencyWalletChanged(address from, address to);
    event OwnershipTransferred(address from, address to);

    // ---------------- Constructor ----------------
    /// @param tokenAddress ERC20 token to vest
    /// @param _emergencyWallet Wallet to hold unclaimed tokens in case of recovery
    constructor(address tokenAddress, address _emergencyWallet) {
        require(tokenAddress != address(0), "Invalid token address");
        require(_emergencyWallet != address(0), "Invalid emergency address");
        token = IERC20(tokenAddress);
        owner = msg.sender;
        emergencyWallet = _emergencyWallet;
    }

    // ---------------- Vesting Logic ----------------

    /// @notice Create a single vesting schedule
    function vest(
        address to,
        uint256 amount,
        uint256 unlockOnStartPercent,
        uint256 cliffTime,
        uint256 linearVestingEndTime
    ) external onlyOwner {
        require(to != address(0), "Zero address");
        require(amount > 0, "Amount must be > 0");
        require(unlockOnStartPercent <= 100, "Invalid unlock %");
        require(cliffTime < linearVestingEndTime, "Cliff must be before end");

        uint256 unlockedNow = (amount * unlockOnStartPercent) / 100;
        require(token.transferFrom(msg.sender, address(this), amount), "Token transfer failed");

        vestings[to].push(VestingSchedule({
            totalAmount: amount,
            claimedAmount: 0,
            unlockAtStartAmount: unlockedNow,
            claimable: unlockedNow,
            cliff: cliffTime,
            start: cliffTime,
            end: linearVestingEndTime
        }));

        emit Vested(to, amount, unlockedNow);
    }

    /// @notice Batch create multiple vesting schedules
    function vestMultiple(
        address[] calldata recipients,
        uint256[] calldata amounts,
        uint256[] calldata unlockPercents,
        uint256[] calldata cliffs,
        uint256[] calldata ends
    ) external onlyOwner {
        uint256 len = recipients.length;
        require(
            len == amounts.length &&
            len == unlockPercents.length &&
            len == cliffs.length &&
            len == ends.length,
            "Mismatched array lengths"
        );

        for (uint256 i = 0; i < len; i++) {
            address to = recipients[i];
            uint256 amount = amounts[i];
            uint256 unlockPercent = unlockPercents[i];
            uint256 cliffTime = cliffs[i];
            uint256 endTime = ends[i];

            require(to != address(0), "Zero address");
            require(amount > 0, "Amount must be > 0");
            require(unlockPercent <= 100, "Invalid unlock %");
            require(cliffTime < endTime, "Cliff must be before end");

            uint256 unlockedNow = (amount * unlockPercent) / 100;
            require(token.transferFrom(msg.sender, address(this), amount), "Transfer failed");

            vestings[to].push(VestingSchedule({
                totalAmount: amount,
                claimedAmount: 0,
                unlockAtStartAmount: unlockedNow,
                claimable: unlockedNow,
                cliff: cliffTime,
                start: cliffTime,
                end: endTime
            }));

            emit Vested(to, amount, unlockedNow);
        }
    }

    /// @notice Claim all claimable tokens from all vesting schedules
    function claim() external nonReentrant {
        VestingSchedule[] storage userVests = vestings[msg.sender];
        require(userVests.length > 0, "No vestings");

        uint256 currentTime = block.timestamp;
        uint256 totalToClaim = 0;

        for (uint256 i = 0; i < userVests.length; i++) {
            VestingSchedule storage vs = userVests[i];
            uint256 unlocked = vs.unlockAtStartAmount;

            if (currentTime < vs.cliff) {
                // Before cliff — only unlockAtStart tokens are claimable
                uint256 earlyClaimable = unlocked > vs.claimedAmount ? unlocked - vs.claimedAmount : 0;
                vs.claimedAmount += earlyClaimable;
                vs.claimable = vs.claimable >= earlyClaimable ? vs.claimable - earlyClaimable : 0;
                totalToClaim += earlyClaimable;
                continue;
            }

            if (currentTime >= vs.end) {
                // After vesting end — full amount unlocked
                uint256 remaining = vs.totalAmount - vs.claimedAmount;
                vs.claimedAmount = vs.totalAmount;
                vs.claimable = 0;
                totalToClaim += remaining;
                continue;
            }

            // During linear vesting
            uint256 linearPortion = vs.totalAmount - vs.unlockAtStartAmount;
            uint256 timeElapsed = currentTime - vs.start;
            uint256 vestingDuration = vs.end - vs.start;

            uint256 linearVested = (linearPortion * timeElapsed) / vestingDuration;
            unlocked += linearVested;

            if (unlocked > vs.totalAmount) unlocked = vs.totalAmount;

            uint256 claimableNow = unlocked > vs.claimedAmount ? unlocked - vs.claimedAmount : 0;
            vs.claimedAmount += claimableNow;
            vs.claimable = vs.claimable >= claimableNow ? vs.claimable - claimableNow : 0;
            totalToClaim += claimableNow;
        }

        require(totalToClaim > 0, "Nothing to claim");
        require(token.transfer(msg.sender, totalToClaim), "Transfer failed");

        emit Claimed(msg.sender, totalToClaim);
    }

    /// @notice View total claimable tokens for a user across all schedules
    function getClaimable(address user) public view returns (uint256 totalClaimable) {
        VestingSchedule[] memory userVests = vestings[user];
        uint256 currentTime = block.timestamp;

        for (uint256 i = 0; i < userVests.length; i++) {
            VestingSchedule memory vs = userVests[i];
            uint256 unlocked = vs.unlockAtStartAmount;

            if (currentTime < vs.cliff) {
                totalClaimable += unlocked > vs.claimedAmount ? unlocked - vs.claimedAmount : 0;
                continue;
            }

            if (currentTime >= vs.end) {
                totalClaimable += vs.totalAmount > vs.claimedAmount ? vs.totalAmount - vs.claimedAmount : 0;
                continue;
            }

            uint256 linearPortion = vs.totalAmount - vs.unlockAtStartAmount;
            uint256 timeElapsed = currentTime - vs.start;
            uint256 vestingDuration = vs.end - vs.start;

            uint256 linearVested = (linearPortion * timeElapsed) / vestingDuration;
            unlocked += linearVested;
            if (unlocked > vs.totalAmount) unlocked = vs.totalAmount;

            totalClaimable += unlocked > vs.claimedAmount ? unlocked - vs.claimedAmount : 0;
        }
    }

    // ---------------- Emergency Logic ----------------

    /// @notice Admin can withdraw all unclaimed tokens for a user to the emergency wallet
    /// @dev Useful in case user's wallet is compromised or lost
    function emergencyWithdraw(address user) external onlyOwner nonReentrant {
        VestingSchedule[] storage vests = vestings[user];
        require(vests.length > 0, "No vesting");

        uint256 totalUnclaimed = 0;
        for (uint256 i = 0; i < vests.length; i++) {
            totalUnclaimed += (vests[i].totalAmount - vests[i].claimedAmount);
        }

        delete vestings[user]; // clear vesting schedules to prevent re-claim

        require(totalUnclaimed > 0, "Nothing to withdraw");
        require(token.transfer(emergencyWallet, totalUnclaimed), "Transfer failed");

        emit EmergencyWithdrawal(user, totalUnclaimed, emergencyWallet);
    }

    /// @notice Update the emergency wallet address
    function changeEmergencyWallet(address newEmergencyWallet) external onlyOwner {
        require(newEmergencyWallet != address(0), "Invalid address");
        emit EmergencyWalletChanged(emergencyWallet, newEmergencyWallet);
        emergencyWallet = newEmergencyWallet;
    }

    // ---------------- Ownership ----------------

    /// @notice Transfer ownership to a new address
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Returns full vesting details for a user
/// @param user Address whose vesting schedules are queried
function getVestingsDetails(address user)
    external
    view
    returns (
        uint256[] memory totalAmounts,
        uint256[] memory claimedAmounts,
        uint256[] memory claimableAmounts,
        uint256[] memory unlockAtStartAmounts,
        uint256[] memory cliffs,
        uint256[] memory starts,
        uint256[] memory ends
    )
{
    VestingSchedule[] memory userVests = vestings[user];
    uint256 len = userVests.length;

    totalAmounts = new uint256[](len);
    claimedAmounts = new uint256[](len);
    claimableAmounts = new uint256[](len);
    unlockAtStartAmounts = new uint256[](len);
    cliffs = new uint256[](len);
    starts = new uint256[](len);
    ends = new uint256[](len);

    uint256 currentTime = block.timestamp;

    for (uint256 i = 0; i < len; i++) {
        VestingSchedule memory vs = userVests[i];

        totalAmounts[i] = vs.totalAmount;
        claimedAmounts[i] = vs.claimedAmount;
        unlockAtStartAmounts[i] = vs.unlockAtStartAmount;
        cliffs[i] = vs.cliff;
        starts[i] = vs.start;
        ends[i] = vs.end;

        // --- calculate real-time claimable ---
        uint256 unlocked = vs.unlockAtStartAmount;

        if (currentTime >= vs.cliff) {
            if (currentTime >= vs.end) {
                unlocked = vs.totalAmount;
            } else {
                uint256 linearPortion = vs.totalAmount - vs.unlockAtStartAmount;
                uint256 timeElapsed = currentTime - vs.start;
                uint256 vestingDuration = vs.end - vs.start;

                uint256 linearVested = (linearPortion * timeElapsed) / vestingDuration;
                unlocked += linearVested;

                if (unlocked > vs.totalAmount) {
                    unlocked = vs.totalAmount;
                }
            }
        }

        claimableAmounts[i] =
            unlocked > vs.claimedAmount
                ? unlocked - vs.claimedAmount
                : 0;
    }
}

}
