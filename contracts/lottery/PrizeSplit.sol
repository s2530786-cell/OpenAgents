// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PrizeSplit
/// @notice Distributes prize pool among multiple winners with configurable shares
/// @dev Winners claim their share after the admin finalizes the round.
///      Uses pull pattern: each winner calls claim() individually.
///      Added 90-day deadline + treasury reclaim for unclaimed prizes.
contract PrizeSplit {
    struct Round {
        address[] winners;
        uint256 prizePool;
        uint256 finalizedAt;
        bool finalized;
        mapping(address => uint256) shares;
        mapping(address => bool) claimed;
    }

    address public admin;
    uint256 public totalPrize;
    uint256 public roundId;

    mapping(uint256 => Round) internal rounds;

    uint256 public constant CLAIM_DEADLINE = 90 days;
    address public treasury;

    event RoundFunded(uint256 indexed roundId, uint256 amount);
    event RoundFinalized(uint256 indexed roundId, uint256 winnerCount);
    event PrizeClaimed(address indexed winner, uint256 amount, uint256 indexed roundId);
    event PrizeReclaimed(uint256 indexed roundId, uint256 amount);
    event TreasurySet(address indexed oldTreasury, address indexed newTreasury);

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    constructor(address _treasury) {
        admin = msg.sender;
        treasury = _treasury;
    }

    function setTreasury(address _treasury) external onlyAdmin {
        emit TreasurySet(treasury, _treasury);
        treasury = _treasury;
    }

    function fundRound() external payable onlyAdmin {
        roundId++;
        rounds[roundId].prizePool = msg.value;
        totalPrize += msg.value;
        emit RoundFunded(roundId, msg.value);
    }

    function finalizeRound(uint256 _roundId, address[] calldata winners) external onlyAdmin {
        Round storage round = rounds[_roundId];
        require(!round.finalized, "Already finalized");
        require(round.prizePool > 0, "No prize pool");

        uint256 sharePerWinner = round.prizePool / winners.length;

        for (uint256 i = 0; i < winners.length; i++) {
            round.winners.push(winners[i]);
            round.shares[winners[i]] = sharePerWinner;
        }

        round.finalized = true;
        round.finalizedAt = block.timestamp;
        emit RoundFinalized(_roundId, winners.length);
    }

    // Fix: CEI pattern — set claimed flag BEFORE external call to prevent reentrancy.
    // Each winner claims individually; contract winners that reject ETH don't block others.
    function claimPrize(uint256 _roundId) external {
        Round storage round = rounds[_roundId];
        require(round.finalized, "Not finalized");
        require(round.shares[msg.sender] > 0, "No share");
        require(!round.claimed[msg.sender], "Already claimed");

        uint256 amount = round.shares[msg.sender];

        // CEI: update state BEFORE external call
        round.claimed[msg.sender] = true;

        (bool sent, ) = msg.sender.call{value: amount}("");
        require(sent, "PrizeSplit: ETH transfer failed");

        emit PrizeClaimed(msg.sender, amount, _roundId);
    }

    /// @notice Reclaim unclaimed prizes after the 90-day deadline.
    function reclaimExpired(uint256 _roundId) external {
        Round storage round = rounds[_roundId];
        require(round.finalized, "Not finalized");
        require(block.timestamp >= round.finalizedAt + CLAIM_DEADLINE, "Deadline not passed");

        uint256 unclaimed = 0;
        for (uint256 i = 0; i < round.winners.length; i++) {
            address winner = round.winners[i];
            if (!round.claimed[winner]) {
                unclaimed += round.shares[winner];
                round.claimed[winner] = true;
            }
        }
        require(unclaimed > 0, "Nothing to reclaim");

        (bool sent, ) = treasury.call{value: unclaimed}("");
        require(sent, "PrizeSplit: reclaim transfer failed");

        emit PrizeReclaimed(_roundId, unclaimed);
    }

    function getShare(uint256 _roundId, address winner) external view returns (uint256) {
        return rounds[_roundId].shares[winner];
    }

    function isClaimed(uint256 _roundId, address winner) external view returns (bool) {
        return rounds[_roundId].claimed[winner];
    }
}
