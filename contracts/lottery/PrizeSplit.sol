// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PrizeSplit - Pull-based Claim Pattern
/// @notice Distributes prize pool among multiple winners. Winners claim individually.
/// @dev Pull pattern: claimable amounts stored in mapping, not pushed on finalization.
///      Failed claims (contracts without receive()) don't block other winners.
///      Unclaimed prizes can be reclaimed by admin after 90-day deadline.
contract PrizeSplit {
    address public admin;
    uint256 public totalPrize;
    uint256 public roundId;

    struct Round {
        address[] winners;
        uint256 prizePool;
        bool finalized;
        uint256 deadline; // timestamp: finalizedAt + 90 days
        mapping(address => uint256) shares;
        mapping(address => bool) claimed;
    }

    /// @notice Claimable amounts per winner per round (pull pattern storage)
    mapping(address => mapping(uint256 => uint256)) public claimable;

    mapping(uint256 => Round) internal rounds;

    uint256 public constant DEADLINE_DURATION = 90 days;

    event RoundFunded(uint256 indexed roundId, uint256 amount);
    event RoundFinalized(uint256 indexed roundId, uint256 winnerCount);
    event PrizeClaimed(address indexed winner, uint256 amount, uint256 indexed roundId);
    event PrizeReclaimed(uint256 indexed roundId, uint256 amount);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor() {
        admin = msg.sender;
    }

    /// @notice Fund a new round
    function fundRound() external payable onlyAdmin {
        require(msg.value > 0, "No ETH sent");
        roundId++;
        rounds[roundId].prizePool = msg.value;
        totalPrize += msg.value;
        emit RoundFunded(roundId, msg.value);
    }

    /// @notice Finalize a round, assigning equal shares to all winners.
    /// @param _roundId The round ID
    /// @param winners Array of winner addresses
    function finalizeRound(uint256 _roundId, address[] calldata winners) external onlyAdmin {
        Round storage round = rounds[_roundId];
        require(!round.finalized, "Already finalized");
        require(round.prizePool > 0, "No prize pool");
        require(winners.length > 0, "No winners specified");

        uint256 sharePerWinner = round.prizePool / winners.length;

        for (uint256 i = 0; i < winners.length; i++) {
            address w = winners[i];
            require(w != address(0), "Invalid winner address");
            round.winners.push(w);
            round.shares[w] = sharePerWinner;
            // Register claimable amount for pull pattern
            claimable[w][_roundId] = sharePerWinner;
        }

        round.finalized = true;
        round.deadline = block.timestamp + DEADLINE_DURATION;

        emit RoundFinalized(_roundId, winners.length);
    }

    /// @notice Claim prize for a specific round.
    /// @dev Each winner claims individually. Failed transfers (contract w/o receive())
    ///      restore the claimable amount so the winner can retry or admin can reclaim.
    /// @param _roundId The round to claim from
    function claimPrize(uint256 _roundId) external {
        Round storage round = rounds[_roundId];
        require(round.finalized, "Round not finalized");
        require(block.timestamp < round.deadline, "Claim period expired");

        uint256 amount = claimable[msg.sender][_roundId];
        require(amount > 0, "Nothing to claim");

        // CEI: update state before external call
        claimable[msg.sender][_roundId] = 0;
        round.claimed[msg.sender] = true;

        (bool sent, ) = msg.sender.call{value: amount}("");
        if (!sent) {
            // Restore claimable on failed transfer (e.g., contract without receive())
            claimable[msg.sender][_roundId] = amount;
            round.claimed[msg.sender] = false;
            return;
        }

        emit PrizeClaimed(msg.sender, amount, _roundId);
    }

    /// @notice Reclaim unclaimed prizes after the 90-day deadline.
    /// @dev Scans all winners, sweeps unclaimed amounts to admin.
    function reclaimExpired(uint256 _roundId) external onlyAdmin {
        Round storage round = rounds[_roundId];
        require(round.finalized, "Round not finalized");
        require(block.timestamp >= round.deadline, "Deadline not reached");

        uint256 unclaimedTotal = 0;

        for (uint256 i = 0; i < round.winners.length; i++) {
            address w = round.winners[i];
            uint256 pending = claimable[w][_roundId];
            if (pending > 0) {
                unclaimedTotal += pending;
                claimable[w][_roundId] = 0;
                round.claimed[w] = true;
            }
        }

        require(unclaimedTotal > 0, "Nothing to reclaim");

        (bool sent, ) = payable(admin).call{value: unclaimedTotal}("");
        require(sent, "Reclaim transfer failed");

        emit PrizeReclaimed(_roundId, unclaimedTotal);
    }

    /// @notice Get total claimable amount for a winner across all rounds
    function getTotalClaimable(address winner) external view returns (uint256 total) {
        for (uint256 i = 1; i <= roundId; i++) {
            total += claimable[winner][i];
        }
    }

    function getShare(uint256 _roundId, address winner) external view returns (uint256) {
        return rounds[_roundId].shares[winner];
    }

    function isClaimed(uint256 _roundId, address winner) external view returns (bool) {
        return rounds[_roundId].claimed[winner];
    }

    function getWinners(uint256 _roundId) external view returns (address[] memory) {
        return rounds[_roundId].winners;
    }

    function roundDeadline(uint256 _roundId) external view returns (uint256) {
        return rounds[_roundId].deadline;
    }
}
